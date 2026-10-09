"""
A cast the engines apply differently is refused, and so are the remaining `Concat` operands with no
single text (#1028).

#1027 refused a boolean, float or decimal `Concat` operand. The same divergence reaches the SQL
through a declared cast, measured on PostgreSQL 16.15 and SQLite 3.45.1 against the F1 fixture:

| expression                               | PostgreSQL        | SQLite                 |
|------------------------------------------|-------------------|------------------------|
| `Cast(<float> 10.0, CharField())`        | `'10'`            | `'10.0'`               |
| `Cast(<bool> true, CharField())`         | `'true'`          | `'1'`                  |
| `Cast(<numeric(10,2)> 14, CharField())`  | `'14.00'`         | `'14'`                 |
| `Cast(<float> 1.5, IntegerField())`      | `2`               | `1` (truncates)        |
| `Cast(<float> -1.5, IntegerField())`     | `-2`              | `-1`                   |
| `Cast(<numeric> 2.5, IntegerField())`    | `3`               | `2`                    |
| `Cast(Round / Floor / Ceil(x), Integer)` | equal on both (±0.5, ±1.5, ±2.5, every `points` row) | |

`output_field` on `Coalesce`/`Greatest`/`Least` renders the same cast, so it follows the same rule.
Three `Concat` operand types #1027 let through differ too: a timestamp (`2009-03-29 06:00:00+00`
against `2009-03-29T06:00:00.000+00:00`), an interval (`PT25.021S` against `00:00:26.898`) and a
JSON document (`{"a": [1, 2]}` against `{"a":[1,2]}`). A date, a time and a uuid agree. And a CTE
column built from `Sum`/`Avg` is now classified by the body's own projection, so it is refused like
the aggregate written directly.

#1040 adds a third target. A cast to `numeric(p, s)` rounds to `s` digits on PostgreSQL and keeps
every digit on SQLite, measured on the same servers:

| expression                                   | PostgreSQL | SQLite  |
|----------------------------------------------|------------|---------|
| `Cast(<float> 1.5, "numeric(10,0)")`         | `2`        | `1.5`   |
| `Cast(<float> 1.555, "numeric(10,2)")`       | `1.56`     | `1.555` |
| `Cast(<text> '1.555', "numeric(10,2)")`      | `1.56`     | `1.555` |
| `Round(<float> 2.675 / 1.555 / 1.005, 2)`    | `2.68` / `1.56` / `1.01` | `2.67` / `1.55` / `1.0` |
| `Round(x)`, and `Cast(x, "numeric")` unscaled | equal on both (±1.5, ±2.5, 1.555, 2.675, 25.0, every `points` row) | |

#1050 narrows the float-literal arm to what diverges: `Cast(Value(1.5 / 0.1 / 2.25), "numeric(10,2)")`
reads the same on both engines, so only a literal with more than `s` places, or more than 15
significant digits, is refused.

`Round(x, d)` renders each engine's own `ROUND`, as Django's does (#1061): the two can round a decimal
tie apart in its last digit, which is documented rather than refused. Text is refused (PostgreSQL
rejects a non-number, SQLite reads 0), and so is a negative `d` (#1044), when the expression is built.

Everything renders through mock connections — no live database, no fixture.

julia -O0 --project=test/integration test/unit/test_cast_divergent_operands.jl
"""

