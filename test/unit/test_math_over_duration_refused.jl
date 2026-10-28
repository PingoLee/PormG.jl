"""
#1324 — a number function over a duration is refused on every engine when the query is built.

`Round`, `Floor`, `Ceil`, `Sqrt`, `Exp`, `Ln`, `Power`, `Mod` and `Abs` mean a number. A duration is
not one, and each engine computed something else over it. For a 2009 fastest lap of `1:27.706`:

| expression | PostgreSQL | SQLite | MySQL |
|---|---|---|---|
| `Round(F("fastestlaptime"))` | fails at the server (`interval` to `numeric`) | `0.0`, computed on the `HH:MM:SS` text | the count of microseconds, unchanged |
| `Sqrt(F("fastestlaptime"))` | fails at the server | `NULL` | a `Float64` over the microseconds |
| `Abs(F("fastestlaptime"))` | fails at the server | refused (#900) | refused (#900) |

`Abs` was already refused on SQLite and MySQL; the others built. A function now states which operand
kinds it means beside its constructor (`_operand_domain`, as `_result_rule` is), and a duration
operand of one that means numbers only is refused on every engine, naming the spelling of a duration's
seconds where the engine has one (`Extract(d, "epoch")` on PostgreSQL and MySQL; SQLite has no `EPOCH`
part). `Sum` and `Avg` mean a duration's total and mean, and keep building.

#1388: every part but `EPOCH` of a duration expression is refused on every engine, as #1070 refuses
it over a `DurationField` column. A CALENDAR part (`Extract(F("fastestlaptime") * 2, "year")`, `@date`,
`@quarter`, `@week_day`) has no meaning: a duration has no calendar date. A CLOCK part
(`Extract(F("start_at") - F("date"), "hour")`) has no single one: PostgreSQL reads a component that
depends on how the interval was formed, SQLite read `NULL` above 24 h, and MySQL its count of
microseconds as a time.

#1406: on PostgreSQL a time of day minus a time of day is a duration, so all of the above cover it.

Everything renders through mock connections — no live database, no fixture.

julia --project=test/integration test/unit/test_math_over_duration_refused.jl
"""

