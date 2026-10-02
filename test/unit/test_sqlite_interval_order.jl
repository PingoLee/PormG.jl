"""
Ordering and comparing a SQLite interval's VALUE by its milliseconds (#894).

On SQLite an interval leaves a query as the `[-]HH:MM:SS[.f]` text a `DurationField` stores — a
projected timestamp difference since #814, and every `DurationField` column always. #881 made each
comparison INSIDE an expression numeric, but everything that sorts or compares the projected value
itself still saw only that text, and text order is numeric order only while every value is
non-negative and under 100 hours:

| values | text order | numeric order |
|---|---|---|
| `"99:00:00"`, `"100:00:00"` | `100:00:00` first | `99:00:00` first |
| `"-01:00:00"`, `"-02:00:00"` | `-01:00:00` first | `-02:00:00` first |

PostgreSQL orders and compares the `interval` itself, so it was right on both rows, and SQLite
returned a silently wrong order or row set. #894 decided to order and compare numerically on
SQLite, wherever the value has a millisecond form:

  1. `order_by` on an interval alias — ordered by the re-rendered milliseconds, NOT by
     `_sqlite_interval_ms` over the alias name, which SQLite resolves to a same-named FROM column
     first inside an expression;
  2. a filter on an interval alias (WHERE or HAVING), the duration bound as milliseconds;
  3. `Max`/`Min` over an interval — the extremum of the milliseconds, returned as the interval text;
  4. a bare `DurationField` column ordered (`order_by("lap")`) or ordered against a duration
     (`lap__@gt`, `@range`, `F("lap") > Minute(2)`). Its equality and membership keep the canonical
     text, which is exact and stays sargable.

The decisive assertions are the in-memory SQLite oracle at the bottom: every rendered statement runs
against SQLite itself over the two pairs above, and against the unpatched renderer each one returns
the text order. The shape testsets above it pin the SQL and the bound values, and that PostgreSQL
renders byte-for-byte what it rendered before.

Everything renders through mock connections; the oracle uses an in-memory SQLite database. No live
database.

Sibling coverage:
  - `test_f_date_operands.jl` → #814/#881, interval arithmetic and comparisons inside an expression,
                                which this file's surfaces reuse (`_render_expr_typed`).
  - `test/integration/test_field_expressions.jl` → the same oracle on the F1 fixture, on both engines.

julia --project=test/integration test/unit/test_sqlite_interval_order.jl
"""

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: F, Q, Qor, inspect_query
using Dates
import PormG.QueryBuilder as QB

# Dedicated config key and mock types: `runtests.jl` includes every unit file into one `Main`.
struct IoMockSQLite <: PormG.PormGSQLite end
struct IoMockPostgres <: PormG.PormGPostgres end
struct IoMockOldSQLite <: PormG.PormGSQLite end   # before 3.30: no NULLS FIRST/LAST syntax
const _IO_SL = IoMockSQLite()
const _IO_PG = IoMockPostgres()
const _IO_OLD = IoMockOldSQLite()
PormG.backend_sqlite_version(::IoMockSQLite) = 3045000
PormG.backend_sqlite_version(::IoMockOldSQLite) = 3029000

PormG.config["io_mock"] = PormG.Configuration.Settings(
  connections = _IO_SL, change_data = true, db_def_folder = "io_mock",
)

module IoModels
import PormG
import PormG.Models

# `starts_at - date` is the projected difference; `circuit` groups it for the aggregate cases.
Io_race = Models.Model("io_race",
  id        = Models.IDField(),
  circuit   = Models.CharField(null = true),
  date      = Models.DateField(null = true),
  starts_at = Models.DateTimeField(null = true),
)

# A stored duration — the bare `DurationField` column surface; `best` is a second one to compare with.
Io_lap = Models.Model("io_lap",
  id      = Models.IDField(),
  circuit = Models.CharField(null = true),
  lap     = Models.DurationField(null = true),
  best    = Models.DurationField(null = true),
)

PormG.Models.set_models(@__MODULE__, "io_mock")
end

const _IOM = IoModels   # not `IO`: that would shadow `Base.IO` for every later file in `Main`
const _IO_FN = PormG.Functions

