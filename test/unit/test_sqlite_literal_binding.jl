"""
A literal never reaches SQLite as a serialized Julia object (#721).

SQLite.jl binds `Int32`, `Int64`, `Bool`, `AbstractFloat`, strings, `Vector{UInt8}`, `missing` and
`nothing` natively. Anything else falls to `bind!(stmt, i, ::Any) = bind!(stmt, i, sqlserialize(val))`,
which stores a serialized Julia object as a BLOB and raises nothing. PormG handed it three kinds of
value raw: a `Value(x)` literal, a function operand, and an integer filter value, which
`format_number_sql` returns unchanged. So `Value(Date(2020, 1, 1))` and `filter("points" => Int16(5))`
compared against garbage, silently.

`sqlite_bind_value` (`src/value_repr.jl`) is now the one table between PormG and SQLite.jl. The
SQLite parameter collector and the raw-SQL `fetch(..., params)` path both go through it. Pinned here:

  1. **The table.** Every row: native values pass through, an integer of another width becomes `Int64`,
     a date/time becomes its column's stored text, and anything else raises `InvalidValueError`.
  2. **Every ORM path reaches it.** `Value(x)`, a scalar filter and an `__@in` list, read from
     `inspect_query` on a mock SQLite connection.
  3. **PostgreSQL did not move.** The same queries bind the raw value with the same cast.
  4. **The engine agrees.** Against a real SQLite database, `typeof(?)` is never `blob`, a projected
     `Value(Date)` reads back as a `Date`, and an `Int16` filter finds its row.

julia --project=test/integration test/unit/test_sqlite_literal_binding.jl
"""

using Test
using Dates, TimeZones, UUIDs, Decimals
using DataFrames
using PormG
# Standalone runs need the SQLite extension for the real-engine half (runtests.jl loads it too).
include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG.Models: Model, IDField, IntegerField, FloatField, DateField
using PormG.QueryBuilder: inspect_query
using PormG.Functions: Value, Coalesce, Greatest
import PormG.ConnectionPool: fetch, SQLiteConnectionPool

const sqlite_bind_value = PormG.sqlite_bind_value

# ─────────────────────────────────────────────────────────────────────────────
# Fixtures: one results model per mock backend. Nothing here executes, so the mocks need no driver.
# ─────────────────────────────────────────────────────────────────────────────
struct SlbMockPostgres <: PormG.PormGPostgres end
struct SlbMockSQLite <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::SlbMockSQLite) = 3045000

PormG.config["slb_pg"] = PormG.Configuration.Settings(connections = SlbMockPostgres(), change_data = true)
PormG.config["slb_sl"] = PormG.Configuration.Settings(connections = SlbMockSQLite(), change_data = true)

function slb_model(key)
  m = Model("slb_results", resultid = IDField(), points = IntegerField(), fpoints = FloatField(),
            race_date = DateField())
  m.connect_key = key
  return m
end
const SLB_SL = slb_model("slb_sl")
const SLB_PG = slb_model("slb_pg")

# The parameters `inspect_query` reports for `build(q)` on a fresh handle.
slb_params(model, build) = (q = model.objects; build(q); inspect_query(q)[:parameters])

