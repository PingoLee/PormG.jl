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
reads the same on both engines, so only a literal with more than `s` places is refused. #1087 drops
the 15-significant-digit bound #1050 also had (PostgreSQL's `float8` → `numeric` is the less exact
side, in the 16th digit) and refuses a `Cast` literal too large for the precision: `Cast(100,
"numeric(3,2)")` raises an overflow on PostgreSQL and is `100` on SQLite. A zero-scale `DecimalField`
holds whole numbers and is read like an integer column.

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
  grid     = Models.DecimalField(max_digits = 4, decimal_places = 0, null = true),  # whole numbers (#1087)
  laps_total = Models.BigIntegerField(null = true),  # `sum(bigint)` is `numeric` on PostgreSQL (#1111)
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
# What diverges is a literal with more fractional digits than `s`. Measured on PostgreSQL 16.15 /
# SQLite 3.45.1: `1.5`, `0.1`, `2.25` read the same at scale 2; `2.675` at scale 2 is `2.68` / `2.675`.
# `12345678901234.56` becomes `12345678901234.6` on PostgreSQL before any scale applies, a 16th-digit
# difference where PostgreSQL is the less exact side: category 3, documented, not refused (#1087).
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
                     1.0e-5 => "a Float64 literal with 5 decimal places"),
      shape in shapes, conn in _CCD_ENGINES
    err = _ccd_refusal(shape(v); conn = conn)
    @test _is_1040(err)
    @test occursin(named, _ccd_msg(err))
  end
  # #1087: more than 15 significant digits is not refused — PostgreSQL's 16th digit is the less exact
  # one — and the place bound moves with the scale.
  for v in (12345678901234.56, 12345678901234567.0), conn in _CCD_ENGINES
    @test _ccd_refusal(Fn.Cast(Fn.Value(v), "numeric(30,8)"); conn = conn) === nothing
    @test _ccd_refusal(Fn.Coalesce(Fn.Value(v), 0; output_field = "numeric(30,2)"); conn = conn) === nothing
  end
  for conn in _CCD_ENGINES
    @test _ccd_refusal(Fn.Cast(Fn.Value(2.675), "numeric(10,3)"); conn = conn) === nothing
    @test _is_1040(_ccd_refusal(Fn.Cast(Fn.Value(0.1), "numeric(10,0)"); conn = conn))
  end
  # The place count itself, through the exponent forms `string` writes.
  @test PormG.QueryBuilder._float_literal_places(1.5) == 1
  @test PormG.QueryBuilder._float_literal_places(2.675) == 3
  @test PormG.QueryBuilder._float_literal_places(1.0e-5) == 5
  @test PormG.QueryBuilder._float_literal_places(1.5e-7) == 8
  @test PormG.QueryBuilder._float_literal_places(12345678901234.56) == 2
  @test PormG.QueryBuilder._float_literal_places(1.0e20) == 0
  @test PormG.QueryBuilder._float_literal_places(-0.125) == 3
end

# ─────────────────────────────────────────────────────────────────────────────
# #1087: a Cast literal too large for numeric(p, s), and a zero-scale DecimalField
# Rounded to `s` places, a value needs at most `p − s` digits before the point. PostgreSQL raises a
# numeric field overflow on one that needs more; SQLite stores it as it is — a silent different
# answer, so the criterion's tie-breaker makes it category 1. A literal is certain to overflow; a
# column or computed value overflows only on some rows, so it is not refused.
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# Cast over a Subquery: the operand is classified by the one expression the subquery projects (#1124)
# The three declared-cast rules read the same classifier `Concat` does, and a `Subquery` had no arm
# in it, so a cast over a float subquery passed every rule that refuses the float itself. The inner
# build now records its projection's classification under the node, so each rule answers for a
# subquery what it answers for the expression alone. A subquery whose projection has one text, or
# that is rounded to an integer inside, passes as before.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1124: a declared cast over a Subquery is classified by its projection" begin
  team(expr) = (s = CCD.Ccd_team.objects; s.filter("id" => PormG.OuterRef("team")); s.values("t" => expr); PormG.Subquery(s))
  for conn in _CCD_ENGINES
    for (expr, is_rule, named) in ((Fn.Cast(team("rating"), Models.CharField()), _is_1028, "the FloatField `rating`"),
                                   (Fn.Cast(team("rating"), Models.IntegerField()), _is_1028, "the FloatField `rating`"),
                                   (Fn.Cast(team(Fn.Avg("rating")), "integer"), _is_1028, "`AVG(…)`"),
                                   (Fn.Cast(team("rating"), "numeric(10,2)"), _is_1040, "the FloatField `rating`"),
                                   (Fn.Coalesce(team("rating"), 0; output_field = "integer"), _is_1028, "the FloatField `rating`"))
      err = _ccd_refusal(expr; conn = conn)
      @test is_rule(err)
      @test occursin("a Subquery projecting " * named, _ccd_msg(err))
    end
    for expr in (Fn.Cast(team("name"), Models.CharField()), Fn.Cast(team(Fn.Count("id")), Models.CharField()),
                 Fn.Cast(team(Fn.Cast(Fn.Round("rating"), Models.IntegerField())), Models.CharField()),
                 Fn.Cast(team("rating"), Models.FloatField()), Fn.Cast(team("rating"), "numeric"))
      @test _ccd_refusal(expr; conn = conn) === nothing
    end
  end
end

_is_1087(e) = e isa QueryBuildError && occursin("(#1087)", _ccd_msg(e))

