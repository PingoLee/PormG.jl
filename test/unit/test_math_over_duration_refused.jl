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

MySQL also holds a duration EXPRESSION as its count of microseconds, so a date part of one
(`Extract(F("start_at") - F("date"), "hour")`) read that count as a date or a time; it is refused on
MySQL, which departs, and only `EPOCH` builds there. PostgreSQL and SQLite do not move for that part.

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

# The F1 result, with a fastest-lap duration, a number, a float and the race's start and date.
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
# #1324: a date part of a duration expression is refused on MySQL, which departs
# MySQL holds a duration as its count of microseconds, so `EXTRACT(HOUR FROM <that count>)` read the
# count as a date or a time where PostgreSQL reads the interval's hours component. Refused on MySQL,
# naming `Extract(d, "epoch")`, which builds there; PostgreSQL and SQLite do not move here. Expected
# SQL on PostgreSQL: the part of the interval, `EXTRACT(HOUR FROM (…))`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1324: Extract over a duration expression on MySQL" begin
  for (expr, part) in ((Fn.Extract(_MF("start_at") - _MF("start_at"), "hour"), "hour"),
                       (Fn.Extract(_MF("fastestlaptime") * 2, "minute"), "minute"),
                       (Fn.Extract(Fn.Sum("fastestlaptime"), "second"), "second"))
    err = _mod_refusal(expr; conn = _MOD_MY)
    @test err isa QueryBuildError
    err isa QueryBuildError || continue
    msg = _mod_msg(err)
    @test occursin("Extract(…, \"$(part)\") over a duration expression is not supported on MySQL", msg)
    @test occursin("Extract(d, \"epoch\")", msg)
    @test _mod_refusal(expr; conn = _MOD_PG) === nothing
  end
  @test _mod_refusal(Fn.Extract(_MF("fastestlaptime") * 2, "epoch"); conn = _MOD_MY) === nothing
  # The four transforms MySQL renders from a date part refuse a duration operand at their Dialect arm,
  # as `Extract` does; a date operand renders as before.
  for (fn, label) in ((:DATE, "@date"), (:QUARTER, "@quarter"), (:QUADRIMESTER, "@quadrimester"),
                      (:WEEK_DAY, "@week_day"))
    arm = getfield(PormG.Dialect, fn)
    err = try arm("x", Dict{String,Any}("temporal_kind" => :interval), _MOD_MY); nothing catch e; e end
    @test err isa QueryBuildError && occursin("$(label) over a duration expression is not supported on MySQL", _mod_msg(err))
    @test arm("x", Dict{String,Any}("temporal_kind" => :date), _MOD_MY) isa String
  end
end