# ─────────────────────────────────────────────────────────────────────────────
# The table: what each Julia value binds as on SQLite
# One assertion per row of `sqlite_bind_value`. The value AND its type are checked. `Int16(5) == 5`
# holds for the unfixed value too, so an equality check alone would pass against the bug.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#721: sqlite_bind_value — the bind table" begin
  # Native: passed through as the very same value.
  for x in (Int64(7), Int32(7), true, 1.5, 2.5f0, "Senna", UInt8[0x01, 0x00], missing, nothing)
    @test sqlite_bind_value(x) === x || isequal(sqlite_bind_value(x), x)
    @test typeof(sqlite_bind_value(x)) === typeof(x)
  end
  # Every other integer width becomes `Int64`: the one integer type SQLite.jl binds as INTEGER
  # at full range.
  for x in (Int8(5), Int16(5), UInt8(5), UInt16(5), UInt32(5), UInt64(5), Int128(5), big(5))
    @test sqlite_bind_value(x) === Int64(5)
  end
  # …and one that does not fit is refused, never truncated.
  for x in (typemax(UInt64), Int128(2)^70, big(2)^80)
    @test_throws PormG.InvalidValueError sqlite_bind_value(x)
  end
  # A date or time becomes the text its column holds. This is the column formatter's own output, so
  # compare against the formatter rather than a restated string.
  @test sqlite_bind_value(Date(2021, 3, 28)) == "2021-03-28" == PormG.Models.format_date_sql(Date(2021, 3, 28))
  @test sqlite_bind_value(DateTime(2021, 3, 28, 15)) == "2021-03-28T15:00:00.000+00:00"
  @test sqlite_bind_value(ZonedDateTime(2021, 3, 28, 12, tz"America/Sao_Paulo")) ==
        "2021-03-28T15:00:00.000+00:00"
  @test sqlite_bind_value(Time(1, 30)) == "01:30:00"
  @test sqlite_bind_value(Minute(90)) == PormG.Models.format_duration_sql(Minute(90))
  # A UUID binds as the text its field formatter produces.
  u = UUID("0b6f1f0e-8f1a-4a53-9c1e-3b1b2f0c9a11")
  @test sqlite_bind_value(u) == string(u)
  # A Decimal is an `AbstractFloat`, which SQLite.jl binds as REAL (measured), so it is left alone.
  @test sqlite_bind_value(Decimal(0, 15, -1)) == Decimal(0, 15, -1)
  @test sqlite_bind_value(Decimal(0, 15, -1)) isa Decimal
  # A byte view is copied into the one container SQLite.jl binds as a blob.
  @test sqlite_bind_value(view(UInt8[1, 2, 3], 1:2)) isa Vector{UInt8}
  # A `Month` has no fixed length: refused, and the message names the value being bound rather than
  # only the `DurationField` the formatter's own message mentions.
  err = @test_throws PormG.InvalidValueError sqlite_bind_value(Month(1))
  @test occursin("Month(1)", err.value.msg) && occursin("SQLite parameter", err.value.msg)
  # Anything else would have been serialized. It is refused, and the message names the value.
  for x in (:points, 'x', 1//2, (1, 2), [1, 2], Dict("a" => 1))
    err = @test_throws PormG.InvalidValueError sqlite_bind_value(x)
    @test occursin("#721", err.value.msg)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Every ORM path that bound a raw value now binds the converted one (mock SQLite)
# `Value(x)` in a projection, a scalar integer filter and an `__@in` list. The filter cases were not
# in the issue; `format_number_sql(::Integer)` returns its argument, so a narrow integer reached the
# binder raw there too.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#721: the SQLite collector converts on every path" begin
  @test slb_params(SLB_SL, q -> q.values("resultid", "d" => Value(Date(2020, 1, 1)))) == Any["2020-01-01"]
  @test slb_params(SLB_SL, q -> q.values("resultid", "n" => Value(Int16(3)))) == Any[3]
  @test only(slb_params(SLB_SL, q -> q.values("resultid", "n" => Value(Int16(3))))) isa Int64
  # A scalar filter on an integer and on a float column.
  for field in ("points", "fpoints")
    p = slb_params(SLB_SL, q -> (q.filter(field => Int16(5)); q.values("resultid")))
    @test p == Any[5] && only(p) isa Int64
  end
  # The list arm, element by element.
  p = slb_params(SLB_SL, q -> (q.filter("points__@in" => Int16[5, 6]); q.values("resultid")))
  @test p == Any[5, 6] && all(v -> v isa Int64, p)
  # A function operand: the #705 bare-literal wrap now reaches the same binder.
  @test slb_params(SLB_SL, q -> q.values("resultid", "d" => Coalesce("race_date", Date(2020, 1, 1)))) ==
        Any["2020-01-01"]
  # A value with no representation is refused when the query is built.
  @test_throws PormG.InvalidValueError slb_params(SLB_SL, q -> q.values("resultid", "s" => Value(:points)))
end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL is untouched
# LibPQ adapts every one of these values itself, and `_infer_parameter_sql_type` adds the cast. The
# same queries still bind the raw Julia value, and the SQL still carries the cast.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#721: PostgreSQL binds the raw value, as before" begin
  q = SLB_PG.objects
  q.values("resultid", "d" => Value(Date(2020, 1, 1)))
  insp = inspect_query(q)
  @test insp[:parameters] == Any[Date(2020, 1, 1)]
  @test occursin("\$1::date", insp[:sql_text])
  p = slb_params(SLB_PG, q -> (q.filter("points" => Int16(5)); q.values("resultid")))
  @test only(p) isa Int16
end

# ─────────────────────────────────────────────────────────────────────────────
# The engine agrees: a real SQLite database
# A mock proves what PormG binds, not what SQLite stores. Here a temp database answers. `typeof(?)`
# is never `blob` on the raw-SQL path, a projected `Value(Date)` reads back as a `Date`, and a
# narrow-integer filter matches the row it names.
# ─────────────────────────────────────────────────────────────────────────────
function slb_with_sqlite(f)
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "slb721.sqlite"); pool_size = 1)
    key = "slb721_sqlite"
    PormG.config[key] = PormG.Configuration.Settings(connections = pool, db_def_folder = dir, change_data = true)
    try
      fetch(pool, """CREATE TABLE slb721_result (resultid INTEGER PRIMARY KEY, points INTEGER NOT NULL,
                     race_date TEXT NOT NULL);""")
      fetch(pool, "INSERT INTO slb721_result VALUES (1, 25, '2021-03-28'), (2, 18, '2021-04-18');")
      model = Model("slb721_result", resultid = IDField(), points = IntegerField(), race_date = DateField())
      model.connect_key = key
      f(pool, model)
    finally
      delete!(PormG.config, key)
      PormG.ConnectionPool.close_pool!(pool)   # release the handle so mktempdir can clean up (Windows)
    end
  end