@testset "#1087: Cast refuses a literal too large for the precision" begin
  refused = (
    (100, "numeric(3,2)", "an Int64 literal with 3 digits before the point", "at most 1 digit before the point"),
    (-100, "numeric(3,2)", "an Int64 literal with 3 digits before the point", "at most 1 digit before the point"),
    # 9.999 has places to round too; the overflow is checked first, after rounding to 10.00.
    (9.999, "numeric(3,2)", "a Float64 literal with 2 digits before the point", "at most 1 digit before the point"),
    (0.995, "decimal(2,2)", "a Float64 literal with 1 digit before the point", "only values below 1"),
    # A scale above the precision leaves no digit before the point.
    (0.5, "numeric(2,3)", "a Float64 literal with 0 digits before the point", "only values below 0.1"),
    # A Float32 binds as double precision on PostgreSQL: read as the Float64 it widens to.
    (100f0, "numeric(3,2)", "a Float32 literal with 3 digits before the point", "at most 1 digit before the point"),
    (Float16(100), "numeric(3,2)", "a Float16 literal with 3 digits before the point", "at most 1 digit before the point"),
    (UInt8(100), "numeric(3,2)", "a UInt8 literal with 3 digits before the point", "at most 1 digit before the point"),
    (99.5, "numeric(2)", "a Float64 literal with 3 digits before the point", "at most 2 digits before the point"),
    (12345678901234.56, "numeric(10,2)", "a Float64 literal with 14 digits before the point", "at most 8 digits before the point"),
    (Decimal(0, 12345, 0), "dec(4,0)", "a Decimal literal with 5 digits before the point", "at most 4 digits before the point"),
    (Decimal(1, 99995, -3), "numeric(4,2)", "a Decimal literal with 3 digits before the point", "at most 2 digits before the point"),
  )
  for (v, target, named, holds) in refused, conn in _CCD_ENGINES
    err = _ccd_refusal(Fn.Cast(Fn.Value(v), target); conn = conn)
    @test _is_1087(err)
    msg = _ccd_msg(err)
    @test occursin("Cast cannot make the same number from $(named)", msg)
    @test occursin("holds $(holds)", msg) && occursin("numeric field overflow", msg)
    @test occursin("Declare a precision that holds it", msg)
  end
  # What fits passes: a value just under the bound, and one that only rounds to it at a wider scale.
  for (v, target) in ((99, "numeric(4,2)"), (9.99, "numeric(3,2)"), (-9.99, "numeric(3,2)"), (0.5, "numeric(2,2)"),
                      (0.994, "numeric(3,3)"), (Decimal(0, 1234, 0), "numeric(4,0)"), (100, "numeric")),
      conn in _CCD_ENGINES
    @test _ccd_refusal(Fn.Cast(Fn.Value(v), target); conn = conn) === nothing
  end
  # Not certain, so not refused: a column, a computed value, and an output_field's literal, which is one
  # candidate value among the operands.
  for expr in (Fn.Cast("price", "numeric(3,2)"), Fn.Cast("number", "numeric(2,0)"), Fn.Cast(_CF("number") * 1000, "numeric(3,0)"),
               Fn.Coalesce("number", 100; output_field = "numeric(3,2)")),
      conn in _CCD_ENGINES
    @test _ccd_refusal(expr; conn = conn) === nothing
  end
  # The value is never printed (#971).
  for conn in _CCD_ENGINES
    msg = _ccd_msg(_ccd_refusal(Fn.Cast(Fn.Value(10871087), "numeric(3,2)"); conn = conn))
    @test !occursin("10871087", msg)
  end
end

