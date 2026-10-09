"""
`PormGtransform`: one ladder per key (#562), and one meaning per key (#579).

`__@date`, `__@year`, `__@month`, `__@day`, `__@yyyy_mm`, `__@quarter`, `__@quadrimester` and the
year-qualified `__@yyyy_q` / `__@yyyy_quad` can each be reached by two spellings that used to take
two different code paths:

  q.values("x" => "created_at__@date")     # the string spelling
  q.values("x" => F("created_at__@date"))  # the F / update-expression spelling

The first resolved the name with `getfield(@__MODULE__, …)` into `QueryBuilder`'s own constructors;
the second resolved the SAME `PormGtransform` entry with `getfield(Dialect, …)` and string-concatenated
the result. Both read one table and emitted different SQL — and for `@date` on SQLite one of them was
not merely different but wrong: `CAST(col AS DATE)` applies NUMERIC affinity, so
`'2026-04-07T21:30:23'` came back as the integer `2026`, projected and compared, silently.

Four of the seven transforms agreed through either ladder, which is exactly what made this hard to
notice — so the guard here is deliberately NOT a list of hand-written expectations. It iterates
`PormGtransform` itself: a transform added to one ladder only fails this file by construction, and so
does a transform whose two spellings drift apart later.

The second half of the file is #579: `@quarter` and `@quadrimester` denote the period NUMBER, the
year-qualified label lives under `@yyyy_q` / `@yyyy_quad`, and both number keys validate their
right-hand side. Before that split one name meant two things depending on where it appeared, so the
documented `filter("date__@quarter" => 1)` compared the integer `1` against the string `'1985-Q1'`
and matched nothing — silently, with a wrong-typed value accepted just as quietly.

Everything renders through mock connections — no live database, no fixture.

julia --project=test/integration test/unit/test_transform_ladder_parity.jl
"""