end

@testset "#721: a real SQLite database stores the value, not a BLOB" begin
  slb_with_sqlite() do pool, model
    # The raw-SQL hatch: each of these was `blob` before #721, and each has one exact type now.
    for (x, expected) in ((Date(2021, 3, 28), "text"), (DateTime(2021), "text"), (Time(1), "text"),
                          (Int16(1), "integer"), (UInt8(1), "integer"), (big(1), "integer"))
      t = (fetch(pool, "SELECT typeof(?) AS t;", [x]) |> DataFrame).t[1]
      @test t == expected
    end
    # A projected date literal binds as text and reads back as a `Date`, as on PostgreSQL. The
    # read-back alone would also pass before #721 (SQLite.jl deserialized the BLOB into a `Date`),
    # so the bound parameter is asserted too.
    q = model.objects
    q.filter("resultid" => 1)
    q.values("resultid", "d" => Value(Date(2021, 3, 28)))
    @test inspect_query(q)[:parameters] == Any["2021-03-28", 1]   # the bound value is the text
    row = only(q.list())
    @test row[:d] == Date(2021, 3, 28)
    @test row[:d] isa Date
    # A naive `DateTime` reads back as a UTC `ZonedDateTime` — what a SQLite `DateTimeField` column
    # reads as, since both store the canonical `+00:00` text. Pinned so a change is deliberate.
    q = model.objects
    q.filter("resultid" => 1)
    q.values("resultid", "dt" => Value(DateTime(2021, 3, 28, 15)))
    dt = only(q.list())[:dt]
    @test dt == ZonedDateTime(2021, 3, 28, 15, tz"UTC")
    @test dt.timezone == tz"UTC"   # the zone itself, not only the instant
    # A narrow-integer filter matches the row it names.
    q = model.objects
    q.filter("points" => Int16(25))
    q.values("resultid")
    @test [r[:resultid] for r in q.list()] == [1]
    # A date literal inside a function compares with the column's stored text. The later of each
    # race date and 1 April 2021 is the literal for race 1 and the race date for race 2.
    q = model.objects
    q.values("resultid", "d" => Greatest("race_date", Date(2021, 4, 1)))
    q.order_by("resultid")
    @test [string(r[:d]) for r in q.list()] == ["2021-04-01", "2021-04-18"]
  end
end