using Test
using Dates
using PormG
using PormG.Models
using PormG.QueryBuilder: inspect_query
import PormG: QueryBuildError

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`, so a
# shared key would let another file's settings decide this file's dialect.
struct ModMockSQLite <: PormG.PormGSQLite end
struct ModMockPostgres <: PormG.PormGPostgres end
struct ModMockMySQL <: PormG.PormGMySQL end
const _MOD_SL = ModMockSQLite()
const _MOD_PG = ModMockPostgres()
const _MOD_MY = ModMockMySQL()
PormG.backend_sqlite_version(::ModMockSQLite) = 3045000
const _MOD_ENGINES = ((_MOD_PG, "PostgreSQL"), (_MOD_SL, "SQLite"), (_MOD_MY, "MySQL"))

PormG.config["mod_mock"] = PormG.Configuration.Settings(
  connections = _MOD_SL, change_data = true, db_def_folder = "mod_mock",
)

# The F1 result, with a fastest-lap duration, a number, a float and the race's start, date and time.
module ModModels
import PormG
import PormG.Models

Mod_result = Models.Model("mod_result",
  resultid       = Models.IDField(),
  grid           = Models.IntegerField(null = true),
  points         = Models.FloatField(null = true),
  fastestlaptime = Models.DurationField(null = true),
  start_at       = Models.DateTimeField(null = true),
  date           = Models.DateField(null = true),
  time           = Models.TimeField(null = true),   # #1406
)

PormG.Models.set_models(@__MODULE__, "mod_mock")
end

const MOD = ModModels
const Fn = PormG.Functions
# Not `F`: `runtests.jl` includes every unit file into one `Main`, where `F` is already imported.
const _MF = PormG.QueryBuilder.F

# A fresh queryset projecting `expr`, rendered on `conn`; the exception it raises, or `nothing`.
_mod_render(expr; conn) =
  inspect_query((q = MOD.Mod_result.objects; q.values("v" => expr); q); connection = conn)[:sql_text]
_mod_refusal(expr; conn) = try _mod_render(expr; conn = conn); nothing catch e; e end
# The message without ANSI colour, so a needle never spans a colourised token.
_mod_msg(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")

# The refusal on every engine: the function by its name, the reason that holds everywhere, #1324, and
# the engine's own remedy — `Extract(d, "epoch")` where it reads a duration's seconds, none on SQLite.
function _mod_refused(expr, name; remedy = :epoch)
  for (conn, engine) in _MOD_ENGINES
    err = _mod_refusal(expr; conn = conn)
    @test err isa QueryBuildError
    err isa QueryBuildError || continue
    msg = _mod_msg(err)
    @test occursin("`$(name)` of a duration is not supported: a duration is not a number, so `$(name)` " *
                   "has no meaning over one on any engine (#1324)", msg)
    if remedy === :abs
      @test occursin("Greatest(d, d * -1)", msg)
    elseif conn === _MOD_SL
      @test occursin("SQLite has no spelling for a duration's seconds", msg) && !occursin("epoch", msg)
    else
      @test occursin("Extract(d, \"epoch\"), and apply `$(name)` to that", msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1324: every number function over a DurationField column is refused on every engine
# `Round` (with and without places), `Floor`, `Ceil`, `Sqrt`, `Exp`, `Ln`, `Power` and `Mod` (the
# duration as either operand) and `Abs`. PostgreSQL failed each at the server, SQLite computed on the
# text (`Round` read `0.0`, `Sqrt` NULL), MySQL on the count of microseconds. Refused when built, with
# one reason on every engine. Expected SQL: none.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1324: a number function over a duration column is refused on every engine" begin
  for (expr, name) in ((Fn.Round("fastestlaptime"), "Round"), (Fn.Round("fastestlaptime", 2), "Round"),
                       (Fn.Floor("fastestlaptime"), "Floor"), (Fn.Ceil("fastestlaptime"), "Ceil"),
                       (Fn.Sqrt("fastestlaptime"), "Sqrt"), (Fn.Exp("fastestlaptime"), "Exp"),
                       (Fn.Ln("fastestlaptime"), "Ln"), (Fn.Power("fastestlaptime", 2), "Power"),
                       (Fn.Power(2, "fastestlaptime"), "Power"), (Fn.Mod("fastestlaptime", 3), "Mod"))
    _mod_refused(expr, name)
  end
  # `Abs` keeps the spelling #900 named, now with the reason that holds on every engine.
  _mod_refused(Fn.Abs("fastestlaptime"), "Abs"; remedy = :abs)
end

# ─────────────────────────────────────────────────────────────────────────────
# #1324: a duration EXPRESSION is a duration too
# The type walk names interval arithmetic, a `Sum` of a duration and a timestamp difference as a
# duration, so a number function over one is refused as over the column. `Floor` named nothing over
# an interval before, so it was refused only under arithmetic on SQLite (#1310); it is refused alone
# now, on every engine. Expected SQL: none.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1324: a number function over a duration expression is refused on every engine" begin
  _mod_refused(Fn.Round(_MF("fastestlaptime") * 2), "Round")
  _mod_refused(Fn.Floor(_MF("fastestlaptime") * 2), "Floor")
  _mod_refused(Fn.Sqrt(Fn.Sum("fastestlaptime")), "Sqrt")
  _mod_refused(Fn.Ceil(_MF("start_at") - _MF("start_at")), "Ceil")
  # Under arithmetic too: `Floor(<a duration>) / 2` is refused at the `Floor`, before the quotient.
  _mod_refused(Fn.Floor(_MF("fastestlaptime") * 2) / 2, "Floor")
end

# ─────────────────────────────────────────────────────────────────────────────
# #1406: a time of day minus a time of day is a duration on PostgreSQL
# PostgreSQL's `time - time` is an `interval`, but the type walk had no arm for a time on the left, so
# the difference had no kind and every check that reads the walk let it through: `Round` built
# `ROUND((…)::numeric)`, which fails at the server, and `Extract(…, "year")` built and read `0`. The
# walk now names it a duration (an engine fact, `_subtracts_times`), so the number-function refusal
# (#1324) and the calendar-part refusal (#1388) cover it with no change of their own, and the column
# reads back as a duration. SQLite and MySQL keep refusing arithmetic on a time of day (#1323).
# Expected SQL on PostgreSQL: `("Tb"."time" - "Tb"."time")`, read as an interval.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1406: time minus time is a duration on PostgreSQL" begin
  diff = () -> _MF("time") - _MF("time")
  # The projection builds, and records the kind its value is read back as.
  q = MOD.Mod_result.objects
  q.values("v" => diff())
  sql = PormG.QueryBuilder.query(q; show_query = :sql, connection = _MOD_PG)
  @test occursin("(\"Tb\".\"time\" - \"Tb\".\"time\")", sql)
  @test get(q.object.projection_kinds, :v, nothing) isa PormG.CInterval
  # A filter on the alias takes a duration, as over a `DurationField`.
  q = MOD.Mod_result.objects
  q.values("v" => diff())
  q.filter("v__@gt" => Minute(1))
  @test inspect_query(q; connection = _MOD_PG)[:parameters] == ["00:01:00"]
  # Every check that reads the walk covers it now: a number function and a calendar part.
  for (expr, name) in ((Fn.Round(diff()), "Round"), (Fn.Floor(diff()), "Floor"), (Fn.Sqrt(diff()), "Sqrt"))
    err = _mod_refusal(expr; conn = _MOD_PG)
    @test err isa QueryBuildError && occursin("`$(name)` of a duration is not supported", _mod_msg(err))
  end
  for part in ("year", "quarter", "dow", "hour", "second")
    err = _mod_refusal(Fn.Extract(diff(), part); conn = _MOD_PG)
    @test err isa QueryBuildError &&
          occursin("The $(part) part over a duration is not supported", _mod_msg(err))
  end
  # EPOCH reads a duration's seconds and builds.
  @test _mod_refusal(Fn.Extract(diff(), "epoch"); conn = _MOD_PG) === nothing
  # SQLite and MySQL refuse the arithmetic itself, as before (#1323).
  for conn in (_MOD_SL, _MOD_MY)
    err = _mod_refusal(diff(); conn = conn)
    @test err isa QueryBuildError && occursin("on a time of day", _mod_msg(err))
  end
  # Only `-` of two times: a time plus a time has no meaning, and stays untyped.
  q = MOD.Mod_result.objects
  q.values("v" => _MF("time") + _MF("time"))
  PormG.QueryBuilder.query(q; show_query = :sql, connection = _MOD_PG)
  @test get(q.object.projection_kinds, :v, nothing) === nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# #1324: what a number function means keeps building
# `Sum` and `Avg` mean a duration's total and mean (their `_operand_domain` holds `:interval`); every
# function over a number builds as before; and the spelling the refusal names, a function over a
# duration's seconds, builds where the engine reads them (PostgreSQL, MySQL). Expected SQL: as before.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1324: Sum and Avg of a duration, and math over numbers, build" begin
  for (conn, _) in _MOD_ENGINES
    for expr in (Fn.Sum("fastestlaptime"), Fn.Avg("fastestlaptime"), Fn.Round("points", 1), Fn.Floor("grid"),
                 Fn.Sqrt("points"), Fn.Power("grid", 2), Fn.Mod("grid", 3), Fn.Abs("points"))
      @test _mod_refusal(expr; conn = conn) === nothing
    end
  end
  for conn in (_MOD_PG, _MOD_MY)
    @test _mod_refusal(Fn.Round(Fn.Extract("fastestlaptime", "epoch")); conn = conn) === nothing
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1324: the fact is stated beside each constructor
# `_operand_domain` answers for every function whose `_result_rule` computes a number, so a new one
# cannot skip the question (`test_expression_kind_rules.jl` enumerates them). Expected: `Sum`/`Avg`
# hold `:interval`, the others `:number` only.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1324: which operands each number function means" begin
  QB = PormG.QueryBuilder
  @test QB._operand_domain(Val(:SUM)) == (:number, :interval)
  @test QB._operand_domain(Val(:AVG)) == (:number, :interval)
  for n in (:ABS, :ROUND, :FLOOR, :CEIL, :SQRT, :EXP, :LN, :POWER, :MOD)
    @test QB._operand_domain(Val(n)) == (:number,)
  end
  @test QB._operand_domain(Val(:COALESCE)) === nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# #1388: a clock part of a duration expression is refused on every engine
# #1324 refused it on MySQL alone, which read its count of microseconds as a time; PostgreSQL and
# SQLite built it. Measured on the F1 fixture (#1388): SQLite read `NULL` for a duration of 24 hours
# or more and for a negative one, and PostgreSQL's component depends on how the interval was formed
# (a 62-hour timestamp difference reads hour 14, a 208-hour sum 208). The build now refuses it on every
# engine, as #1070 refuses it over a `DurationField` column, naming the engine's spelling of a
# duration's seconds (none on SQLite). Expected SQL: none.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1388: a clock part over a duration expression is refused on every engine" begin
  shapes = ((Fn.Extract(_MF("start_at") - _MF("start_at"), "hour"), "hour"),
            (Fn.Extract(_MF("start_at") - _MF("date"), "minute"), "minute"),
            (Fn.Extract(_MF("fastestlaptime") * 2, "minute"), "minute"),
            (Fn.Extract(_MF("fastestlaptime") * 2, "second"), "second"),
            (Fn.Extract(Fn.Sum("fastestlaptime"), "second"), "second"),
            (Fn.Extract(Fn.Avg("fastestlaptime"), "hour"), "hour"),
            (Fn.Extract(_MF("fastestlaptime") * 2, "milliseconds"), "milliseconds"),
            (Fn.Extract(_MF("fastestlaptime") * 2, "microseconds"), "microseconds"))
  for (expr, part) in shapes, (conn, engine) in _MOD_ENGINES
    err = _mod_refusal(expr; conn = conn)
    @test err isa QueryBuildError
    err isa QueryBuildError || continue
    msg = _mod_msg(err)
    @test occursin("The $(part) part over a duration is not supported: the part reads a time of day, " *
                   "and a duration has none", msg)
    @test occursin("(#1388)", msg)
    if conn === _MOD_SL
      @test occursin("SQLite has no spelling for a duration's seconds", msg) && !occursin("epoch", msg)
    else
      @test occursin("For a duration's seconds, write Extract(d, \"epoch\").", msg)
    end
  end
  # The alias, filtered: the same refusal, before any value is compared.
  for (conn, _) in _MOD_ENGINES
    err = try
      inspect_query((q = MOD.Mod_result.objects; q.values("h" => Fn.Extract(_MF("fastestlaptime") * 2, "hour"));
                     q.filter("h" => 1); q); connection = conn)
      nothing
    catch e
      e
    end
    @test err isa QueryBuildError && occursin("The hour part over a duration", _mod_msg(err))
  end
  # A `TIMEZONE` part reads a zoned timestamp, which a duration is not: no meaning at all, not "no
  # single" one.
  for (conn, _) in _MOD_ENGINES, part in ("timezone", "timezone_hour")
    err = _mod_refusal(Fn.Extract(_MF("start_at") - _MF("date"), part); conn = conn)
    @test err isa QueryBuildError
    err isa QueryBuildError || continue
    msg = _mod_msg(err)
    @test occursin("over a duration is not supported: the part reads a timestamp with a time zone, and a " *
                   "duration has none, so the part has no meaning over one on any engine (#1388)", msg)
  end
end

# The #1388 refusal, without colour: the part, the reason that holds on every engine, no remedy.
_mod_calendar_refused(msg, label) =
  occursin("$(label) over a duration is not supported: a duration has no calendar date on any engine", msg) &&
  occursin("(#1388)", msg) && !occursin("epoch", msg)

# ─────────────────────────────────────────────────────────────────────────────
# #1388: a calendar part of a duration expression is refused on every engine
# #1070 refused every part but EPOCH over a `DurationField` column, by its field, and let an
# expression through. A timestamp difference, interval arithmetic or a `Sum` of a duration has no
# calendar date either. PostgreSQL built `EXTRACT(QUARTER FROM (…))` over the interval, SQLite read the
# duration's text or milliseconds as a date, and MySQL refused with #1324's epoch remedy. Now the type
# walk names the operand a duration and the build refuses it on every engine with one reason; the
# `century` part, which SQLite refused as a missing feature, gets the same reason there. Expected SQL:
# none.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1388: a calendar part over a duration expression is refused on every engine" begin
  QB = PormG.QueryBuilder
  shapes = (
    (Fn.Extract(_MF("start_at") - _MF("date"), "quarter"), "quarter"),
    (Fn.Extract(_MF("fastestlaptime") * 2, "year"), "year"),
    (Fn.Extract(_MF("fastestlaptime") * 2, "century"), "century"),
    (Fn.Extract(Fn.Sum("fastestlaptime"), "month"), "month"),
    (Fn.Extract(_MF("start_at") - _MF("start_at"), "dow"), "dow"),
    (Fn.Extract(_MF("fastestlaptime") + _MF("fastestlaptime"), "week"), "week"),
    (Fn.Extract(Fn.Avg("fastestlaptime"), "isodow"), "isodow"),
    (Fn.Extract(_MF("fastestlaptime") * 2, "doy"), "doy"),
    (QB.DATE(_MF("fastestlaptime") * 2), "date"),
    (QB.QUARTER(_MF("start_at") - _MF("date")), "quarter"),
    (QB.QUADRIMESTER(Fn.Sum("fastestlaptime")), "quadrimester"),
    (QB.WEEK_DAY(_MF("fastestlaptime") * 2), "week_day"),
    (Fn.ToChar(_MF("fastestlaptime") * 2, "YYYY-MM"), "yyyy_mm"),
  )
  for (expr, part) in shapes, (conn, engine) in _MOD_ENGINES
    err = _mod_refusal(expr; conn = conn)
    @test err isa QueryBuildError
    err isa QueryBuildError || continue
    @test _mod_calendar_refused(_mod_msg(err), "The $(part) part")
  end
  # The same node filtered and ordered by its alias, the spelling `filter`/`order_by` take for one.
  for (conn, _) in _MOD_ENGINES
    part = Fn.Extract(_MF("fastestlaptime") * 2, "year")
    for build in (q -> (q.values("y" => part); q.filter("y" => 2009)),
                  q -> (q.values("resultid", "y" => part); q.order_by("y")))
      err = try
        inspect_query((q = MOD.Mod_result.objects; build(q); q); connection = conn); nothing
      catch e
        e
      end
      @test err isa QueryBuildError && _mod_calendar_refused(_mod_msg(err), "The year part")
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1388: what the duration refusal leaves alone
# EPOCH builds where the engine has it. A date plus a duration is a timestamp, so its calendar and
# clock parts build. A clock part of a timestamp difference's own operands, and of a time column,
# builds. A `DurationField` column keeps #1070's message. Expected SQL on PostgreSQL for a timestamp's
# hour: `EXTRACT(HOUR FROM (…))::integer`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1388: EPOCH, timestamps and columns are unchanged" begin
  for (conn, engine) in _MOD_ENGINES
    @test _mod_refusal(Fn.Extract(_MF("date") + _MF("fastestlaptime"), "year"); conn = conn) === nothing
    @test _mod_refusal(Fn.Extract(_MF("start_at") + _MF("fastestlaptime"), "hour"); conn = conn) === nothing
    @test _mod_refusal(Fn.Extract("time", "hour"); conn = conn) === nothing
    for part in ("year", "hour")
      err = _mod_refusal(Fn.Extract("fastestlaptime", part); conn = conn)
      @test err isa QueryBuildError && occursin("(#1070)", _mod_msg(err)) && !occursin("#1388", _mod_msg(err))
    end
  end
  @test occursin("EXTRACT(HOUR FROM", _mod_render(Fn.Extract(_MF("start_at") + _MF("fastestlaptime"), "hour"); conn = _MOD_PG))
  for conn in (_MOD_PG, _MOD_MY)
    @test _mod_refusal(Fn.Extract(_MF("fastestlaptime") * 2, "epoch"); conn = conn) === nothing
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1388: MySQL's date arms say the same
# The build refuses a calendar part before a MySQL arm renders, but the arms that read the operand's
# temporal kind refuse it too, with the #1388 reason instead of #1324's epoch remedy: `@date`,
# `@quarter`, `@quadrimester`, `@week_day`, and `Extract`'s calendar parts. `Extract`'s clock parts
# keep the epoch remedy, and a date operand renders as before. Expected SQL for a date: `QUARTER(x)`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1388: MySQL's date arms refuse a calendar part of a duration" begin
  for (fn, label) in ((:DATE, "@date"), (:QUARTER, "@quarter"), (:QUADRIMESTER, "@quadrimester"),
                      (:WEEK_DAY, "@week_day"))
    arm = getfield(PormG.Dialect, fn)
    err = try arm("x", Dict{String,Any}("temporal_kind" => :interval), _MOD_MY); nothing catch e; e end
    @test err isa QueryBuildError && _mod_calendar_refused(_mod_msg(err), label)
    @test arm("x", Dict{String,Any}("temporal_kind" => :date), _MOD_MY) isa String
  end
  @test PormG.Dialect.QUARTER("x", Dict{String,Any}("temporal_kind" => :date), _MOD_MY) == "QUARTER(x)"
  extract(part) = try
    PormG.Dialect.EXTRACT("x", Dict{String,Any}("part" => part, "temporal_kind" => :interval), _MOD_MY)
  catch e
    e
  end
  # `century` and `julian` have no MySQL spelling, and still meet the duration's refusal first.
  for part in ("year", "quarter", "dow", "isoyear", "century", "julian")
    err = extract(part)
    @test err isa QueryBuildError && _mod_calendar_refused(_mod_msg(err), "Extract(…, \"$(part)\")")
  end
  for part in ("hour", "microseconds")
    err = extract(part)
    @test err isa QueryBuildError && occursin("over a duration expression is not supported on MySQL", _mod_msg(err)) &&
          occursin("Extract(d, \"epoch\")", _mod_msg(err))
  end
  @test extract("epoch") == "(x / 1000000)"
end