using Test
using Dates
using PormG
using PormG.Models
using PormG.QueryBuilder: inspect_query

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`, so a
# shared key would let another file's settings decide this file's dialect.
struct TlpMockSQLite <: PormG.PormGSQLite end
struct TlpMockPostgres <: PormG.PormGPostgres end
const _TLP_SL = TlpMockSQLite()
const _TLP_PG = TlpMockPostgres()
PormG.backend_sqlite_version(::TlpMockSQLite) = 3045000

PormG.config["tlp_mock"] = PormG.Configuration.Settings(
  connections = _TLP_SL, change_data = true, db_def_folder = "tlp_mock",
)

# Both temporal column kinds. The distinction matters here: the #352/#373 sargable rewrite only
# fires on a plain `DateField`, so `seen` and `ts` exercise different filter paths for the same
# transform while sharing the projection path.
module TlpModels
import PormG
import PormG.Models

Tlp_row = Models.Model("tlp_row",
  id   = Models.IDField(),
  seen = Models.DateField(null = true),
  ts   = Models.DateTimeField(null = true),
  note = Models.CharField(null = true),
)

# #955: the column kinds the field-type gate tells apart beyond a date and a timestamp — a time of
# day, a duration (which a public `Extract` may read), and a relation to `Tlp_row`.
Tlp_clock = Models.Model("tlp_clock",
  id    = Models.IDField(),
  clock = Models.TimeField(null = true),
  span  = Models.DurationField(null = true),
  rowid = Models.ForeignKey(Tlp_row, pk_field = "id", on_delete = "CASCADE"),
  # #1070: a timestamp WITHOUT a time zone — `EXTRACT(TIMEZONE …)` has nothing to read in it.
  naive = Models.DateTimeField(null = true, type = "TIMESTAMP"),
)

# #1068: relations a date part reads through. `dayid` targets a DATE key, so its value is a date; the
# one-to-one `rowid` targets `Tlp_row`'s integer id, like `Tlp_clock.rowid` above.
Tlp_day = Models.Model("tlp_day",
  id  = Models.IDField(),
  day = Models.DateField(unique = true),
)
Tlp_visit = Models.Model("tlp_visit",
  id    = Models.IDField(),
  dayid = Models.ForeignKey(Tlp_day, pk_field = "day", on_delete = "CASCADE"),
  rowid = Models.OneToOneField(Tlp_row, pk_field = "id", on_delete = "CASCADE"),
)

PormG.Models.set_models(@__MODULE__, "tlp_mock")
end

const TLP = TlpModels

_tlp_sql(q; conn)    = inspect_query(q; connection = conn)[:sql_text]
_tlp_params(q; conn) = inspect_query(q; connection = conn)[:parameters]

const _TLP_BACKENDS = (("PostgreSQL", _TLP_PG), ("SQLite", _TLP_SL))

# The transforms the parity loops run over this model's date and time columns: every
# `PormGtransform` key but `@len` (#28), which counts an ArrayField's elements and refuses a date
# column by design — there is no date row for it to agree on. Its two-spelling parity is asserted on
# an array column, in `test_array_lookups.jl`. Still computed from the registry, so a new date
# transform joins the loops by itself.
const _TLP_DATE_TRANSFORMS = sort(filter(!=("len"), collect(keys(PormG.PormGtransform))))

# Since #955 a time-of-day transform over a plain `DateField` is refused when the query is built — a
# date has no hour — so the loops that run every transform over both columns skip those pairs. The
# refusal itself is asserted in the #955 testset below; every other pair still runs on both columns.
_tlp_reads(col, key) = !(col == "seen" && key in ("hour", "minute", "second"))

# The projection through each spelling, aliased identically so only the EXPRESSION can differ.
_tlp_string_route(col, key, conn) =
  _tlp_sql((q = TLP.Tlp_row.objects; q.values("x" => "$(col)__@$(key)"); q); conn = conn)
_tlp_f_route(col, key, conn) =
  _tlp_sql((q = TLP.Tlp_row.objects; q.values("x" => F("$(col)__@$(key)")); q); conn = conn)

# ─────────────────────────────────────────────────────────────────────────────
# One ladder: every `PormGtransform` key renders identically through both spellings (#562).
# Iterating the constant rather than a hand-written list is the point — this is the test the issue
# asks for, the one that fails when a future transform is wired into only one of the two routes.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#562: both spellings of a transform render the same SQL" begin
  for (backend, conn) in _TLP_BACKENDS
    for key in _TLP_DATE_TRANSFORMS
      for col in ("seen", "ts")
        _tlp_reads(col, key) || continue
        string_sql = _tlp_string_route(col, key, conn)
        f_sql      = _tlp_f_route(col, key, conn)
        @test string_sql == f_sql
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# `@date` on SQLite: a date, not the year (#562).
# The regression that motivated the collapse. `CAST(col AS DATE)` is valid SQLite that returns the
# WRONG VALUE — `DATE` carries no affinity keyword, so NUMERIC affinity turns the stored text into
# the leading integer. Both halves are asserted: the correct call is present and the CAST spelling
# is absent, because a test for only the first would pass against a render that emitted both.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#562: @date renders strftime on SQLite, never CAST(... AS DATE)" begin
  for col in ("seen", "ts")
    for sql in (_tlp_string_route(col, "date", _TLP_SL), _tlp_f_route(col, "date", _TLP_SL))
      @test occursin("strftime('%Y-%m-%d', \"Tb\".\"$(col)\")", sql)
      @test !occursin("AS DATE", sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# `@date` on PostgreSQL: the real cast, on both spellings (#562).
# PostgreSQL HAS a `date` type, so the engine-correct rendering differs from SQLite's — which is
# why `@date` is a named function rather than a `to_char` mask. The string spelling used to render
# `to_char(col, 'YYYY-MM-DD')`, i.e. text; it now yields a `date` like the `F` spelling always did.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#562: @date renders a real cast on PostgreSQL" begin
  for col in ("seen", "ts")
    for sql in (_tlp_string_route(col, "date", _TLP_PG), _tlp_f_route(col, "date", _TLP_PG))
      @test occursin("(\"Tb\".\"$(col)\")::date", sql)
      @test !occursin("to_char", sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Regression controls: the four transforms that already agreed must still render as they did.
# These are quoted literally rather than derived, so a change of rendering shows up here as a
# failing expectation instead of silently satisfying the parity loop above — parity alone is
# satisfied by BOTH ladders drifting together.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#562: the four transforms that already agreed are unchanged" begin
  expected = Dict(
    (:sqlite, "year")    => "CAST(strftime('%Y', \"Tb\".\"ts\") AS INTEGER)",
    (:sqlite, "month")   => "CAST(strftime('%m', \"Tb\".\"ts\") AS INTEGER)",
    (:sqlite, "day")     => "CAST(strftime('%d', \"Tb\".\"ts\") AS INTEGER)",
    (:sqlite, "yyyy_mm") => "strftime('%Y-%m', \"Tb\".\"ts\")",
    # #571: the PostgreSQL arms cast `::integer` so the read-back type matches SQLite's `Int`.
    (:postgres, "year")    => "EXTRACT(YEAR FROM \"Tb\".\"ts\")::integer",
    (:postgres, "month")   => "EXTRACT(MONTH FROM \"Tb\".\"ts\")::integer",
    (:postgres, "day")     => "EXTRACT(DAY FROM \"Tb\".\"ts\")::integer",
    (:postgres, "yyyy_mm") => "to_char(\"Tb\".\"ts\", 'YYYY-MM')",
  )
  for (engine, conn) in ((:sqlite, _TLP_SL), (:postgres, _TLP_PG))
    for key in ("year", "month", "day", "yyyy_mm")
      want = expected[(engine, key)]
      @test occursin(want, _tlp_string_route("ts", key, conn))
      @test occursin(want, _tlp_f_route("ts", key, conn))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The sargable date-range rewrite still recognises `@date` (#562 × #352/#373).
# `@date` stopped being a `ToChar` node carrying a `"YYYY-MM-DD"` mask and became a named `DATE`
# function, so the bucket matcher in `_render_sargable_date_range` had to move with it. This is the
# one part of the collapse no correctness assertion can catch: on a plain `DateField` the rewrite
# DROPS the transform, so a stale matcher renders correct-but-unindexable SQL, silently — the #376
# failure mode. The rewrite is asserted by its shape (bare column, no function call) and the
# `DateTimeField` control proves the gate still excludes timestamps.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#562: @date still collapses to a bare-column comparison on a DateField" begin
  for (backend, conn) in _TLP_BACKENDS
    q = TLP.Tlp_row.objects
    q.values("note")
    q.filter("seen__@date" => "1991-10-27")
    sql = _tlp_sql(q; conn = conn)
    # The rewrite dropped the transform: the comparison is on the raw column.
    @test occursin("\"Tb\".\"seen\" = ", sql)
    @test !occursin("strftime", sql)
    @test !occursin("::date", sql)

    # The control: a TIMESTAMP column is deliberately excluded from the rewrite, so the transform
    # is still rendered there. If this ever renders bare too, the DATE-only gate has been widened.
    q2 = TLP.Tlp_row.objects
    q2.values("note")
    q2.filter("ts__@date" => "1991-10-27")
    sql2 = _tlp_sql(q2; conn = conn)
    @test occursin(conn === _TLP_SL ? "strftime('%Y-%m-%d'" : "::date", sql2)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# `@quarter` / `@quadrimester` extract the period number (#579).
# The documented contract in `api.md`, `read/filters_and_aggregates.md` and
# `read/functions_and_dates.md` has always said "Extract quarter (1-4)" and shown `=> 1` as the
# filter value. The implementation rendered `CONCAT(year, '-Q', CASE …)`, so the predicate compared
# a string to an integer: valid SQL, zero rows, no error. Both the projection and the predicate are
# asserted, because it is the PREDICATE that was unusable and the projection that hid it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#579: @quarter and @quadrimester denote a number, in both positions" begin
  numeric = Dict(
    (:sqlite, "quarter")        => "((strftime('%m', \"Tb\".\"ts\") - 1) / 3) + 1",
    (:sqlite, "quadrimester")   => "((strftime('%m', \"Tb\".\"ts\") - 1) / 4) + 1",
    (:postgres, "quarter")      => "EXTRACT(QUARTER FROM \"Tb\".\"ts\")::integer",   # #571 cast
    (:postgres, "quadrimester") => "CEIL(EXTRACT(MONTH FROM \"Tb\".\"ts\") / 4.0)::integer",
  )
  for (engine, conn) in ((:sqlite, _TLP_SL), (:postgres, _TLP_PG))
    for key in ("quarter", "quadrimester")
      want = numeric[(engine, key)]
      # Projected, through both spellings.
      @test occursin(want, _tlp_string_route("ts", key, conn))
      @test occursin(want, _tlp_f_route("ts", key, conn))
      # And in a predicate — the half that could never match. The label expansion is absent and the
      # bound parameter is the documented scalar, not nine `CASE` operands plus it.
      q = TLP.Tlp_row.objects
      q.values("note")
      q.filter("ts__@$(key)" => 1)
      @test occursin(want, _tlp_sql(q; conn = conn))
      @test !occursin("CASE", _tlp_sql(q; conn = conn))
      @test _tlp_params(q; conn = conn) == [1]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The year-qualified label kept its rendering, under its own name (#579).
# `@yyyy_q` / `@yyyy_quad` carry the `Concat`/`Case` expansion `@quarter` used to be, byte for byte
# — the split is a rename of the label half, not a redesign of it. `@yyyy_quad` still spells its
# separator `-Q`, sharing it with `@yyyy_q`; that predates #579 and is deliberately left alone here.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#579: @yyyy_q and @yyyy_quad carry the year-qualified label" begin
  for (backend, conn) in _TLP_BACKENDS
    for key in ("yyyy_q", "yyyy_quad")
      sql = _tlp_string_route("ts", key, conn)
      # The expansion: a year cast, the literal separator as a bound parameter, and a CASE ladder.
      @test occursin("CASE", sql)
      @test occursin("-Q", string(_tlp_params((q = TLP.Tlp_row.objects; q.values("x" => "ts__@$(key)"); q); conn = conn)))
      @test occursin(conn === _TLP_SL ? "strftime('%Y'" : "EXTRACT(YEAR FROM", sql)
    end
    # Four branches for quarters, three for quadrimesters — the two are not the same expansion.
    n_branch(key) = count("WHEN", _tlp_string_route("ts", key, conn))
    @test n_branch("yyyy_q") == 4
    @test n_branch("yyyy_quad") == 3
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The right-hand side of a period comparison is validated (#579).
# The `Concat` node carried no formatter, so `filter("date__@quarter" => "abc")` bound the string
# and returned nothing. Naming the function let a formatter be attached; the range check follows
# `@year`'s precedent of refusing a value no bucket can express rather than building SQL that
# silently matches nothing. The type WAS `InvalidValueError`, matching the sibling `@month`/`@day`
# formatters exactly, and this comment named #576 as the issue that would move the whole family to
# `FilterError`. #576 has landed and it did: `format_quarter_sql` still raises `InvalidValueError`,
# but the filter path converted it, so what a CALLER saw was `FilterError`. #971 moved it back: a
# refused value is an `InvalidValueError` on the filter path too, located on the transform. The
# refusal itself — the whole point of #579 — is unchanged, which is why only the type moved below.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#579: a value no period can express is refused, not bound" begin
  for (backend, conn) in _TLP_BACKENDS
    for (key, over) in (("quarter", 5), ("quadrimester", 4))
      # Not a number at all.
      @test_throws PormG.InvalidValueError _tlp_sql(
        (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@$(key)" => "abc"); q); conn = conn)
      # A number, but outside the period range — the case a plain numeric formatter would accept
      # and then match nothing with.
      @test_throws PormG.InvalidValueError _tlp_sql(
        (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@$(key)" => over); q); conn = conn)
      @test_throws PormG.InvalidValueError _tlp_sql(
        (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@$(key)" => 0); q); conn = conn)
      # The in-range values all build.
      for v in 1:(key == "quarter" ? 4 : 3)
        @test _tlp_params(
          (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@$(key)" => v); q); conn = conn) == [v]
      end
      # And through `__@in`, which binds a collection: the range check has to reach INSIDE it, or a
      # list containing an impossible period is accepted one element at a time. The two engines
      # bind `IN` differently — SQLite expands `IN (?, ?)` with flat parameters, PostgreSQL renders
      # `= ANY($1)` with one array parameter — so the expected shape is engine-specific here. That
      # divergence predates #579 and is shared verbatim with the sibling `@month` / `@day`.
      @test _tlp_params(
        (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@$(key)__@in" => [1, 2]); q);
        conn = conn) == (conn === _TLP_SL ? [1, 2] : [[1, 2]])
      @test_throws PormG.InvalidValueError _tlp_sql(
        (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@$(key)__@in" => [1, over]); q); conn = conn)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The time-part transforms (#636).
# `@hour` / `@minute` / `@second` reuse `Dialect.EXTRACT`, so the rendering is quoted literally here
# for the same reason as #562's controls above: the parity loops iterate `PormGtransform` and would be
# satisfied by both ladders rendering the wrong part together. `SECOND` is the one whose PostgreSQL
# arm differs from the rest — `trunc` first, because `numeric::integer` ROUNDS (45.6 → 46) where
# SQLite's `%S` truncates. Range refusal follows #579: a value no clock can show is refused (an
# `InvalidValueError` since #971),
# never a bound parameter that silently matches nothing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#636: the time-part transforms render and validate on both engines" begin
  expected = Dict(
    (:sqlite, "hour")   => "CAST(strftime('%H', \"Tb\".\"ts\") AS INTEGER)",
    (:sqlite, "minute") => "CAST(strftime('%M', \"Tb\".\"ts\") AS INTEGER)",
    (:sqlite, "second") => "CAST(strftime('%S', \"Tb\".\"ts\") AS INTEGER)",
    (:postgres, "hour")   => "EXTRACT(HOUR FROM \"Tb\".\"ts\")::integer",
    (:postgres, "minute") => "EXTRACT(MINUTE FROM \"Tb\".\"ts\")::integer",
    (:postgres, "second") => "trunc(EXTRACT(SECOND FROM \"Tb\".\"ts\"))::integer",
  )
  for (engine, conn) in ((:sqlite, _TLP_SL), (:postgres, _TLP_PG))
    for key in ("hour", "minute", "second")
      want = expected[(engine, key)]
      @test occursin(want, _tlp_string_route("ts", key, conn))
      @test occursin(want, _tlp_f_route("ts", key, conn))
    end
  end

  for (backend, conn) in _TLP_BACKENDS
    for (key, hi) in (("hour", 23), ("minute", 59), ("second", 59))
      build(v) = (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@$(key)" => v); q)
      # Out of range on either side, fractional, and not a number at all.
      for bad in (hi + 1, -1, 1.5, "abc")
        @test_throws PormG.InvalidValueError _tlp_sql(build(bad); conn = conn)
      end
      # Both ends of the range bind, as integers.
      @test _tlp_params(build(0); conn = conn) == [0]
      @test _tlp_params(build(hi); conn = conn) == [hi]
      # The check reaches inside a collection (same engine-specific `IN` shape as #579 above).
      @test _tlp_params(
        (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@$(key)__@in" => [0, hi]); q);
        conn = conn) == (conn === _TLP_SL ? [0, hi] : [[0, hi]])
      @test_throws PormG.InvalidValueError _tlp_sql(
        (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@$(key)__@in" => [0, hi + 1]); q); conn = conn)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The week-part transforms (#636): Django's numbering, identical on both engines.
# `@week` is the ISO-8601 week (1-53), `@iso_year` the ISO week-numbering year, `@iso_week_day` runs
# 1 = Monday … 7 = Sunday and `@week_day` 1 = Sunday … 7 = Saturday. Neither engine's default spelling
# gives that on its own — SQLite's `%W` is not the ISO week and PostgreSQL's `DOW` is 0-based — so the
# SQL is quoted literally, and the SQLite arithmetic is then EXECUTED in memory against Julia's own
# `Dates.week` / `Dates.dayofweek`: a third source neither ladder can satisfy by agreeing with the
# other. The PostgreSQL arms are the server's own ISO fields, whose numbering is PostgreSQL's
# documented contract; `test/integration/test_sql_functions.jl` reads them back from db_2.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#636: the week-part transforms render, validate and number like Django" begin
  thursday = "date(\"Tb\".\"ts\", '-3 days', 'weekday 4')"
  expected = Dict(
    (:sqlite, "week")         => "((CAST(strftime('%j', $(thursday)) AS INTEGER) - 1) / 7 + 1)",
    (:sqlite, "iso_year")     => "CAST(strftime('%Y', $(thursday)) AS INTEGER)",
    (:sqlite, "iso_week_day") => "((CAST(strftime('%w', \"Tb\".\"ts\") AS INTEGER) + 6) % 7 + 1)",
    (:sqlite, "week_day")     => "(CAST(strftime('%w', \"Tb\".\"ts\") AS INTEGER) + 1)",
    (:postgres, "week")         => "EXTRACT(WEEK FROM \"Tb\".\"ts\")::integer",
    (:postgres, "iso_year")     => "EXTRACT(ISOYEAR FROM \"Tb\".\"ts\")::integer",
    (:postgres, "iso_week_day") => "EXTRACT(ISODOW FROM \"Tb\".\"ts\")::integer",
    (:postgres, "week_day")     => "(EXTRACT(DOW FROM \"Tb\".\"ts\")::integer + 1)",
  )
  # Both spellings reach the same rendering (the #562 contract, quoted rather than only compared).
  for (engine, conn) in ((:sqlite, _TLP_SL), (:postgres, _TLP_PG))
    for key in ("week", "iso_year", "iso_week_day", "week_day")
      want = expected[(engine, key)]
      @test occursin(want, _tlp_string_route("ts", key, conn))
      @test occursin(want, _tlp_f_route("ts", key, conn))
    end
  end

  # Range refusal, as for the time parts (#579): a week or a day no calendar has is refused, never
  # bound. `@iso_year` is a year, so like `@year` it only has to be an integer.
  for (backend, conn) in _TLP_BACKENDS
    for (key, lo, hi) in (("week", 1, 53), ("week_day", 1, 7), ("iso_week_day", 1, 7))
      build(v) = (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@$(key)" => v); q)
      for bad in (lo - 1, hi + 1, 1.5, "abc")
        @test_throws PormG.InvalidValueError _tlp_sql(build(bad); conn = conn)
      end
      @test _tlp_params(build(lo); conn = conn) == [lo]
      @test _tlp_params(build(hi); conn = conn) == [hi]
      @test_throws PormG.InvalidValueError _tlp_sql(
        (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@$(key)__@in" => [lo, hi + 1]); q); conn = conn)
    end
    @test _tlp_params(
      (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@iso_year" => 2020); q); conn = conn) == [2020]
    @test_throws PormG.InvalidValueError _tlp_sql(
      (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@iso_year" => "abc"); q); conn = conn)
  end

  # The numbering itself, executed. The dates straddle the year ends where ISO and calendar
  # numbering part ways: 2020 has an ISO week 53 that runs into 2021-01-03, 2024-12-30 is already
  # week 1 of ISO 2025, and 2027-01-01 is still week 53 of ISO 2026. Each row is stored the way
  # PormG writes it — the canonical UTC text for `ts`, `YYYY-MM-DD` for `seen` — and at 23:30, so a
  # rendering that read the clock instead of the date would show up as an off-by-one day.
  isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
  days = [Date(2020, 12, 24):Day(1):Date(2021, 1, 12);
          Date(2024, 12, 27):Day(1):Date(2025, 1, 6);
          Date(2026, 12, 26):Day(1):Date(2027, 1, 5);
          Date(2015, 12, 31); Date(2032, 2, 29)]
  # Julia's ISO year: the year of the Thursday of the date's Monday-started week.
  iso_year(d) = year(d + Day(4 - dayofweek(d)))
  db = Main.SQLite.DB()
  try
    Main.SQLite.DBInterface.execute(db, "CREATE TABLE tlp_row (id INTEGER, seen TEXT, ts TEXT, note TEXT)")
    for (i, d) in enumerate(days)
      Main.SQLite.DBInterface.execute(db, "INSERT INTO tlp_row VALUES (?, ?, ?, NULL)",
        [i, string(d), string(d, "T23:30:00.000+00:00")])
    end
    for col in ("seen", "ts")
      insp = inspect_query((q = TLP.Tlp_row.objects;
                            q.values("id", "w" => "$(col)__@week", "y" => "$(col)__@iso_year",
                                     "iwd" => "$(col)__@iso_week_day", "wd" => "$(col)__@week_day");
                            q); connection = _TLP_SL)
      # Read inside the iteration: a SQLite row is a view of the cursor.
      got = Dict(r.id => (r.w, r.y, r.iwd, r.wd)
                 for r in Main.SQLite.DBInterface.execute(db, insp[:sql_text], insp[:parameters]))
      for (i, d) in enumerate(days)
        @test got[i] == (week(d), iso_year(d), dayofweek(d), dayofweek(d) % 7 + 1)
      end
    end
    # And the comparison side: the bound week number selects exactly the days Julia puts in it.
    insp = inspect_query((q = TLP.Tlp_row.objects; q.values("id"); q.filter("ts__@week" => 53); q);
                         connection = _TLP_SL)
    ids = sort([r.id for r in Main.SQLite.DBInterface.execute(db, insp[:sql_text], insp[:parameters])])
    @test ids == sort([i for (i, d) in enumerate(days) if week(d) == 53])
  finally
    close(db)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The label transforms bind correctly in every position (#586, #587).
# Two pre-existing parameter defects became reachable through a documented spelling once `@yyyy_q`
# and `@yyyy_quad` existed — a predicate rendered the expansion twice and kept both sets of
# parameters (#586); ORDER BY filed its parameters in a bucket that flattened before WHERE (#587).
# Both were pinned here as `@test_broken` while the docs carried a "projection-only" warning; the
# assertions below are the same statements, now expected to hold, so the contract is pinned rather
# than the symptom.
#
# The two engines failed differently, and asserting the same thing on both is how this testset would
# pass for the wrong reason. SQLite's `?` is positional at BIND time, so its criterion is the COUNT.
# PostgreSQL numbers `$n` at RENDER time, so its counts always agreed — 19 params and
# `max($n) == 19` — and its criterion is whether the `$n` sequence is CONTIGUOUS: the discarded
# render consumed `$10..$18`, which appeared nowhere in the text.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#586/#587: a parameter-binding transform binds once, in text position" begin
  _sqlite_placeholders(sql) = count("?", sql)
  _pg_refs(sql) = sort(unique(parse(Int, m.match[2:end]) for m in eachmatch(r"\$\d+", sql)))

  for (backend, conn) in _TLP_BACKENDS
    # The control, and it is a real one: a PROJECTION of the same label binds exactly what the text
    # references, on both engines. Asserted first so nothing below reads as "labels are broken".
    proj = TLP.Tlp_row.objects
    proj.values("x" => "ts__@yyyy_q")
    proj_sql = _tlp_sql(proj; conn = conn)
    proj_params = _tlp_params(proj; conn = conn)
    if conn === _TLP_SL
      @test _sqlite_placeholders(proj_sql) == length(proj_params)
    else
      @test _pg_refs(proj_sql) == collect(1:length(proj_params))
    end

    # #586 — a PREDICATE used to render the expansion twice and keep both sets of parameters. Now
    # the left-hand side renders once: the operands, then the comparison value, on both engines.
    for key in ("yyyy_q", "yyyy_quad")
      q = TLP.Tlp_row.objects
      q.values("note")
      q.filter("ts__@$(key)" => "1991-Q1")
      sql = _tlp_sql(q; conn = conn)
      params = _tlp_params(q; conn = conn)
      @test params[end] == "1991-Q1"
      if conn === _TLP_SL
        @test length(params) == _sqlite_placeholders(sql)
      else
        ns = _pg_refs(sql)
        # PostgreSQL's own arithmetic was always satisfied — this is NOT the defect, and asserting
        # only a count here would make the PG arm green for a reason PostgreSQL does not care about.
        @test maximum(ns) == length(params)
        # The defect was the gap the discarded render left behind.
        @test ns == collect(1:maximum(ns))
      end
    end

    # #587 — ORDER BY used to render under the `:join` context, which flushes BEFORE `where`, while
    # the text order is the reverse. It has its own `:order` bucket now (flattened last), so the
    # SQLite vector matches the text; PostgreSQL was always correct and is the control.
    # The whole vector is asserted, not its ends: pinning `params[1]`/`params[end]` would still pass
    # a fix that reordered the middle, and would break spuriously if anything ever bound after the
    # WHERE value (a LIMIT operand).
    q = TLP.Tlp_row.objects
    q.values("note")
    q.filter("note" => "x")
    q.order_by("ts__@yyyy_q")
    params = _tlp_params(q; conn = conn)
    # Text order: the WHERE placeholder comes first, then the nine ordering operands.
    in_text_order = Any["x", "-Q", 3, 1, 6, 2, 9, 3, 12, 4]
    # Both engines now agree; before #587 SQLite bound `["-Q", 3, …, 4, "x"]` — the WHERE value
    # last, so the predicate received the separator "-Q" and the ordering expression received "x".
    @test params == in_text_order
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #843: a transform in a function's STRING operand goes up the same ladder
# `Coalesce`, `Greatest`, `Least`, `NullIf`, `Power`, `Mod` and `Replace`'s column take their
# operands through `_function_operand`, which wrapped a string as `SQLField(x)`. The walk returns an
# `SQLField` untouched, so `Coalesce("ts__@date", "seen")` sent `__@date` to join resolution as a
# column and the build died ("does not have a 'how' property") — while `Max("ts__@date")` and
# `Coalesce(F("ts__@date"), "seen")` worked. Same shape as the #562 test above: iterate the
# constant, and require the string spelling to render exactly what the `F` spelling renders, SQL
# and parameters both, on each engine.
# ─────────────────────────────────────────────────────────────────────────────
const _TLP_843_CTORS = (
  ("Coalesce", op -> PormG.Functions.Coalesce(op, "seen")),
  ("Greatest", op -> PormG.Functions.Greatest(op, "seen")),
  ("Least",    op -> PormG.Functions.Least(op, "seen")),
  ("NullIf",   op -> PormG.Functions.NullIf(op, "seen")),
  ("Power",    op -> PormG.Functions.Power(op, 2)),
  ("Mod",      op -> PormG.Functions.Mod(op, 4)),
  ("Replace",  op -> PormG.Functions.Replace(op, "-", "/")),
)

@testset "#843: a transform in a function's string operand renders like its F spelling" begin
  for (backend, conn) in _TLP_BACKENDS, (name, ctor) in _TLP_843_CTORS
    for key in _TLP_DATE_TRANSFORMS, col in ("seen", "ts")
      _tlp_reads(col, key) || continue
      path = "$(col)__@$(key)"
      a = TLP.Tlp_row.objects; a.values("x" => ctor(path))
      b = TLP.Tlp_row.objects; b.values("x" => ctor(F(path)))
      ia = inspect_query(a; connection = conn)
      ib = inspect_query(b; connection = conn)
      @test ia[:sql_text] == ib[:sql_text]
      @test ia[:parameters] == ib[:parameters]
    end
  end
  # The issue's own query, spelled out: the transform renders, the plain path stays a column.
  sql = _tlp_sql((q = TLP.Tlp_row.objects; q.values("c" => PormG.Functions.Coalesce("ts__@date", "seen")); q);
                 conn = _TLP_SL)
  @test occursin("COALESCE(strftime('%Y-%m-%d', \"Tb\".\"ts\"), \"Tb\".\"seen\")", sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# #843 controls: what a bare string operand must still do
# Storing the operand as a bare string hands it to the same walk every other string path takes,
# so three things are pinned. A CTE path (`"ev__seen"`) still resolves to the CTE column, as
# `CTE("ev", "seen")` does. A suffix that is an OPERATOR, not a transform, is refused with
# `FilterError` rather than reaching the join resolver. And a filter on the projection's alias
# binds the compared date exactly as the `F` spelling does.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#843 controls: CTE paths, operator suffixes and alias filters" begin
  # A CTE column through the string path and through the explicit handle: one query.
  for (backend, conn) in _TLP_BACKENDS
    ev() = (c = TLP.Tlp_row.objects; c.values("id", "seen"); c)
    a = TLP.Tlp_row.objects
    a.with("ev" => ev(), join_field = "id" => "id")
    a.values("x" => PormG.Functions.Coalesce("ev__seen", "seen"))
    b = TLP.Tlp_row.objects
    b.with("ev" => ev(), join_field = "id" => "id")
    b.values("x" => PormG.Functions.Coalesce(CTE("ev", "seen"), "seen"))
    @test _tlp_sql(a; conn = conn) == _tlp_sql(b; conn = conn)
  end

  # `@gt` is an operator: in a function operand it is the ladder's FilterError, not a join crash.
  q = TLP.Tlp_row.objects
  @test_throws PormG.FilterError q.values("x" => PormG.Functions.Coalesce("ts__@gt", "seen"))

  # Filtering on the alias binds the same date, through either spelling.
  for (backend, conn) in _TLP_BACKENDS
    a = TLP.Tlp_row.objects
    a.values("c" => PormG.Functions.Coalesce("ts__@date", "seen"))
    a.filter("c__@gte" => Date(2020, 1, 1))
    b = TLP.Tlp_row.objects
    b.values("c" => PormG.Functions.Coalesce(F("ts__@date"), "seen"))
    b.filter("c__@gte" => Date(2020, 1, 1))
    @test _tlp_sql(a; conn = conn) == _tlp_sql(b; conn = conn)
    @test _tlp_params(a; conn = conn) == _tlp_params(b; conn = conn)
  end

  # The caller's handle is not rewritten by the build (#508). The walk resolves the transform into a
  # `DATE` node; before the operand list was copied, that node was written back into `h.column`.
  # The `h.column` assertion is the gate. The second is a control: the old write was idempotent, so
  # the reused handle rendered the same SQL either way, and it must keep doing so.
  h = PormG.Functions.Coalesce("ts__@date", "seen")
  sqls = map(_TLP_BACKENDS) do (backend, conn)
    _tlp_sql((q = TLP.Tlp_row.objects; q.values("x" => h); q); conn = conn)
  end
  @test h.column == Any["ts__@date", "seen"]
  @test sqls[1] == _tlp_sql((q = TLP.Tlp_row.objects; q.values("x" => h); q); conn = _TLP_PG)
end

# ─────────────────────────────────────────────────────────────────────────────
# #863: a transform resolves in a function wherever the function sits, not only in values(...)
# `_check_function` was the only walker that resolves `"col__@transform"`, it walked a function's
# `column` only, and only `values(...)` called it. So a transform inside a function on a filter's
# right-hand side, in a Case/When branch, in F arithmetic, in a window's `partition_by`, in a
# `Lag` default or in an `update` SET value reached join resolution as a column name, and the build
# died ("does not have a 'how' property"). Same oracle as #843: every position, with the string
# spelling and with the `F(path)` spelling, renders the same SQL and binds the same parameters.
# `yyyy_q` binds parameters of its own, which pins their order in each position.
# ─────────────────────────────────────────────────────────────────────────────
const _TLP_863_POSITIONS = let QB = PormG.QueryBuilder, Fn = PormG.Functions
  (
    ("filter right-hand side", (q, op) -> q.filter("seen__@gte" => Fn.Coalesce(op, "seen"))),
    ("Q right-hand side",      (q, op) -> q.filter(QB.Q("seen__@gte" => Fn.Coalesce(op, "seen")))),
    ("When condition",         (q, op) -> q.values("c" => Fn.Case([Fn.When("seen__@gte" => Fn.Coalesce(op, "seen"), then = 1)], default = 0))),
    ("Case then and default",  (q, op) -> q.values("c" => Fn.Case([Fn.When("id" => 1, then = Fn.Coalesce(op, "seen"))], default = Fn.Coalesce(op, "seen")))),
    ("When otherwise",         (q, op) -> q.values("c" => Fn.When("id" => 1, then = 1, otherwise = Fn.Coalesce(op, 0)))),
    ("then = Greatest (#844)", (q, op) -> q.values("c" => Fn.Case([Fn.When("id" => 1, then = Fn.Greatest(op, "seen"))]))),
    ("F arithmetic operand",   (q, op) -> q.values("x" => F("id") + Fn.Coalesce(op, 0))),
    ("F arithmetic filter",    (q, op) -> q.filter((F("id") + Fn.Coalesce(op, 0)) > 5)),
    ("window partition_by",    (q, op) -> q.values("id", "r" => QB.Rank(over = QB.WindowOver(partition_by = [Fn.Coalesce(op, 0)], order_by = ["id"])))),
    ("Lag default",            (q, op) -> q.values("id", "l" => QB.Lag("seen", default = Fn.Coalesce(op, "seen"), over = QB.WindowOver(order_by = ["id"])))),
  )
end

@testset "#863: a transform in a function resolves in every position, like its F spelling" begin
  for (backend, conn) in _TLP_BACKENDS, (label, position) in _TLP_863_POSITIONS
    @testset "$backend — $label" begin
      for key in ("date", "year", "yyyy_q"), col in ("seen", "ts")
        path = "$(col)__@$(key)"
        a = TLP.Tlp_row.objects; position(a, path)
        b = TLP.Tlp_row.objects; position(b, F(path))
        ia = inspect_query(a; connection = conn)
        ib = inspect_query(b; connection = conn)
        @test ia[:sql_text] == ib[:sql_text]
        @test ia[:parameters] == ib[:parameters]
      end
    end
  end

  # `Max(…) - Min(…)`: the expression is the arithmetic's LEFT side (`field_name`), not its operand.
  for (backend, conn) in _TLP_BACKENDS
    q = TLP.Tlp_row.objects
    q.values("span" => PormG.QueryBuilder.Max("ts__@year") - PormG.QueryBuilder.Min("ts__@year"))
    @test occursin(backend == "SQLite" ? "MAX(CAST(strftime('%Y', \"Tb\".\"ts\") AS INTEGER))" :
                                         "MAX(EXTRACT(YEAR FROM \"Tb\".\"ts\")::integer)", _tlp_sql(q; conn = conn))
  end

  # The issue's own query, and an `update` SET value (SQLite: `update` renders on the model's own
  # connection, which is this file's SQLite mock).
  # #895: the issue's query compared a plain column with `Max(…)` in WHERE, which both engines reject
  # and #895 now refuses at build time. The transform inside the aggregate is the thing pinned here,
  # so it is asked in the position where an aggregate on the right is legal: against an aggregate
  # alias, in HAVING.
  sql = _tlp_sql((q = TLP.Tlp_row.objects; q.values("id", "last_seen" => PormG.QueryBuilder.Max("seen"));
                  q.filter("last_seen__@gte" => PormG.QueryBuilder.Max("ts__@date")); q);
                 conn = _TLP_SL)
  @test occursin("HAVING MAX(\"Tb\".\"seen\") >= MAX(strftime('%Y-%m-%d', \"Tb\".\"ts\"))", sql)
  q = TLP.Tlp_row.objects
  q.filter("id" => 1)
  upd = q.update("seen" => PormG.Functions.Coalesce("ts__@date", "seen"), show_query = :dict)
  @test occursin("SET \"seen\" = COALESCE(strftime('%Y-%m-%d', \"Tb\".\"ts\"), \"Tb\".\"seen\")", upd[:sql_text])

  # An operator suffix in the operand is the ladder's FilterError, raised by filter() itself.
  q = TLP.Tlp_row.objects
  @test_throws PormG.FilterError q.filter("seen" => PormG.Functions.Coalesce("ts__@gt", "seen"))

  # A subquery operand is already resolved: these two died with a MethodError naming the walker.
  for (backend, conn) in _TLP_BACKENDS
    inner() = (i = TLP.Tlp_row.objects; i.filter("id" => PormG.QueryBuilder.OuterRef("id")); i)
    q = TLP.Tlp_row.objects
    q.values("id", "c" => PormG.Functions.Case([PormG.Functions.When(PormG.QueryBuilder.Q(PormG.QueryBuilder.Exists(inner())), then = 1)], default = 0))
    @test occursin("EXISTS", _tlp_sql(q; conn = conn))
    s = inner(); s.values("seen")
    q = TLP.Tlp_row.objects
    q.values("id", "g" => PormG.Functions.Greatest(PormG.QueryBuilder.Subquery(s), "seen"))
    @test occursin("SELECT", _tlp_sql(q; conn = conn))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #863: the walk constructs — a handle the caller still holds is never rewritten (#508)
# Every newly walked slot is a place a user's own node sits: a branch, a partition entry, an
# arithmetic operand, a right-hand side. The walk resolves into NEW nodes; the handles keep their
# unresolved `"ts__@…"` operand across two builds, and a shared WindowSpec is not written into.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#863: walked slots leave the caller's handles untouched" begin
  Fn = PormG.Functions; QB = PormG.QueryBuilder
  branch = Fn.Coalesce("ts__@date", "seen")
  case = Fn.Case([Fn.When("id" => 1, then = branch)])
  part = Fn.Coalesce("ts__@year", 0)
  spec = QB.WindowOver(partition_by = [part], order_by = ["id"])
  arith = F("id") + Fn.Coalesce("ts__@year", 0)
  rhs = Fn.Coalesce("ts__@date", "seen")
  for (backend, conn) in _TLP_BACKENDS, _ in 1:2
    q = TLP.Tlp_row.objects
    q.values("id", "c" => case, "r" => QB.Rank(over = spec), "x" => arith)
    q.filter("seen__@gte" => rhs)
    _tlp_sql(q; conn = conn)
  end
  @test branch.column[1] == "ts__@date"
  @test case.column[1].kwargs["then"] === branch
  @test part.column[1] == "ts__@year"
  @test spec.partition_by[1] === part
  @test arith.operand.column[1] == "ts__@year"
  @test rhs.column[1] == "ts__@date"
end

# ─────────────────────────────────────────────────────────────────────────────
# #863: every entry point that STORES a filter node walks it
# A filter node handed over directly — F arithmetic compared with a value, or an `OP` — is stored by
# eight call sites, and each one used to push it raw: `Q`, `Qor`, `push!` on both, `.on`, `.cjoin`,
# `.cjoin_on`, and `filter`. A pair whose right-hand side is F arithmetic takes its own method too.
# Each site is driven here with the string spelling and the `F(path)` spelling of the same transform,
# so a site that stops walking crashes the string spelling ("does not have a 'how' property") and
# fails this testset. A results/drivers pair supplies the relation the join entry points need.
# ─────────────────────────────────────────────────────────────────────────────
module TlpJoinModels
import PormG
import PormG.Models
Tlp_driver = Models.Model("tlp_driver", id = Models.IDField(), surname = Models.CharField(null = true),
  dob = Models.DateField(null = true))
Tlp_result = Models.Model("tlp_result", id = Models.IDField(),
  driver = Models.ForeignKey(Tlp_driver, on_delete = "CASCADE", related_name = "tlp_results", null = true),
  points = Models.IntegerField(null = true), grid = Models.IntegerField(null = true),
  ts = Models.DateTimeField(null = true))
PormG.Models.set_models(@__MODULE__, "tlp_mock")
end

@testset "#863: every entry point that stores a filter node walks it" begin
  QB = PormG.QueryBuilder; Fn = PormG.Functions; J = TlpJoinModels
  # The arithmetic node over the result's own `ts`, and over the joined driver's `dob`.
  node(op) = (F("id") + Fn.Coalesce(op, 0)) > 5
  entry_points = (
    ("filter",     "ts",  (q, op) -> q.filter(node(op))),
    ("Q",          "ts",  (q, op) -> q.filter(QB.Q("grid" => 1, node(op)))),
    ("Qor",        "ts",  (q, op) -> q.filter(QB.Qor("grid" => 1, node(op)))),
    ("push! Q",    "ts",  (q, op) -> (c = QB.Q("grid" => 1); push!(c, node(op)); q.filter(c))),
    ("push! Qor",  "ts",  (q, op) -> (c = QB.Qor("grid" => 1); push!(c, node(op)); q.filter(c))),
    ("cjoin_on",   "ts",  (q, op) -> q.cjoin_on("Tlp_driver", alias = "d", on = [Joined("d", "id") == F("driver"), node(op)])),
    # A pair whose right-hand side is F arithmetic (`_get_pair_to_oper(::SQLTypeF)`), both branches.
    ("pair F rhs, suffix", "ts", (q, op) -> q.filter("points__@gt" => F("id") + Fn.Coalesce(op, 0))),
    ("pair F rhs, =",      "ts", (q, op) -> q.filter("points" => F("id") + Fn.Coalesce(op, 0))),
    # A hand-built `OP` whose value is a function (`_check_function(::SQLTypeOper)` walks `values`).
    ("OP value",   "ts",  (q, op) -> q.filter(QB.OP("points", ">", Fn.Coalesce(op, 0)))),
  )
  for (backend, conn) in _TLP_BACKENDS, (label, col, entry!) in entry_points
    @testset "$backend — $label" begin
      path = "$(col)__@year"
      a = J.Tlp_result.objects; entry!(a, path)
      b = J.Tlp_result.objects; entry!(b, F(path))
      ia = inspect_query(a; connection = conn)
      ib = inspect_query(b; connection = conn)
      @test ia[:sql_text] == ib[:sql_text]
      @test ia[:parameters] == ib[:parameters]
    end
  end

  # `.on` and `.cjoin`: an F-arithmetic node goes through their join prefixer, which refuses it
  # whatever its operands, so they are driven with a hand-built `OP` node — stored by the same push
  # site — whose column is the joined model's and whose VALUE is the function to walk.
  op_node(op) = QB.OP("id", ">", Fn.Coalesce(op, 0))   # `id` is the joined driver's; the value is not prefixed
  joins = (
    ("on",    (q, op) -> (q.on("driver", op_node(op)); q.values("id", "driver__surname"))),
    ("cjoin", (q, op) -> (q.cjoin("driver" => "Tlp_driver", filters = [op_node(op)], warn = false); q.values("id"))),
  )
  for (backend, conn) in _TLP_BACKENDS, (label, entry!) in joins
    @testset "$backend — $label" begin
      a = J.Tlp_result.objects; entry!(a, "ts__@year")
      b = J.Tlp_result.objects; entry!(b, F("ts__@year"))
      @test _tlp_sql(a; conn = conn) == _tlp_sql(b; conn = conn)
      @test _tlp_params(a; conn = conn) == _tlp_params(b; conn = conn)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# `@isnull`, `@range` and `@nrange` after a transform (#972, #886).
# The transform arm of `_get_filter_query(::SQLTypeOper)` bound every value with one `add_parameter!`,
# so `"date__@year__@range" => [1990, 1999]` and `"date__@year__@isnull" => true` were refused as
# "BETWEEN / ISNULL is not a supported operator", and `@yyyy_mm` / `@date` / `@quarter` sent the
# `@isnull` polarity through their own formatter and blamed the value (#886). Django renders
# `pub_date__year__isnull` as `EXTRACT(…) IS NULL`; PormG now does the same.
#
# The expected left-hand side is NOT written out here: it is read from the PROJECTION of the same
# transform, a render this change does not touch, so every key — and a key added later — is checked
# against an independent source rather than against a list copied from the new output. `@isnull`
# binds nothing; a range binds its two formatted operands after whatever the expression bound itself
# (`@yyyy_q` binds its `'-Q'` and CASE bounds).
#
# The two filter spellings are the pair and `Q(…)`: an `F` comparison overloads the comparison
# operators only, so there is no `F` spelling of `@isnull` or `@range` to agree with.
#
# Mutation gates: restore the arm's single `add_parameter!` (`_bind_transform_value` →
# `add_parameter!(instruc, _guarded_format(…))`) and every row fails as "not a supported operator";
# drop `expression = transform_lhs` at the tail and every `@isnull` row fails on the #197 refusal;
# format the `ISNULL` polarity again and the `@yyyy_mm` / `@date` / `@quarter` rows fail as #886.
# ─────────────────────────────────────────────────────────────────────────────

# The transform's own SQL, as the projection renders it, plus the parameters that SQL binds.
function _tlp_transform_lhs(col, key, conn)
  r = inspect_query((q = TLP.Tlp_row.objects; q.values("x" => "$(col)__@$(key)"); q); connection = conn)
  m = match(r"SELECT\s+(.*?)\s+as \"x\""s, r[:sql_text])
  return (m.captures[1], r[:parameters])
end

# The two year-qualified labels, the transforms that render a `Concat`.
const _TLP_LABEL_TRANSFORMS = ("yyyy_q", "yyyy_quad")

# The third slot is what precedes the predicate in WHERE: `Q(…)` parenthesizes its group.
_tlp_972_spellings = (
  ("pair", (q, path, v) -> q.filter(path => v),    "WHERE "),
  ("Q",    (q, path, v) -> q.filter(Q(path => v)), "WHERE ("),
)

# The two labels are in the loop since #997, which made them NULL for a NULL date on both engines;
# #972 refused `@isnull` after them until then.
@testset "#972: @isnull after a transform renders IS [NOT] NULL and binds nothing" begin
  for (backend, conn) in _TLP_BACKENDS, key in _TLP_DATE_TRANSFORMS, col in ("seen", "ts")
    _tlp_reads(col, key) || continue
    lhs, lhs_params = _tlp_transform_lhs(col, key, conn)
    for (spelling, filter!, where) in _tlp_972_spellings, (polarity, tail) in ((true, "IS NULL"), (false, "IS NOT NULL"))
      @testset "$backend $(col)__@$(key) $spelling $polarity" begin
        r = inspect_query((q = TLP.Tlp_row.objects; filter!(q, "$(col)__@$(key)__@isnull", polarity); q);
                          connection = conn)
        @test occursin("$(where)$(lhs) $(tail)", r[:sql_text])
        @test r[:parameters] == lhs_params
      end
    end
  end
end

@testset "#886: the @isnull polarity never reaches the transform's formatter" begin
  # The three keys whose formatter refuses a `Bool`, so the polarity used to come back as a refused
  # VALUE — `InvalidValueError` on `@yyyy_mm`, the one #886 reported. The loop above already renders
  # them; this names the regression and pins that no value refusal is raised.
  for (backend, conn) in _TLP_BACKENDS, key in ("yyyy_mm", "date", "quarter"), polarity in (true, false)
    @test _tlp_params((q = TLP.Tlp_row.objects; q.filter("seen__@$(key)__@isnull" => polarity); q);
                      conn = conn) == _tlp_transform_lhs("seen", key, conn)[2]
  end
end

@testset "#972: @range / @nrange after a transform bind both operands, in order" begin
  operands(key) = key == "date" ? ([Date(2020, 1, 1), Date(2020, 2, 1)], ["2020-01-01", "2020-02-01"]) :
                  key == "yyyy_mm" ? (["2020-01", "2020-03"], ["2020-01", "2020-03"]) :
                  key in _TLP_LABEL_TRANSFORMS ? (["2020-Q1", "2020-Q2"], ["2020-Q1", "2020-Q2"]) :
                  ([1, 3], [1, 3])
  for (backend, conn) in _TLP_BACKENDS, key in _TLP_DATE_TRANSFORMS, col in ("seen", "ts")
    _tlp_reads(col, key) || continue
    lhs, lhs_params = _tlp_transform_lhs(col, key, conn)
    given, bound = operands(key)
    n = length(lhs_params)
    ph1, ph2 = conn === _TLP_SL ? ("?", "?") : ("\$$(n + 1)", "\$$(n + 2)")
    for (spelling, filter!, where) in _tlp_972_spellings, (op, sql_op) in (("range", "BETWEEN"), ("nrange", "NOT BETWEEN"))
      @testset "$backend $(col)__@$(key)__@$(op) $spelling" begin
        r = inspect_query((q = TLP.Tlp_row.objects; filter!(q, "$(col)__@$(key)__@$(op)", given); q);
                          connection = conn)
        @test occursin("$(where)$(lhs) $(sql_op) $(ph1) AND $(ph2)", r[:sql_text])
        @test r[:parameters] == [lhs_params..., bound...]
      end
    end
  end
  # The operands still go through the transform's formatter, but a range's ends are BOUNDS (#1088):
  # `[1, 25]` covers every hour from 1 and is how a caller writes "1 or later", so it binds. What is
  # no hour at all — a word, a fraction — is still refused, not bound.
  for (backend, conn) in _TLP_BACKENDS
    @test _tlp_params((q = TLP.Tlp_row.objects; q.filter("ts__@hour__@range" => [1, 25]); q); conn = conn)[end-1:end] == [1, 25]
    @test_throws PormG.InvalidValueError _tlp_sql(
      (q = TLP.Tlp_row.objects; q.filter("ts__@hour__@range" => ["1", "abc"]); q); conn = conn)
    @test_throws PormG.InvalidValueError _tlp_sql(
      (q = TLP.Tlp_row.objects; q.filter("ts__@hour__@range" => [1, 2.5]); q); conn = conn)
  end
end

@testset "#972: the other places a filter pair is read take the same render" begin
  # A `When` condition and a joined path read the pair through the same parser and the same arms.
  # Pinned because they are the two routes most likely to grow their own binding later; the
  # expected text is again the projection's. `@yyyy_q` rides along since #997: its `@isnull` is
  # licensed in a different arm of `_get_filter_query` from `@year`'s, so it is a separate route.
  for (backend, conn) in _TLP_BACKENDS, key in ("year", "yyyy_q")
    lhs, _ = _tlp_transform_lhs("ts", key, conn)
    sql = _tlp_sql((q = TLP.Tlp_row.objects;
                    q.values("x" => PormG.Functions.Case([PormG.Functions.When("ts__@$(key)__@isnull" => true, then = 1)], default = 0)); q);
                   conn = conn)
    @test occursin("WHEN $(lhs) IS NULL THEN", sql)

    J = TlpJoinModels
    proj = _tlp_sql((q = J.Tlp_result.objects; q.values("x" => "driver__dob__@$(key)"); q); conn = conn)
    joined_lhs = match(r"SELECT\s+(.*?)\s+as \"x\""s, proj).captures[1]
    sql = _tlp_sql((q = J.Tlp_result.objects; q.filter("driver__dob__@$(key)__@isnull" => false); q); conn = conn)
    @test occursin("$(joined_lhs) IS NOT NULL", sql)
  end
end

@testset "#972: COUNT under @isnull stays refused on the internal OP route" begin
  # The two `PormGTypeField`-keyed arms are reached only by the internal `OP(Count(…), …)`. They
  # refused every `@isnull` before #972; `COUNT` keeps that refusal, because `COUNT(…) IS NULL` can
  # never match — the alias branch's #654 rule. Mutation gate: drop the `COUNT` check in
  # `_bind_transform_value` and this renders a predicate that is always false.
  QB = PormG.QueryBuilder; Fn = PormG.Functions
  for (backend, conn) in _TLP_BACKENDS
    err = try
      _tlp_sql((q = TLP.Tlp_row.objects;
                q.values("id", "x" => Fn.Case([Fn.When(QB.OP(Fn.Count("id"), "ISNULL", true), then = 1)], default = 0)); q);
               conn = conn)
      nothing
    catch e
      e
    end
    @test err isa PormG.FilterError
    @test occursin("COUNT never returns NULL", replace(sprint(showerror, err), r"\e\[[0-9;]*m" => ""))
  end
end

@testset "#997: @yyyy_q / @yyyy_quad join with || on both engines, so a NULL date is a NULL label" begin
  # PostgreSQL's `CONCAT` skips a NULL argument, so the label read `'-Q'` for a NULL date there and
  # NULL on SQLite, whose `||` propagates it. Both engines render `||` now. The operands and their
  # binding are unchanged, so the parameters agree across engines, separator first.
  for (backend, conn) in _TLP_BACKENDS, key in _TLP_LABEL_TRANSFORMS, col in ("seen", "ts")
    @testset "$backend $(col)__@$(key)" begin
      lhs, lhs_params = _tlp_transform_lhs(col, key, conn)
      @test !occursin("CONCAT(", lhs)
      @test count(" ||", lhs) == 2
      # #1006: the public `Concat` coalesces its operands on SQLite; the labels must not.
      @test !occursin("COALESCE(", lhs)
      @test first(lhs_params) == "-Q"
      @test lhs_params == _tlp_transform_lhs(col, key, conn === _TLP_PG ? _TLP_SL : _TLP_PG)[2]
    end
  end
end

@testset "#1006: a public Concat skips a NULL operand on both engines" begin
  # PostgreSQL's `CONCAT` skips a NULL argument; SQLite's `||` propagated it, so one row read
  # `" Senna"` on one engine and NULL on the other. Django's `Concat` skips it on every backend, so
  # SQLite now coalesces each operand to `''` and PostgreSQL keeps `CONCAT`. The `''` is a literal,
  # so both engines bind the same parameters.
  Fn = PormG.Functions
  build() = (q = TLP.Tlp_row.objects;
             q.values("x" => Fn.Concat("note", Fn.Value(" "), "seen__@year")); q)
  pg, sl = _tlp_sql(build(); conn = _TLP_PG), _tlp_sql(build(); conn = _TLP_SL)

  @test occursin("CONCAT(", pg)
  @test !occursin("COALESCE(", pg)
  @test !occursin(" ||", pg)

  # Every operand is wrapped, a column, a bound literal and a transform alike.
  @test !occursin("CONCAT(", sl)
  @test count("COALESCE(", sl) == 3
  @test occursin("COALESCE(\"Tb\".\"note\", '') ||", sl)
  @test occursin("COALESCE(?, '') ||", sl)
  @test _tlp_params(build(); conn = _TLP_PG) == _tlp_params(build(); conn = _TLP_SL) == [" "]

  # One operand has no `||` to make it text, so `COALESCE(7, '')` would stay an integer while a NULL
  # row reads `''`. The trailing `|| ''` keeps the column text, as `CONCAT(7)` is on PostgreSQL.
  single = (q = TLP.Tlp_row.objects; q.values("x" => Fn.Concat(["seen__@year"])); q)
  @test occursin("AS INTEGER), '') ||\n'')", _tlp_sql(single; conn = _TLP_SL))

  # A Concat nested in a Case branch renders through the same arm.
  nested = (q = TLP.Tlp_row.objects;
            q.values("x" => Fn.Case(Fn.When("note__@isnull" => false, then = Fn.Concat("note", Fn.Value("!"))))); q)
  @test occursin("COALESCE(\"Tb\".\"note\", '') ||", _tlp_sql(nested; conn = _TLP_SL))
end

# ─────────────────────────────────────────────────────────────────────────────
# #955, #1070: a date or time part refuses a column it cannot read, when the query is built — through
# either spelling. #955 gated only the `__@` transforms, by a tag the ladder stamped, so the public
# `Extract` building the SAME node went unchecked: `Extract("seen", "HOUR")` rendered
# `EXTRACT(HOUR FROM …)`, which answers `0` on SQLite and is refused by PostgreSQL. #1070 checks the
# part against the operand's declared type wherever the node renders, so both spellings refuse alike,
# with the same message. It fails OPEN: a column PormG cannot name a field for passes. (A relation is
# checked against the key it holds — the #1068 testset below.)
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1070: a date part over a column of the wrong type is refused, whoever built it" begin
  Fn = PormG.Functions
  plain(e) = replace(PormG.error_message(e), r"\e\[[0-9;]*m" => "")
  refused(build, conn) = (try _tlp_sql(build(); conn = conn); nothing catch e; e end)
  # The refusal for one projection, so the two spellings can be compared message for message.
  projected(model, x, conn) = refused(() -> (q = model.objects; q.values("x" => x); q), conn)
  for (backend, conn) in _TLP_BACKENDS
    @testset "$backend" begin
      # A text column under a date part, in every position and through both spellings.
      for build in (() -> (q = TLP.Tlp_row.objects; q.values("x" => "note__@month"); q),
                    () -> (q = TLP.Tlp_row.objects; q.values("x" => F("note__@month")); q),
                    () -> (q = TLP.Tlp_row.objects; q.values("x" => Fn.Extract("note", "month")); q),
                    () -> (q = TLP.Tlp_row.objects; q.values("id"); q.filter("note__@month" => 3); q),
                    () -> (q = TLP.Tlp_row.objects; q.values("id"); q.order_by("note__@month"); q))
        e = refused(build, conn)
        @test e isa PormG.QueryBuildError
        @test occursin("month part", plain(e)) && occursin("note", plain(e)) && occursin("CharField", plain(e))
      end
      # A time-of-day part over a date: the date has no hour. The transform and the `Extract` it is
      # sugar for refuse with one message — the rule lives on the part, not on the spelling.
      e_transform = projected(TLP.Tlp_row, "seen__@hour", conn)
      e_extract = projected(TLP.Tlp_row, Fn.Extract("seen", "HOUR"), conn)
      @test e_transform isa PormG.QueryBuildError && e_extract isa PormG.QueryBuildError
      @test occursin("time of day", plain(e_extract)) && occursin("DateField", plain(e_extract))
      @test plain(e_transform) == plain(e_extract)
      # A calendar part over a time of day, including a week part (#636) and a label (`@yyyy_q`,
      # whose `Concat` holds the checked year and month nodes).
      for key in ("week", "year", "date", "yyyy_q")
        e = projected(TLP.Tlp_clock, "clock__@$(key)", conn)
        @test e isa PormG.QueryBuildError
        @test occursin("TimeField", plain(e))
      end
      @test projected(TLP.Tlp_clock, Fn.Extract("clock", "year"), conn) isa PormG.QueryBuildError
      # A joined path is checked against the field at its end.
      @test projected(TLP.Tlp_clock, "rowid__note__@year", conn) isa PormG.QueryBuildError
      # Every transform the registry holds is checked, not only the spellings above.
      for key in _TLP_DATE_TRANSFORMS
        @test projected(TLP.Tlp_row, "note__@$(key)", conn) isa PormG.QueryBuildError
      end
      # A `DurationField` reads only `EPOCH`: PostgreSQL would extract a component of the duration,
      # while SQLite reads the stored text as a clock (NULL from 24 hours) — so its hours are refused
      # through both spellings now, where #955 let the public `Extract` through.
      @test projected(TLP.Tlp_clock, "span__@hour", conn) isa PormG.QueryBuildError
      @test projected(TLP.Tlp_clock, Fn.Extract("span", "hour"), conn) isa PormG.QueryBuildError
      # A zone exists only on a timestamp.
      @test projected(TLP.Tlp_row, Fn.Extract("seen", "timezone"), conn) isa PormG.QueryBuildError

      # What still builds: each part on a column it reads…
      @test occursin("Tb", _tlp_sql((q = TLP.Tlp_clock.objects; q.values("x" => "clock__@hour"); q); conn = conn))
      @test occursin("Tb", _tlp_sql((q = TLP.Tlp_clock.objects; q.values("x" => Fn.Extract("clock", "minute")); q); conn = conn))
      @test occursin("Tb", _tlp_sql((q = TLP.Tlp_clock.objects; q.values("x" => "rowid__seen__@week"); q); conn = conn))
      # …`EPOCH` over a date, the documented `Cast(Extract("date", "epoch"), "bigint")`, and over a
      # duration — PostgreSQL only (SQLite has no `EPOCH`), so it is rendered there alone…
      if conn isa PormG.PormGPostgres
        @test occursin("EPOCH", _tlp_sql((q = TLP.Tlp_row.objects; q.values("x" => Fn.Cast(Fn.Extract("seen", "epoch"), "bigint")); q); conn = conn))
        @test occursin("EPOCH", _tlp_sql((q = TLP.Tlp_clock.objects; q.values("x" => Fn.Extract("span", "epoch")); q); conn = conn))
      end
      # …and an operand PormG cannot type: an expression is not refused for what it cannot know.
      @test occursin("Tb", _tlp_sql((q = TLP.Tlp_row.objects; q.values("x" => Fn.Extract(Fn.Coalesce("note", "note"), "HOUR")); q); conn = conn))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1068: a date part over a relation reads the key the relation holds.
# A `ForeignKey`'s column holds the related row's key, so `"rowid__@year"` over an integer key renders
# `EXTRACT(YEAR FROM "Tb"."rowid")` — refused by PostgreSQL when it runs, answered from the text by
# SQLite. #955 let every relation through; the check now follows the relation to its key's field, so
# an integer key is refused at build time and a key that is itself a date is read as one.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1068: a date part over a relation is checked against the related key" begin
  Fn = PormG.Functions
  plain(e) = replace(PormG.error_message(e), r"\e\[[0-9;]*m" => "")
  projected(model, x, conn) = (try _tlp_sql((q = model.objects; q.values("x" => x); q); conn = conn); nothing catch e; e end)
  for (backend, conn) in _TLP_BACKENDS
    @testset "$backend" begin
      # An integer key, through a foreign key and a one-to-one, and through both spellings. The
      # message says why a relation was checked at all: its value is the key, and the key's type.
      for (model, x) in ((TLP.Tlp_clock, "rowid__@year"), (TLP.Tlp_clock, Fn.Extract("rowid", "YEAR")),
                         (TLP.Tlp_visit, "rowid__@month"), (TLP.Tlp_clock, "rowid__@hour"))
        e = projected(model, x, conn)
        @test e isa PormG.QueryBuildError
        @test occursin("rowid", plain(e)) && occursin("related key", plain(e)) && occursin("IDField", plain(e))
      end
      # In a filter too, which renders the part before it binds anything.
      @test_throws PormG.QueryBuildError _tlp_sql(
        (q = TLP.Tlp_clock.objects; q.values("id"); q.filter("rowid__@year" => 2009); q); conn = conn)
      # A key that is a date is read as one: the year, and a calendar part, of the relation's value.
      @test occursin("\"dayid\"", _tlp_sql((q = TLP.Tlp_visit.objects; q.values("x" => "dayid__@year"); q); conn = conn))
      @test occursin("\"dayid\"", _tlp_sql((q = TLP.Tlp_visit.objects; q.values("x" => Fn.Extract("dayid", "MONTH")); q); conn = conn))
      # …but not a time of day: the key's type decides, exactly as for a plain DateField.
      e = projected(TLP.Tlp_visit, "dayid__@hour", conn)
      @test e isa PormG.QueryBuildError && occursin("DateField", plain(e))
      # Through the relation to a real date column is unaffected: the part reads the joined field.
      @test occursin("Tb", _tlp_sql((q = TLP.Tlp_clock.objects; q.values("x" => "rowid__seen__@year"); q); conn = conn))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1070: every `EXTRACT` part has a row, and the ladder stamps nothing on its nodes.
# The rows are what check an operand and a filter's value, so a part `Dialect` learns without one
# would arrive unchecked; `_temporal_row_of` raises a `KeyError` on it rather than pass it silently,
# and this fails first. The `"transform"` tag #955 put in `kwargs` is gone: `"seen__@year"` and
# `Extract("seen", "YEAR")` are one node, so nothing distinguishes them.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1070: every EXTRACT part has a row; ladder nodes carry no transform tag" begin
  QB = PormG.QueryBuilder
  for part in PormG.Dialect.PG_EXTRACT_FIELDS
    @test haskey(QB._EXTRACT_PART_ROWS, part)
  end
  # A walk over the node's operands and kwargs — `@yyyy_q` is a `Concat` holding a `Case`.
  tagged(x) = x isa QB.FObject ? (haskey(x.kwargs, "transform") || tagged(x.column) || any(tagged, values(x.kwargs))) :
              x isa AbstractVector ? any(tagged, x) :
              hasproperty(x, :column) ? tagged(getproperty(x, :column)) : false
  for key in _TLP_DATE_TRANSFORMS
    @test !tagged(QB._check_function(["seen", key]))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #955, #1070: a filter on a date part is held to the part's range, through either spelling.
# #955 put the range on the formatter each ladder constructor chose, so it followed the spelling:
# `"ts__@hour" => 25` was refused while `OP(Extract("ts", "HOUR"), "=", 25)` was not, and `@month`
# and `@day` had no range at all — `"seen__@month" => 13` bound and matched nothing. The range is the
# part's now. A Bool is refused too (`format_number_sql` maps `true` to `1`). The refusal names the
# part and never quotes the value (#971).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1070: a date part's filter value is range-checked through either spelling" begin
  Fn = PormG.Functions
  plain(e) = replace(PormG.error_message(e), r"\e\[[0-9;]*m" => "")
  # (EXTRACT part, the `__@` key that is sugar for it or `nothing`, first value out of range, last in range)
  ranges = (("HOUR", "hour", 24, 23), ("MINUTE", "minute", 60, 59), ("SECOND", "second", 60, 59),
            ("MONTH", "month", 13, 12), ("DAY", "day", 32, 31), ("QUARTER", "quarter", 5, 4),
            ("WEEK", "week", 54, 53), ("ISODOW", "iso_week_day", 8, 7), ("DOW", nothing, 7, 6),
            ("DOY", nothing, 367, 366))
  for (backend, conn) in _TLP_BACKENDS
    @testset "$backend" begin
      for (part, key, bad, good) in ranges
        # SQLite has no `QUARTER` field: its `@quarter` is a node of its own, checked below.
        conn isa PormG.PormGSQLite && part == "QUARTER" && continue
        # The public spelling is an alias of the `Extract`; `OP` is the node-level comparison the
        # `@yyyy_q` labels build (internal), which reaches the WHERE path's function arm.
        alias(v) = (q = TLP.Tlp_row.objects; q.values("p" => Fn.Extract("ts", part)); q.filter("p" => v); q)
        op(v) = (q = TLP.Tlp_row.objects; q.values("id"); q.filter(PormG.QueryBuilder.OP(Fn.Extract("ts", part), "=", v)); q)
        for build in (alias, op)
          @test_throws PormG.InvalidValueError _tlp_sql(build(bad); conn = conn)
          @test occursin("Tb", _tlp_sql(build(good); conn = conn))
        end
        key === nothing && continue
        pair(v) = (q = TLP.Tlp_row.objects; q.values("id"); q.filter("ts__@$(key)" => v); q)
        @test_throws PormG.InvalidValueError _tlp_sql(pair(bad); conn = conn)
        @test occursin("Tb", _tlp_sql(pair(good); conn = conn))
      end
      # The issue's case: a plain `DateField` (not on the sargable rewrite's path for `@month`).
      @test_throws PormG.InvalidValueError _tlp_sql(
        (q = TLP.Tlp_row.objects; q.values("id"); q.filter("seen__@month" => 13); q); conn = conn)
      # An alias of an `Extract` is held to the part's range too.
      @test_throws PormG.InvalidValueError _tlp_sql(
        (q = TLP.Tlp_row.objects; q.values("h" => Fn.Extract("ts", "HOUR")); q.filter("h" => 24); q); conn = conn)
      # Arithmetic over a part is a plain number: the range belongs to the part, not to `hour + 1`, so
      # 24 builds — and it is still a NUMBER, so a word is refused rather than bound raw (untyped, as
      # `hour + 1` would be if only `format_number_sql` counted as a number, `"abc"` reached the driver).
      plus_one(v) = (q = TLP.Tlp_row.objects; q.values("h" => Fn.Extract("ts", "HOUR") + 1); q.filter("h" => v); q)
      @test occursin("Tb", _tlp_sql(plus_one(24); conn = conn))
      @test_throws PormG.InvalidValueError _tlp_sql(plus_one("abc"); conn = conn)

      # `Any[...]`: a literal `[5, true]` promotes to `[5, 1]` before PormG sees it.
      for (path, v) in (("ts__@hour", true), ("ts__@quarter", true), ("seen__@week_day", true),
                        ("ts__@minute__@in", Any[5, true]), ("ts__@month", true))
        @test_throws PormG.InvalidValueError _tlp_sql(
          (q = TLP.Tlp_row.objects; q.values("note"); q.filter(path => v); q); conn = conn)
      end
      e = try _tlp_sql((q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@hour" => 24); q); conn = conn); nothing catch e; e end
      @test e isa PormG.InvalidValueError
      @test occursin("hour part", plain(e))
      @test occursin("integer from 0 to 23", plain(e))
      @test !occursin("EXTRACT", plain(e))
      @test !occursin("24", plain(e))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1088: a date part's RANGE is checked only for `=` and `@in`; its SHAPE under every operator.
# #1070 held every filter value to the part's range whatever the operator, so the natural way to
# write a bound was refused: `"ts__@month__@lt" => 13` matches every row and `"ts__@hour__@lte" => 24`
# is "any hour". Django has no range check, and both engines answer an out-of-range value with no
# rows, so the guard is PormG's own: it stays where an out-of-range value can only be a typo (`=`,
# `@in`) and binds the number as given everywhere else. A malformed value — a Bool, a fraction, a
# word — is no value of the part, so it is refused on every operator, and its kind says which it is:
# `:range` for a whole number outside the part, `:type` / `:format` for one that is not a number.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1088: the operator decides whether a date part's range applies" begin
  Fn = PormG.Functions
  # The refusal itself, or `nothing` when the query builds.
  refusal(f, conn) = try _tlp_sql((q = TLP.Tlp_row.objects; q.values("note"); f(q); q); conn = conn); nothing catch e; e end
  for (backend, conn) in _TLP_BACKENDS
    @testset "$backend" begin
      # `=` and `@in` still refuse a whole number outside the part, as `:range`, through the pair, a
      # `DateField` (off the sargable rewrite for `@month`), and an alias of an `Extract`.
      for f in (q -> q.filter("ts__@month" => 13), q -> q.filter("ts__@month__@in" => [1, 13]),
                q -> q.filter("seen__@month" => 13), q -> q.filter("ts__@hour" => 24),
                q -> (q.values("m" => Fn.Extract("ts", "MONTH")); q.filter("m" => 13)))
        e = refusal(f, conn)
        @test e isa PormG.InvalidValueError && e.kind === :range
      end
      # Every other operator binds the number as given: an ordering bound, a range's ends, and the
      # negations (`@ne` / `@nin` are not `=` / `@in`, and an out-of-range value matches every row).
      for (path, v) in (("ts__@month__@lt", 13), ("ts__@hour__@lte", 24), ("ts__@month__@gt", 0),
                        ("seen__@day__@lte", 32), ("ts__@month__@ne", 13), ("ts__@month__@nin", [13]),
                        ("ts__@minute__@range", [0, 60]))
        @test refusal(q -> q.filter(path => v), conn) === nothing
        # Bound as the integers written, never as text. A membership list is one array parameter on
        # PostgreSQL (`<> ALL($1)`) and one marker per element on SQLite; a range is always two.
        want = !(v isa Vector) ? [v] : (conn === _TLP_PG && !endswith(path, "range")) ? [v] : v
        @test _tlp_params((q = TLP.Tlp_row.objects; q.values("note"); q.filter(path => v); q); conn = conn) == want
      end
      # The alias of an `Extract` takes the same rule: a comparison is a bound.
      @test refusal(q -> (q.values("m" => Fn.Extract("ts", "MONTH")); q.filter("m__@lt" => 13)), conn) === nothing
      # The shape is checked under every operator, with its own kind — never `:range`.
      for (path, v, kind) in (("ts__@month__@lt", true, :type), ("ts__@month__@lt", 1.5, :format),
                              ("ts__@hour__@gte", "abc", :format), ("ts__@month", 1.5, :format),
                              ("ts__@hour__@range", Any[0, true], :type))
        e = refusal(q -> q.filter(path => v), conn)
        @test e isa PormG.InvalidValueError && e.kind === kind
      end
      # A whole float is a whole number: in range it binds as the integer, out of range it is `:range`.
      @test _tlp_params((q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@month" => 3.0); q); conn = conn) == [3]
      e = refusal(q -> q.filter("ts__@month" => 1e30), conn)
      @test e isa PormG.InvalidValueError && e.kind === :range
      # Under a comparison there is no range, but the bound must still fit the integer it binds as —
      # and the message says that, not "an integer from 0 to 23" for an operator that takes 24 (review).
      e = refusal(q -> q.filter("ts__@hour__@lt" => 1e30), conn)
      @test e isa PormG.InvalidValueError && e.kind === :range && occursin("64-bit integer", e.msg)
      # A value no number formatter takes is refused as `:type`, not a raw `MethodError` (review).
      for v in (Time(3), 3 // 1)
        e = refusal(q -> q.filter("ts__@hour" => v), conn)
        @test e isa PormG.InvalidValueError && e.kind === :type
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1091: `@year` and `@yyyy_mm` are checked on every path, not only the `DateField` range rewrite.
# Their bounds ran inside `_render_sargable_date_range`, which fires only for `=` and the orderings on a
# plain `DateField`. Off it — `@in`, a `DateTimeField` — the ladder formatted the value as a plain
# number or text and bound it: `99999`, `true` as `1`, `"1991-13"`. Each now has its own formatter,
# under #1088's split: a year outside 1–9999 is refused by `=` / `@in`, and a value that is no year or
# no month (a Bool, a fraction, month 13) under every operator.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1091: @year and @yyyy_mm are checked off the DateField rewrite" begin
  refusal(path, v, conn) = try _tlp_sql((q = TLP.Tlp_row.objects; q.values("id"); q.filter(path => v); q); conn = conn); nothing catch e; e end
  params(path, v, conn) = _tlp_params((q = TLP.Tlp_row.objects; q.values("id"); q.filter(path => v); q); conn = conn)
  for (backend, conn) in _TLP_BACKENDS
    @testset "$backend" begin
      # The issue's table, row by row, with the kind each refusal now carries.
      for (path, v, kind) in (("seen__@year__@in", [99999], :range), ("ts__@year", 99999, :range),
                              ("ts__@year", true, :type), ("ts__@year__@gte", 1991.5, :format),
                              ("ts__@yyyy_mm", "1991-13", :format), ("ts__@yyyy_mm__@lt", "1991-13", :format),
                              ("ts__@yyyy_mm", 199113, :format), ("ts__@yyyy_mm", "0000-01", :range))
        e = refusal(path, v, conn)
        @test e isa PormG.InvalidValueError && e.kind === kind
      end
      # A comparison's out-of-range year is a bound: it binds, as the integer.
      @test params("ts__@year__@gte", 99999, conn) == [99999]
      @test params("ts__@yyyy_mm__@lt", "0000-05", conn) == ["0000-05"]
      # In range, every shape the rewrite accepts binds the year as an integer here too.
      @test params("ts__@year", 1991.0, conn) == [1991]
      @test params("ts__@year", "1991", conn) == [1991]
      @test params("ts__@yyyy_mm", 199103, conn) == ["1991-03"]
      # Review: non-ASCII digits are no `YYYY-MM` (they were a raw `StringIndexError`); a year string too
      # long for `Int` is out of range on the rewrite path as on the transform path; and an alias of
      # `Extract(…, "YEAR")` takes the year's rule like the pair spelling.
      @test (e = refusal("ts__@yyyy_mm", "١٩٩١-٠١", conn); e isa PormG.InvalidValueError && e.kind === :format)
      @test (e = refusal("seen__@yyyy_mm__@lte", "١٩٩١-٠١", conn); e isa PormG.InvalidValueError && e.kind === :format)
      for path in ("seen__@year__@gte", "ts__@year__@gte")
        e = refusal(path, "99999999999999999999", conn)
        @test e isa PormG.InvalidValueError && e.kind === :range
      end
      alias_year(v) = try _tlp_sql((q = TLP.Tlp_row.objects; q.values("y" => PormG.Functions.Extract("seen", "YEAR")); q.filter("y" => v); q); conn = conn); nothing catch e; e end
      @test (e = alias_year(99999); e isa PormG.InvalidValueError && e.kind === :range)
      @test alias_year(1991) === nothing
      # `F("…__@year")` takes the year's rule through the #1083 comparison arm.
      e = try _tlp_sql((q = TLP.Tlp_row.objects; q.values("id"); q.filter(F("ts__@year") == 99999); q); conn = conn); nothing catch e; e end
      @test e isa PormG.InvalidValueError && e.kind === :range
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1083: a comparison written with `F` or `Extract` follows the same rule as the pair spelling.
# The comparison arm typed its literal from the ROOTED column, never from the part on the left, so
# `F("ts__@hour") == 25` bound 25 and matched nothing while `"ts__@hour" => 25` was refused. The part's
# formatter now decides, under #1088's operator rule: `==` is held to the range, `>` and the other
# orderings bind their bound, and the shape (a Bool, a fraction) is refused under every operator.
# There is no `@in` form to cover: an `F`/`Extract` key in a filter pair is refused at parse.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1083: an F or Extract comparison over a date part takes the part's rule" begin
  Fn = PormG.Functions
  build(f) = (q = TLP.Tlp_row.objects; q.values("id"); q.filter(f()); q)
  refusal(f, conn) = try _tlp_sql(build(f); conn = conn); nothing catch e; e end
  for (backend, conn) in _TLP_BACKENDS
    @testset "$backend" begin
      # Equality: the three spellings refuse alike, with the same kind.
      for f in (() -> F("ts__@hour") == 25, () -> Fn.Extract("ts", "HOUR") == 25, () -> F("seen__@month") == 13)
        e = refusal(f, conn)
        @test e isa PormG.InvalidValueError && e.kind === :range
      end
      @test _tlp_params(build(() -> F("ts__@hour") == 3); conn = conn) == [3]
      # An ordering binds its bound — and keeps the PostgreSQL integer cast the numeric arm gives it.
      for f in (() -> F("ts__@hour") > 25, () -> Fn.Extract("ts", "HOUR") > 25, () -> F("ts__@hour") != 25)
        r = inspect_query(build(f); connection = conn)
        @test r[:parameters] == [25]
        @test occursin(conn === _TLP_PG ? "\$1::bigint" : "?", r[:sql_text])
      end
      # The shape under every operator: no hour is `true` or 1.5 (both bound as `1` and `"1.5"` before).
      for (f, kind) in ((() -> F("ts__@hour") == true, :type), (() -> F("ts__@hour") > 1.5, :format))
        e = refusal(f, conn)
        @test e isa PormG.InvalidValueError && e.kind === kind
      end
      # Arithmetic over a part is a plain number (#1070): `hour + 1` reaches 24.
      @test _tlp_params(build(() -> (F("ts__@hour") + 1) == 24); conn = conn)[end] == 24
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1086: a pattern lookup's value is a FRAGMENT of the column's text, on every column.
# Django's `PatternLookup` skips the field's `get_prep_value`, because `"2009"` is a prefix of a date
# and of a `"YYYY-MM"` label, not a whole value of either. PormG did that only for the network and UUID
# kinds, so after #1084 `ToChar(x, "YYYY-MM")` — which IS `@yyyy_mm` — refused `@startswith "2009"`.
# The value now binds as text with the `%` the lookup adds; an exact value is still a whole value. On
# PostgreSQL a `date` has no `LIKE`, so a date column is read as its `YYYY-MM-DD` text, the text
# SQLite stores (`to_char`, not `::text`, which follows `DateStyle`).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1086: a pattern lookup binds a text fragment, on every column" begin
  Fn = PormG.Functions
  refusal(f, conn) = try _tlp_sql((q = TLP.Tlp_row.objects; f(q); q); conn = conn); nothing catch e; e end
  params(f, conn) = _tlp_params((q = TLP.Tlp_row.objects; f(q); q); conn = conn)
  for (backend, conn) in _TLP_BACKENDS
    @testset "$backend" begin
      # Both spellings of the issue: an alias of `ToChar(…, "YYYY-MM")`, and the `@yyyy_mm` transform.
      # Each binds the fragment with the prefix wildcard, as text.
      alias_ym = q -> (q.values("ym" => Fn.ToChar("seen", "YYYY-MM")); q.filter("ym__@startswith" => "2009"))
      @test params(alias_ym, conn) == ["2009%"]
      @test params(q -> (q.values("id"); q.filter("seen__@yyyy_mm__@startswith" => "2009")), conn) == ["2009%"]
      # A pattern over a date part's text is odd but valid: the hour's range is not asked of `"2"`.
      @test params(q -> (q.values("id"); q.filter("ts__@hour__@startswith" => "2")), conn) == ["2%"]
      # An exact value is still a whole value: the label's shape and the hour's range still refuse.
      e = refusal(q -> (q.values("ym" => Fn.ToChar("seen", "YYYY-MM")); q.filter("ym" => "2009")), conn)
      @test e isa PormG.InvalidValueError
      @test refusal(q -> (q.values("id"); q.filter("ts__@hour" => 25)), conn) isa PormG.InvalidValueError
      # A date column: the value is the fragment, and PostgreSQL reads the column as its date text.
      sql = _tlp_sql((q = TLP.Tlp_row.objects; q.values("id"); q.filter("seen__@startswith" => "2009"); q); conn = conn)
      @test params(q -> (q.values("id"); q.filter("seen__@startswith" => "2009")), conn) == ["2009%"]
      @test occursin(conn === _TLP_PG ? "to_char(\"Tb\".\"seen\", 'YYYY-MM-DD') LIKE" : "\"Tb\".\"seen\" LIKE", sql)
      # A transform reads the text of what it yields (review): `@date` is a date, so PostgreSQL reads
      # it through `to_char` too, and a date part is an integer, read as its digits. On SQLite both
      # are already text to `LIKE`. Without this, PostgreSQL got a `LIKE` on a `date` / an integer.
      tsql(path, v) = _tlp_sql((q = TLP.Tlp_row.objects; q.values("id"); q.filter(path => v); q); conn = conn)
      if conn === _TLP_PG
        @test occursin("to_char((\"Tb\".\"ts\")::date, 'YYYY-MM-DD') LIKE", tsql("ts__@date__@startswith", "2009"))
        @test occursin("CAST(EXTRACT(HOUR FROM \"Tb\".\"ts\")::integer AS text) LIKE", tsql("ts__@hour__@startswith", "2"))
        aliased = _tlp_sql((q = TLP.Tlp_row.objects; q.values("y" => Fn.Extract("seen", "YEAR")); q.filter("y__@startswith" => "200"); q); conn = conn)
        @test occursin("CAST(EXTRACT(YEAR FROM \"Tb\".\"seen\")::integer AS text) LIKE", aliased)
      else
        @test occursin("WHERE CAST(strftime('%H', \"Tb\".\"ts\") AS INTEGER) LIKE ?", tsql("ts__@hour__@startswith", "2"))
      end
      # A number column binds its fragment as text, a float as the text it always bound; a text
      # column still refuses a float (#860), and no column takes a Bool (#876).
      @test params(q -> (q.values("id"); q.filter("id__@startswith" => 1)), conn) == ["1%"]
      @test params(q -> (q.values("id"); q.filter("id__@startswith" => 1.5)), conn) == ["1.5%"]
      @test refusal(q -> (q.values("id"); q.filter("note__@contains" => 1.5)), conn) isa PormG.InvalidValueError
      @test refusal(q -> (q.values("id"); q.filter("seen__@startswith" => true)), conn) isa PormG.InvalidValueError
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #955: a transform and its `Extract` twin are one grouped expression.
# The #798 grouping check matches a grouped projection against the same expression elsewhere by a
# structural signature of the node, kwargs included. While the ladder tagged its nodes, a
# `"seen__@year"` node and a public `Extract("seen", "YEAR")` stopped matching and a valid mixed
# projection was refused. With no tag (#1070) they are the same node.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#955: a transform does not split a grouped expression from its Extract twin" begin
  Fn = PormG.Functions
  for (backend, conn) in _TLP_BACKENDS
    q = TLP.Tlp_row.objects
    q.values("y" => "seen__@year", "x" => Fn.Coalesce(Fn.Extract("seen", "YEAR"), PormG.QueryBuilder.Count("id")))
    @test occursin("GROUP BY", _tlp_sql(q; conn = conn))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1070 (review): the part's rule follows every spelling of the column, and stays with the part.
# A bare `F("note")` names a column as plainly as `"note"`, so it is checked as that column. A
# `TIMEZONE` part needs a zoned timestamp: PostgreSQL rejects it over `type = "TIMESTAMP"`. The public
# `ToChar(x, "YYYY-MM")` IS `@yyyy_mm`, so it gets the same value check. And the range belongs to the
# part only: a `Coalesce` over it may be its fallback (`0` for a NULL date), while `Max` of an hour is
# still an hour.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1070: bare F columns, zoned timestamps, ToChar's mask, and Coalesce over a part" begin
  Fn = PormG.Functions
  plain(e) = replace(PormG.error_message(e), r"\e\[[0-9;]*m" => "")
  built(model, f, conn) = (try _tlp_sql((q = model.objects; f(q); q); conn = conn); catch e; e end)
  for (backend, conn) in _TLP_BACKENDS
    @testset "$backend" begin
      # A bare `F` column is checked; an `F` with an operation is an expression and is not.
      e = built(TLP.Tlp_row, q -> q.values("x" => Fn.Extract(F("note"), "YEAR")), conn)
      @test e isa PormG.QueryBuildError && occursin("CharField", plain(e))
      @test built(TLP.Tlp_row, q -> q.values("x" => Fn.Extract(F("seen"), "YEAR")), conn) isa AbstractString
      # `TIMEZONE` over a timestamp without a zone is refused on both engines, naming why.
      e = built(TLP.Tlp_clock, q -> q.values("x" => Fn.Extract("naive", "TIMEZONE")), conn)
      @test e isa PormG.QueryBuildError && occursin("with a time zone", plain(e))
      # `ToChar`'s `YYYY-MM` mask checks the value's shape as `@yyyy_mm` does, through an alias.
      @test built(TLP.Tlp_row, q -> (q.values("ym" => Fn.ToChar("seen", "YYYY-MM")); q.filter("ym" => "not-a-month")), conn) isa PormG.InvalidValueError
      @test built(TLP.Tlp_row, q -> (q.values("ym" => Fn.ToChar("seen", "YYYY-MM")); q.filter("ym" => "2009-12")), conn) isa AbstractString
      # A `Coalesce` over a part may hold its fallback; `Max` of a part keeps the part's range.
      @test built(TLP.Tlp_row, q -> (q.values("m" => Fn.Coalesce("ts__@month", 0)); q.filter("m" => 0)), conn) isa AbstractString
      @test built(TLP.Tlp_row, q -> (q.values("m" => Fn.Coalesce(Fn.Extract("ts", "HOUR"), -1)); q.filter("m" => -1)), conn) isa AbstractString
      @test built(TLP.Tlp_row, q -> (q.values("ym" => Fn.Coalesce("seen__@yyyy_mm", Fn.Value("none"))); q.filter("ym" => "none")), conn) isa AbstractString
      @test built(TLP.Tlp_row, q -> (q.values("note", "mh" => Fn.Max(Fn.Extract("ts", "HOUR"))); q.filter("mh" => 24)), conn) isa PormG.InvalidValueError
    end
  end
  # PostgreSQL only — SQLite has no `TIMEZONE` part — a zoned timestamp reads its zone.
  @test occursin("TIMEZONE", _tlp_sql((q = TLP.Tlp_row.objects; q.values("x" => Fn.Extract("ts", "TIMEZONE")); q); conn = _TLP_PG))
end
