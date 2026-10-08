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
             Fn.Round("points", 2),                         # a fraction survives two digits
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
  for (operand, target) in ("points" => "numeric(10,2)", "points" => "double precision",
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
  for (lit, named) in (Fn.Value(DateTime(2009, 3, 29, 6)) => "DateTime literal", Fn.Value(Minute(1)) => "duration literal")
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