_io_sql(q; conn = _IO_SL)    = inspect_query(q; connection = conn)[:sql_text]
_io_params(q; conn = _IO_SL) = inspect_query(q; connection = conn)[:parameters]
_io_gap() = F("starts_at") - F("date")

# The SQL each side reads as milliseconds on SQLite.
const _IO_GAP_MS = "CAST(round((julianday(\"Tb\".\"starts_at\") - julianday(\"Tb\".\"date\")) * 86400000) AS INTEGER)"
const _IO_LAP_MS = PormG.Dialect._sqlite_interval_ms("\"Tb\".\"lap\"")
const _IO_BEST_MS = PormG.Dialect._sqlite_interval_ms("\"Tb\".\"best\"")

# ─────────────────────────────────────────────────────────────────────────────
# #894 — order_by on an interval alias
# SQLite orders by the difference's milliseconds, re-rendered into ORDER BY; PostgreSQL keeps the
# alias. Ordering by the alias on SQLite sorted its `HH:MM:SS` text.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#894: order_by on an interval alias orders by milliseconds on SQLite" begin
  for (term, dir) in (("gap", "ASC NULLS LAST"), ("-gap", "DESC NULLS FIRST"))
    q = _IOM.Io_race.objects
    q.values("id", "gap" => _io_gap())
    q.order_by(term)
    @test occursin("ORDER BY $(_IO_GAP_MS) $(dir)", _io_sql(q))
    # The projection is unchanged: the value a query returns is still the interval text.
    @test occursin("printf('%02d:%02d:%02d'", _io_sql(q))
    @test isempty(_io_params(q))

    q_pg = _IOM.Io_race.objects
    q_pg.values("id", "gap" => _io_gap())
    q_pg.order_by(term)
    @test occursin("ORDER BY \"gap\" $(dir)", _io_sql(q_pg; conn = _IO_PG))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #894 — a binding projection ordered by its alias binds twice, in clause order
