"""
A duration literal as an interval VALUE (#1553).

A Dates period (or an `Interval`) was only a SHIFT operand (#25): `F("date") + Day(1)` built and nothing
else did. As an interval value — scaled by a number, divided by one, beside an interval on either side —
it was refused on every engine: `F("grid") * Day(1)` by #1476's right-hand catch-all, `Day(1) * F("grid")`,
`Day(1) / F("grid")` and `Day(1) - F("lap")` by #1549's left-hand one, and `F("lap") - Day(1)` with an
`InvalidValueError` from the date-column check. An interval COLUMN already took this arithmetic (#881);
what was missing is the literal rendered as an interval value:

  - PostgreSQL: `make_interval(<unit> => \$n::integer, …)`, an `interval`;
  - SQLite: the duration in milliseconds, bound as an integer (`_IntervalMs`, #881);
  - MySQL: the duration in microseconds, bound as an integer, as a `DurationField` stores it (#1130).

A month or a year has no fixed length, so it is a value only on PostgreSQL, whose `interval` keeps months
apart: SQLite and MySQL refuse it as the `calendar_intervals` capability, and so does the shape that
refused it before #1553 (a timestamp difference `+ Month(1)`), which raised a `QueryBuildError` then.

What stays refused, on every engine, is what has no meaning: a number or an interval divided by a
duration (at construction), a duration minus a number or a date, a duration divided by an interval, and
a date, a text column or an interval multiplied by a duration. PostgreSQL refuses them at build too,
rather than emitting SQL that fails when the statement runs.

Everything renders through mock connections — no live database. The read-back is
`test/integration/test_field_expressions.jl` → "#1553".

julia --project=test/integration test/unit/test_duration_value_1553.jl
"""

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: F, inspect_query
using PormG: Interval
using Dates
import PormG.QueryBuilder as QB

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`.
struct Dv1553MockSQLite <: PormG.PormGSQLite end
struct Dv1553MockPostgres <: PormG.PormGPostgres end
struct Dv1553MockMySQL <: PormG.PormGMySQL end
const _DV_SL = Dv1553MockSQLite()
const _DV_PG = Dv1553MockPostgres()
const _DV_MY = Dv1553MockMySQL()
PormG.backend_sqlite_version(::Dv1553MockSQLite) = 3045000

PormG.config["dv1553_mock"] = PormG.Configuration.Settings(
  connections = _DV_SL, change_data = true, db_def_folder = "dv1553_mock",
)

module Dv1553Models
import PormG
import PormG.Models

Dv_lap = Models.Model("dv_lap",
  id        = Models.IDField(),
  grid      = Models.IntegerField(null = true),
  points    = Models.FloatField(null = true),
  lap       = Models.DurationField(null = true),
  seen      = Models.DateField(null = true),
  logged_at = Models.DateTimeField(null = true),
  code      = Models.CharField(null = true),
)

PormG.Models.set_models(@__MODULE__, "dv1553_mock")
end

const DV = Dv1553Models
_dv_proj(expr) = (q = DV.Dv_lap.objects; q.values("x" => expr); q)
_dv_sql(expr, conn) = inspect_query(_dv_proj(expr); connection = conn)[:sql_text]
_dv_params(expr, conn) = inspect_query(_dv_proj(expr); connection = conn)[:parameters]
_dv_plain(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")
_dv_err(f) = try f(); nothing catch e; e end

# The SQLite reading of the `lap` column's `[-]HH:MM:SS[.f]` text as signed milliseconds, spelled out
# (it is `Dialect._sqlite_interval_ms`, the #881 reader, under test here only as the left's form).
const _DV_LAP_MS = "((CASE WHEN substr(\"Tb\".\"lap\", 1, 1) = '-' THEN -1 ELSE 1 END) * " *
                   "(CAST(ltrim(\"Tb\".\"lap\", '+-') AS INTEGER) * 3600000 + " *
                   "CAST(substr(\"Tb\".\"lap\", instr(\"Tb\".\"lap\", ':') + 1, 2) AS INTEGER) * 60000 + " *
                   "CAST(round(CAST(substr(\"Tb\".\"lap\", instr(\"Tb\".\"lap\", ':') + 4) AS REAL) * 1000) AS INTEGER)))"

# ─────────────────────────────────────────────────────────────────────────────
# #1553: each shape builds on all three engines, to the interval it means
# Expected, per (shape, engine): the SQL fragment and the bound parameters. PostgreSQL binds the
# duration's components into `make_interval`; SQLite binds its milliseconds (one hour is 3_600_000)
# and MySQL its microseconds (3_600_000_000), and both round a product or a quotient back to a whole
# unit (#881). Every row raised before #1553, so none of these assertions holds on the unpatched code.
# Why it matters: a lap time scaled by a lap count, an hour split across a grid, a limit less a lap time
# are durations users write; the interval column already took the same arithmetic.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1553: a duration literal as an interval value — $label" for (label, expr, pg, sl, my, pgp, unitp) in (
    ("F int * duration", () -> F("grid") * Hour(1),
     "(\"Tb\".\"grid\" * make_interval(hours => \$1::integer))",
     "CAST(round((\"Tb\".\"grid\") * (?)) AS INTEGER)",
     "CAST(ROUND((`Tb`.`grid`) * (?)) AS SIGNED)", Any[1], 1),
    ("duration * F int (commutes)", () -> Hour(1) * F("grid"),
     "(\"Tb\".\"grid\" * make_interval(hours => \$1::integer))",
     "CAST(round((\"Tb\".\"grid\") * (?)) AS INTEGER)",
     "CAST(ROUND((`Tb`.`grid`) * (?)) AS SIGNED)", Any[1], 1),
    ("duration / F int", () -> Hour(1) / F("grid"),
     "(make_interval(hours => \$1::integer) / \"Tb\".\"grid\")",
     "CAST(round((?) * 1.0 / (\"Tb\".\"grid\")) AS INTEGER)",
     "CAST(ROUND((?) * 1.0 / (`Tb`.`grid`)) AS SIGNED)", Any[1], 1),
    ("F interval - duration", () -> F("lap") - Hour(1),
     "(\"Tb\".\"lap\" - make_interval(hours => \$1::integer))",
     "($(_DV_LAP_MS) - ?)",
     "(`Tb`.`lap` - ?)", Any[1], 1),
    ("F interval + duration", () -> F("lap") + Hour(1),
     "(\"Tb\".\"lap\" + make_interval(hours => \$1::integer))",
     "($(_DV_LAP_MS) + ?)",
     "(`Tb`.`lap` + ?)", Any[1], 1),
    ("duration + F interval (commutes)", () -> Hour(1) + F("lap"),
     "(\"Tb\".\"lap\" + make_interval(hours => \$1::integer))",
     "($(_DV_LAP_MS) + ?)",
     "(`Tb`.`lap` + ?)", Any[1], 1),
    ("duration - F interval", () -> Hour(1) - F("lap"),
     "(make_interval(hours => \$1::integer) - \"Tb\".\"lap\")",
     "(? - $(_DV_LAP_MS))",
     "(? - `Tb`.`lap`)", Any[1], 1),
    ("an Interval literal * F int", () -> Interval("01:00:00") * F("grid"),
     "(\"Tb\".\"grid\" * make_interval(hours => \$1::integer))",
     "CAST(round((\"Tb\".\"grid\") * (?)) AS INTEGER)",
     "CAST(ROUND((`Tb`.`grid`) * (?)) AS SIGNED)", Any[1], 1),
  )
  @test occursin(pg, _dv_sql(expr(), _DV_PG))
  @test _dv_params(expr(), _DV_PG) == pgp
  @test occursin(sl, _dv_sql(expr(), _DV_SL))
  @test _dv_params(expr(), _DV_SL) == Any[3_600_000 * unitp]
  @test occursin(my, _dv_sql(expr(), _DV_MY))
  @test _dv_params(expr(), _DV_MY) == Any[3_600_000_000 * unitp]
  # The value is an interval to the read path on every engine, so it reads back as a duration.
  for conn in (_DV_PG, _DV_SL, _DV_MY)
    q = _dv_proj(expr())
    PormG.QueryBuilder.query(q; show_query = :sql, connection = conn)
    @test get(q.object.projection_kinds, :x, nothing) == PormG.CInterval()
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1553: a duration value composes — a date shifted by a scaled duration, a comparison against one
# Expected: `F("seen") + F("grid") * Hour(1)` is the date shifted by the interval (#881's date + interval
# arm), a timestamp; `F("lap") > F("grid") * Second(30)` compares two intervals (numbers on SQLite and
# MySQL). PostgreSQL binds the component; SQLite the milliseconds.
# Why it matters: the value is only useful if the rest of the interval vocabulary takes it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1553: a duration value composes with dates and comparisons" begin
  shifted = () -> F("seen") + F("grid") * Hour(1)
  @test occursin("(\"Tb\".\"seen\" + (\"Tb\".\"grid\" * make_interval(hours => \$1::integer)))", _dv_sql(shifted(), _DV_PG))
  @test _dv_params(shifted(), _DV_SL) == Any[3_600_000]
  @test occursin("CAST(round((\"Tb\".\"grid\") * (?)) AS INTEGER)", _dv_sql(shifted(), _DV_SL))
  @test occursin("INTERVAL (CAST(ROUND((`Tb`.`grid`) * (?)) AS SIGNED)) MICROSECOND", _dv_sql(shifted(), _DV_MY))
  q = DV.Dv_lap.objects
  q.filter(F("lap") > F("grid") * Second(30))
  q.values("id")
  @test occursin("WHERE (\"Tb\".\"lap\" > (\"Tb\".\"grid\" * make_interval(secs => \$1::double precision)))",
                 inspect_query(q; connection = _DV_PG)[:sql_text])
  @test occursin("WHERE ($(_DV_LAP_MS) > CAST(round((\"Tb\".\"grid\") * (?)) AS INTEGER))",
                 inspect_query(q; connection = _DV_SL)[:sql_text])
  @test inspect_query(q; connection = _DV_SL)[:parameters] == Any[30_000]
end

# ─────────────────────────────────────────────────────────────────────────────
# #1553: a month or a year is a value only on PostgreSQL (`calendar_intervals`)
# Expected: `F("grid") * Month(1)` renders `make_interval(months => $1::integer)` on PostgreSQL and
# raises `BackendCapabilityError` on SQLite and MySQL, naming the feature and PostgreSQL. The shape
# that refused a month before (a timestamp difference `+ Month(1)`, a `QueryBuildError` through v0.9.0)
# raises the same capability error now: one fact, one refusal. A month SHIFT of a date still builds on
# every engine.
# Why it matters: a month has no fixed number of milliseconds, so SQLite and MySQL cannot compute one
# as a value; a silent 30-day month would be a different answer.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1553: a calendar duration as a value is PostgreSQL's" begin
  @test occursin("(\"Tb\".\"grid\" * make_interval(months => \$1::integer))", _dv_sql(F("grid") * Month(1), _DV_PG))
  @test occursin("(make_interval(years => \$1::integer) - \"Tb\".\"lap\")", _dv_sql(Year(1) - F("lap"), _DV_PG))
  @test PormG._supports(_DV_PG, :calendar_intervals)
  for conn in (_DV_SL, _DV_MY)
    @test !PormG._supports(conn, :calendar_intervals)
    for expr in (F("grid") * Month(1), Year(1) - F("lap"), F("lap") - Month(1),
                 (F("logged_at") - F("logged_at")) + Month(1))
      e = _dv_err(() -> _dv_sql(expr, conn))
      @test e isa PormG.BackendCapabilityError
      msg = _dv_plain(e)
      @test occursin("months or years", msg) && occursin("supported on PostgreSQL", msg)
    end
    # A shift of a date by a month is not a value: it builds on every engine.
    @test _dv_sql(F("seen") + Month(1), conn) isa String
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1553: what stays refused, on every engine
# Expected: `QueryBuildError` at construction for a number or an interval divided by a duration, and at
# build — on PostgreSQL too, which would otherwise emit SQL that fails when it runs — for a duration
# minus a number or a date, a duration divided by an interval, and a date, a text column or an interval
# multiplied by a duration. Each message says what the shape takes instead.
# Why it matters: these have no meaning (a number per hour, a duration minus a date) or no operator
# (`interval * interval`), and a refusal must name a spelling that works (the #536 class).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1553: what stays refused" begin
  for (label, f, needle) in (
      ("a number / duration", () -> F("grid") / Hour(1), "Day(1) / F(\"grid\")"),
      ("an interval / duration", () -> F("lap") / Hour(1), "Day(1) / F(\"grid\")"),
      ("CTE / duration", () -> PormG.CTE("g", "n") / Hour(1), "Day(1) / F(\"grid\")"))
    @testset "$label (construction)" begin
      e = _dv_err(f)
      @test e isa PormG.QueryBuildError
      @test occursin(needle, _dv_plain(e))
    end
  end
  for (label, expr, needle) in (
      ("duration - number", () -> Hour(1) - F("grid"), "takes an interval under `-`"),
      ("duration - date", () -> Hour(1) - F("seen"), "A duration minus a date has no meaning"),
      ("duration / interval", () -> Hour(1) / F("lap"), "takes an interval under `-`"),
      ("duration / text", () -> Hour(1) / F("code"), "takes an interval under `-`"),
      ("date * duration", () -> F("seen") * Hour(1), "A duration is scaled by a number"),
      ("text * duration", () -> F("code") * Hour(1), "A duration is scaled by a number"),
      ("interval * duration", () -> F("lap") * Hour(1), "A duration is scaled by a number"),
      ("float literal left", () -> F("grid") * 2 * Hour(1), nothing))
    @testset "$label: $(nameof(typeof(conn)))" for conn in (_DV_PG, _DV_SL, _DV_MY)
      if needle === nothing
        # `F("grid") * 2` is a number: it is scaled, not refused (the control row).
        @test _dv_sql(expr(), conn) isa String
      else
        e = _dv_err(() -> _dv_sql(expr(), conn))
        @test e isa PormG.QueryBuildError
        @test occursin(needle, _dv_plain(e))
      end
    end
  end
  # A zero-length duration is zero whatever its unit: `Month(0)` binds 0 where a month has no fixed
  # length, as the shift `F("lap") - Month(0)` is the identity there (review of #1553).
  for conn in (_DV_SL, _DV_MY)
    @test _dv_params(Month(0) * F("grid"), conn) == Any[0]
  end
  # A non-temporal column shifted by a duration keeps its #25 refusal.
  e = _dv_err(() -> _dv_sql(F("grid") + Hour(1), _DV_PG))
  @test e isa PormG.InvalidValueError
end

# ─────────────────────────────────────────────────────────────────────────────
# #1553: a CTE column takes a duration value as `F` does
# Expected: `CTE("g", "n") * Hour(1)` and `Hour(1) - CTE("g", "u")` construct an `FExpression` keeping the
# handle and the duration where they were written (`*` commutes, `-` keeps the duration on the left);
# `desc = true` is refused (#1539). The render of each is a matrix cell (`test_expression_kind_matrix.jl`).
# Why it matters: the handle is the one spelling of a CTE column; it must take what `F` takes.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1553: a CTE column takes a duration value" begin
  c = PormG.CTE("g", "n")
  x = c * Hour(1)
  @test x isa QB.FExpression && x.field_name === c && x.operation == "*" && x.operand == Hour(1)
  x = Hour(1) * c
  @test x isa QB.FExpression && x.field_name === c && x.operand == Hour(1)
  x = Hour(1) - c
  @test x isa QB.FExpression && x.field_name == Hour(1) && x.operation == "-" && x.operand === c
  x = Hour(1) / c
  @test x isa QB.FExpression && x.field_name == Hour(1) && x.operation == "/"
  @test _dv_err(() -> PormG.CTE("g", "n"; desc = true) * Hour(1)) isa PormG.QueryBuildError
  @test _dv_err(() -> Hour(1) - PormG.CTE("g", "n"; desc = true)) isa PormG.QueryBuildError
  # Functions and window functions take no duration (#1553 scope): their refusal keeps its advice.
  e = _dv_err(() -> Hour(1) * PormG.Functions.Max("grid"))
  @test e isa PormG.QueryBuildError && occursin("inside the function", _dv_plain(e))
end