using Test
using Dates
using Decimals
using PormG
using PormG.Models
using PormG.QueryBuilder: inspect_query
import PormG: QueryBuildError

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`, so a
# shared key would let another file's settings decide this file's dialect.
struct CcdMockSQLite <: PormG.PormGSQLite end
struct CcdMockPostgres <: PormG.PormGPostgres end
const _CCD_SL = CcdMockSQLite()
const _CCD_PG = CcdMockPostgres()
PormG.backend_sqlite_version(::CcdMockSQLite) = 3045000

PormG.config["ccd_mock"] = PormG.Configuration.Settings(
  connections = _CCD_SL, change_data = true, db_def_folder = "ccd_mock",
)

# One column of each type the rule names or lets through, and a to-one relation so a joined path
# is reachable.
module CcdModels
import PormG
import PormG.Models

Ccd_team = Models.Model("ccd_team",
  id     = Models.IDField(),
  name   = Models.CharField(),
  rating = Models.FloatField(null = true),
)
Ccd_driver = Models.Model("ccd_driver",
  id       = Models.IDField(),
  surname  = Models.CharField(),
  number   = Models.IntegerField(null = true),
  born     = Models.DateField(null = true),
  active   = Models.BooleanField(null = true),
  points   = Models.FloatField(null = true),
  price    = Models.DecimalField(max_digits = 10, decimal_places = 2, null = true),
  start_at = Models.DateTimeField(null = true),
  laptime  = Models.DurationField(null = true),
  clock    = Models.TimeField(null = true),
  payload  = Models.JSONField(null = true),
  token    = Models.UUIDField(null = true),
  team     = Models.ForeignKey(Ccd_team, on_delete = "CASCADE"),
)

PormG.Models.set_models(@__MODULE__, "ccd_mock")
end

const CCD = CcdModels
const Fn = PormG.Functions
# Not `F`: `runtests.jl` includes every unit file into one `Main`, where `F` is already imported.
const _CF = PormG.QueryBuilder.F
const _CCD_ENGINES = (_CCD_PG, _CCD_SL)

_ccd_sql(q; conn) = inspect_query(q; connection = conn)[:sql_text]
# A fresh queryset projecting `expr`, rendered on `conn`.
_ccd_render(expr; conn) = _ccd_sql((q = CCD.Ccd_driver.objects; q.values("x" => expr); q); conn = conn)
# The exception the render raises on one engine, or `nothing` when it renders.
_ccd_refusal(expr; conn) = try _ccd_render(expr; conn = conn); nothing catch e; e end
# The message text without ANSI colour, so a needle never spans a colourised token.
_ccd_msg(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")
# The #1028 refusal itself, not any `QueryBuildError`: a renamed field would raise one too.
_is_1028(e) = e isa QueryBuildError && occursin("(#1028)", _ccd_msg(e))

# ─────────────────────────────────────────────────────────────────────────────
# Cast to text: every operand Concat refuses is refused by the cast too
# A cast to text writes the operand through the same per-engine conversion `Concat` does, so the
# operand set is the same: boolean, float, decimal, a `numeric` function, and the timestamp,
# interval and JSON types below. Field-object and string targets alike, on both engines.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: Cast to text refuses an operand with no single text" begin
  operands = [
    "active"   => "BooleanField `active`",
    "points"   => "FloatField `points`",
    "price"    => "DecimalField `price`",
    "team__rating" => "FloatField `team__rating`",          # a joined path resolves to the field
    "start_at" => "DateTimeField `start_at`",
    "laptime"  => "DurationField `laptime`",
    "payload"  => "JSONField `payload`",
    _CF("start_at") - _CF("start_at") => "an interval expression",   # the renderer names it
    Fn.Avg("number") => "`AVG(…)`",                          # numeric on PostgreSQL, REAL on SQLite
    Fn.Max("start_at") => "a timestamp expression",          # a typed function carries its kind
    _CF("points") * 2 => "arithmetic over the FloatField `points`",
  ]
  for (operand, named) in operands, target in (Models.CharField(), Models.TextField(), "text", "varchar(20)"),
      conn in _CCD_ENGINES
    err = _ccd_refusal(Fn.Cast(operand, target); conn = conn)
    @test _is_1028(err)
    msg = _ccd_msg(err)
    @test occursin("Cast cannot make the same text from", msg)
    @test occursin(named, msg)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Cast to an integer: a fractional number is refused, a boolean is not
# PostgreSQL rounds a float or numeric cast to an integer and SQLite truncates it, so `1.5` is `2`
# on one and `1` on the other. A boolean casts to `1`/`0` on both, and the integer escape —
# `Round`/`Floor`/`Ceil` first — has nothing left to round.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: Cast to an integer refuses a fractional number" begin
  refused = ["points", "price", "team__rating", Fn.Avg("number"), Fn.Sum("points"), _CF("points") / 2,
             Fn.Round("price", 2),                          # a fraction survives two digits
             Fn.Cast("points", "numeric"), Fn.Value(1.5), Fn.Value(Decimal(2.5))]
  for operand in refused, target in (Models.IntegerField(), Models.BigIntegerField(), "integer", "bigint", "int8", "smallint"),
      conn in _CCD_ENGINES
    err = _ccd_refusal(Fn.Cast(operand, target); conn = conn)
    @test _is_1028(err)
    msg = _ccd_msg(err)
    @test occursin("Cast cannot make the same integer from", msg)
    @test occursin("Cast(Round(x), IntegerField())", msg)
  end
end

@testset "#1028: Cast to an integer passes a boolean and an integral value" begin
  allowed = ["active", "number", _CF("number") + 1, Fn.Value(true), Fn.Max("active"),
             Fn.Round("points"), Fn.Round("price", 0), Fn.Floor("points"), Fn.Ceil("price"),
             Fn.Floor(_CF("points") / 2), Fn.Round(Fn.Avg("number"))]
  for operand in allowed, conn in _CCD_ENGINES
    sql = _ccd_render(Fn.Cast(operand, Models.IntegerField()); conn = conn)
    @test occursin(conn === _CCD_PG ? r"\)::integer as"i : r"AS INTEGER\)"i, sql)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Cast: the types with one text on both engines pass, to text and to anything else
# An integer, a date, a time, a uuid and text already agree. A cast to a type that is neither
# text nor an integer (`numeric`, `double precision`, `date`) is not a text conversion, so its
# operand is not checked here; `Concat` refuses the result if it is then used as text.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: Cast passes operands and targets that agree" begin
  to_text = ["number", "surname", "born", "clock", "token", "born__@year", "start_at__@date",
             Fn.Count("id"), Fn.Floor("number"), Fn.Value("x"), Fn.Value(7),
             Fn.ToChar("start_at", "YYYY-MM-DD HH:MI:SS")]
  for operand in to_text, conn in _CCD_ENGINES
    @test !isempty(_ccd_render(Fn.Cast(operand, Models.CharField()); conn = conn))
  end
  for (operand, target) in ("points" => "numeric", "points" => "double precision",   # #1040: unscaled
                            "price" => Models.FloatField(), "active" => "boolean"),
      conn in _CCD_ENGINES
    @test !isempty(_ccd_render(Fn.Cast(operand, target); conn = conn))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# output_field: Coalesce, Greatest and Least apply the same cast, so the same rule
# Each renders `(…)::type` / `CAST(… AS type)` for its `output_field` (#852). The message names the
# function as written. `Case` is fail-open: its value is a branch, which the rule does not type.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: an output_field cast follows the same rule" begin
  for (expr, fname) in ((Fn.Coalesce("points", 0; output_field = "integer"), "Coalesce(…; output_field = \"integer\")"),
                        (Fn.Greatest("number", "points"; output_field = Models.IntegerField()), "Greatest(…; output_field = \"INTEGER\")"),
                        (Fn.Least("price", 25; output_field = "text"), "Least(…; output_field = \"text\")"),
                        (Fn.Coalesce("active", false; output_field = Models.CharField()), "Coalesce(…; output_field = \"VARCHAR\")")),
      conn in _CCD_ENGINES
    err = _ccd_refusal(expr; conn = conn)
    @test _is_1028(err)
    @test occursin(fname, _ccd_msg(err))
  end
  for expr in (Fn.Coalesce("number", 0; output_field = "integer"),
               Fn.Greatest(Fn.Floor("points"), 0; output_field = "integer"),
               Fn.Least("points", 25; output_field = "double precision"),
               Fn.Coalesce("active", false; output_field = "integer")),
      conn in _CCD_ENGINES
    @test !isempty(_ccd_render(expr; conn = conn))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Cast: the message fits the operand and the target
# Each kind gives its own reason and way out: the boolean the word `true` (a cast, unlike
# `CONCAT`'s `t`) and a `Case` naming the column, a timestamp a `ToChar` naming it, an interval or a
# document formatting in Julia, and an integer target the three rounding functions.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: the message fits the operand and the target" begin
  msg(expr) = _ccd_msg(_ccd_refusal(expr; conn = _CCD_SL))
  text = Models.CharField()
  @test occursin("reads `true` on PostgreSQL and `1` on SQLite", msg(Fn.Cast("active", text)))
  @test occursin("Case(When(\"active\" => true", msg(Fn.Cast("active", text)))
  @test occursin("a float reads `25` on PostgreSQL and `25.0`", msg(Fn.Cast("points", text)))
  @test occursin("a decimal reads `3.00`", msg(Fn.Cast("price", text)))
  @test occursin("ToChar(\"start_at\", \"YYYY-MM-DD HH:MI:SS\")", msg(Fn.Cast("start_at", text)))
  @test occursin("IntervalStyle", msg(Fn.Cast("laptime", text)))
  @test occursin("`jsonb` re-renders", msg(Fn.Cast("payload", text)))
  @test occursin("format it in Julia", msg(Fn.Cast("payload", text)))
  int = msg(Fn.Cast("points", Models.IntegerField()))
  @test occursin("rounds", int) && occursin("truncates", int)
  @test !occursin("Case(When", int)
end

# ─────────────────────────────────────────────────────────────────────────────
# Concat: a timestamp, an interval or a JSON operand is refused (#1028), a time or uuid passes
# The three types #1027 left unmeasured. Each is refused through every shape that types it: a
# column, a typed function, and the intervals only the renderer can name — a timestamp difference,
# duration arithmetic, `Sum(duration)` (`_render_interval_operand`). A JSON key lookup is the value
# at that key, not the document, and passes. The #1027 kinds keep their own tag.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: Concat refuses a timestamp, interval or JSON operand" begin
  refused = [
    "start_at" => "DateTimeField `start_at`",
    "laptime"  => "DurationField `laptime`",
    "payload"  => "JSONField `payload`",
    _CF("payload") => "JSONField `payload`",
    Fn.Max("start_at") => "timestamp",
    Fn.Max("laptime") => "interval",
    _CF("laptime") + _CF("laptime") => "an interval expression",
    _CF("start_at") - _CF("start_at") => "an interval expression",
    Fn.Sum("laptime") => "`SUM(…)` over the DurationField `laptime`",
  ]
  for (operand, named) in refused, conn in _CCD_ENGINES
    err = _ccd_refusal(Fn.Concat(Fn.Value("|"), operand); conn = conn)
    @test _is_1028(err)
    msg = _ccd_msg(err)
    @test occursin("Concat cannot make the same text from", msg)
    @test occursin(named, msg)
  end
  for operand in ("clock", "token", "born", "start_at__@date", "start_at__@year", "payload__driver",
                  "payload__0__name", Fn.ToChar("start_at", "YYYY-MM-DD HH:MI:SS")), conn in _CCD_ENGINES
    sql = _ccd_render(Fn.Concat(Fn.Value("|"), operand); conn = conn)
    @test occursin(conn === _CCD_PG ? "CONCAT(" : "COALESCE(", sql)
  end
  # The #1027 kinds keep the #1027 tag; only the new ones carry #1028.
  @test occursin("(#1027)", _ccd_msg(_ccd_refusal(Fn.Concat(Fn.Value("|"), "points"); conn = _CCD_SL)))
end

# ─────────────────────────────────────────────────────────────────────────────
# Concat and Cast over a Cast: the inner cast is refused first
# `Concat(…, Cast("points", CharField()))` was the escape #1027 first proposed. The inner `Cast`
# renders while `Concat`'s operands do, so it meets the #1028 refusal before `Concat` reads it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: Concat over a divergent Cast meets the Cast refusal" begin
  for conn in _CCD_ENGINES
    err = _ccd_refusal(Fn.Concat("surname", Fn.Value("-"), Fn.Cast("points", Models.CharField())); conn = conn)
    @test _is_1028(err)
    @test occursin("Cast cannot make the same text", _ccd_msg(err))
    # The integer escape renders, and Concat accepts its integer result.
    @test !isempty(_ccd_render(Fn.Concat("surname", Fn.Value("-"),
                                         Fn.Cast(Fn.Round("points"), Models.IntegerField())); conn = conn))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# CTE: a column built from Sum or Avg is classified by the body's projection
# `_set_field_from_sql_function` types a `Sum` column as an integer and an `Avg` one as its
# operand's field, which let `Concat` over `Avg("number")` or `Sum("points")` through as a CTE
# column while the same aggregate written directly was refused. The body's classification is
# recorded while it builds, so both `Concat` and `Cast` see it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: a CTE column from Sum/Avg is refused like the aggregate" begin
  function withcte(outer)
    q = CCD.Ccd_team.objects
    body = CCD.Ccd_driver.objects
    body.values("team", "avg_n" => Fn.Avg("number"), "sum_p" => Fn.Sum("points"),
                "max_n" => Fn.Max("number"), "cnt" => Fn.Count("id"), "last" => Fn.Max("start_at"))
    q.with("c" => body, join_field = "id" => "team")
    q.values("x" => outer)
    return q
  end
  for conn in _CCD_ENGINES
    for (col, kind) in (("avg_n", "`AVG(…)`"), ("sum_p", "`SUM(…)` over the FloatField `points`"),
                        ("last", "timestamp"))
      err = try _ccd_sql(withcte(Fn.Concat(Fn.Value("-"), PormG.CTE("c", col))); conn = conn); nothing catch e; e end
      @test err isa QueryBuildError
      msg = _ccd_msg(err)
      @test occursin("the CTE column `CTE(\"c\", \"$(col)\")`", msg)
      @test occursin(kind, msg)
      # The same spelling `"c__<col>"` resolves to the same handle.
      err = try _ccd_sql(withcte(Fn.Concat(Fn.Value("-"), "c__$(col)")); conn = conn); nothing catch e; e end
      @test err isa QueryBuildError && occursin("the CTE column", _ccd_msg(err)) && occursin(kind, _ccd_msg(err))
    end
    err = try _ccd_sql(withcte(Fn.Cast(PormG.CTE("c", "avg_n"), Models.IntegerField())); conn = conn); nothing catch e; e end
    @test _is_1028(err)
    # An integer CTE column has one text, and passes both.
    for col in ("max_n", "cnt")
      @test !isempty(_ccd_sql(withcte(Fn.Concat(Fn.Value("-"), PormG.CTE("c", col))); conn = conn))
      @test !isempty(_ccd_sql(withcte(Fn.Cast(PormG.CTE("c", col), Models.CharField())); conn = conn))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The year-qualified labels (#997) still render
# `@yyyy_q` / `@yyyy_quad` expand to `Cast(Year(x), CharField())` inside a `Concat`: an integer
# cast to text, which agrees on both engines. This pins that the new cast check passes it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: the @yyyy_q / @yyyy_quad labels still render" begin
  for key in ("yyyy_q", "yyyy_quad"), path in ("born", "start_at"), conn in _CCD_ENGINES
    @test occursin(" ||", _ccd_sql((q = CCD.Ccd_driver.objects; q.values("x" => "$(path)__@$(key)"); q); conn = conn))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Review of #1028: the shapes only the render can type, and the literals
# `F("start_at") + Day(1)` is a timestamp no type reader names; its render does (`_render_operand_kind`).
# A `DateTime` or duration literal binds `$1::timestamp` / an interval on PostgreSQL and the stored text
# on SQLite, so `Concat` refuses it when built, and a text cast when rendered. A `Date` literal agrees.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: timestamp arithmetic and temporal literals are refused" begin
  for conn in _CCD_ENGINES
    for expr in (Fn.Concat(Fn.Value("|"), _CF("start_at") + Day(1)), Fn.Cast(_CF("start_at") + Day(1), "text"))
      err = _ccd_refusal(expr; conn = conn)
      @test _is_1028(err)
      @test occursin("a timestamp expression", _ccd_msg(err))
    end
    @test _is_1028(_ccd_refusal(Fn.Cast(Fn.Value(DateTime(2009, 3, 29, 6)), Models.CharField()); conn = conn))
    @test _is_1028(_ccd_refusal(Fn.Cast(Fn.Value(Minute(1)), "text"); conn = conn))
    # A date stays a date through arithmetic, and passes.
    @test !isempty(_ccd_render(Fn.Concat(Fn.Value("|"), _CF("born") + Day(1)); conn = conn))
  end
  for (lit, named) in (Fn.Value(DateTime(2009, 3, 29, 6)) => "a DateTime literal", Fn.Value(Minute(1)) => "a duration literal")
    err = try Fn.Concat("surname", lit); nothing catch e; e end
    @test _is_1028(err)
    @test occursin(named, _ccd_msg(err))
  end
  @test !isempty(_ccd_render(Fn.Concat(Fn.Value("|"), Fn.Value(Date(2009, 3, 29))); conn = _CCD_SL))
end

# ─────────────────────────────────────────────────────────────────────────────
# Review of #1028: whole numbers cast to an integer pass
# `Mod` of integers and `+`/`-`/`*` of whole numbers have nothing to round: PostgreSQL's `numeric` and
# SQLite's REAL spell the same whole number. A `/` or a float operand still has a fraction.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: whole-number arithmetic casts to an integer" begin
  for conn in _CCD_ENGINES
    for operand in (Fn.Mod("number", 3), Fn.Floor("points") * 2, _CF("number") * 2 + Fn.Ceil("price"))
      @test !isempty(_ccd_render(Fn.Cast(operand, Models.IntegerField()); conn = conn))
    end
    for operand in (Fn.Mod("points", 3), Fn.Floor("points") * 1.5, Fn.Floor("points") / 2)
      @test _is_1028(_ccd_refusal(Fn.Cast(operand, Models.IntegerField()); conn = conn))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Review of #1028: a CTE column built from a JSON key lookup holds the value, not the document
# The CTE types the column with the JSONField itself, so without the body's record it read as the
# whole document and was refused. A `Case(…; output_field)` stays unchecked (its value is a branch).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: a JSON key column of a CTE passes; Case output_field is not checked" begin
  for conn in _CCD_ENGINES
    q = CCD.Ccd_team.objects
    body = CCD.Ccd_driver.objects
    body.values("team", "drv" => "payload__driver", "doc" => "payload")
    q.with("c" => body, join_field = "id" => "team")
    q.values("x" => Fn.Concat(Fn.Value("|"), PormG.CTE("c", "drv")))
    @test !isempty(_ccd_sql(q; conn = conn))
    q = CCD.Ccd_team.objects
    q.with("c" => body, join_field = "id" => "team")
    q.values("x" => Fn.Concat(Fn.Value("|"), PormG.CTE("c", "doc")))
    err = try _ccd_sql(q; conn = conn); nothing catch e; e end
    @test _is_1028(err) && occursin("JSONField", _ccd_msg(err))
    expr = Fn.Case(Fn.When("active" => true, then = Fn.Value(1)), default = 0; output_field = "text")
    @test !isempty(_ccd_render(expr; conn = conn))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Review of #1028: the checks render a literal operand as before
# A duration literal under a cast renders as the bound text on SQLite, as it did before the check
# re-routed the operands — not through the millisecond form `_render_interval_operand` gives it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: a literal operand renders as it did" begin
  sql = _ccd_render(Fn.Cast(Fn.Value(Minute(1)), Models.IntegerField()); conn = _CCD_SL)
  @test occursin("CAST(? AS INTEGER)", sql)
  sql = _ccd_render(Fn.Coalesce("laptime", Fn.Value(Minute(1)); output_field = "integer"); conn = _CCD_SL)
  @test !occursin("_pormg_ms", sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# Delta review of #1028: both engines answer the same; a bare F key lookup in a CTE body
# On SQLite `Greatest`/`Least` render NULL-skipping `COALESCE` rotations, whose render names neither
# a timestamp nor an interval beside another type; so over such arithmetic both engines answer alike.
# A body column spelled `F("payload__driver")` is the key's value, as the bare path is.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: Greatest/Least answer the same on both engines; F key lookup in a CTE" begin
  for expr in (Fn.Greatest(_CF("start_at") + Day(1), _CF("start_at") + Day(2); output_field = "text"),
               Fn.Least(_CF("start_at") + Day(1), _CF("start_at") - Day(1); output_field = "varchar(40)"),
               Fn.Greatest(_CF("laptime") + _CF("laptime"), _CF("laptime") * 2; output_field = "text"),
               Fn.Greatest(_CF("laptime") + _CF("laptime"), _CF("number") + 1; output_field = "text"),
               Fn.Greatest(_CF("start_at") - _CF("start_at"), _CF("number") * 2; output_field = "text"))
    @test (_ccd_refusal(expr; conn = _CCD_PG) === nothing) == (_ccd_refusal(expr; conn = _CCD_SL) === nothing)
  end
  # A typed operand is still read by name: a `DurationField` column is refused on both.
  for conn in _CCD_ENGINES
    @test _is_1028(_ccd_refusal(Fn.Greatest("laptime", _CF("laptime") * 2; output_field = "text"); conn = conn))
  end
  for conn in _CCD_ENGINES
    q = CCD.Ccd_team.objects
    body = CCD.Ccd_driver.objects
    body.values("team", "drv" => _CF("payload__driver"))
    q.with("c" => body, join_field = "id" => "team")
    q.values("x" => Fn.Concat(Fn.Value("|"), PormG.CTE("c", "drv")))
    @test !isempty(_ccd_sql(q; conn = conn))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1040: a cast to numeric(p, s) refuses an operand with more than s fractional digits
# PostgreSQL rounds to the scale (half away from zero) and SQLite keeps every digit, measured on
# PostgreSQL 16.15 / SQLite 3.45.1: `1.5` at `numeric(10,0)` is `2` / `1.5`, `1.555` at
# `numeric(10,2)` is `1.56` / `1.555`, and the text `'1.555'` the same. Rounding to the scale first is
# the escape (#1061): only a decimal tie can still differ, in its last digit. A whole number
# (`Round(x)`, `Floor`, `Ceil`) and an unscaled `numeric` agree.
# ─────────────────────────────────────────────────────────────────────────────
_is_1040(e) = e isa QueryBuildError && occursin("(#1040)", _ccd_msg(e))

@testset "#1040: Cast to a scaled numeric refuses an operand it would round" begin
  refused = [
    "points"              => "FloatField `points`",
    "team__rating"        => "FloatField `team__rating`",
    # #1050: a float literal is refused for its places, which 1.555 has more of than any target here.
    Fn.Value(1.555)       => "a Float64 literal with 3 decimal places",
    _CF("points") * 2     => "arithmetic over the FloatField `points`",
    Fn.Avg("number")      => "`AVG(…)`",
    Fn.Cast("points", "numeric") => "a value cast to numeric",
    Fn.Cast(Fn.Round("price", 0), "numeric(10,3)") => "a value cast to numeric(10,3)",
    "surname"             => "text column `surname`",        # PostgreSQL parses '1.555' and rounds it
    Fn.Value("1.555")     => "a string literal",
    Fn.Lower("surname")   => "a text expression",
    Fn.Value(Decimal(0, 1555, -3)) => "a Decimal literal with 3 decimal places",
    # A JSON value is text to PostgreSQL's cast (`#>>`, `jsonb::numeric`) and a number to SQLite's.
    "payload"             => "JSONField `payload`",
    "payload__score"      => "JSONField `payload__score`",
    Fn.Max("points")      => "`MAX(…)` over the FloatField `points`",
    Fn.Coalesce(Fn.Sum("price"), 0) => "`COALESCE(…)` over",   # the recursion still refuses a sum
  ]
  for (operand, named) in refused, target in ("numeric(10,2)", "decimal(8, 1)", "numeric(10,0)", "numeric(10)", "dec(10,2)"),
      conn in _CCD_ENGINES
    err = _ccd_refusal(Fn.Cast(operand, target); conn = conn)
    @test _is_1040(err)
    msg = _ccd_msg(err)
    @test occursin("Cast cannot make the same number from", msg)
    @test occursin(named, msg)
    # The message names the escapes: round to the scale first, or an unscaled numeric.
    @test occursin("Round it to the scale first", msg) && occursin("unscaled", msg)
  end
  # A DecimalField is bounded by its own places: `price` has two.
  for (target, refuses) in ("numeric(10,0)" => true, "numeric(10,1)" => true, "numeric(10,2)" => false,
                            "numeric(12,4)" => false),
      operand in ("price", _CF("price"), Fn.Max("price"), Fn.Coalesce("price", 0), Fn.Abs("price")), conn in _CCD_ENGINES
    err = _ccd_refusal(Fn.Cast(operand, target); conn = conn)
    @test refuses ? (_is_1040(err) && occursin("DecimalField `price` (2 decimal places)", _ccd_msg(err))) : err === nothing
  end
end

@testset "#1040: Cast to a scaled numeric passes what it cannot round" begin
  allowed = ["number", Fn.Round("points"), Fn.Floor("points"), Fn.Ceil("price"), Fn.Round("price", 0),
             Fn.Count("id"), _CF("number") + 1, Fn.Mod("number", 3), Fn.Value(25.0), Fn.Value(7),
             Fn.Value(Decimal(0, 150, -2)),                  # 1.50 needs one digit
             Fn.Cast(Fn.Round("points"), Models.IntegerField()), Fn.Cast(Fn.Round("price", 0), "numeric(10,1)")]
  for operand in allowed, conn in _CCD_ENGINES
    @test _ccd_refusal(Fn.Cast(operand, "numeric(10,1)"); conn = conn) === nothing
  end
  # PostgreSQL has no cast from a boolean, a timestamp or an interval to `numeric`, so the statement
  # fails there when it runs; nothing is rounded, and this is not the #1040 refusal.
  for operand in ("active", "start_at", "laptime"), conn in _CCD_ENGINES
    @test !_is_1040(_ccd_refusal(Fn.Cast(operand, "numeric(10,1)"); conn = conn))
  end
  # An unscaled numeric keeps the value on both engines, so any operand passes; the escape renders.
  for operand in ("points", "surname", Fn.Round("price", 2)),
      target in ("numeric", "decimal", Models.DecimalField(max_digits = 10, decimal_places = 2)),
      conn in _CCD_ENGINES
    @test _ccd_refusal(Fn.Cast(operand, target); conn = conn) === nothing
  end
  for conn in _CCD_ENGINES
    sql = _ccd_render(Fn.Cast(Fn.Round("points"), "numeric(10,0)"); conn = conn)
    @test occursin(conn === _CCD_PG ? r"\)::numeric\(10,0\) as"i : r"AS NUMERIC\(10,0\)\)"i, sql)
  end
end

@testset "#1040: an output_field numeric scale follows the same rule" begin
  for (expr, fname) in ((Fn.Coalesce("points", 0; output_field = "numeric(10,2)"), "Coalesce(…; output_field = \"numeric(10,2)\")"),
                        (Fn.Greatest("number", "price"; output_field = "numeric(10,1)"), "Greatest(…; output_field = \"numeric(10,1)\")"),
                        (Fn.Least("surname", "surname"; output_field = "numeric(10)"), "Least(…; output_field = \"numeric(10)\")")),
      conn in _CCD_ENGINES
    err = _ccd_refusal(expr; conn = conn)
    @test _is_1040(err)
    @test occursin(fname, _ccd_msg(err))
  end
  for expr in (Fn.Coalesce("number", 0; output_field = "numeric(10,0)"),
               Fn.Greatest("price", 25; output_field = "numeric(10,2)"),
               Fn.Least(Fn.Floor("points"), "number"; output_field = "numeric(10,0)"),
               Fn.Coalesce("points", 0; output_field = "numeric")),
      conn in _CCD_ENGINES
    @test _ccd_refusal(expr; conn = conn) === nothing
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1050: a float literal that fits the scale passes, as a Decimal literal does
# What diverges is a literal with more fractional digits than `s`, or more than the 15 significant
# digits PostgreSQL converts `float8` to `numeric` at. Measured on PostgreSQL 16.15 / SQLite 3.45.1:
# `1.5`, `0.1`, `2.25` read the same at scale 2; `2.675` at scale 2 is `2.68` / `2.675`; and
# `12345678901234.56` becomes `12345678901234.6` on PostgreSQL before any scale applies.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1050: a float literal is bounded by its shortest decimal form" begin
  # A cast and the shared classifier's other route, an output_field.
  shapes = (v -> Fn.Cast(Fn.Value(v), "numeric(10,2)"),
            v -> Fn.Coalesce(Fn.Value(v), 0; output_field = "numeric(16,2)"),
            v -> Fn.Greatest(Fn.Value(v), "number"; output_field = "numeric(16,2)"),
            v -> Fn.Least(Fn.Value(v), "number"; output_field = "numeric(16,2)"))
  for v in (1.5, 0.1, 2.25, -2.25, 0.0, 1.0e-2, 25.0), shape in shapes, conn in _CCD_ENGINES
    @test _ccd_refusal(shape(v); conn = conn) === nothing
  end
  for (v, named) in (2.675 => "a Float64 literal with 3 decimal places",
                     1.555 => "a Float64 literal with 3 decimal places",
                     1.0e-5 => "a Float64 literal with 5 decimal places",
                     12345678901234.56 => "a Float64 literal with 16 significant digits",
                     # Whole, but not at 15 digits: PostgreSQL reads 12345678901234600.
                     12345678901234567.0 => "with 17 significant digits"),
      shape in shapes, conn in _CCD_ENGINES
    err = _ccd_refusal(shape(v); conn = conn)
    @test _is_1040(err)
    @test occursin(named, _ccd_msg(err))
  end
  # The significant-digit bound holds at any scale, and the place bound moves with it.
  for conn in _CCD_ENGINES
    @test _is_1040(_ccd_refusal(Fn.Cast(Fn.Value(12345678901234.56), "numeric(30,8)"); conn = conn))
    @test _ccd_refusal(Fn.Cast(Fn.Value(2.675), "numeric(10,3)"); conn = conn) === nothing
    @test _is_1040(_ccd_refusal(Fn.Cast(Fn.Value(0.1), "numeric(10,0)"); conn = conn))
  end
  # The digit count itself, through the exponent forms `string` writes.
  @test PormG.QueryBuilder._float_literal_digits(1.5) == (1, 2)
  @test PormG.QueryBuilder._float_literal_digits(2.675) == (3, 4)
  @test PormG.QueryBuilder._float_literal_digits(1.0e-5) == (5, 1)
  @test PormG.QueryBuilder._float_literal_digits(1.5e-7) == (8, 2)
  @test PormG.QueryBuilder._float_literal_digits(12345678901234.56) == (2, 16)
  @test PormG.QueryBuilder._float_literal_digits(1.0e20) == (0, 1)
  @test PormG.QueryBuilder._float_literal_digits(-0.125) == (3, 3)
end

# ─────────────────────────────────────────────────────────────────────────────
# #1061: Round(x, d) renders each engine's own ROUND, as Django's does
# `ROUND(x::numeric, d)` on PostgreSQL rounds the exact decimal form; `ROUND(x, d)` on SQLite rounds
# the stored double. They differ only at a decimal tie whose double sits below it (`2.675` → `2.68` /
# `2.67`), a last-digit difference documented rather than refused. Text changes the value itself
# (PostgreSQL rejects a non-number, SQLite reads 0), so it is refused, a JSON value included.
# ─────────────────────────────────────────────────────────────────────────────
_is_1061(e) = e isa QueryBuildError && occursin("(#1061)", _ccd_msg(e))

@testset "#1061: Round(x, d) renders over any number, on both engines" begin
  rating() = (s = CCD.Ccd_team.objects; s.filter("id" => OuterRef("team")); s.values("rating"); s)
  numbers = ["points", "team__rating", _CF("points") * 2, Fn.Avg("number"), Fn.Sqrt("number"),
             Fn.Max("points"), Fn.Cast("points", "numeric"), Fn.Value(2.675), Fn.Value(Decimal(0, 1555, -3)),
             "price", "number", Fn.Sum("price"), Subquery(rating()),
             Fn.Case([Fn.When("id" => 1, then = _CF("points"))], default = 0)]
  for operand in numbers, d in (1, 2, 3), conn in _CCD_ENGINES
    @test _ccd_refusal(Fn.Round(operand, d); conn = conn) === nothing
  end
  # Each engine's own ROUND, the precision bound after the operand's own parameters.
  for conn in _CCD_ENGINES
    out = inspect_query((q = CCD.Ccd_driver.objects; q.values("x" => Fn.Round("points", 2)); q); connection = conn)
    @test occursin(conn === _CCD_PG ? r"ROUND\(\(\S+points\S*\)::numeric, \$1::integer\) as"i :
                                      r"ROUND\(\S+points\S*, \?\) as"i, out[:sql_text])
    @test out[:parameters] == Any[2]
    r = inspect_query((q = CCD.Ccd_driver.objects; q.values("x" => Fn.Round(Fn.Value(1.5), 2)); q); connection = conn)
    @test r[:parameters] == Any[1.5, 2]
  end
  # Any `Integer` precision, as `Round` accepts.
  for conn in _CCD_ENGINES, d in (Int32(2), UInt8(2), big(2))
    @test _ccd_refusal(Fn.Round("points", d); conn = conn) === nothing
  end
end

@testset "#1061: Round(x, d) refuses text, a JSON value included" begin
  text = [
    "surname"             => "the text column `surname`",
    Fn.Value("1.555")     => "a string literal",
    "payload__score"      => "the JSONField `payload__score`",
  ]
  for (operand, named) in text, d in (1, 2), conn in _CCD_ENGINES
    err = _ccd_refusal(Fn.Round(operand, d); conn = conn)
    @test _is_1061(err)
    msg = _ccd_msg(err)
    @test occursin("Round(…, $(d)) cannot round $(named): it is text", msg)
    @test occursin("Round(Cast(x, FloatField()), $(d))", msg)
  end
  # Wherever it renders.
  positions = (
    ("values",            q -> q.values("x" => Fn.Round("surname", 2))),
    ("filter right-hand", q -> q.filter("number__@gte" => Fn.Round("surname", 2))),
    ("Case branch",       q -> q.values("c" => Fn.Case([Fn.When("id" => 1, then = Fn.Round("surname", 2))], default = 0))),
  )
  for (label, position) in positions, conn in _CCD_ENGINES
    err = try _ccd_sql((q = CCD.Ccd_driver.objects; position(q); q); conn = conn); nothing catch e; e end
    @test _is_1061(err)
  end
end

@testset "#1061: a Round has at most d places for a cast to read" begin
  rating() = (s = CCD.Ccd_team.objects; s.filter("id" => OuterRef("team")); s.values("rating"); s)
  for conn in _CCD_ENGINES
    for operand in ("price", "points", Fn.Avg("number"), Subquery(rating()))
      @test _ccd_refusal(Fn.Cast(Fn.Round(operand, 2), "numeric(10,2)"); conn = conn) === nothing
      @test _ccd_refusal(Fn.Cast(Fn.Round(operand, 2), "numeric(10,3)"); conn = conn) === nothing
    end
    @test _ccd_refusal(Fn.Round(Fn.Round("price", 2), 2); conn = conn) === nothing
    @test _ccd_refusal(Fn.Coalesce(Fn.Round("points", 2), 0; output_field = "numeric(10,2)"); conn = conn) === nothing
    # Wider than the scale: PostgreSQL rounds a two-place value cast to one place, SQLite keeps it.
    err = _ccd_refusal(Fn.Cast(Fn.Round("price", 2), "numeric(10,1)"); conn = conn)
    @test _is_1040(err) && occursin("`ROUND(…)`", _ccd_msg(err))
  end
end

# The string, Float64 and Decimal labels this classifier writes. A Float32 literal and arithmetic over
# a literal are named by #1027's `Concat` labels, pinned in the #1057 testset below.
@testset "#1040: a string, Float64 or Decimal literal is named by its digits, not its value (#971)" begin
  marker = "s3cr3t1044"
  for (expr, named) in ((Fn.Round(Fn.Value(marker), 2), "a string literal"),
                        (Fn.Cast(Fn.Value(marker), "numeric(10,2)"), "a string literal"),
                        (Fn.Cast(Fn.Value(1044.123456), "numeric(10,2)"), "a Float64 literal with 6 decimal places"),
                        (Fn.Cast(Fn.Value(Decimal(0, 1044123, -3)), "numeric(10,2)"), "a Decimal literal with 3 decimal places")),
      conn in _CCD_ENGINES
    err = _ccd_refusal(expr; conn = conn)
    msg = _ccd_msg(err)
    @test err isa QueryBuildError && occursin(named, msg)
    @test !occursin(marker, msg) && !occursin("1044.123", msg) && !occursin("1044123", msg)
  end
end

# #1027's literal labels, and every label built over one (`arithmetic over …`), name the literal by
# its type. Each route that reaches them: `Concat` when built, and `Concat`, `Cast` and `Round` when
# rendered — a cast to an integer or to text through `_cast_divergent_operand`, and a cast to
# `numeric(p, s)` through `_scale_divergent_operand`'s fall-through. Every marker holds `1057`
# or `2057`, which nothing else in these messages does.
@testset "#1057: a Concat or Cast refusal never prints the literal (#971)" begin
  cases = (
    (() -> Fn.Concat("surname", 1057.25), "a Float64 literal"),
    (() -> Fn.Concat("surname", Fn.Value(Decimal(0, 1057125, -3))), "a Decimal literal"),
    (() -> Fn.Concat("surname", Fn.Value(DateTime(2057, 1, 5))), "a DateTime literal"),
    (() -> Fn.Concat("surname", Fn.Value(Minute(1057))), "a duration literal"),
    (() -> Fn.Concat(Fn.Value("|"), _CF("number") * 1057.25), "arithmetic over a Float64 literal"),
    (() -> Fn.Cast(Fn.Value(1057.25), Models.IntegerField()), "a Float64 literal"),
    (() -> Fn.Cast(_CF("number") + 1057.25, "numeric(10,0)"), "arithmetic over a Float64 literal"),
    (() -> Fn.Cast(Fn.Max(Fn.Value(1057.25)), Models.CharField()), "`MAX(…)` over a Float64 literal"),
    (() -> Fn.Cast(Fn.Value(Float32(1057.25)), "numeric(10,2)"), "a Float32 literal"),
  )
  for (build, named) in cases, conn in _CCD_ENGINES
    err = try _ccd_render(build(); conn = conn); nothing catch e; e end
    msg = _ccd_msg(err)
    @test err isa QueryBuildError && occursin(named, msg)
    @test !occursin("1057", msg) && !occursin("2057", msg)
  end
end

@testset "#1044: a negative precision is refused when the expression is built" begin
  for operand in ("number", "points", Fn.Value(125)), d in (-1, -2)
    err = try Fn.Round(operand, d); nothing catch e; e end
    @test err isa PormG.InvalidValueError
    msg = _ccd_msg(err)
    @test occursin("(#1044)", msg) && occursin("Round(…, $(d))", msg) && occursin("round(x, RoundNearestTiesAway; digits = $(d))", msg)
  end
end