# The milliseconds are rendered again under ORDER BY, so a projection that binds a parameter binds it
# again there. Positional SQLite needs one value per marker, in text order — SELECT's first.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#894: a re-rendered ORDER BY binds its own parameters" begin
  q = _IOM.Io_race.objects
  q.values("id", "late" => _io_gap() + Dates.Hour(1))
  q.order_by("late")
  sql, params = _io_sql(q), _io_params(q)
  @test params == Any[3_600_000, 3_600_000]
  @test count(==('?'), sql) == length(params)
  @test occursin("ORDER BY ($(_IO_GAP_MS) + ?) ASC NULLS LAST", sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# #894 — a filter on an interval alias compares milliseconds on SQLite
# The issue's HAVING repro (`Max - Min`, an aggregate alias) and a WHERE alias, every comparison,
# range and membership operator, and a duration string. PostgreSQL binds what it bound before.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#894: a filter on an interval alias compares milliseconds on SQLite" begin
  span = _IO_FN.Max("starts_at") - _IO_FN.Min("starts_at")
  span_ms = "CAST(round((julianday(MAX(\"Tb\".\"starts_at\")) - julianday(MIN(\"Tb\".\"starts_at\"))) * 86400000) AS INTEGER)"

  q = _IOM.Io_race.objects
  q.values("circuit", "span" => span)
  q.filter("span__@gt" => Dates.Hour(1))
  @test occursin("HAVING $(span_ms) > ?", _io_sql(q))
  @test _io_params(q) == Any[3_600_000]   # was Any["01:00:00"], compared as text

  q_pg = _IOM.Io_race.objects
  q_pg.values("circuit", "span" => span)
  q_pg.filter("span__@gt" => Dates.Hour(1))
  @test occursin("HAVING (MAX(\"Tb\".\"starts_at\") - MIN(\"Tb\".\"starts_at\")) > \$1", _io_sql(q_pg; conn = _IO_PG))
  @test _io_params(q_pg; conn = _IO_PG) == Any[Dates.Hour(1)]

  # A row alias filters in WHERE, through the same path.
  for (lookup, value, rendered, bound) in (
      ("gap",         Dates.Hour(6),                        "= ?",               Any[21_600_000]),
      ("gap__@lte",   Dates.Minute(90),                     "<= ?",              Any[5_400_000]),
      ("gap__@gte",   "100:00:00",                          ">= ?",              Any[360_000_000]),
      ("gap__@range", [Dates.Hour(-2), Dates.Hour(99)],     "BETWEEN ? AND ?",   Any[-7_200_000, 356_400_000]),
      ("gap__@in",    [Dates.Hour(1), Dates.Hour(100)],     "IN (?, ?)",         Any[3_600_000, 360_000_000]),
    )
    q = _IOM.Io_race.objects
    q.values("id", "gap" => _io_gap())
    q.filter(lookup => value)
    @test occursin("WHERE $(_IO_GAP_MS) $(rendered)", _io_sql(q))
    @test _io_params(q) == bound
  end

  # Not a comparison: a pattern lookup reads the text, as before.
  q = _IOM.Io_race.objects
  q.values("id", "gap" => _io_gap())
  q.filter("gap__@icontains" => "06")
  @test occursin("pormg_lower((SELECT CASE WHEN _pormg_ms IS NULL", _io_sql(q))
  @test _io_params(q) == Any["%06%"]
end

# ─────────────────────────────────────────────────────────────────────────────
# #894 — Max/Min over an interval are the extremum of the milliseconds
# Projected as the interval text over `MAX(<ms>)`; ordered and filtered by `MAX(<ms>)` itself. Over the
# stored text, `MAX` was the last value in TEXT order.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#894: Max/Min over an interval aggregate the milliseconds on SQLite" begin
  q = _IOM.Io_race.objects
  q.values("circuit", "m" => _IO_FN.Max(_io_gap()))
  q.order_by("-m")
  sql = _io_sql(q)
  @test occursin("FROM (SELECT MAX($(_IO_GAP_MS)) AS _pormg_ms)) as \"m\"", sql)
  @test occursin("ORDER BY MAX($(_IO_GAP_MS)) DESC NULLS FIRST", sql)

  q = _IOM.Io_lap.objects
  q.values("circuit", "m" => _IO_FN.Min("lap"))
  q.filter("m__@lt" => Dates.Minute(2))
  sql = _io_sql(q)
  @test occursin("FROM (SELECT MIN($(_IO_LAP_MS)) AS _pormg_ms)) as \"m\"", sql)
  @test occursin("HAVING MIN($(_IO_LAP_MS)) < ?", sql)
  @test _io_params(q) == Any[120_000]

  # PostgreSQL: unchanged.
  q_pg = _IOM.Io_lap.objects
  q_pg.values("circuit", "m" => _IO_FN.Min("lap"))
  q_pg.filter("m__@lt" => Dates.Minute(2))
  @test occursin("MIN(\"Tb\".\"lap\") as \"m\"", _io_sql(q_pg; conn = _IO_PG))
  @test occursin("HAVING MIN(\"Tb\".\"lap\") < \$1", _io_sql(q_pg; conn = _IO_PG))
  @test _io_params(q_pg; conn = _IO_PG) == Any["00:02:00"]
end

# ─────────────────────────────────────────────────────────────────────────────
# #894 — a bare DurationField column orders by its milliseconds on SQLite
# `order_by`, the ordering lookups and the `F` spelling, which must agree. Equality and membership keep
# the stored text — exact on the canonical value the writer stores (#891), and sargable.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#894: a DurationField column orders by its milliseconds on SQLite" begin
  # Not projected, and projected under its own name: both order by the parsed text.
  for project in (false, true)
    q = _IOM.Io_lap.objects
    project ? q.values("id", "lap") : q.values("id")
    q.order_by("-lap")
    @test occursin("ORDER BY $(_IO_LAP_MS) DESC NULLS FIRST", _io_sql(q))
  end
  q_pg = _IOM.Io_lap.objects
  q_pg.values("id")
  q_pg.order_by("lap")
  @test occursin("ORDER BY \"Tb\".\"lap\" ASC NULLS LAST", _io_sql(q_pg; conn = _IO_PG))

  for (lookup, value, rendered, bound, pg_bound) in (
      ("lap__@gt",    Dates.Minute(2),          "> ?",             Any[120_000],          Any["00:02:00"]),
      ("lap__@lte",   "1:30",                   "<= ?",            Any[90_000],           Any["00:01:30"]),
      ("lap__@range", ["00:01:00", "100:00:00"], "BETWEEN ? AND ?", Any[60_000, 360_000_000], Any["00:01:00", "100:00:00"]),
    )
    q = _IOM.Io_lap.objects
    q.filter(lookup => value)
    @test occursin("WHERE $(_IO_LAP_MS) $(rendered)", _io_sql(q))
    @test _io_params(q) == bound
    q_pg = _IOM.Io_lap.objects
    q_pg.filter(lookup => value)
    @test _io_params(q_pg; conn = _IO_PG) == pg_bound
  end

  # The `F` spelling agrees with the pair.
  q = _IOM.Io_lap.objects
  q.filter(F("lap") > Dates.Minute(2))
  @test occursin("WHERE ($(_IO_LAP_MS) > ?)", _io_sql(q))
  @test _io_params(q) == Any[120_000]

  # Against another DurationField, in both spellings; PostgreSQL compares the columns.
  q = _IOM.Io_lap.objects
  q.filter("lap__@gt" => F("best"))
  @test occursin("WHERE $(_IO_LAP_MS) > $(_IO_BEST_MS)", _io_sql(q))
  q = _IOM.Io_lap.objects
  q.filter(F("lap") > F("best"))
  @test occursin("WHERE ($(_IO_LAP_MS) > $(_IO_BEST_MS))", _io_sql(q))
  q_pg = _IOM.Io_lap.objects
  q_pg.filter("lap__@gt" => F("best"))
  @test occursin("WHERE \"Tb\".\"lap\" > \"Tb\".\"best\"", _io_sql(q_pg; conn = _IO_PG))

  # Equality and membership: the canonical text.
  for (lookup, value) in (("lap", Dates.Minute(2)), ("lap__@in", [Dates.Minute(2), Dates.Minute(3)]))
    q = _IOM.Io_lap.objects
    q.filter(lookup => value)
    @test occursin("WHERE \"Tb\".\"lap\" ", _io_sql(q))
    @test all(p -> p isa String, _io_params(q))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #894 — an alias named like a column orders by the projection, not the column
# `values("lap" => Max("lap"))` grouped by circuit: inside an ORDER BY expression SQLite resolves
# `lap` to the FROM column before the result alias, so ordering by `_sqlite_interval_ms("lap")` would
# have sorted by an arbitrary row's raw lap. The projection is re-rendered instead.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#894: an interval alias named like a column orders by the projection" begin
  q = _IOM.Io_lap.objects
  q.values("circuit", "lap" => _IO_FN.Max("lap"))
  q.order_by("lap")
  @test occursin("ORDER BY MAX($(_IO_LAP_MS)) ASC NULLS LAST", _io_sql(q))
end

# ─────────────────────────────────────────────────────────────────────────────
# #894 — an interval alias compared with an EXPRESSION, and the Q/Qor and @nrange spellings
# Against an expression both sides render to milliseconds when both have them; when only one does it
# is wrapped back into the interval text, so the comparison is the text one it always was (the SQL
# below is the pre-#894 SQL). `Q`/`Qor` take the same paths as the bare filter.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#894: alias against an expression, Q/Qor and @nrange compare milliseconds on SQLite" begin
  q = _IOM.Io_race.objects
  q.values("id", "gap" => _io_gap())
  q.filter("gap__@gt" => _io_gap() - Dates.Hour(1))
  @test occursin("WHERE $(_IO_GAP_MS) > ($(_IO_GAP_MS) - ?)", _io_sql(q))
  @test _io_params(q) == Any[3_600_000]

  # No millisecond form on the right: both sides are the text, as before.
  q = _IOM.Io_race.objects
  q.values("id", "gap" => _io_gap())
  q.filter("gap__@gt" => F("circuit"))
  sql = _io_sql(q)
  @test occursin("FROM (SELECT $(_IO_GAP_MS) AS _pormg_ms)) > \"Tb\".\"circuit\"", sql)
  @test count(==('?'), sql) == length(_io_params(q)) == 0

  for wrap in (Q, x -> Qor(x, "id" => 0))
    q = _IOM.Io_race.objects
    q.values("id", "gap" => _io_gap())
    q.filter(wrap("gap__@gt" => Dates.Hour(99)))
    @test occursin("$(_IO_GAP_MS) > ?", _io_sql(q))
    @test _io_params(q)[1] == 356_400_000
  end

  q = _IOM.Io_race.objects
  q.values("id", "gap" => _io_gap())
  q.filter("gap__@nrange" => [Dates.Hour(-1), Dates.Hour(99)])
  @test occursin("WHERE $(_IO_GAP_MS) NOT BETWEEN ? AND ?", _io_sql(q))
  @test _io_params(q) == Any[-3_600_000, 356_400_000]

  q = _IOM.Io_lap.objects
  q.filter("lap__@nrange" => [Dates.Minute(1), Dates.Minute(2)])
  @test occursin("WHERE $(_IO_LAP_MS) NOT BETWEEN ? AND ?", _io_sql(q))
  @test _io_params(q) == Any[60_000, 120_000]

  # A DurationField against a column with no millisecond form keeps the text comparison.
  q = _IOM.Io_lap.objects
  q.filter("lap__@gt" => F("circuit"))
  @test occursin("WHERE \"Tb\".\"lap\" > \"Tb\".\"circuit\"", _io_sql(q))

  # A model column projected under its own name is a COLUMN, not an alias: projecting it changes
  # nothing about how it filters — `==` stays on the text, the text fallback stays the bare column.
  for project in (false, true)
    q = _IOM.Io_lap.objects
    project ? q.values("id", "lap") : q.values("id")
    q.filter("lap" => F("best"))
    @test occursin("WHERE \"Tb\".\"lap\" = \"Tb\".\"best\"", _io_sql(q))
    q = _IOM.Io_lap.objects
    project ? q.values("id", "lap") : q.values("id")
    q.filter("lap__@gt" => F("circuit"))
    @test occursin("WHERE \"Tb\".\"lap\" > \"Tb\".\"circuit\"", _io_sql(q))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #894 — SQLite before 3.30 still places NULLs, and Max/Min over a difference are typed intervals
# A re-rendered ORDER BY that binds gets a SECOND render of the projection as its NULL flag, binding
# its own identical copy of the values — the emulation skips a term whose one text would print a `?`
# twice. Not the alias as the flag: SQLite reads a name inside an expression as a FROM column first,
# so an alias named like a column (`"lap" => F("best") * 2`) would flag the wrong value; the oracle
# below runs that SQL. The extremum over a difference reads back as a `Dates.CompoundPeriod` on both.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#894: old-SQLite NULL placement, and the interval kind of Max/Min" begin
  q = _IOM.Io_race.objects
  q.values("id", "late" => _io_gap() + Dates.Hour(1))
  q.order_by("late")
  sql = _io_sql(q; conn = _IO_OLD)
  @test occursin("ORDER BY (($(_IO_GAP_MS) + ?) IS NULL) ASC, ($(_IO_GAP_MS) + ?) ASC", sql)
  @test _io_params(q; conn = _IO_OLD) == Any[3_600_000, 3_600_000, 3_600_000]
  @test count(==('?'), sql) == 3

  # The collision case, executed: NULLs last (as modern SQLite and PostgreSQL place them), ordered by
  # the projection — never by the `lap` column the alias is named like.
  isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
  db = Main.SQLite.DB()
  try
    Main.SQLite.DBInterface.execute(db, "CREATE TABLE io_lap (id INTEGER, circuit TEXT, lap TEXT, best TEXT)")
    for (id, lap, best) in ((1, missing, "01:00:00"), (2, "05:00:00", missing), (3, "03:00:00", "03:00:00"))
      Main.SQLite.DBInterface.execute(db, "INSERT INTO io_lap VALUES (?, 'a', ?, ?)", Any[id, lap, best])
    end
    q = _IOM.Io_lap.objects
    q.values("id", "lap" => F("best") * 2)
    q.order_by("lap")
    insp = inspect_query(q; connection = _IO_OLD)
    @test [r.id for r in Main.SQLite.DBInterface.execute(db, insp[:sql_text], insp[:parameters])] == [1, 3, 2]
  finally
    close(db)
  end

  q = _IOM.Io_lap.objects
  q.values("id")
  q.order_by("-lap")
  @test occursin("ORDER BY ($(_IO_LAP_MS) IS NULL) DESC, $(_IO_LAP_MS) DESC", _io_sql(q; conn = _IO_OLD))

  for conn in (_IO_SL, _IO_PG)
    q = _IOM.Io_race.objects
    q.values("circuit", "mx" => _IO_FN.Max(_io_gap()), "mn" => _IO_FN.Min(_io_gap()))
    QB.query(q; connection = conn, show_query = :sql)
    @test q.object.projection_kinds[:mx] == PormG.CInterval()
    @test q.object.projection_kinds[:mn] == PormG.CInterval()
  end
  # Typing it on PostgreSQL changes the read, never the SQL.
  q_pg = _IOM.Io_race.objects
  q_pg.values("circuit", "mx" => _IO_FN.Max(_io_gap()))
  @test occursin("MAX((\"Tb\".\"starts_at\" - \"Tb\".\"date\")) as \"mx\"", _io_sql(q_pg; conn = _IO_PG))
end

# ─────────────────────────────────────────────────────────────────────────────
# #894 — the oracle: every rendered statement, run against SQLite itself
# Two discriminating pairs on both surfaces: 99 h / 100 h and -1 h / -2 h. Each expected answer is the
# numeric one PostgreSQL gives; the text comparison this replaces returns the other on every line.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#894: SQLite orders and filters intervals numerically (in-memory oracle)" begin
  isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
  db = Main.SQLite.DB()
  try
    exe(sql, params = Any[]) = Main.SQLite.DBInterface.execute(db, sql, params)
    exe("CREATE TABLE io_race (id INTEGER, circuit TEXT, date TEXT, starts_at TEXT)")
    exe("CREATE TABLE io_lap (id INTEGER, circuit TEXT, lap TEXT, best TEXT)")
    # gap = starts_at - date: 1 → 99 h, 2 → 100 h, 3 → -1 h, 4 → -2 h, 5 → 6 h.
    # span per circuit = Max(starts_at) - Min(starts_at): a → 100 h, b → 8 h, c → 0.
    for (id, circuit, starts_at) in ((1, "a", "2009-04-02T03:00:00.000+00:00"),
                                     (2, "c", "2009-04-02T04:00:00.000+00:00"),
                                     (3, "a", "2009-03-28T23:00:00.000+00:00"),
                                     (4, "b", "2009-03-28T22:00:00.000+00:00"),
                                     (5, "b", "2009-03-29T06:00:00.000+00:00"))
      exe("INSERT INTO io_race VALUES (?, ?, '2009-03-29', ?)", Any[id, circuit, starts_at])
    end
    # Written through the formatter, exactly as a `create` stores them. `best` swaps each pair, so
    # `lap > best` holds for 2, 3 and 5 — and for 1, 4 and 5 in text order.
    for (id, circuit, lap, best) in ((1, "a", Dates.Hour(99), Dates.Hour(100)), (2, "b", Dates.Hour(100), Dates.Hour(99)),
                                     (3, "a", Dates.Hour(-1), Dates.Hour(-2)), (4, "b", Dates.Hour(-2), Dates.Hour(-1)),
                                     (5, "c", Dates.Minute(1) + Dates.Second(30), Dates.Minute(1)))
      exe("INSERT INTO io_lap VALUES (?, ?, ?, ?)", Any[id, circuit, PormG.Models.format_duration_sql(lap),
                                                         PormG.Models.format_duration_sql(best)])
    end

    rows(model, build!) = begin
      q = model.objects
      build!(q)
      insp = inspect_query(q; connection = _IO_SL)
      [Dict(k => getproperty(r, k) for k in propertynames(r)) for r in exe(insp[:sql_text], insp[:parameters])]
    end
    col(model, key, build!) = [r[key] for r in rows(model, build!)]

    # 1. order_by on the alias, both directions.
    @test col(_IOM.Io_race, :id, q -> (q.values("id", "gap" => _io_gap()); q.order_by("gap"))) == [4, 3, 5, 1, 2]
    @test col(_IOM.Io_race, :id, q -> (q.values("id", "gap" => _io_gap()); q.order_by("-gap"))) == [2, 1, 5, 3, 4]
    # 2. filters on the alias.
    @test sort(col(_IOM.Io_race, :id, q -> (q.values("id", "gap" => _io_gap()); q.filter("gap__@gt" => Dates.Hour(99))))) == [2]
    @test sort(col(_IOM.Io_race, :id, q -> (q.values("id", "gap" => _io_gap()); q.filter("gap__@lt" => Dates.Hour(0))))) == [3, 4]
    @test sort(col(_IOM.Io_race, :id, q -> (q.values("id", "gap" => _io_gap());
                                          q.filter("gap__@range" => [Dates.Hour(-1), Dates.Hour(99)])))) == [1, 3, 5]
    @test sort(col(_IOM.Io_race, :id, q -> (q.values("id", "gap" => _io_gap());
                                           q.filter("gap__@gt" => _io_gap() - Dates.Hour(1))))) == [1, 2, 3, 4, 5]
    @test sort(col(_IOM.Io_race, :id, q -> (q.values("id", "gap" => _io_gap());
                                           q.filter(Q("gap__@gte" => Dates.Hour(99), "gap__@lt" => Dates.Hour(200)))))) == [1, 2]
    @test sort(col(_IOM.Io_race, :circuit, q -> (q.values("circuit", "span" => _IO_FN.Max("starts_at") - _IO_FN.Min("starts_at"));
                                              q.filter("span__@gt" => Dates.Hour(99))))) == ["a"]
    # 3. Max/Min over the difference: the value, and the order.
    maxes = rows(_IOM.Io_race, q -> (q.values("circuit", "m" => _IO_FN.Max(_io_gap())); q.order_by("-m")))
    @test [r[:circuit] for r in maxes] == ["c", "a", "b"]
    @test [r[:m] for r in maxes] == ["100:00:00", "99:00:00", "06:00:00"]
    mins = rows(_IOM.Io_race, q -> (q.values("circuit", "m" => _IO_FN.Min(_io_gap())); q.order_by("m")))
    @test [r[:circuit] for r in mins] == ["b", "a", "c"]
    @test [r[:m] for r in mins] == ["-02:00:00", "-01:00:00", "100:00:00"]

    # 4. A DurationField column: order_by, the lookups, the F spelling, Max/Min and the alias collision.
    @test col(_IOM.Io_lap, :id, q -> (q.values("id"); q.order_by("lap"))) == [4, 3, 5, 1, 2]
    @test sort(col(_IOM.Io_lap, :id, q -> (q.values("id"); q.filter("lap__@gt" => Dates.Hour(99))))) == [2]
    @test sort(col(_IOM.Io_lap, :id, q -> (q.values("id"); q.filter(F("lap") >= Dates.Hour(99))))) == [1, 2]
    @test sort(col(_IOM.Io_lap, :id, q -> (q.values("id"); q.filter("lap__@lt" => "-1:30:00")))) == [4]
    @test sort(col(_IOM.Io_lap, :id, q -> (q.values("id");
                                         q.filter("lap__@range" => [Dates.Minute(-90), Dates.Minute(2)])))) == [3, 5]
    @test sort(col(_IOM.Io_lap, :id, q -> (q.values("id"); q.filter("lap__@gt" => F("best"))))) == [2, 3, 5]
    @test sort(col(_IOM.Io_lap, :id, q -> (q.values("id"); q.filter(F("lap") > F("best"))))) == [2, 3, 5]
    @test col(_IOM.Io_lap, :m, q -> q.values("m" => _IO_FN.Max("lap"))) == ["100:00:00"]
    @test col(_IOM.Io_lap, :m, q -> q.values("m" => _IO_FN.Min("lap"))) == ["-02:00:00"]
    # Max per circuit — a: 99 h, b: 100 h, c: 1:30 — ordered by an alias that is also a column name.
    @test col(_IOM.Io_lap, :circuit, q -> (q.values("circuit", "lap" => _IO_FN.Max("lap")); q.order_by("lap"))) ==
          ["c", "a", "b"]
    # Equality is still exact on the canonical text.
    @test col(_IOM.Io_lap, :id, q -> (q.values("id"); q.filter("lap" => "100:00:00"))) == [2]
  finally
    close(db)
  end
end