@testset "#1087: a zero-scale DecimalField reads like an integer column" begin
  # Both engines write a whole-number decimal `14`, so Concat and a cast to text or an integer pass.
  for expr in (Fn.Concat("surname", "grid"), Fn.Cast("grid", Models.CharField()), Fn.Cast("grid", Models.IntegerField()),
               Fn.Cast(Fn.Max("grid"), Models.CharField()), Fn.Cast("grid", "numeric(10,0)")),
      conn in _CCD_ENGINES
    @test _ccd_refusal(expr; conn = conn) === nothing
  end
  # A DecimalField with places is still refused, as #1027/#1028 refuse it.
  for expr in (Fn.Cast("price", Models.CharField()), Fn.Cast("price", Models.IntegerField())), conn in _CCD_ENGINES
    @test _is_1028(_ccd_refusal(expr; conn = conn))
  end
  # Until it is divided: SQLite stores the whole values as INTEGER and divides them as integers
  # (`15 / 2` is `7`), where PostgreSQL's `numeric / int` is `7.5`. Through an aggregate too.
  for (expr, is_rule) in ((Fn.Cast(_CF("grid") / 2, Models.IntegerField()), _is_1028),
                          (Fn.Cast(_CF("grid") / _CF("number"), Models.CharField()), _is_1028),
                          (Fn.Cast(_CF("grid") / 2, "numeric(10,1)"), _is_1040),
                          (Fn.Cast((_CF("grid") + 1) / 2, Models.IntegerField()), _is_1028),
                          (Fn.Cast(Fn.Sum("grid") / Fn.Count("id"), Models.IntegerField()), _is_1028),
                          # `Coalesce` always carries an `output_field` key, `nothing` when none was given.
                          (Fn.Cast(Fn.Coalesce("grid", 0) / 2, Models.IntegerField()), _is_1028),
                          (Fn.Cast(Fn.Greatest("grid", 1) / 2, Models.CharField()), _is_1028)),
      conn in _CCD_ENGINES
    err = _ccd_refusal(expr; conn = conn)
    @test is_rule(err) && occursin("DecimalField `grid`", _ccd_msg(err))
  end
  for conn in _CCD_ENGINES
    @test _ccd_refusal(Fn.Concat("surname", _CF("grid") / 2); conn = conn) isa QueryBuildError
    # `+`, `-`, `*` keep a whole number whole on both engines, and an integer column divides alike.
    for expr in (Fn.Cast(_CF("grid") * 2, Models.IntegerField()), Fn.Cast(_CF("grid") + 1, Models.CharField()),
                 Fn.Cast(_CF("number") / 2, Models.IntegerField()))
      @test _ccd_refusal(expr; conn = conn) === nothing
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Floor/Ceil/Abs over an integer keep it on every engine, divided too (#1147)
# Their meaning is the operand's type (`:promoting`). PostgreSQL computed them over `(x)::numeric`,
# so `Floor(grid) / 2` kept the half there (`0.5`, `2.5`, `3.5` over grid 1, 5, 7 on PostgreSQL 16)
# where SQLite divides its integer (`0`, `2`, `3`), and #1111 refused it. Now an integer operand — a
# column, `Count`, integer arithmetic, an integer cast or literal, an integer date part — renders as
# itself under `Floor`/`Ceil` (PostgreSQL has no `floor(integer)`: `floor(int)` is a `double
# precision`) and bare under `ABS` (`abs(int)` is an `int`). Expected SQL, pinned per engine below:
# PostgreSQL `((("Tb"."number") / $1::bigint))::integer`, SQLite `CAST((FLOOR("Tb"."number") / ?) AS
# INTEGER)`. Every query #1111 refused for these now builds on both engines; the values it reads are
# checked against Julia in `test/integration/test_sql_functions.jl`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1147: Floor/Ceil/Abs over an integer keep it on every engine, divided too" begin
  team(expr) = (s = CCD.Ccd_team.objects; s.filter("id" => PormG.OuterRef("team")); s.values("t" => expr); PormG.Subquery(s))
  for (expr, pg, sl) in (
      (Fn.Cast(Fn.Floor("number") / 2, Models.IntegerField()),
       "(((\"Tb\".\"number\") / \$1::bigint))::integer", "CAST((FLOOR(\"Tb\".\"number\") / ?) AS INTEGER)"),
      (Fn.Cast(Fn.Ceil("number") / 2, Models.CharField()),
       "(((\"Tb\".\"number\") / \$1::bigint))::varchar", "CAST((CEIL(\"Tb\".\"number\") / ?) AS TEXT)"),
      (Fn.Cast(Fn.Abs("number") / 2, "numeric(10,1)"),
       "((ABS(\"Tb\".\"number\") / \$1::bigint))::numeric(10,1)", "CAST((ABS(\"Tb\".\"number\") / ?) AS NUMERIC(10,1))"),
      (Fn.Cast(Fn.Floor("born__@year") / 2, Models.IntegerField()),
       "(((EXTRACT(YEAR FROM \"Tb\".\"born\")::integer) / \$1::bigint))::integer",
       "CAST((FLOOR(CAST(strftime('%Y', \"Tb\".\"born\") AS INTEGER)) / ?) AS INTEGER)"),
      (Fn.Concat("surname", Fn.Floor("number") / 2),
       "CONCAT(\"Tb\".\"surname\",\n((\"Tb\".\"number\") / \$1::bigint))",
       "(COALESCE(\"Tb\".\"surname\", '') ||\nCOALESCE((FLOOR(\"Tb\".\"number\") / ?), ''))"),
      (Fn.Ceil(Fn.Value(7)), "(\$1::bigint)", "CEIL(?)"))
    @test occursin(pg, _ccd_render(expr; conn = _CCD_PG))
    @test occursin(sl, _ccd_render(expr; conn = _CCD_SL))
  end
  # Everything #1111 refused for these, through arithmetic, an aggregate, a rounding function, a
  # literal and a Subquery's record (#1124), builds on both engines.
  for conn in _CCD_ENGINES
    for expr in (Fn.Cast((Fn.Floor("number") + 1) / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Max(Fn.Abs("number")) / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Floor(Fn.Count("id")) / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Ceil(_CF("number") + 1) / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Abs(Fn.Cast(Fn.Round("points"), Models.IntegerField())) / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Floor(Fn.Value(7)) / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Round(Fn.Floor("number") / 2), Models.IntegerField()),
                 Fn.Cast(Fn.Ceil(Fn.Floor("number") / 2), Models.IntegerField()),
                 Fn.Cast(Fn.Round(Fn.Floor("number") / 2, 1), "numeric(10,1)"),
                 Fn.Cast(Fn.Round(Fn.Floor("number") / 2), "numeric(10,0)"),
                 Fn.Cast(Fn.Coalesce(Fn.Abs("id"), 0) / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Sum(Fn.Floor("number")) / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Coalesce(team(Fn.Floor("id")), 0) / 2, Models.IntegerField()))
      @test _ccd_refusal(expr; conn = conn) === nothing
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Floor/Ceil/Abs over anything but an integer keep PostgreSQL's `(x)::numeric` (#1147)
# The cast is what parses a JSON key's text value (`#>>` returns text, and PostgreSQL has no
# `floor(text)` or `abs(text)`), and over a float or a decimal it is the `numeric` the rounding
# functions compute. Only an integer by type renders without it; an operand PormG cannot type is
# not guessed at, and a quotient keeps it too. Expected SQL: `FLOOR(("Tb"."points")::numeric)`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1147: Floor/Ceil/Abs over anything but an integer keep PostgreSQL's ::numeric" begin
  for (expr, pg, sl) in (
      (Fn.Floor("points"), "FLOOR((\"Tb\".\"points\")::numeric)", "FLOOR(\"Tb\".\"points\")"),
      (Fn.Floor("price"), "FLOOR((\"Tb\".\"price\")::numeric)", "FLOOR(\"Tb\".\"price\")"),
      (Fn.Abs("payload__points"), "ABS((\"Tb\".\"payload\" #>> '{\"points\"}')::numeric)",
       "ABS(json_extract(\"Tb\".\"payload\", '\$.points'))"),
      (Fn.Ceil("payload__points"), "CEIL((\"Tb\".\"payload\" #>> '{\"points\"}')::numeric)",
       "CEIL(json_extract(\"Tb\".\"payload\", '\$.points'))"),
      (Fn.Ceil(_CF("number") / 2), "CEIL(((\"Tb\".\"number\" / \$1::bigint))::numeric)", "CEIL((\"Tb\".\"number\" / ?))"),
      (Fn.Abs("grid"), "ABS((\"Tb\".\"grid\")::numeric)", "ABS(\"Tb\".\"grid\")"))
    @test occursin(pg, _ccd_render(expr; conn = _CCD_PG))
    @test occursin(sl, _ccd_render(expr; conn = _CCD_SL))
  end
  # Review of #1147: a CTE types an `Avg` column and a `Sum` of floats as integers, so read by its
  # field such a column rendered as itself under `Floor`/`Ceil` on PostgreSQL — `7.5` unrounded, where
  # SQLite's `FLOOR` gives `7`. The body's own record decides instead: only a column the body computed
  # as an integer by type (`Sum("number")`) renders without the cast.
  function withcte(outer)
    q = CCD.Ccd_team.objects
    body = CCD.Ccd_driver.objects
    body.values("team", "av" => Fn.Avg("number"), "sp" => Fn.Sum("points"), "sn" => Fn.Sum("number"))
    q.with("c" => body, join_field = "id" => "team")
    q.values("x" => outer)
    return _ccd_sql(q; conn = _CCD_PG)
  end
  for (outer, col) in ((Fn.Floor(PormG.CTE("c", "av")), "av"), (Fn.Ceil(PormG.CTE("c", "sp")), "sp"),
                       (Fn.Cast(Fn.Floor(PormG.CTE("c", "av")), Models.IntegerField()), "av"))
    @test occursin(Regex("(FLOOR|CEIL)\\(\\(\"R\\d+_\\d+\"\\.\"$(col)\"\\)::numeric\\)"), withcte(outer))
  end
  @test occursin(r"SELECT\s+\(\"R\d+_\d+\"\.\"sn\"\) as \"x\"", withcte(Fn.Floor(PormG.CTE("c", "sn"))))
  # Review of #1147: a `Lag`/`Lead` answers its `default` on the first rows, so a float default makes
  # the window a `double precision` on PostgreSQL (`lag(int4, int, float8)`): `FLOOR` must stay. An
  # integer default binds `$n::bigint` and keeps the integer, so the window renders as itself.
  over = PormG.QueryBuilder.WindowOver(order_by = ["id"])
  for expr in (Fn.Floor(Fn.Lag("number", default = 1.5, over = over)), Fn.Ceil(Fn.Lead("number", default = 0.5, over = over)))
    @test occursin(r"(FLOOR|CEIL)\(\(LAG|(FLOOR|CEIL)\(\(LEAD", _ccd_render(expr; conn = _CCD_PG))
  end
  @test occursin(r"SELECT\s+\(LAG\(", _ccd_render(Fn.Floor(Fn.Lag("number", default = 1, over = over)); conn = _CCD_PG))
  # Delta review of #1147: a ranking window and a `Case` of integers are a `bigint` on PostgreSQL and an
  # integer on SQLite, though `_known_whole` does not name them, so the body records them whole too.
  # `Floor` over the column then renders it as itself and divides as integers on both engines, and
  # an outer `Sum` over it is still the `sum(bigint)` #1127 refuses — never `FLOOR(x::numeric) / 2`,
  # which kept the half on PostgreSQL only.
  function withrank(outer; conn)
    q = CCD.Ccd_team.objects
    body = CCD.Ccd_driver.objects
    body.values("team", "rk" => PormG.QueryBuilder.Rank(over = PormG.QueryBuilder.WindowOver(order_by = ["number"])),
                "cs" => Fn.Case(Fn.When("active" => true, then = 1), default = 0))
    q.with("c" => body, join_field = "id" => "team")
    q.values("x" => outer)
    return try _ccd_sql(q; conn = conn) catch e; e end
  end
  for col in ("rk", "cs"), conn in _CCD_ENGINES
    for outer in (Fn.Cast(Fn.Floor(PormG.CTE("c", col)) / 2, Models.IntegerField()),
                  Fn.Cast(Fn.Abs(PormG.CTE("c", col)) / 2, Models.IntegerField()))
      sql = withrank(outer; conn = conn)
      @test sql isa String && !occursin("::numeric", sql)
    end
    for outer in (Fn.Cast(Fn.Sum(Fn.Floor(PormG.CTE("c", col))) / 2, Models.IntegerField()),
                  Fn.Cast(Fn.Sum(Fn.Abs(PormG.CTE("c", col))) / 2, Models.IntegerField()))
      @test _is_1028(withrank(outer; conn = conn))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Sum of a BIGINT column, and a zero-scale decimal, divided (#1111)
# PostgreSQL's `sum(bigint)` is `numeric`, so `/ 2` keeps the half there, where SQLite's sum is an
# integer and divides as one: `Sum(resultid) / 2` over two rows read `1.5` and `1` (PostgreSQL 16,
# SQLite 3.45). The #1087 shape again: under `/` the value is refused through every rule the
# classifier feeds, and through an aggregate or arithmetic over it; `+`, `-`, `*`, a bare cast, and
# the aggregates both engines keep integer (`Max`, `Count`, `Sum` of an INTEGER column) still pass.
# `Floor`/`Ceil`/`Abs` carry the split of what they round (#1147): over a sum of a BIGINT or a
# zero-scale decimal it is still `numeric` on PostgreSQL, and `Sum(Abs("id"))` sums the `bigint`
# `ABS` keeps. Expected SQL: none — the build raises.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1111: Sum of a BIGINT and a zero-scale decimal, divided, refused through Floor/Ceil/Abs too" begin
  team(expr) = (s = CCD.Ccd_team.objects; s.filter("id" => PormG.OuterRef("team")); s.values("t" => expr); PormG.Subquery(s))
  for conn in _CCD_ENGINES
    for (expr, is_rule, named) in (
        (Fn.Cast(Fn.Sum("id") / Fn.Count("id"), Models.IntegerField()), _is_1028, "`SUM(…)` over the IDField `id`"),
        (Fn.Cast(Fn.Sum("laps_total") / 2, Models.CharField()), _is_1028, "`SUM(…)` over the BigIntegerField `laps_total`"),
        (Fn.Cast(Fn.Sum("team") / 2, Models.IntegerField()), _is_1028, "`SUM(…)` over the ForeignKey `team`"),
        (Fn.Cast(Fn.Sum(_CF("id") + 1) / 2, Models.IntegerField()), _is_1028, "`SUM(…)` over the IDField `id`"),
        # #1147: `ABS`/`FLOOR` over a `bigint` keep it, so their sum is a `sum(bigint)`.
        (Fn.Cast(Fn.Sum(Fn.Abs("id")) / 2, Models.IntegerField()), _is_1028, "`SUM(…)` over `ABS(…)` over the IDField `id`"),
        (Fn.Cast(Fn.Sum(Fn.Floor("id")) / 2, Models.IntegerField()), _is_1028, "`SUM(…)` over `FLOOR(…)` over the IDField `id`"),
        # Over a `numeric` whole number `FLOOR`/`CEIL` keep the split: they render `::numeric` there.
        (Fn.Cast(Fn.Floor(Fn.Sum("id")) / 2, Models.IntegerField()), _is_1028, "arithmetic over `FLOOR(…)` over `SUM(…)` over the IDField `id`"),
        (Fn.Cast(Fn.Floor("grid") / 2, Models.IntegerField()), _is_1028, "arithmetic over `FLOOR(…)` over the DecimalField `grid`"),
        (Fn.Cast(Fn.Abs("grid") / 2, "numeric(10,1)"), _is_1040, "arithmetic over `ABS(…)` over the DecimalField `grid`"),
        # Review of #1111: rounding the quotient cannot bring the half back — `ROUND(7.5)` is `8` on
        # PostgreSQL and `round(7)` is `7` on SQLite — so the rounding functions are not whole over it,
        # for an integer target, a scaled one, and the #1087 shape alike.
        (Fn.Cast(Fn.Round(Fn.Sum("id") / 2), Models.IntegerField()), _is_1028, "`ROUND(…)` over arithmetic over `SUM(…)` over the IDField `id`"),
        (Fn.Cast(Fn.Ceil(Fn.Sum("id") / 2), Models.IntegerField()), _is_1028, "`CEIL(…)` over arithmetic over `SUM(…)` over the IDField `id`"),
        (Fn.Cast(Fn.Floor(Fn.Sum("id") / 2), Models.CharField()), _is_1028, "`FLOOR(…)` over arithmetic over `SUM(…)` over the IDField `id`"),
        (Fn.Cast(Fn.Round(_CF("grid") / 2), Models.IntegerField()), _is_1028, "`ROUND(…)` over arithmetic over the DecimalField `grid`"),
        (Fn.Cast(Fn.Round(Fn.Sum("id") / 2, 1), "numeric(10,1)"), _is_1040, "`ROUND(…)` over arithmetic over `SUM(…)` over the IDField `id`"),
        (Fn.Cast(Fn.Round(Fn.Sum("id") / 2), "numeric(10,0)"), _is_1040, "`ROUND(…)` over arithmetic over `SUM(…)` over the IDField `id`"),
        # A Subquery projecting one of these answers the same once divided (#1124's record). No
        # operator takes a Subquery directly; `Coalesce` carries its operand's value.
        (Fn.Cast(Fn.Coalesce(team(Fn.Sum("id")), 0) / 2, Models.IntegerField()), _is_1028,
         "`COALESCE(…)` over a Subquery projecting `SUM(…)` over the IDField `id`"))
      err = _ccd_refusal(expr; conn = conn)
      @test is_rule(err)
      @test occursin(named, _ccd_msg(err))
      @test occursin("SQLite as an integer", _ccd_msg(err))
    end
    err = _ccd_refusal(Fn.Concat("surname", Fn.Sum("id") / 2); conn = conn)
    @test err isa QueryBuildError && occursin("(#1027)", _ccd_msg(err)) && occursin("arithmetic over `SUM(…)`", _ccd_msg(err))
    # The integer-target advice has to divide as a float first: rounding after an integer division
    # cannot bring the half back on SQLite.
    err = _ccd_refusal(Fn.Cast(Fn.Sum("id") / 2, Models.IntegerField()); conn = conn)
    @test occursin("x / 2.0", _ccd_msg(err))
    # The scale target's usual way out, an unscaled `numeric`, keeps `7` on SQLite: not offered here.
    err = _ccd_refusal(Fn.Cast(Fn.Sum("id") / 2, "numeric(10,1)"); conn = conn)
    @test occursin("x / 2.0", _ccd_msg(err)) && !occursin("unscaled", _ccd_msg(err))
    # Unchanged: `+`, `-`, `*`, a bare cast, the documented escape, and the aggregates both engines
    # keep integer.
    for expr in (Fn.Cast(Fn.Sum("id") * 2, Models.IntegerField()), Fn.Cast(Fn.Sum("id") + 1, Models.CharField()),
                 Fn.Cast(Fn.Sum("id"), Models.IntegerField()),
                 Fn.Cast(Fn.Round(Fn.Sum("id") / 2.0), Models.IntegerField()),
                 Fn.Cast(Fn.Max("number") / 2, Models.IntegerField()), Fn.Cast(Fn.Sum("number") / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Count("id") / 2, Models.IntegerField()), Fn.Cast(_CF("number") / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Max("laps_total") / 2, Models.IntegerField()),
                 Fn.Cast(team(Fn.Sum("id")), Models.IntegerField()),
                 # An operand PormG cannot type is not refused: a float under `Floor` is a REAL on
                 # SQLite too, and the engines agree. Only a type that is known is answered.
                 Fn.Cast(Fn.Floor(Fn.Case(Fn.When("active" => true, then = "points"), default = "points")) / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Floor("payload__points") / 2, Models.IntegerField()))
      @test _ccd_refusal(expr; conn = conn) === nothing
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A CTE column built from Sum of a BIGINT column, divided, is refused like the Sum (#1127)
# The CTE model types a `SUM` column as an integer, whatever it sums, so `CTE("c", "s") / 2` read as
# an integer column divided and built — while `Sum("id") / 2` is refused (#1111): PostgreSQL's
# `sum(bigint)` is `numeric` and keeps the half, SQLite's is an integer and drops it. The body's
# answer is recorded while it builds, as #1028 records its text classification, and the division
# check reads it on each route the column reaches a `/`: under `Coalesce` and under an outer
# aggregate, to an integer, a text and a scaled target. Expected SQL: none — the build raises.
# Also `Sum(F("id") / 2) / 2`: `bigint / integer` is a `bigint` on PostgreSQL, so the sum is one.
# Review of #1127: a `Count`, a `Sum` of an integer or a `Rank` column is a `bigint` on PostgreSQL
# though the CTE types it as an integer, so an outer `Sum` over it is `sum(bigint)`, a `numeric`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1127: a CTE column from Sum of a BIGINT, divided, is refused like the Sum" begin
  function withcte(outer)
    q = CCD.Ccd_team.objects
    body = CCD.Ccd_driver.objects
    body.values("team", "s" => Fn.Sum("id"), "laps" => Fn.Sum("laps_total"), "fl" => Fn.Sum(Fn.Floor("number")),
                "s_int" => Fn.Sum("number"), "top" => Fn.Max("id"), "cnt" => Fn.Count("id"),
                "rk" => PormG.QueryBuilder.Rank(over = PormG.QueryBuilder.WindowOver(order_by = ["number"])))
    q.with("c" => body, join_field = "id" => "team")
    q.values("x" => outer)
    return q
  end
  refusal(outer, conn) = try _ccd_sql(withcte(outer); conn = conn); nothing catch e; e end
  for conn in _CCD_ENGINES
    for (outer, named) in (
        (Fn.Cast(Fn.Coalesce(PormG.CTE("c", "s"), 0) / 2, Models.IntegerField()),
         "`COALESCE(…)` over the CTE column `CTE(\"c\", \"s\")` (`SUM(…)` over the IDField `id`)"),
        (Fn.Cast(Fn.Coalesce(PormG.CTE("c", "laps"), 0) / 2, Models.CharField()),
         "the CTE column `CTE(\"c\", \"laps\")` (`SUM(…)` over the BigIntegerField `laps_total`)"),
        (Fn.Cast(Fn.Sum(PormG.CTE("c", "s")) / 2, Models.IntegerField()),
         "`SUM(…)` over the CTE column `CTE(\"c\", \"s\")`"),
        (Fn.Cast(Fn.Max(PormG.CTE("c", "laps")) / 2, "numeric(10,1)"),
         "`MAX(…)` over the CTE column `CTE(\"c\", \"laps\")`"),
        # #1147: `Sum(Floor("number"))` sums the integer `FLOOR` keeps, so it is `s_int` again:
        # a `bigint` the CTE types as an integer, which an outer `Sum` makes a `sum(bigint)`.
        (Fn.Cast(Fn.Sum(PormG.CTE("c", "fl")) / 2, Models.IntegerField()),
         "`SUM(…)` over the CTE column `CTE(\"c\", \"fl\")` (`SUM(…)` over an integer)"),
        (Fn.Cast(Fn.Sum(PormG.CTE("c", "cnt")) / 2, Models.IntegerField()),
         "`SUM(…)` over the CTE column `CTE(\"c\", \"cnt\")` (`COUNT(…)`)"),
        (Fn.Cast(Fn.Sum(PormG.CTE("c", "s_int")) / 2, Models.IntegerField()),
         "`SUM(…)` over the CTE column `CTE(\"c\", \"s_int\")` (`SUM(…)` over an integer)"),
        (Fn.Cast(Fn.Sum(PormG.CTE("c", "rk")) / 2, Models.IntegerField()),
         "`SUM(…)` over the CTE column `CTE(\"c\", \"rk\")` (`RANK(…)`)"))
      err = refusal(outer, conn)
      @test err isa QueryBuildError
      @test occursin(named, _ccd_msg(err))
      @test occursin("SQLite as an integer", _ccd_msg(err))
    end
    # The sibling: a BIGINT divided by a whole number inside the sum is still a BIGINT on PostgreSQL.
    err = _ccd_refusal(Fn.Cast(Fn.Sum(_CF("id") / 2) / 2, Models.IntegerField()); conn = conn)
    @test _is_1028(err) && occursin("`SUM(…)` over the IDField `id`", _ccd_msg(err))
    # A nested quotient of whole numbers is still integer division, so still a BIGINT.
    err = _ccd_refusal(Fn.Cast(Fn.Sum((_CF("id") / 2) / 2) / 2, Models.IntegerField()); conn = conn)
    @test _is_1028(err) && occursin("`SUM(…)` over the IDField `id`", _ccd_msg(err))
    # Unchanged: the CTE columns both engines keep integer when divided directly (a `Sum` of an
    # INTEGER column, `Max`, `Count`: `bigint / integer` divides as an integer on both), an extremum
    # over one, the record read outside a division, and a sum of integer-column arithmetic
    # (`number * number` is `int4`, its sum an `int8` that divides as one). Not `F("number") / 2`:
    # PostgreSQL binds the literal `2` as `bigint`, so that sum is `numeric`, and it is refused
    # (#1141, below).
    for outer in (Fn.Cast(Fn.Coalesce(PormG.CTE("c", "s_int"), 0) / 2, Models.IntegerField()),
                  Fn.Concat("name", Fn.Coalesce(PormG.CTE("c", "fl"), 0) / 2),
                  Fn.Cast(Fn.Coalesce(PormG.CTE("c", "top"), 0) / 2, Models.IntegerField()),
                  Fn.Cast(Fn.Coalesce(PormG.CTE("c", "cnt"), 0) / 2, Models.IntegerField()),
                  Fn.Cast(Fn.Max(PormG.CTE("c", "cnt")) / 2, Models.IntegerField()),
                  Fn.Cast(Fn.Coalesce(PormG.CTE("c", "s"), 0) * 2, Models.IntegerField()),
                  Fn.Cast(PormG.CTE("c", "s"), Models.CharField()))
      @test refusal(outer, conn) === nothing
    end
    @test _ccd_refusal(Fn.Cast(Fn.Sum(_CF("number") * _CF("number")) / 2, Models.IntegerField()); conn = conn) === nothing
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Sum over an integer literal, divided, is refused like Sum of a BIGINT column (#1141)
# PostgreSQL binds an integer literal as `$n::bigint`, and `int4 + int8` is `int8`, so
# `SUM(("Tb"."number" + $1::bigint))` is a `sum(bigint)`: a `numeric` that keeps the half once
# divided, where SQLite's sum is an integer and drops it (#1111's split, `7.5` → `8` against `7`).
# #1111 named the BIGINT by the column's field only, so a literal in the summed arithmetic, or as a
# `Coalesce` fallback, built. The same reaches a CTE column: `Sum(F("number") + 1)` is recorded as
# a `numeric`, and a `Lag(Count(…))` column as the `bigint` it is. Expected SQL: none — the build
# raises, on both engines (the refusal is decided once, as #1111's is).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1141: Sum over an integer literal, divided, is refused as a sum(bigint)" begin
  literal = "an integer literal (a `bigint` on PostgreSQL)"
  function withcte(outer)
    q = CCD.Ccd_team.objects
    body = CCD.Ccd_driver.objects
    body.values("team", "plus" => Fn.Sum(_CF("number") + 1),
                "lagc" => PormG.QueryBuilder.Lag(Fn.Count("id"), over = PormG.QueryBuilder.WindowOver(order_by = ["team"])),
                # `LAG("number", $1::integer, $2::bigint)`: PostgreSQL resolves the default with the
                # operand, so the column is an `int8`.
                "prev" => PormG.QueryBuilder.Lag("number", default = 0, over = PormG.QueryBuilder.WindowOver(order_by = ["number"])),
                "prev_int" => PormG.QueryBuilder.Lag("number", over = PormG.QueryBuilder.WindowOver(order_by = ["number"])),
                # `LAG(RANK() OVER …, $1::integer, $2::bigint)`: a `bigint` either way.
                "prank" => PormG.QueryBuilder.Lag(PormG.QueryBuilder.Rank(over = PormG.QueryBuilder.WindowOver(order_by = ["number"])),
                                                  default = 0, over = PormG.QueryBuilder.WindowOver(order_by = ["number"])))
    q.with("c" => body, join_field = "id" => "team")
    q.values("x" => outer)
    return q
  end
  refusal(outer, conn) = try _ccd_sql(withcte(outer); conn = conn); nothing catch e; e end
  for conn in _CCD_ENGINES
    # The premise: the literal really is bound as `bigint` on PostgreSQL.
    conn === _CCD_PG && @test occursin("SUM((\"Tb\".\"number\" + \$1::bigint))", _ccd_render(Fn.Sum(_CF("number") + 1); conn = conn))
    for (expr, named) in (
        (Fn.Cast(Fn.Sum(_CF("number") + 1) / 2, Models.IntegerField()), "`SUM(…)` over $(literal)"),
        (Fn.Cast(Fn.Sum(1 + _CF("number")) / 2, Models.IntegerField()), "`SUM(…)` over $(literal)"),
        (Fn.Cast(Fn.Sum(_CF("number") / 2) / 2, Models.CharField()), "`SUM(…)` over $(literal)"),
        (Fn.Cast(Fn.Sum(Fn.Coalesce("number", 0)) / 2, Models.IntegerField()), "`SUM(…)` over `COALESCE(…)` over $(literal)"),
        # A function carrying its operand's value carries a BIGINT column too.
        (Fn.Cast(Fn.Sum(Fn.Coalesce("laps_total", Fn.Value(nothing))) / 2, Models.IntegerField()),
         "`SUM(…)` over `COALESCE(…)` over the BigIntegerField `laps_total`"),
        (Fn.Cast(Fn.Sum(Fn.Greatest("number", 1)) / 2, Models.IntegerField()), "`SUM(…)` over `GREATEST(…)` over $(literal)"),
        # Review of #1141: the conditional count — `CASE … THEN $2::bigint ELSE $3::bigint` — the
        # bitwise operators, a shift's left operand, and a declared `bigint`.
        (Fn.Cast(Fn.Sum(Fn.Case(Fn.When("number__@gt" => 3, then = 1), default = 0)) / 2, Models.IntegerField()),
         "`SUM(…)` over `CASE(…)` over $(literal)"),
        (Fn.Cast(Fn.Sum(Fn.Case(Fn.When("number__@gt" => 3, then = _CF("id")), default = nothing)) / 2, Models.IntegerField()),
         "`SUM(…)` over `CASE(…)` over the IDField `id`"),
        (Fn.Cast(Fn.Sum(_CF("number") & 1) / 2, Models.IntegerField()), "`SUM(…)` over $(literal)"),
        (Fn.Cast(Fn.Sum(xor(_CF("number"), 1)) / 2, Models.IntegerField()), "`SUM(…)` over $(literal)"),
        (Fn.Cast(Fn.Sum(_CF("laps_total") << 1) / 2, Models.IntegerField()),
         "`SUM(…)` over the BigIntegerField `laps_total`"),
        # A value PormG cannot type beside the `bigint` does not hide it: `COALESCE(("Tb"."number"
        # / $1::bigint), $2::bigint)` is an `int8`, and so is `coalesce(int4 << int4, int8)`.
        (Fn.Cast(Fn.Sum(Fn.Coalesce(_CF("number") / 2, 0)) / 2, Models.IntegerField()),
         "`SUM(…)` over `COALESCE(…)` over $(literal)"),
        (Fn.Cast(Fn.Sum(Fn.Coalesce(1 << _CF("number"), 0)) / 2, Models.IntegerField()),
         "`SUM(…)` over `COALESCE(…)` over $(literal)"),
        (Fn.Cast(Fn.Sum(Fn.Cast("number", Models.BigIntegerField())) / 2, Models.IntegerField()),
         "`SUM(…)` over a value cast to BIGINT"),
        (Fn.Cast(Fn.Sum(Fn.Coalesce("number", 0; output_field = Models.BigIntegerField())) / 2, Models.IntegerField()),
         "`SUM(…)` over a value cast to BIGINT"))
      err = _ccd_refusal(expr; conn = conn)
      @test _is_1028(err)
      @test occursin(named, _ccd_msg(err))
      @test occursin("SQLite as an integer", _ccd_msg(err))
    end
    for (outer, named) in (
        (Fn.Cast(Fn.Coalesce(PormG.CTE("c", "plus"), 0) / 2, Models.IntegerField()),
         "the CTE column `CTE(\"c\", \"plus\")` (`SUM(…)` over $(literal))"),
        (Fn.Cast(Fn.Sum(PormG.CTE("c", "lagc")) / 2, Models.IntegerField()),
         "`SUM(…)` over the CTE column `CTE(\"c\", \"lagc\")` (`LAG(…)` over `COUNT(…)`)"),
        (Fn.Cast(Fn.Sum(PormG.CTE("c", "prev")) / 2, Models.IntegerField()),
         "`SUM(…)` over the CTE column `CTE(\"c\", \"prev\")` (`LAG(…)` over $(literal))"),
        (Fn.Cast(Fn.Sum(PormG.CTE("c", "prank")) / 2, Models.IntegerField()),
         "`SUM(…)` over the CTE column `CTE(\"c\", \"prank\")` (`LAG(…)` over $(literal))"))
      err = refusal(outer, conn)
      @test err isa QueryBuildError
      @test occursin(named, _ccd_msg(err))
    end
    # Unchanged: a `sum(integer)` is a `bigint` and divides as an integer on both, and so does a
    # `bigint` that is not summed (`Max`, `Coalesce`); undivided, a `sum(bigint)` reads the same.
    for expr in (Fn.Cast(Fn.Sum("number") / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Sum(_CF("number") * _CF("number")) / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Max(_CF("number") + 1) / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Coalesce("number", 0) / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Sum(_CF("number") + 1), Models.IntegerField()),
                 Fn.Cast(Fn.Sum(_CF("number") + 1) * 2, Models.IntegerField()),
                 # A declared `integer` decides alone, though the operands hold a `bigint` literal.
                 Fn.Cast(Fn.Sum(Fn.Coalesce("number", 0; output_field = Models.IntegerField())) / 2, Models.IntegerField()),
                 # `NULLIF(a, b)` has `a`'s type; a shift has its left operand's and binds a literal
                 # on either side `::integer` (`$1::integer << …`, review of #1141); `~` and `&` of
                 # integer columns are integers; a `Case` NULL branch is no value.
                 Fn.Cast(Fn.Sum(Fn.NullIf("number", 0)) / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Sum(_CF("number") << 2) / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Sum(1 << _CF("number")) / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Sum(1024 >> _CF("number")) / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Sum(~_CF("number")) / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Sum(_CF("number") & _CF("number")) / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Sum(Fn.Case(Fn.When("number__@gt" => 3, then = _CF("number")), default = nothing)) / 2, Models.IntegerField()))
      @test _ccd_refusal(expr; conn = conn) === nothing
    end
    @test refusal(Fn.Cast(Fn.Max(PormG.CTE("c", "lagc")) / 2, Models.IntegerField()), conn) === nothing
    @test refusal(Fn.Cast(Fn.Sum(PormG.CTE("c", "prev_int")) / 2, Models.IntegerField()), conn) === nothing
    # The widest value wins: a float branch makes the `Case` a `float8`, so it is never named as the
    # `bigint` its integer branch alone would be. (An untyped `Case` is otherwise let through, the
    # #1111 fail-open; this asserts only that the `bigint` rule does not answer for it.)
    err = _ccd_refusal(Fn.Cast(Fn.Sum(Fn.Case(Fn.When("number__@gt" => 3, then = 1.5), default = 0)) / 2, Models.IntegerField()); conn = conn)
    @test err === nothing || !occursin(literal, _ccd_msg(err))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Floor/Ceil/Abs over an integer date part keep the integer, divided too (#1135, #1147)
# #1135 refused `Floor("born__@year") / 2`: PostgreSQL rendered
# `FLOOR((EXTRACT(YEAR FROM "Tb"."born")::integer)::numeric) / $1::bigint`, which keeps the half, where
# SQLite's `FLOOR(CAST(strftime('%Y', …) AS INTEGER)) / ?` divides as integers. The date part is read
# through the transform ladder, and the parts both engines compute as integers count as whole by type:
# the `EXTRACT` fields but `EPOCH` and the sub-second ones, `@quarter`, `@quadrimester`, `@week_day`.
# Since #1147 that same reading is what renders them over the integer on PostgreSQL too, so every one
# divides as integers on both engines and builds. Expected SQL (PostgreSQL), for the year:
# `(((EXTRACT(YEAR FROM "Tb"."born")::integer) / $1::bigint))::integer` — no `::numeric`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1135/#1147: Floor/Ceil/Abs over an integer date part keep the integer, divided too" begin
  for conn in _CCD_ENGINES
    for expr in (Fn.Cast(Fn.Floor("born__@year") / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Ceil("born__@month") / 2, Models.CharField()),
                 Fn.Cast(Fn.Floor("born__@quarter") / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Floor("born__@quadrimester") / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Abs("born__@week_day") / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Floor("start_at__@second") / 2, Models.IntegerField()),
                 # The explicit function is the same node the path builds.
                 Fn.Cast(Fn.Abs(Fn.Extract("born", "year")) / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Floor(Fn.Extract("born", "dow")) / 2, "numeric(10,1)"),
                 Fn.Concat("surname", Fn.Floor("born__@year") / 2),
                 Fn.Cast(Fn.Floor("born__@yyyy_mm"), Models.CharField()),
                 Fn.Cast(Fn.Floor("born__@year"), Models.IntegerField()),
                 Fn.Cast(Fn.Floor("born__@day") * 2, Models.IntegerField()),
                 Fn.Cast(_CF("born__@year") / 2, Models.IntegerField()),
                 Fn.Cast(Fn.Sum("born__@year") / 2, Models.IntegerField()))
      @test _ccd_refusal(expr; conn = conn) === nothing
    end
  end
  for expr in (Fn.Floor("start_at__@second"), Fn.Ceil("born__@month"), Fn.Abs(Fn.Extract("born", "year")))
    @test !occursin("::numeric", _ccd_render(expr; conn = _CCD_PG))
  end
  # A text transform is not a whole number by type, so PostgreSQL keeps the cast that parses it.
  @test occursin("::numeric", _ccd_render(Fn.Floor("born__@yyyy_mm"); conn = _CCD_PG))
  # `EPOCH` stays fractional on PostgreSQL (`EXTRACT(EPOCH …)` is `numeric`), so it is no whole number
  # to refuse; SQLite has no `EPOCH` part at all.
  @test _ccd_refusal(Fn.Cast(Fn.Floor(Fn.Extract("start_at", "epoch")) / 2, Models.IntegerField()); conn = _CCD_PG) === nothing
  # Review of #1135: a part SQLite cannot render raises there (category 4), so it has no SQLite answer
  # to split from, and PostgreSQL keeps rendering it. `@quarter` is a node of its own on both engines;
  # an `EXTRACT` `QUARTER` field is PostgreSQL's alone.
  for part in ("century", "quarter", "timezone_hour")
    expr = Fn.Cast(Fn.Floor(Fn.Extract("start_at", part)) / 2, Models.IntegerField())
    @test _ccd_refusal(expr; conn = _CCD_PG) === nothing
    @test _ccd_refusal(expr; conn = _CCD_SL) isa PormG.BackendCapabilityError
  end
end

@testset "#1087: the precision, the scale and a Decimal exponent are bounded before they size a BigInt" begin
  size = PormG.QueryBuilder._numeric_cast_size
  @test size("numeric(1000,1000)") == (1000, 1000)
  @test size("numeric(10)") == (10, 0)
  # Past PostgreSQL's own bound of 1000 the server refuses the type: a larger size reads as 1001, never
  # parsed whole, so the overflow check leaves it to the server while the scale rule still applies.
  for (t, read) in ("numeric(99999999999999999999)" => (1001, 0), "numeric(1001,2)" => (1001, 2),
                    "numeric(10,1001)" => (10, 1001), "numeric(10,99999999999999999999)" => (10, 1001))
    @test size(t) == read
  end
  for conn in _CCD_ENGINES
    @test _ccd_refusal(Fn.Cast(Fn.Value(100), "numeric(99999999999999999999)"); conn = conn) === nothing
    @test _is_1040(_ccd_refusal(Fn.Cast(Fn.Value(2.675), "numeric(1001,2)"); conn = conn))
    @test _is_1040(_ccd_refusal(Fn.Cast("points", "numeric(1001,2)"); conn = conn))
    # A zero Decimal is zero on both engines, whatever its exponent.
    @test _ccd_refusal(Fn.Cast(Fn.Value(Decimal(0, 0, -5)), "numeric(10,2)"); conn = conn) === nothing
    # A huge or tiny Decimal exponent is decided without building the power of ten.
    huge = Fn.Cast(Fn.Value(Decimal(0, 1, 10^9)), "numeric(10,2)")
    started = time(); err = _ccd_refusal(huge; conn = conn)
    @test time() - started < 5
    @test occursin("a Decimal literal with more than 2000 digits before the point", _ccd_msg(err))
    @test _is_1087(err)
    # A Decimal is an AbstractFloat, and Base's `isinteger` calls 1e-30 whole: it used to pass the
    # #1040 scale rule as a whole number. PostgreSQL makes it `0.00`, SQLite keeps it.
    err = _ccd_refusal(Fn.Cast(Fn.Value(Decimal(0, 1, -30)), "numeric(10,2)"); conn = conn)
    @test _is_1040(err) && occursin("a Decimal literal with 30 decimal places", _ccd_msg(err))
  end
  # A tiny one rounds to zero at any scale PostgreSQL accepts, decided from the exponent alone.
  exact = PormG.QueryBuilder._literal_exact_value
  started = time()
  @test exact(Decimal(0, 1, -10^9)) == 0
  @test exact(Decimal(1, 7, 10^9)) < -big(10)^2000
  @test time() - started < 1
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

# ─────────────────────────────────────────────────────────────────────────────
# #1078: `dec` is typed as `decimal` is
# PostgreSQL's third spelling of `numeric`; SQLite gives `DEC` NUMERIC affinity, as it does `DECIMAL`.
# `_numeric_cast_scale` read a scaled `dec(p, s)`, but the type reader did not know an unscaled
# `"dec"`, so every rule that types a declared cast let it through: a cast to an integer over it
# (PostgreSQL rounds `1.5` to `2`, SQLite truncates it to `1`), `Concat`, and the alias filter.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1078: an unscaled dec cast is typed as decimal is" begin
  for t in ("dec", "DEC", "Dec")
    @test PormG.QueryBuilder._sql_type_field(t) isa Models.sDecimalField
  end
  for t in ("dec", "decimal"), conn in _CCD_ENGINES
    # A cast to an integer or to text over it is the #1028 refusal, through either spelling.
    @test _is_1028(_ccd_refusal(Fn.Cast(Fn.Cast("points", t), Models.IntegerField()); conn = conn))
    @test _is_1028(_ccd_refusal(Fn.Cast(Fn.Cast("number", t), Models.CharField()); conn = conn))
    @test _ccd_refusal(Fn.Concat("surname", Fn.Cast("number", t)); conn = conn) isa QueryBuildError
    # The alias filter checks the value as a number.
    q = CCD.Ccd_driver.objects; q.values("d" => Fn.Cast("number", t)); q.filter("d" => "abc")
    @test (try _ccd_sql(q; conn = conn); nothing catch e; e end) isa PormG.InvalidValueError
    q = CCD.Ccd_driver.objects; q.values("d" => Fn.Cast("number", t)); q.filter("d" => 3)
    @test !isempty(_ccd_sql(q; conn = conn))
    # #1085: Round(x, d) renders each engine's own ROUND over it, as over any number.
    sql = _ccd_render(Fn.Round(Fn.Cast("points", t), 2); conn = conn)
    @test occursin("ROUND(", uppercase(sql)) && !occursin("FLOOR(", uppercase(sql))
  end
end
