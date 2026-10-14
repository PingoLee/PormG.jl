"""
A declared cast is refused on the engine that departs from what it means; a `Concat` operand that
is not text is refused on every engine (#1028, #1040, #1087, #1111, #1147).

#1027 refused a boolean, float or decimal `Concat` operand, and #1028 onwards followed the same
operands through a declared cast. Until #1147 every such refusal compared the two engines and fired
on both. #1147 step 2 sorts each case by what the expression MEANS, never by the other engine:

- **Meaning** — an engine computes a different value from the one the expression means. Refused on
  that engine only, naming it alone; every other engine builds the query as written. Measured on
  PostgreSQL 16.15 and SQLite 3.45.1 against the F1 fixture:

| expression                                 | means                | PostgreSQL           | SQLite                  | refused on |
|--------------------------------------------|----------------------|----------------------|-------------------------|------------|
| `Cast(<bool> true, CharField())`           | `'true'`             | `'true'`             | `'1'`                   | SQLite (#1028) |
| `Cast(<float> 1.5, IntegerField())`        | `2`, the nearest     | `2`                  | `1` (truncates)         | SQLite (#1028) |
| `Cast(<float> -1.5, IntegerField())`       | `-2`                 | `-2`                 | `-1`                    | SQLite (#1028) |
| `Cast(<numeric> 2.5, IntegerField())`      | `3`                  | `3`                  | `2`                     | SQLite (#1028) |
| `Cast(<float> 1.555, "numeric(10,2)")`     | `1.56`               | `1.56`               | `1.555`                 | SQLite (#1040) |
| `Cast(<text> '1.555', "numeric(10,2)")`    | `1.56`               | `1.56`               | `1.555`                 | SQLite (#1040) |
| `Cast(100, "numeric(3,2)")`                | an overflow          | raises one           | `100`                   | SQLite (#1087) |

  `Cast(Round / Floor / Ceil(x), Integer)` and `Round(x)` agree on both engines (±0.5, ±1.5, ±2.5,
  every `points` row), so the way out of each refusal builds everywhere.

- **Representation** — the same value spelled differently: a float's text (`'10'` / `'10.0'`), a
  decimal's (`'14.00'` / `'14'`), a timestamp's (`2009-03-29 06:00:00+00` /
  `2009-03-29T06:00:00.000+00:00`), an interval's (`PT25.021S` / `00:00:26.898`) and a JSON
  document's (`{"a": [1, 2]}` / `{"a":[1,2]}`). A cast to text asks for the value's text, and each
  engine writes its own: it builds on both, with no refusal.

- **Explicit intent** — `Concat` over a number, a boolean, a timestamp, an interval or a JSON
  document, and `Round` over text: the query does not say which text, or which number, it means.
  Refused on every engine, the message naming no engine and the spelling that says it
  (`Cast(x, "text")`, `ToChar`, a `Case`, `Cast(x, FloatField())`).

- **Normalized** — where PormG can render the meaning on the engine that would depart, it does:
  PostgreSQL widens `sum(bigint)` to `numeric`, so a `Sum` the type walk names a `bigint` renders
  `SUM(x)::bigint` there, divides as an integer on both engines, and builds everywhere (a shifted or
  bitwise one too, #1153: `Sum(F("laps_total") << 1) / 2` is `7` on both). SQLite stores a whole
  decimal as INTEGER, and a value that is one of several as the row's own integer, so a quotient the
  walk names a decimal or a float divides as REAL there, `(CAST(x AS REAL) / ?)` (#1150):
  `<decimal(4,0)> 15 / 2` is `7.5` on both, where #1087 refused it on SQLite.

`output_field` on `Coalesce`/`Greatest`/`Least` renders the same cast, so it follows the same rules, and
so does a `Case`'s, over each branch value (#1217).
A CTE column built from `Sum`/`Avg`, and a `Subquery`, are classified by the body's own projection.
#1050 narrows the float-literal arm of #1040 to a literal with more places than the scale, and #1087
reads a zero-scale `DecimalField` like an integer column until it is divided.

`Round(x, d)` renders each engine's own `ROUND`, as Django's does (#1061): the two can round a decimal
tie apart in its last digit, which is documented rather than refused. A negative `d` is refused when
the expression is built (#1044).

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
  laps_total = Models.BigIntegerField(null = true),  # `sum(bigint)` is `numeric` on PostgreSQL (#1111, #1147)
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
# The refusal of one issue, not any `QueryBuildError`: a renamed field would raise one too.
_is_1028(e) = e isa QueryBuildError && occursin("(#1028)", _ccd_msg(e))
_ccd_engine(conn) = conn === _CCD_PG ? "PostgreSQL" : "SQLite"
_ccd_other_engine(conn) = conn === _CCD_PG ? "SQLite" : "PostgreSQL"

# MEANING (#1147 step 2): refused on each engine `departs` names — with `issue`'s tag, `named` in the
# message, and a message naming that engine only — and built as written on the others. `departs` is
# the test's own expectation, spelled out per engine; it is never read from PormG's departure table,
# so the test stays the oracle. `run(conn)` builds the query (default: project `expr`). Returns the
# per-engine exception (`nothing` where it built).
function _ccd_expect(expr; departs::NamedTuple{(:postgres, :sqlite)}, issue::AbstractString,
                     named::Union{AbstractString,Nothing} = nothing,
                     run = conn -> _ccd_render(expr; conn = conn))
  errs = map((_CCD_PG, _CCD_SL), (departs.postgres, departs.sqlite)) do conn, refuses
    err = try run(conn); nothing catch e; e end
    if refuses
      msg = err === nothing ? "" : _ccd_msg(err)
      @test err isa QueryBuildError
      @test occursin("so PormG refuses it on $(_ccd_engine(conn)) ($(issue))", msg)
      @test !occursin(_ccd_other_engine(conn), msg)
      named === nothing || @test occursin(named, msg)
    else
      @test err === nothing
    end
    err
  end
  return (postgres = errs[1], sqlite = errs[2])
end
# EXPLICIT INTENT: refused on every engine, with `issue`'s tag, `named` in the message, and no
# engine named. Returns the messages.
function _ccd_refused_everywhere(expr; issue::AbstractString, named::Union{AbstractString,Nothing} = nothing,
                                 run = conn -> _ccd_render(expr; conn = conn))
  map(_CCD_ENGINES) do conn
    err = try run(conn); nothing catch e; e end
    msg = err === nothing ? "" : _ccd_msg(err)
    @test err isa QueryBuildError
    @test occursin("($(issue))", msg)
    @test !occursin("PostgreSQL", msg) && !occursin("SQLite", msg)
    named === nothing || @test occursin(named, msg)
    msg
  end
end
# Built on every engine: a representation difference, or an expression with nothing to refuse.
_ccd_builds(expr; run = conn -> _ccd_render(expr; conn = conn)) =
  all(conn -> (try run(conn); true catch; false end), _CCD_ENGINES)
const _SL_ONLY = (postgres = false, sqlite = true)
const _PG_ONLY = (postgres = true, sqlite = false)

# ─────────────────────────────────────────────────────────────────────────────
# Cast to text over a float, decimal, timestamp, interval or JSON builds on both engines
# REPRESENTATION (#1147 step 2): the cast asks for the value's text, and each engine writes its own
# (`'10'` / `'10.0'`, `'14.00'` / `'14'`, `2009-03-29 06:00:00+00` / `…T06:00:00.000+00:00`). The value
# is the same, so nothing is refused. Before #1147 every one of these was refused on both engines.
# Expected SQL: `("Tb"."points")::varchar` on PostgreSQL, `CAST("Tb"."points" AS TEXT)` on SQLite.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028, #1147: Cast to text over a float, decimal, timestamp, interval or JSON builds on both engines (representation)" begin
  operands = ["points", "price", "team__rating", "start_at", "laptime", "payload",
              _CF("start_at") - _CF("start_at"), Fn.Avg("number"), Fn.Max("start_at"), _CF("points") * 2]
  for operand in operands, target in (Models.CharField(), Models.TextField(), "text", "varchar(20)")
    @test _ccd_builds(Fn.Cast(operand, target))
  end
  @test occursin("(\"Tb\".\"points\")::varchar as \"x\"", _ccd_render(Fn.Cast("points", Models.CharField()); conn = _CCD_PG))
  @test occursin("CAST(\"Tb\".\"points\" AS TEXT) as \"x\"", _ccd_render(Fn.Cast("points", Models.CharField()); conn = _CCD_SL))
end

# ─────────────────────────────────────────────────────────────────────────────
# Cast of a boolean to text is refused on SQLite only
# MEANING (#1028): a boolean's text is the word, `true` or `false`, which PostgreSQL writes. SQLite has
# no boolean and stores `1`/`0`, so its cast writes `'1'`: it departs and is refused, naming the `Case`
# that writes the word on every engine. PostgreSQL builds `("Tb"."active")::varchar`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: Cast of a boolean to text is refused on SQLite only (meaning)" begin
  for (operand, named) in ("active" => "the BooleanField `active`", Fn.Value(true) => "a Bool literal"),
      target in (Models.CharField(), Models.TextField(), "text", "varchar(20)")
    errs = _ccd_expect(Fn.Cast(operand, target); departs = _SL_ONLY, issue = "#1028", named = named)
    @test occursin("Write the text you mean: Case(When(", _ccd_msg(errs.sqlite))
  end
  @test occursin("(\"Tb\".\"active\")::varchar as \"x\"", _ccd_render(Fn.Cast("active", Models.CharField()); conn = _CCD_PG))
end

# ─────────────────────────────────────────────────────────────────────────────
# Cast to an integer: a fractional number is refused on SQLite only, a boolean is not
# MEANING (#1028): a fractional number cast to an integer is the nearest one, `1.5` → `2`, which
# PostgreSQL computes; SQLite's cast truncates it to `1`, so SQLite departs and is refused, and
# PostgreSQL builds `("Tb"."points")::integer`. A boolean casts to `1`/`0` on both, and the integer
# escape — `Round`/`Floor`/`Ceil` first — has nothing left to round.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: Cast to an integer refuses a fractional number on SQLite only (meaning)" begin
  refused = ["points", "price", "team__rating", Fn.Avg("number"), Fn.Sum("points"), _CF("points") / 2,
             Fn.Round("price", 2),                          # a fraction survives two digits
             Fn.Cast("points", "numeric"), Fn.Value(1.5), Fn.Value(Decimal(2.5))]
  for operand in refused, target in (Models.IntegerField(), Models.BigIntegerField(), "integer", "bigint", "int8", "smallint")
    errs = _ccd_expect(Fn.Cast(operand, target); departs = _SL_ONLY, issue = "#1028")
    msg = _ccd_msg(errs.sqlite)
    @test occursin("means the nearest integer", msg) && occursin("Cast(Round(x), IntegerField())", msg)
  end
  @test occursin("(\"Tb\".\"points\")::integer as \"x\"", _ccd_render(Fn.Cast("points", Models.IntegerField()); conn = _CCD_PG))
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
# output_field: Coalesce, Greatest and Least apply the same cast, so the same rules
# Each renders `(…)::type` / `CAST(… AS type)` for its `output_field` (#852). The message names the
# function as written. A fraction to an integer and a boolean to text are refused on SQLite only
# (meaning, #1028); a decimal to text builds on both (representation). A `Case` is not one of the
# three: its value is a branch, so without an `output_field` its branch values are read (#1151, #1187).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: an output_field cast follows the same rules" begin
  for (expr, fname) in ((Fn.Coalesce("points", 0; output_field = "integer"), "Coalesce(…; output_field = \"integer\")"),
                        (Fn.Greatest("number", "points"; output_field = Models.IntegerField()), "Greatest(…; output_field = \"INTEGER\")"),
                        (Fn.Coalesce("active", false; output_field = Models.CharField()), "Coalesce(…; output_field = \"VARCHAR\")"))
    _ccd_expect(expr; departs = _SL_ONLY, issue = "#1028", named = fname)
  end
  for expr in (Fn.Coalesce("number", 0; output_field = "integer"),
               Fn.Greatest(Fn.Floor("points"), 0; output_field = "integer"),
               Fn.Least("points", 25; output_field = "double precision"),
               Fn.Coalesce("active", false; output_field = "integer"),
               Fn.Least("price", 25; output_field = "text"))      # representation: each engine's text
    @test _ccd_builds(expr)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A meaning refusal says what the cast means, what SQLite computes, and the way out
# The boolean's text is the word `true` (a cast, unlike `CONCAT`'s `t`) and the way out a `Case`
# naming the column; an integer target's meaning is the nearest integer, and the way out the three
# rounding functions. The message names the engine at hand only, never a pair (#1147). The cast is
# labelled with its declared type.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: a meaning refusal says what the cast means and what SQLite computes" begin
  msg(expr) = _ccd_msg(_ccd_refusal(expr; conn = _CCD_SL))
  bool = msg(Fn.Cast("active", Models.CharField()))
  @test occursin("Cast(…, \"VARCHAR\") of the BooleanField `active` means its text, `true` or `false`", bool)
  @test occursin("SQLite computes `1` or `0`", bool)
  @test occursin("Case(When(\"active\" => true, then = Value(\"true\")), default = \"false\")", bool)
  int = msg(Fn.Cast("points", Models.IntegerField()))
  @test occursin("Cast(…, \"INTEGER\") of the FloatField `points` means the nearest integer", int)
  @test occursin("SQLite computes the truncated one", int)
  @test occursin("Cast(Round(x), IntegerField())", int) && !occursin("Case(When", int)
  @test occursin("Cast(…, \"text\") of", msg(Fn.Cast("active", "text")))
  for m in (bool, int)
    @test occursin("so PormG refuses it on SQLite (#1028)", m) && !occursin("PostgreSQL", m)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Concat: a timestamp, an interval or a JSON operand is refused on every engine, a time or uuid passes
# EXPLICIT INTENT (#1147 step 2): the query does not say which text of the value it means. Each is
# refused through every shape that types it: a column, a typed function, and the intervals only the
# renderer can name — a timestamp difference, duration arithmetic, `Sum(duration)`
# (`_render_interval_operand`). The message names no engine and points to `ToChar` or a cast to text.
# A JSON key lookup is the value at that key, not the document, and passes. The #1027 kinds keep
# their own tag.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: Concat refuses a timestamp, interval or JSON operand on every engine (explicit intent)" begin
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
  for (operand, named) in refused
    for msg in _ccd_refused_everywhere(Fn.Concat(Fn.Value("|"), operand); issue = "#1028", named = named)
      @test occursin("Concat joins text, and", msg) && occursin("is not text", msg)
    end
  end
  # A timestamp is pointed to a format; the others to a cast to text.
  for msg in _ccd_refused_everywhere(Fn.Concat(Fn.Value("|"), "start_at"); issue = "#1028")
    @test occursin("ToChar(\"start_at\", \"YYYY-MM-DD HH:MI:SS\")", msg) && occursin("Cast(\"start_at\", \"text\")", msg)
  end
  for msg in _ccd_refused_everywhere(Fn.Concat(Fn.Value("|"), "payload"); issue = "#1028")
    @test occursin("Cast(\"payload\", \"text\")", msg)
  end
  for operand in ("clock", "token", "born", "start_at__@date", "start_at__@year", "payload__driver",
                  "payload__0__name", Fn.ToChar("start_at", "YYYY-MM-DD HH:MI:SS")), conn in _CCD_ENGINES
    sql = _ccd_render(Fn.Concat(Fn.Value("|"), operand); conn = conn)
    @test occursin(conn === _CCD_PG ? "CONCAT(" : "COALESCE(", sql)
  end
  # The #1027 kinds keep the #1027 tag; only the new ones carry #1028.
  _ccd_refused_everywhere(Fn.Concat(Fn.Value("|"), "points"); issue = "#1027")
end

# ─────────────────────────────────────────────────────────────────────────────
# Concat over a Cast to text: the explicit spelling builds; over a boolean it meets SQLite's refusal
# `Concat(…, Cast("points", CharField()))` says which text it means — the float's own text on each
# engine — so it builds on both (representation). Expected SQL: `("Tb"."points")::varchar` inside
# `CONCAT(…)` on PostgreSQL, `CAST("Tb"."points" AS TEXT)` on SQLite. A boolean's cast to text is a
# question of meaning (#1028): the inner `Cast` renders while `Concat`'s operands do, so it meets the
# SQLite refusal there, and PostgreSQL builds.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028, #1147: Concat over a Cast to text builds; over a boolean's cast it is refused on SQLite only" begin
  expr = Fn.Concat("surname", Fn.Value("-"), Fn.Cast("points", Models.CharField()))
  @test _ccd_builds(expr)
  @test occursin("(\"Tb\".\"points\")::varchar", _ccd_render(expr; conn = _CCD_PG))
  @test occursin("CAST(\"Tb\".\"points\" AS TEXT)", _ccd_render(expr; conn = _CCD_SL))
  _ccd_expect(Fn.Concat("surname", Fn.Value("-"), Fn.Cast("active", Models.CharField()));
              departs = _SL_ONLY, issue = "#1028", named = "the BooleanField `active`")
  # The integer escape renders, and Concat accepts its integer result.
  @test _ccd_builds(Fn.Concat("surname", Fn.Value("-"), Fn.Cast(Fn.Round("points"), Models.IntegerField())))
end

# ─────────────────────────────────────────────────────────────────────────────
# CTE: a column built from Sum or Avg is classified by the body's projection
# `_set_field_from_sql_function` types a `Sum` column as an integer and an `Avg` one as its
# operand's field, which let `Concat` over `Avg("number")` or `Sum("points")` through as a CTE
# column while the same aggregate written directly was refused. The body's classification is
# recorded while it builds, so both `Concat` and `Cast` see it: `Concat` refuses it on every engine
# (explicit intent), a cast of the `Avg` column to an integer on SQLite only (meaning, #1028).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: a CTE column from Sum/Avg is classified like the aggregate" begin
  function withcte(outer)
    q = CCD.Ccd_team.objects
    body = CCD.Ccd_driver.objects
    body.values("team", "avg_n" => Fn.Avg("number"), "sum_p" => Fn.Sum("points"),
                "max_n" => Fn.Max("number"), "cnt" => Fn.Count("id"), "last" => Fn.Max("start_at"))
    q.with("c" => body, join_field = "id" => "team")
    q.values("x" => outer)
    return q
  end
  cte(outer) = conn -> _ccd_sql(withcte(outer); conn = conn)
  for (col, kind, issue) in (("avg_n", "`AVG(…)`", "#1027"), ("sum_p", "`SUM(…)` over the FloatField `points`", "#1027"),
                             ("last", "timestamp", "#1028"))
    for msg in _ccd_refused_everywhere(nothing; issue = issue, run = cte(Fn.Concat(Fn.Value("-"), PormG.CTE("c", col))))
      @test occursin("the CTE column `CTE(\"c\", \"$(col)\")`", msg)
      @test occursin(kind, msg)
    end
    # The same spelling `"c__<col>"` resolves to the same handle.
    for msg in _ccd_refused_everywhere(nothing; issue = issue, run = cte(Fn.Concat(Fn.Value("-"), "c__$(col)")))
      @test occursin("the CTE column", msg) && occursin(kind, msg)
    end
  end
  _ccd_expect(nothing; departs = _SL_ONLY, issue = "#1028", named = "the CTE column `CTE(\"c\", \"avg_n\")`",
              run = cte(Fn.Cast(PormG.CTE("c", "avg_n"), Models.IntegerField())))
  # An integer CTE column has one text, and passes both.
  for col in ("max_n", "cnt")
    @test _ccd_builds(nothing; run = cte(Fn.Concat(Fn.Value("-"), PormG.CTE("c", col))))
    @test _ccd_builds(nothing; run = cte(Fn.Cast(PormG.CTE("c", col), Models.CharField())))
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
# on SQLite. `Concat` over any of them is explicit intent, refused on every engine — a literal when
# the `Concat` is built. A cast of one to text is representation and builds on both (#1147 step 2).
# A `Date` literal agrees.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: Concat refuses timestamp arithmetic and temporal literals everywhere; a cast to text builds" begin
  _ccd_refused_everywhere(Fn.Concat(Fn.Value("|"), _CF("start_at") + Day(1)); issue = "#1028", named = "a timestamp expression")
  for expr in (Fn.Cast(_CF("start_at") + Day(1), "text"), Fn.Cast(Fn.Value(DateTime(2009, 3, 29, 6)), Models.CharField()),
               Fn.Cast(Fn.Value(Minute(1)), "text"),
               Fn.Concat(Fn.Value("|"), _CF("born") + Day(1)))   # a date stays a date through arithmetic
    @test _ccd_builds(expr)
  end
  for (lit, named) in (Fn.Value(DateTime(2009, 3, 29, 6)) => "a DateTime literal", Fn.Value(Minute(1)) => "a duration literal")
    err = try Fn.Concat("surname", lit); nothing catch e; e end
    @test _is_1028(err)
    @test occursin(named, _ccd_msg(err))
    @test !occursin("PostgreSQL", _ccd_msg(err)) && !occursin("SQLite", _ccd_msg(err))
  end
  @test _ccd_builds(Fn.Concat(Fn.Value("|"), Fn.Value(Date(2009, 3, 29))))
end

# ─────────────────────────────────────────────────────────────────────────────
# Review of #1028: whole numbers cast to an integer pass; a fraction is refused on SQLite only
# `Mod` of integers and `+`/`-`/`*` of whole numbers have nothing to round: PostgreSQL's `numeric` and
# SQLite's REAL spell the same whole number. A `/` or a float operand still has a fraction, whose
# nearest integer SQLite truncates (meaning, #1028); PostgreSQL builds.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: whole-number arithmetic casts to an integer; a fraction is refused on SQLite only" begin
  for operand in (Fn.Mod("number", 3), Fn.Floor("points") * 2, _CF("number") * 2 + Fn.Ceil("price"))
    @test _ccd_builds(Fn.Cast(operand, Models.IntegerField()))
  end
  for operand in (Fn.Mod("points", 3), Fn.Floor("points") * 1.5, Fn.Floor("points") / 2)
    _ccd_expect(Fn.Cast(operand, Models.IntegerField()); departs = _SL_ONLY, issue = "#1028")
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Review of #1028: a CTE column built from a JSON key lookup holds the value, not the document
# The CTE types the column with the JSONField itself, so without the body's record it read as the
# whole document and was refused. The document column is still refused by `Concat`, on every engine
# (explicit intent). A `Case(…; output_field = "text")` over an integer branch builds: an integer's
# text is representation (its branches are checked since #1217).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: a JSON key column of a CTE passes; a Case output_field text over an integer builds" begin
  function withcte(col)
    q = CCD.Ccd_team.objects
    body = CCD.Ccd_driver.objects
    body.values("team", "drv" => "payload__driver", "doc" => "payload")
    q.with("c" => body, join_field = "id" => "team")
    q.values("x" => Fn.Concat(Fn.Value("|"), PormG.CTE("c", col)))
    return q
  end
  @test _ccd_builds(nothing; run = conn -> _ccd_sql(withcte("drv"); conn = conn))
  _ccd_refused_everywhere(nothing; issue = "#1028", named = "JSONField", run = conn -> _ccd_sql(withcte("doc"); conn = conn))
  @test _ccd_builds(Fn.Case(Fn.When("active" => true, then = Fn.Value(1)), default = 0; output_field = "text"))
end

# ─────────────────────────────────────────────────────────────────────────────
# #1151: a Case is typed by its branch values: a float branch, cast to an integer, is refused on SQLite
# An untyped `Case` passed the #1028 check, but its branches are typed: PostgreSQL resolves the `CASE`
# to the widest of them (`$2::double precision` beside `$3::bigint` is a `float8`), so its cast to an
# integer rounds `1.5` to `2`, while SQLite's truncates it to `1`. The type walk names that kind
# (`_case_kind`); since #1187 the classifier reads the branches itself (`_case_textless_branch`) and
# names the branch — a `Coalesce` over such a `Case` too. Expected SQL, PostgreSQL:
#   (CASE WHEN "Tb"."number" = $1 THEN $2::double precision ELSE $3::bigint END)::integer
# Built on both: integer branches, text branches, a NULL default, and the cast to text
# (representation). A `Case` with an `output_field = IntegerField()` over the same `1.5` branch is that
# cast already, so it is refused on SQLite by itself (#1217), before the outer cast is read.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1151: a Case with a float branch, cast to an integer, is refused on SQLite only" begin
  float_case(; then = 1.5, default = 0) = Fn.Case(Fn.When("number" => 1, then = then), default = default)
  for (expr, named) in (
      (Fn.Cast(float_case(), Models.IntegerField()), "`CASE(…)` over a Float64 literal"),
      (Fn.Cast(float_case(then = 1, default = 0.5), Models.IntegerField()), "`CASE(…)` over a Float64 literal"),
      (Fn.Cast(float_case(then = _CF("points")), Models.IntegerField()), "`CASE(…)` over the FloatField `points`"),
      (Fn.Cast(float_case(), "bigint"), "`CASE(…)` over a Float64 literal"),
      (Fn.Cast(Fn.Coalesce(float_case(), 0), Models.IntegerField()), "`COALESCE(…)` over `CASE(…)` over a Float64 literal"))
    _ccd_expect(expr; departs = _SL_ONLY, issue = "#1028", named = named)
  end
  @test occursin("(CASE WHEN \"Tb\".\"number\" = \$1 THEN \$2::double precision ELSE \$3::bigint END)::integer as \"x\"",
                 _ccd_render(Fn.Cast(float_case(), Models.IntegerField()); conn = _CCD_PG))
  for expr in (Fn.Cast(float_case(then = 1), Models.IntegerField()),
               Fn.Cast(float_case(then = "a", default = "b"), Models.IntegerField()),
               Fn.Cast(float_case(then = 2, default = nothing), Models.IntegerField()),
               Fn.Cast(float_case(), "text"))
    @test _ccd_builds(expr)
  end
  _ccd_expect(Fn.Cast(Fn.Case(Fn.When("number" => 1, then = 1.5), default = 0; output_field = Models.IntegerField()), Models.IntegerField());
              departs = _SL_ONLY, issue = "#1028", named = "Case(…; output_field = ")
end

# ─────────────────────────────────────────────────────────────────────────────
# #1187: the scale and decimal rules read a Case branch by branch too
# A `Case` with no `output_field` is one of its branch values on each row, so it has more than `s`
# places when one branch has. A `FloatField` branch cast to `numeric(10,0)` is rounded by PostgreSQL
# (`1.5` → `2`) and kept by SQLite (`1.5`): refused on SQLite (#1040). A `1.5` literal branch at
# `numeric(10,2)` has nothing to round (#1050) and builds on both. A `DecimalField` branch keeps its
# own places, which the type walk drops: two places cast to an integer is refused on SQLite (#1028),
# a zero-scale column (`grid`, `DecimalField(4, 0)`) is whole and builds. Expected SQL:
#   PostgreSQL  (CASE WHEN "Tb"."number" = $1 THEN $2::double precision ELSE $3::bigint END)::numeric(10,2)
#   SQLite      CAST(CASE WHEN "Tb"."number" = ? THEN ? ELSE ? END AS NUMERIC(10,2))
# Why: both rules let any untyped `Case` through, so the same value read two ways on the two engines.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1187: a Case's branches decide the scale and decimal rules" begin
  case(then; default = 0) = Fn.Case(Fn.When("number" => 1, then = then), default = default)
  for (expr, issue, named) in (
      (Fn.Cast(case(_CF("points")), "numeric(10,0)"), "#1040", "`CASE(…)` over the FloatField `points`"),
      (Fn.Cast(case(1.555), "numeric(10,2)"), "#1040", "`CASE(…)` over a Float64 literal with 3 decimal places"),
      (Fn.Cast(case(1; default = _CF("price")), "numeric(10,1)"), "#1040", "`CASE(…)` over the DecimalField `price` (2 decimal places)"),
      (Fn.Cast(case(_CF("price")), Models.IntegerField()), "#1028", "`CASE(…)` over the DecimalField `price`"),
      (Fn.Cast(case(Decimal(0, 15, -1)), "integer"), "#1028", "`CASE(…)` over a Decimal literal"))
    _ccd_expect(expr; departs = _SL_ONLY, issue = issue, named = named)
  end
  @test occursin("(CASE WHEN \"Tb\".\"number\" = \$1 THEN \$2::double precision ELSE \$3::bigint END)::numeric(10,2) as \"x\"",
                 _ccd_render(Fn.Cast(case(1.5), "numeric(10,2)"); conn = _CCD_PG))
  @test occursin("CAST(CASE WHEN \"Tb\".\"number\" = ? THEN ? ELSE ? END AS NUMERIC(10,2)) as \"x\"",
                 _ccd_render(Fn.Cast(case(1.5), "numeric(10,2)"); conn = _CCD_SL))
  for expr in (Fn.Cast(case(1.5), "numeric(10,2)"),                      # #1050: no place to round
               Fn.Cast(case(_CF("price")), "numeric(10,2)"),             # two places at scale 2
               Fn.Cast(case(_CF("grid")), Models.IntegerField()),        # a zero-scale decimal is whole
               Fn.Cast(case(_CF("grid")), "numeric(10,0)"),
               Fn.Cast(case(1; default = nothing), "numeric(10,0)"))     # an integer and a NULL
    @test _ccd_builds(expr)
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
# Greatest/Least to text over timestamps or intervals build on both engines; a bare F key lookup in a CTE body
# On SQLite `Greatest`/`Least` render NULL-skipping `COALESCE` rotations. Their `output_field` to
# text over timestamp or interval arithmetic, or over a `DurationField` column, is REPRESENTATION
# (#1147 step 2): each engine writes the value's own text, so all of them build on both. (Before
# #1147 this testset asserted only that the two engines answered alike.) A body column spelled
# `F("payload__driver")` is the key's value, as the bare path is.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028, #1147: Greatest/Least to text over timestamps or intervals build on both engines; F key lookup in a CTE" begin
  for expr in (Fn.Greatest(_CF("start_at") + Day(1), _CF("start_at") + Day(2); output_field = "text"),
               Fn.Least(_CF("start_at") + Day(1), _CF("start_at") - Day(1); output_field = "varchar(40)"),
               Fn.Greatest(_CF("laptime") + _CF("laptime"), _CF("laptime") * 2; output_field = "text"),
               Fn.Greatest(_CF("laptime") + _CF("laptime"), _CF("number") + 1; output_field = "text"),
               Fn.Greatest(_CF("start_at") - _CF("start_at"), _CF("number") * 2; output_field = "text"),
               Fn.Greatest("laptime", _CF("laptime") * 2; output_field = "text"))   # a typed DurationField column too
    @test _ccd_builds(expr)
  end
  function keyed()
    outer = CCD.Ccd_team.objects
    body = CCD.Ccd_driver.objects
    body.values("team", "drv" => _CF("payload__driver"))
    outer.with("c" => body, join_field = "id" => "team")
    outer.values("x" => Fn.Concat(Fn.Value("|"), PormG.CTE("c", "drv")))
    return outer
  end
  @test _ccd_builds(nothing; run = conn -> _ccd_sql(keyed(); conn = conn))
end

# ─────────────────────────────────────────────────────────────────────────────
# #1040: a cast to numeric(p, s) over an operand with more than s fractional digits is refused on SQLite only
# MEANING: a cast to `numeric(p, s)` means the value rounded to `s` places, which PostgreSQL computes
# (half away from zero). SQLite reads the type name as NUMERIC affinity and keeps every digit, so it
# departs and is refused; PostgreSQL builds. Measured on PostgreSQL 16.15 / SQLite 3.45.1: `1.5` at
# `numeric(10,0)` is `2` / `1.5`, `1.555` at `numeric(10,2)` is `1.56` / `1.555`, and the text
# `'1.555'` the same. Rounding to the scale first is the escape (#1061): only a decimal tie can still
# differ, in its last digit. A whole number (`Round(x)`, `Floor`, `Ceil`) and an unscaled `numeric`
# keep the value on both engines.
# ─────────────────────────────────────────────────────────────────────────────
_is_1040(e) = e isa QueryBuildError && occursin("(#1040)", _ccd_msg(e))

@testset "#1040: Cast to a scaled numeric over an operand it would round is refused on SQLite only (meaning)" begin
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
  for (operand, named) in refused, target in ("numeric(10,2)", "decimal(8, 1)", "numeric(10,0)", "numeric(10)", "dec(10,2)")
    errs = _ccd_expect(Fn.Cast(operand, target); departs = _SL_ONLY, issue = "#1040", named = named)
    # The message names the escapes: round to the scale first, or an unscaled numeric.
    msg = _ccd_msg(errs.sqlite)
    @test occursin("Round it to the scale first", msg) && occursin("unscaled", msg)
  end
  @test occursin("(\"Tb\".\"points\")::numeric(10,2) as \"x\"", _ccd_render(Fn.Cast("points", "numeric(10,2)"); conn = _CCD_PG))
  # A DecimalField is bounded by its own places: `price` has two.
  for (target, refuses) in ("numeric(10,0)" => true, "numeric(10,1)" => true, "numeric(10,2)" => false,
                            "numeric(12,4)" => false),
      operand in ("price", _CF("price"), Fn.Max("price"), Fn.Coalesce("price", 0), Fn.Abs("price"))
    if refuses
      _ccd_expect(Fn.Cast(operand, target); departs = _SL_ONLY, issue = "#1040", named = "DecimalField `price` (2 decimal places)")
    else
      @test _ccd_builds(Fn.Cast(operand, target))
    end
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

# ─────────────────────────────────────────────────────────────────────────────
# #1040: an output_field numeric scale follows the same rule
# Refused on SQLite only, the message naming the function as written; PostgreSQL builds. What has no
# place to round builds on both.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1040: an output_field numeric scale follows the same rule" begin
  for (expr, fname) in ((Fn.Coalesce("points", 0; output_field = "numeric(10,2)"), "Coalesce(…; output_field = \"numeric(10,2)\")"),
                        (Fn.Greatest("number", "price"; output_field = "numeric(10,1)"), "Greatest(…; output_field = \"numeric(10,1)\")"),
                        (Fn.Least("surname", "surname"; output_field = "numeric(10)"), "Least(…; output_field = \"numeric(10)\")"))
    _ccd_expect(expr; departs = _SL_ONLY, issue = "#1040", named = fname)
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
# #1217: a Case's output_field is checked against each branch value, as Cast checks its operand
# A `Case(…; output_field = T)` renders `(CASE … END)::T` on PostgreSQL and `CAST(CASE … END AS T)` on
# SQLite, the same declared cast as `Cast` and `Coalesce`'s `output_field`, taken on whichever branch
# the row matches. So each `then` and the default is an operand: `numeric(10,1)` over a float or a
# two-place decimal branch is rounded by PostgreSQL and kept by SQLite (#1040), `integer` over `1.5` is
# `2` on PostgreSQL and `1` on SQLite (#1028), `text` over a boolean is `true` / `1` (#1028): refused
# on SQLite only. A branch with nothing to round builds on both, and so does a `Cast` over a declared
# `Case` whose scale the cast's covers (the `Case` is checked itself). Expected SQL, PostgreSQL:
#   (CASE WHEN "Tb"."number" = $1 THEN "Tb"."points" ELSE $2::numeric(10,1) END)::numeric(10,1)
# Why: before #1217 every one of these built, a silent different value on SQLite.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1217: a Case output_field is checked against its branches, refused on SQLite only" begin
  case(then; default = 0, output_field) = Fn.Case(Fn.When("number" => 1, then = then), default = default, output_field = output_field)
  for (expr, issue, named) in (
      (case(_CF("points"); output_field = "numeric(10,1)"), "#1040", "the FloatField `points`"),
      (case(_CF("points") * 1.5; output_field = "numeric(10,1)"), "#1040", "arithmetic over the FloatField `points`"),
      (case(_CF("price"); output_field = "numeric(10,1)"), "#1040", "the DecimalField `price` (2 decimal places)"),
      (case(1; default = _CF("points"), output_field = "numeric(10,0)"), "#1040", "the FloatField `points`"),   # the default too
      (case(1; default = _CF("team__rating"), output_field = "numeric(10,0)"), "#1040", "the FloatField `team__rating`"),   # a joined default (rendered in Phase 3)
      (case(1.5; output_field = "integer"), "#1028", "a Float64 literal"),
      (case(1.5; output_field = Models.IntegerField()), "#1028", "a Float64 literal"),
      (case(_CF("price"); output_field = "bigint"), "#1028", "the DecimalField `price`"),
      (Fn.Case(Fn.When("number" => 1, then = _CF("active")); output_field = "text"), "#1028", "the BooleanField `active`"),
      (Fn.Coalesce(case(_CF("points"); output_field = "numeric(10,1)"), 0), "#1040", "the FloatField `points`"))
    errs = _ccd_expect(expr; departs = _SL_ONLY, issue = issue, named = named)
    @test occursin("Case(…; output_field = ", _ccd_msg(errs.sqlite))
  end
  @test occursin("(CASE WHEN \"Tb\".\"number\" = \$1 THEN \"Tb\".\"points\" ELSE \$2::numeric(10,1) END)::numeric(10,1) as \"x\"",
                 _ccd_render(case(_CF("points"); output_field = "numeric(10,1)"); conn = _CCD_PG))
  for expr in (case(Fn.Round("points", 1); output_field = "numeric(10,1)"),
               case(_CF("number"); output_field = "numeric(10,1)"),
               case(_CF("price"); output_field = "numeric(10,2)"),
               case(1.5; output_field = "numeric(10,1)"),          # #1050: one place fits one
               case(_CF("grid"); output_field = "integer"),        # a zero-scale decimal is whole
               case(Fn.Floor("points"); output_field = Models.IntegerField()),
               case(_CF("points"); output_field = "numeric"),      # unscaled keeps the value
               case(Fn.Value(1); output_field = "text"),            # an integer's text is representation
               Fn.Cast(case(Fn.Round("points", 1); output_field = "numeric(10,1)"), "numeric(10,2)"))
    @test _ccd_builds(expr)
  end
  # The nested declaration is read for its scale: one place under a cast to none still rounds.
  _ccd_expect(Fn.Cast(case(Fn.Round("points", 1); output_field = "numeric(10,1)"), "numeric(10,0)");
              departs = _SL_ONLY, issue = "#1040", named = "a value cast to numeric(10,1)")
end

# ─────────────────────────────────────────────────────────────────────────────
# #1050: a float literal that fits the scale passes, as a Decimal literal does
# What SQLite departs on is a literal with more fractional digits than `s`, refused there only.
# Measured on PostgreSQL 16.15 / SQLite 3.45.1: `1.5`, `0.1`, `2.25` read the same at scale 2; `2.675`
# at scale 2 is `2.68` / `2.675`. `12345678901234.56` becomes `12345678901234.6` on PostgreSQL before any
# scale applies, a 16th-digit difference where PostgreSQL is the less exact side: representation,
# documented, not refused (#1087).
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
      shape in shapes
    _ccd_expect(shape(v); departs = _SL_ONLY, issue = "#1040", named = named)
  end
  # #1087: more than 15 significant digits is not refused — PostgreSQL's 16th digit is the less exact
  # one — and the place bound moves with the scale.
  for v in (12345678901234.56, 12345678901234567.0), conn in _CCD_ENGINES
    @test _ccd_refusal(Fn.Cast(Fn.Value(v), "numeric(30,8)"); conn = conn) === nothing
    @test _ccd_refusal(Fn.Coalesce(Fn.Value(v), 0; output_field = "numeric(30,2)"); conn = conn) === nothing
  end
  @test _ccd_builds(Fn.Cast(Fn.Value(2.675), "numeric(10,3)"))
  _ccd_expect(Fn.Cast(Fn.Value(0.1), "numeric(10,0)"); departs = _SL_ONLY, issue = "#1040")
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
# Cast over a Subquery: the operand is classified by the one expression the subquery projects (#1124)
# The three declared-cast rules read the same classifier `Concat` does, and a `Subquery` had no arm
# in it, so a cast over a float subquery passed every rule that refuses the float itself. The inner
# build now records its projection's classification under the node, so each rule answers for a
# subquery what it answers for the expression alone: a fraction to an integer or a scaled numeric is
# refused on SQLite only (meaning), and a float to text builds on both (representation, #1147). A
# subquery whose projection has one text, or that is rounded to an integer inside, builds as before.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1124: a declared cast over a Subquery is classified by its projection" begin
  team(expr) = (s = CCD.Ccd_team.objects; s.filter("id" => PormG.OuterRef("team")); s.values("t" => expr); PormG.Subquery(s))
  for (expr, issue, named) in ((Fn.Cast(team("rating"), Models.IntegerField()), "#1028", "the FloatField `rating`"),
                               (Fn.Cast(team(Fn.Avg("rating")), "integer"), "#1028", "`AVG(…)`"),
                               (Fn.Cast(team("rating"), "numeric(10,2)"), "#1040", "the FloatField `rating`"),
                               (Fn.Coalesce(team("rating"), 0; output_field = "integer"), "#1028", "the FloatField `rating`"))
    _ccd_expect(expr; departs = _SL_ONLY, issue = issue, named = "a Subquery projecting " * named)
  end
  for expr in (Fn.Cast(team("rating"), Models.CharField()),                  # representation (#1147)
               Fn.Cast(team("name"), Models.CharField()), Fn.Cast(team(Fn.Count("id")), Models.CharField()),
               Fn.Cast(team(Fn.Cast(Fn.Round("rating"), Models.IntegerField())), Models.CharField()),
               Fn.Cast(team("rating"), Models.FloatField()), Fn.Cast(team("rating"), "numeric"))
    @test _ccd_builds(expr)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1087: a Cast literal too large for numeric(p, s) is refused on SQLite only
# MEANING: rounded to `s` places, a value needs at most `p − s` digits before the point, and a cast of
# one that needs more means a numeric field overflow, which PostgreSQL raises. SQLite stores the
# value as it is — a silent different answer. By the tie-breaker (an error on one engine is left to
# raise when the engines that answer give the meaning), PostgreSQL builds and raises when it runs,
# and SQLite is refused. A literal is certain to overflow; a column or computed value overflows only
# on some rows, so it is not refused. Expected SQL on PostgreSQL: `($1::bigint)::numeric(3,2)`.
# ─────────────────────────────────────────────────────────────────────────────
_is_1087(e) = e isa QueryBuildError && occursin("(#1087)", _ccd_msg(e))

@testset "#1087: Cast of a literal too large for the precision is refused on SQLite only (meaning)" begin
  refused = (
    (100, "numeric(3,2)", "an Int64 literal with 3 digits before the point"),
    (-100, "numeric(3,2)", "an Int64 literal with 3 digits before the point"),
    # 9.999 has places to round too; the overflow is checked first, after rounding to 10.00.
    (9.999, "numeric(3,2)", "a Float64 literal with 2 digits before the point"),
    (0.995, "decimal(2,2)", "a Float64 literal with 1 digit before the point"),
    # A scale above the precision leaves no digit before the point.
    (0.5, "numeric(2,3)", "a Float64 literal with 0 digits before the point"),
    # A Float32 binds as double precision on PostgreSQL: read as the Float64 it widens to.
    (100f0, "numeric(3,2)", "a Float32 literal with 3 digits before the point"),
    (Float16(100), "numeric(3,2)", "a Float16 literal with 3 digits before the point"),
    (UInt8(100), "numeric(3,2)", "a UInt8 literal with 3 digits before the point"),
    (99.5, "numeric(2)", "a Float64 literal with 3 digits before the point"),
    (12345678901234.56, "numeric(10,2)", "a Float64 literal with 14 digits before the point"),
    (Decimal(0, 12345, 0), "dec(4,0)", "a Decimal literal with 5 digits before the point"),
    (Decimal(1, 99995, -3), "numeric(4,2)", "a Decimal literal with 3 digits before the point"),
  )
  for (v, target, named) in refused
    errs = _ccd_expect(Fn.Cast(Fn.Value(v), target); departs = _SL_ONLY, issue = "#1087", named = "of $(named)")
    msg = _ccd_msg(errs.sqlite)
    @test occursin("means a numeric field overflow, since $(target) cannot hold it", msg)
    @test occursin("SQLite computes the value as it is", msg)
    @test occursin("Declare a precision that holds it", msg)
  end
  @test occursin("(\$1::bigint)::numeric(3,2) as \"x\"", _ccd_render(Fn.Cast(Fn.Value(100), "numeric(3,2)"); conn = _CCD_PG))
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
  # The value is never printed (#971), on the engine that refuses it.
  msg = _ccd_msg(_ccd_refusal(Fn.Cast(Fn.Value(10871087), "numeric(3,2)"); conn = _CCD_SL))
  @test _is_1087(_ccd_refusal(Fn.Cast(Fn.Value(10871087), "numeric(3,2)"); conn = _CCD_SL))
  @test !occursin("10871087", msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# #1087, #1150: a zero-scale DecimalField reads like an integer column; divided, it is a decimal quotient
# Both engines write a whole-number decimal `14`, so `Concat` and a cast to text or an integer pass.
# Divided, it means a decimal quotient (`15 / 2` is `7.5`, PostgreSQL's `numeric / int`). SQLite stores
# the whole values as INTEGER and divided them as integers (`7`), which #1087 refused there. Since #1150
# SQLite casts the dividend to REAL instead and computes the quotient the expression means. Expected
# SQL: `(CAST("Tb"."grid" AS REAL) / ?)` on SQLite, `("Tb"."grid" / $1::bigint)` on PostgreSQL. The
# quotient is then a fraction like any other: to text it is representation and builds everywhere; to
# an integer SQLite truncates what means the nearest one (#1028), and to a scale it keeps every digit
# (#1040), refused on SQLite only; under `Concat` it is explicit intent, refused everywhere (#1027).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1087, #1150: a zero-scale DecimalField reads like an integer column; divided, it is a decimal quotient on both engines" begin
  for expr in (Fn.Concat("surname", "grid"), Fn.Cast("grid", Models.CharField()), Fn.Cast("grid", Models.IntegerField()),
               Fn.Cast(Fn.Max("grid"), Models.CharField()), Fn.Cast("grid", "numeric(10,0)")),
      conn in _CCD_ENGINES
    @test _ccd_refusal(expr; conn = conn) === nothing
  end
  # A DecimalField with places: to text it is representation and builds on both (#1147); to an
  # integer, the nearest-integer meaning SQLite truncates (#1028).
  @test _ccd_builds(Fn.Cast("price", Models.CharField()))
  _ccd_expect(Fn.Cast("price", Models.IntegerField()); departs = _SL_ONLY, issue = "#1028", named = "the DecimalField `price`")
  # The quotient, on each engine.
  @test occursin("(CAST(\"Tb\".\"grid\" AS REAL) / ?) as \"x\"", _ccd_render(_CF("grid") / 2; conn = _CCD_SL))
  @test occursin("(\"Tb\".\"grid\" / \$1::bigint) as \"x\"", _ccd_render(_CF("grid") / 2; conn = _CCD_PG))
  # To text: built everywhere.
  for expr in (Fn.Cast(_CF("grid") / _CF("number"), Models.CharField()), Fn.Cast(Fn.Greatest("grid", 1) / 2, Models.CharField()))
    @test _ccd_builds(expr)
  end
  # To an integer: a fraction, refused on SQLite (#1028).
  for expr in (Fn.Cast(_CF("grid") / 2, Models.IntegerField()),
               Fn.Cast((_CF("grid") + 1) / 2, Models.IntegerField()),
               Fn.Cast(Fn.Sum("grid") / Fn.Count("id"), Models.IntegerField()),
               # `Coalesce` always carries an `output_field` key, `nothing` when none was given.
               Fn.Cast(Fn.Coalesce("grid", 0) / 2, Models.IntegerField()))
    _ccd_expect(expr; departs = _SL_ONLY, issue = "#1028", named = "a decimal quotient")
  end
  @test occursin("((\"Tb\".\"grid\" / \$1::bigint))::integer as \"x\"",
                 _ccd_render(Fn.Cast(_CF("grid") / 2, Models.IntegerField()); conn = _CCD_PG))
  # To a scale: every digit, on SQLite (#1040).
  _ccd_expect(Fn.Cast(_CF("grid") / 2, "numeric(10,1)"); departs = _SL_ONLY, issue = "#1040", named = "a decimal quotient")
  _ccd_refused_everywhere(Fn.Concat("surname", _CF("grid") / 2); issue = "#1027", named = "a decimal quotient")
  # `+`, `-`, `*` keep a whole number whole on both engines, and an integer column divides alike.
  for expr in (Fn.Cast(_CF("grid") * 2, Models.IntegerField()), Fn.Cast(_CF("grid") + 1, Models.CharField()),
               Fn.Cast(_CF("number") / 2, Models.IntegerField()))
    @test _ccd_builds(expr)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Floor/Ceil/Abs and Sum divided: what the walk types builds; an untyped whole number is refused on PostgreSQL (#1111, #1147)
# `FLOOR`/`CEIL`/`ABS` render `(x)::numeric` on PostgreSQL over an operand the type walk does not name
# as an integer, and PostgreSQL's `sum(bigint)` is `numeric`, so `/ 2` kept the half there where
# SQLite divided as integers. Measured on the F1 fixture (`Result.grid` 1, 5, 7): `Floor(grid) / 2`
# read `0.5`, `2.5`, `3.5` on PostgreSQL 16 and `0`, `2`, `3` on SQLite 3.45 before #1147, and #1111
# refused the division on both engines.
#
# #1147 moved most of those to BUILT: `+`, `-`, `*`, `/` over two integers is an integer to the walk
# (`F("number") + 1` is an `int8`), so `Floor`/`Ceil`/`Abs` over it cast back to the integer
# (`FLOOR((x)::numeric)::bigint`), and a `Sum` the walk names a `bigint` renders `SUM(x)::bigint`.
# Both engines then divide an integer. Expected SQL, PostgreSQL:
#   ((FLOOR((("Tb"."number" + $1::bigint))::numeric)::bigint / $2::bigint))::integer
#   ((SUM("Tb"."laps_total")::bigint / $1::bigint))::integer
#
# A `Lag` whose `default` is a float is a `float8` on PostgreSQL (`lag(int4, int, float8)`), so its
# quotient keeps the fraction; SQLite held the integer on every other row and divided those as
# integers, refused there under #1147. Since #1150 SQLite casts the dividend to REAL, so the quotient
# is the fraction it means on both engines: to text it builds, to an integer or a scale it is refused
# on SQLite as any fraction is (#1028, #1040). So is a zero-scale decimal divided, alone or under `Floor`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1111, #1147: Floor/Ceil/Abs and Sum, divided — typed integers build on both engines, an untyped whole number is refused on PostgreSQL" begin
  team(expr) = (s = CCD.Ccd_team.objects; s.filter("id" => PormG.OuterRef("team")); s.values("t" => expr); PormG.Subquery(s))
  lag(default) = PormG.QueryBuilder.Lag("number"; default = default, over = PormG.QueryBuilder.WindowOver(order_by = ["id"]))
  # Refused under #1111 on both engines; the walk now types them, and both engines divide an integer.
  for expr in (
      Fn.Cast(Fn.Floor(_CF("number") + 1) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Ceil(_CF("number") + 1) / 2, Models.CharField()),
      Fn.Cast(Fn.Abs(_CF("number") * 2) / 2, "numeric(10,1)"),
      Fn.Cast(Fn.Max(Fn.Abs(_CF("number") + 1)) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Sum("id") / Fn.Count("id"), Models.IntegerField()),
      Fn.Cast(Fn.Sum("laps_total") / 2, Models.CharField()),
      Fn.Cast(Fn.Sum("team") / 2, Models.IntegerField()),
      Fn.Cast(Fn.Sum(_CF("id") + 1) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Sum(Fn.Floor("id")) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Floor(Fn.Sum("id")) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Abs(Fn.Sum("laps_total")) / 2, Models.IntegerField()),
      # Rounding an integer quotient: there is no half on either engine.
      Fn.Cast(Fn.Round(Fn.Floor(_CF("number") + 1) / 2), Models.IntegerField()),
      Fn.Cast(Fn.Ceil(Fn.Floor(_CF("number") + 1) / 2), Models.IntegerField()),
      Fn.Cast(Fn.Floor(Fn.Sum("id") / 2), Models.CharField()),
      Fn.Cast(Fn.Round(Fn.Floor(_CF("number") + 1) / 2, 1), "numeric(10,1)"),
      Fn.Cast(Fn.Round(Fn.Floor(_CF("number") + 1) / 2), "numeric(10,0)"),
      # A Subquery projecting one of these answers the same once divided (#1124's record).
      Fn.Cast(Fn.Coalesce(team(Fn.Floor(_CF("id") + 1)), 0) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Coalesce(team(Fn.Sum("id")), 0) / 2, Models.IntegerField()),
      Fn.Concat("surname", Fn.Floor(_CF("number") + 1) / 2))
    @test _ccd_builds(expr)
  end
  @test occursin("((FLOOR(((\"Tb\".\"number\" + \$1::bigint))::numeric)::bigint / \$2::bigint))::integer as \"x\"",
                 _ccd_render(Fn.Cast(Fn.Floor(_CF("number") + 1) / 2, Models.IntegerField()); conn = _CCD_PG))
  @test occursin("CAST((FLOOR((\"Tb\".\"number\" + ?)) / ?) AS INTEGER) as \"x\"",
                 _ccd_render(Fn.Cast(Fn.Floor(_CF("number") + 1) / 2, Models.IntegerField()); conn = _CCD_SL))
  @test occursin("((SUM(\"Tb\".\"laps_total\")::bigint / \$1::bigint))::integer as \"x\"",
                 _ccd_render(Fn.Cast(Fn.Sum("laps_total") / 2, Models.IntegerField()); conn = _CCD_PG))
  # #1150: a `Lag` with a float `default` is a float, whose quotient SQLite now divides as REAL
  # (`CAST(FLOOR(LAG(…)) AS REAL) / ?`). To text it is representation; to an integer or a scale a
  # fraction, refused on SQLite; under `Concat` a number, refused on every engine.
  for expr in (Fn.Cast(Fn.Abs(lag(_CF("points"))) / 2, Models.CharField()), Fn.Cast(Fn.Floor(lag(3.5)) / 2, Models.CharField()))
    @test _ccd_builds(expr)
  end
  @test occursin(r"\(CAST\(FLOOR\(LAG\(\"Tb\"\.\"number\", \?, \?\) OVER \([^)]*\)\) AS REAL\) / \?\)",
                 _ccd_render(Fn.Floor(lag(3.5)) / 2; conn = _CCD_SL))
  for (expr, issue, named) in (
      (Fn.Cast(Fn.Abs(lag(_CF("points"))) / 2, Models.IntegerField()), "#1028", "arithmetic over `ABS(…)` over `LAG(…)`"),
      (Fn.Cast(Fn.Floor(lag(3.5)) / 2, "numeric(10,1)"), "#1040", "arithmetic over `FLOOR(…)` over `LAG(…)`"),
      (Fn.Cast(lag(3.5) / 2, Models.IntegerField()), "#1028", "arithmetic over `LAG(…)`"))
    _ccd_expect(expr; departs = _SL_ONLY, issue = issue, named = named)
  end
  _ccd_refused_everywhere(Fn.Concat(Fn.Value("-"), Fn.Floor(lag(3.5)) / 2); issue = "#1027",
                          named = "arithmetic over `FLOOR(…)` over `LAG(…)`")
  # Undivided, a float default makes the window a float: its cast to an integer is the #1028 row.
  _ccd_expect(Fn.Cast(lag(3.5), Models.IntegerField()); departs = _SL_ONLY, issue = "#1028")
  # A whole-number default keeps the window an integer: it divides as one on both engines.
  @test _ccd_builds(Fn.Cast(Fn.Floor(lag(0)) / 2, Models.IntegerField()))
  @test _ccd_builds(Fn.Cast(lag(0) / 2, Models.IntegerField()))
  # A zero-scale DecimalField under `Floor` is a decimal, so its quotient is one (#1150): to an
  # integer, the #1028 fraction. Rounded to no places it is whole on both engines (`ROUND(7.5)` is `8`
  # on each), so that cast builds.
  _ccd_expect(Fn.Cast(Fn.Floor("grid") / 2, Models.IntegerField()); departs = _SL_ONLY, issue = "#1028",
              named = "a decimal quotient")
  @test _ccd_builds(Fn.Cast(Fn.Round(_CF("grid") / 2), Models.IntegerField()))
  # Over an operand PormG cannot type, `Floor` is not refused: a float under it is a REAL on SQLite
  # too, and the engines agree. Only a type that is known is answered (review of #1111).
  for expr in (Fn.Cast(Fn.Floor(Fn.Case(Fn.When("active" => true, then = "points"), default = "points")) / 2, Models.IntegerField()),
               Fn.Cast(Fn.Floor("payload__points") / 2, Models.IntegerField()))
    @test _ccd_builds(expr)
  end
  # Unchanged: `+`, `-`, `*`, a bare cast, the documented escape, and the aggregates both engines
  # keep integer.
  for expr in (Fn.Cast(Fn.Floor(_CF("number") + 1) * 2, Models.IntegerField()), Fn.Cast(Fn.Floor(_CF("number") + 1) + 1, Models.CharField()),
               Fn.Cast(Fn.Floor(_CF("number") + 1), Models.IntegerField()), Fn.Cast(Fn.Abs(_CF("number") + 1), Models.CharField()),
               Fn.Cast(Fn.Round(Fn.Floor(_CF("number") + 1) / 2.0), Models.IntegerField()),
               Fn.Cast(Fn.Max("number") / 2, Models.IntegerField()), Fn.Cast(Fn.Sum("number") / 2, Models.IntegerField()),
               Fn.Cast(Fn.Count("id") / 2, Models.IntegerField()), Fn.Cast(_CF("number") / 2, Models.IntegerField()),
               Fn.Cast(Fn.Max("laps_total") / 2, Models.IntegerField()), Fn.Concat("surname", Fn.Floor(_CF("number") + 1)),
               Fn.Cast(team(Fn.Floor(_CF("id") + 1)), Models.IntegerField()))
    @test _ccd_builds(expr)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Floor/Ceil/Abs over an integer keep it on both engines, so divided it builds (#1147)
# PostgreSQL has `abs(int2|int4|int8)`, and no `floor`/`ceil` over an integer, so those two round
# through `numeric` and cast back to the operand's own type: exact for a `bigint`, which `double`
# would not be. SQLite keeps an integer operand's type already. Expected SQL, PostgreSQL:
#   ((FLOOR(("Tb"."number")::numeric)::integer / $1::bigint))::integer
# — integer division on both engines, where it was `numeric` division on PostgreSQL (`7.5`). These
# rows were refused under #1111; the operand still decides, so the residual above stays refused.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1147: Floor/Ceil/Abs over an integer, divided, build on both engines" begin
  team(expr) = (s = CCD.Ccd_team.objects; s.filter("id" => PormG.OuterRef("team")); s.values("t" => expr); PormG.Subquery(s))
  built = (
    Fn.Cast(Fn.Floor("number") / 2, Models.IntegerField()),
    Fn.Cast(Fn.Ceil("number") / 2, Models.CharField()),
    Fn.Cast(Fn.Abs("number") / 2, "numeric(10,1)"),
    Fn.Cast((Fn.Floor("number") + 1) / 2, Models.IntegerField()),
    Fn.Cast(Fn.Max(Fn.Abs("number")) / 2, Models.IntegerField()),
    # Over a whole number by type: a count, a cast to an integer, a literal, a bigint key.
    Fn.Cast(Fn.Floor(Fn.Count("id")) / 2, Models.IntegerField()),
    Fn.Cast(Fn.Abs(Fn.Cast(Fn.Round("points"), Models.IntegerField())) / 2, Models.IntegerField()),
    Fn.Cast(Fn.Floor(Fn.Value(7)) / 2, Models.IntegerField()),
    Fn.Cast(Fn.Ceil("id") / 2, Models.IntegerField()),
    # Rounding an integer quotient: there is no half on either engine.
    Fn.Cast(Fn.Round(Fn.Floor("number") / 2), Models.IntegerField()),
    Fn.Cast(Fn.Ceil(Fn.Floor("number") / 2), Models.IntegerField()),
    Fn.Cast(Fn.Round(Fn.Floor("number") / 2, 1), "numeric(10,1)"),
    # `sum(int4)` is a `bigint`, which divides as an integer on both engines.
    Fn.Cast(Fn.Sum(Fn.Floor("number")) / 2, Models.IntegerField()),
    Fn.Cast(Fn.Coalesce(team(Fn.Floor("id")), 0) / 2, Models.IntegerField()),
    Fn.Concat("surname", Fn.Floor("number") / 2),
    # A `Lag` whose `default` is an integer too is one (`lag(int4, int, int8)` is an `int8`), and a
    # NULL default is never the value (`lag(int4, int, NULL)` is an `int4`).
    Fn.Cast(Fn.Floor(PormG.QueryBuilder.Lag("number"; default = 0, over = PormG.QueryBuilder.WindowOver(order_by = ["id"]))) / 2,
            Models.IntegerField()),
    Fn.Cast(Fn.Floor(PormG.QueryBuilder.Lag("number"; default = missing, over = PormG.QueryBuilder.WindowOver(order_by = ["id"]))) / 2,
            Models.IntegerField()))
  for expr in built, conn in _CCD_ENGINES
    @test _ccd_refusal(expr; conn = conn) === nothing
  end
  @test occursin("((FLOOR((\"Tb\".\"number\")::numeric)::integer / \$1::bigint))::integer as \"x\"",
                 _ccd_render(Fn.Cast(Fn.Floor("number") / 2, Models.IntegerField()); conn = _CCD_PG))
  @test occursin("CAST((FLOOR(\"Tb\".\"number\") / ?) AS INTEGER) as \"x\"",
                 _ccd_render(Fn.Cast(Fn.Floor("number") / 2, Models.IntegerField()); conn = _CCD_SL))
  @test occursin("(SUM(FLOOR((\"Tb\".\"number\")::numeric)::integer) / \$1::bigint)",
                 _ccd_render(Fn.Cast(Fn.Sum(Fn.Floor("number")) / 2, Models.IntegerField()); conn = _CCD_PG))
end

# ─────────────────────────────────────────────────────────────────────────────
# #1157: a whole number is one the type walk names an integer
# `_known_whole` was a hand-built classifier, and it named fewer integers than the walk: `Length`, the
# ranking windows, an integer `Case` and `Coalesce(x, NULL)` were not whole to it. It is now the walk's
# integer kind, so those divide as integers on both engines under `Floor`/`Ceil`/`Abs` (PostgreSQL casts
# the floor back, `FLOOR((LENGTH("Tb"."surname"))::numeric)::integer`, as over any integer, #1147).
# The `SUM` arm of the #1111 division check now fires only over an operand the walk cannot type: a
# sum it names another kind is that kind's sum. `Sum(F("id") + F("grid"))` over a zero-scale decimal
# was refused on PostgreSQL as an integer quotient (`sum(bigint)` read through the `id`), though both
# engines compute the decimal quotient `7.5` (#1150): it is the #1028 fraction to an integer, refused
# on SQLite, and builds to text on both.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1157: a whole number is the walk's integer; a sum it types otherwise is no integer quotient" begin
  rank() = PormG.QueryBuilder.Rank(over = PormG.QueryBuilder.WindowOver(order_by = ["number"]))
  for operand in (Fn.Length("surname"), rank(), Fn.Case(Fn.When("number" => 1, then = 1), default = 0),
                  Fn.Coalesce("number", Fn.Value(nothing))),
      f in (Fn.Floor, Fn.Ceil, Fn.Abs), target in (Models.IntegerField(), Models.CharField())
    @test _ccd_builds(Fn.Cast(f(operand) / 2, target))
  end
  @test occursin("((FLOOR((LENGTH(\"Tb\".\"surname\"))::numeric)::integer / \$1::bigint))::integer as \"x\"",
                 _ccd_render(Fn.Cast(Fn.Floor(Fn.Length("surname")) / 2, Models.IntegerField()); conn = _CCD_PG))
  @test occursin("CAST((FLOOR(LENGTH(\"Tb\".\"surname\")) / ?) AS INTEGER) as \"x\"",
                 _ccd_render(Fn.Cast(Fn.Floor(Fn.Length("surname")) / 2, Models.IntegerField()); conn = _CCD_SL))
  # The sum of a `bigint` and a decimal is a decimal: no integer quotient on PostgreSQL.
  _ccd_expect(Fn.Cast(Fn.Sum(_CF("id") + _CF("grid")) / 2, Models.IntegerField()); departs = _SL_ONLY, issue = "#1028",
              named = "a decimal quotient")
  @test _ccd_builds(Fn.Cast(Fn.Sum(_CF("id") + _CF("grid")) / 2, "text"))
  @test occursin("CAST((CAST(SUM((\"Tb\".\"id\" + \"Tb\".\"grid\")) AS REAL) / ?) AS TEXT) as \"x\"",
                 _ccd_render(Fn.Cast(Fn.Sum(_CF("id") + _CF("grid")) / 2, "text"); conn = _CCD_SL))
  # `Mod` and `Round(x)` are whole in value but no integer in type (a `numeric` on PostgreSQL, a REAL
  # on SQLite): a quotient over them keeps the half on both, so it is a fraction, not an integer one.
  @test _ccd_builds(Fn.Cast(Fn.Floor(Fn.Round("number")) / 2, "text"))
  # What still reaches the #1111 row: a `bigint` summed with an operand the walk cannot type (a JSON
  # key lookup), which PostgreSQL's `sum(bigint)` would widen. Fail-closed on PostgreSQL until #1034's
  # phase 4 decides what an unknown kind means per view.
  _ccd_expect(Fn.Cast(Fn.Sum(_CF("laps_total") + _CF("payload__n")) / 2, Models.IntegerField()); departs = _PG_ONLY,
              issue = "#1111", named = "`SUM(…)` over the BigIntegerField `laps_total`")
end

# ─────────────────────────────────────────────────────────────────────────────
# A CTE column from Sum of a BIGINT, divided, builds on both engines (#1127, #1147, #1153)
# The CTE model types a `SUM` column as an integer, whatever it sums. Under #1127 the body's answer was
# recorded and `CTE("c", "s") / 2` refused on both engines, since PostgreSQL's `sum(bigint)` is
# `numeric` and kept the half. #1147 step 2 NORMALIZES it instead: the body renders
# `SUM("Tb"."id")::bigint as "s"` on PostgreSQL (bare on SQLite), so the column is an integer on both
# engines and divides as one — under `Coalesce`, under an outer aggregate, to an integer, a text and a
# scaled target. So does an outer `Sum` over a `Count`, a `Sum` of an integer or a `Rank` column, which
# PostgreSQL types `bigint`: `SUM("R1_1"."s")::bigint`. Also `Sum(F("id") / 2)`: `bigint / integer` is
# a `bigint`. #1153: so is a body `Sum` over a shift, `F("laps_total") << 1`, which the walk names a
# `bigint` now (a shift has its left operand's type), rendered `SUM(("Tb"."laps_total" << $1::integer))::bigint`
# there; it was a bare `sum(bigint)`, refused once divided on PostgreSQL (#1111).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1127, #1147, #1153: a CTE column from Sum of a BIGINT, divided, builds on both engines" begin
  function withcte(outer)
    q = CCD.Ccd_team.objects
    body = CCD.Ccd_driver.objects
    body.values("team", "s" => Fn.Sum("id"), "laps" => Fn.Sum("laps_total"), "fl" => Fn.Sum(Fn.Floor("number")),
                "s_int" => Fn.Sum("number"), "top" => Fn.Max("id"), "cnt" => Fn.Count("id"),
                "rk" => PormG.QueryBuilder.Rank(over = PormG.QueryBuilder.WindowOver(order_by = ["number"])),
                "shift" => Fn.Sum(_CF("laps_total") << 1))
    q.with("c" => body, join_field = "id" => "team")
    q.values("x" => outer)
    return q
  end
  cte(outer) = conn -> _ccd_sql(withcte(outer); conn = conn)
  for outer in (
      Fn.Cast(Fn.Coalesce(PormG.CTE("c", "s"), 0) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Coalesce(PormG.CTE("c", "laps"), 0) / 2, Models.CharField()),
      Fn.Cast(Fn.Sum(PormG.CTE("c", "s")) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Max(PormG.CTE("c", "laps")) / 2, "numeric(10,1)"),
      Fn.Cast(Fn.Sum(PormG.CTE("c", "cnt")) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Sum(PormG.CTE("c", "s_int")) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Sum(PormG.CTE("c", "rk")) / 2, Models.IntegerField()),
      # Unchanged since #1127: the columns both engines kept integer, an extremum over one, the record
      # read outside a division, and a sum of a `sum(int4)` column.
      Fn.Cast(Fn.Coalesce(PormG.CTE("c", "s_int"), 0) / 2, Models.IntegerField()),
      Fn.Concat("name", Fn.Coalesce(PormG.CTE("c", "fl"), 0) / 2),
      Fn.Cast(Fn.Coalesce(PormG.CTE("c", "top"), 0) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Coalesce(PormG.CTE("c", "cnt"), 0) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Max(PormG.CTE("c", "cnt")) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Coalesce(PormG.CTE("c", "s"), 0) * 2, Models.IntegerField()),
      Fn.Cast(PormG.CTE("c", "s"), Models.CharField()))
    @test _ccd_builds(nothing; run = cte(outer))
  end
  pg = _ccd_sql(withcte(Fn.Sum(PormG.CTE("c", "s"))); conn = _CCD_PG)
  @test occursin("SUM(\"Tb\".\"id\")::bigint as \"s\"", pg) && occursin("SUM(\"R1_1\".\"s\")::bigint as \"x\"", pg)
  sl = _ccd_sql(withcte(Fn.Sum(PormG.CTE("c", "s"))); conn = _CCD_SL)
  @test occursin("SUM(\"Tb\".\"id\") as \"s\"", sl) && occursin("SUM(\"R1_1\".\"s\") as \"x\"", sl)
  shifted = cte(Fn.Cast(Fn.Coalesce(PormG.CTE("c", "shift"), 0) / 2, Models.IntegerField()))
  @test _ccd_builds(nothing; run = shifted)
  @test occursin("SUM((\"Tb\".\"laps_total\" << \$1::integer))::bigint as \"shift\"", shifted(_CCD_PG))
  @test occursin("SUM((\"Tb\".\"laps_total\" << ?)) as \"shift\"", shifted(_CCD_SL))
  # The sibling: a BIGINT divided by a whole number inside the sum is still a BIGINT, and nested too —
  # both named by the walk, so both normalized.
  @test _ccd_builds(Fn.Cast(Fn.Sum(_CF("id") / 2) / 2, Models.IntegerField()))
  @test _ccd_builds(Fn.Cast(Fn.Sum((_CF("id") / 2) / 2) / 2, Models.IntegerField()))
  @test _ccd_builds(Fn.Cast(Fn.Sum(_CF("number") * _CF("number")) / 2, Models.IntegerField()))
end

# ─────────────────────────────────────────────────────────────────────────────
# Sum over an integer literal: a bigint sum PostgreSQL renders ::bigint; one the walk cannot name is refused there (#1141, #1147)
# PostgreSQL binds an integer literal as `$n::bigint`, and `int4 + int8` is `int8`, so
# `SUM(("Tb"."number" + $1::bigint))` is a `sum(bigint)`: a `numeric` that kept the half once divided
# (#1111's split, `7.5` → `8` against `7`). #1141 refused those on both engines. #1147 step 2: the type
# walk names that sum a `bigint` — integer arithmetic, an integer `Case`, `Coalesce`/`Greatest` over an
# integer, a declared `bigint` — and PostgreSQL renders it `SUM(…)::bigint`, so it divides as an
# integer on both engines and builds. The same holds for a CTE column (`Lag(Count(…))`, a `Lag` with
# an integer default). #1153: so does a bitwise operator and a shift (`int4 & int8` is `int8`, a shift
# its left operand's type), which the walk did not name: they were a bare `sum(bigint)`, refused once
# divided on PostgreSQL only (#1111). Expected SQL, PostgreSQL: `SUM(("Tb"."number" & $1::bigint))::bigint`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1141, #1147, #1153: Sum over an integer literal divides as an integer on both engines" begin
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
  cte(outer) = conn -> _ccd_sql(withcte(outer); conn = conn)
  # The premise: the literal really is bound as `bigint` on PostgreSQL, and the sum cast back.
  @test occursin("SUM((\"Tb\".\"number\" + \$1::bigint))::bigint as \"x\"", _ccd_render(Fn.Sum(_CF("number") + 1); conn = _CCD_PG))
  @test occursin("SUM((\"Tb\".\"number\" + ?)) as \"x\"", _ccd_render(Fn.Sum(_CF("number") + 1); conn = _CCD_SL))
  # Normalized: built on both engines.
  for expr in (
      Fn.Cast(Fn.Sum(_CF("number") + 1) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Sum(1 + _CF("number")) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Sum(_CF("number") / 2) / 2, Models.CharField()),
      Fn.Cast(Fn.Sum(Fn.Coalesce("number", 0)) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Sum(Fn.Coalesce("laps_total", Fn.Value(nothing))) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Sum(Fn.Greatest("number", 1)) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Sum(Fn.Case(Fn.When("number__@gt" => 3, then = 1), default = 0)) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Sum(Fn.Case(Fn.When("number__@gt" => 3, then = _CF("id")), default = nothing)) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Sum(Fn.Coalesce(_CF("number") / 2, 0)) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Sum(Fn.Cast("number", Models.BigIntegerField())) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Sum(Fn.Coalesce("number", 0; output_field = Models.BigIntegerField())) / 2, Models.IntegerField()))
    @test _ccd_builds(expr)
  end
  for col in ("plus", "lagc", "prev", "prank")
    @test _ccd_builds(nothing; run = cte(Fn.Cast(Fn.Sum(PormG.CTE("c", col)) / 2, Models.IntegerField())))
  end
  @test _ccd_builds(nothing; run = cte(Fn.Cast(Fn.Coalesce(PormG.CTE("c", "plus"), 0) / 2, Models.IntegerField())))
  # #1153: the bitwise operators and a shift's left operand are typed by the walk, so these are
  # normalized too (they were refused on PostgreSQL, the bare `sum(bigint)` keeping the half).
  for expr in (
      Fn.Cast(Fn.Sum(_CF("number") & 1) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Sum(xor(_CF("number"), 1)) / 2, Models.IntegerField()),
      Fn.Cast(Fn.Sum(_CF("laps_total") << 1) / 2, Models.IntegerField()),
      # `coalesce(int4 << int4, int8)` is an `int8`.
      Fn.Cast(Fn.Sum(Fn.Coalesce(1 << _CF("number"), 0)) / 2, Models.IntegerField()))
    @test _ccd_builds(expr)
  end
  @test occursin("SUM((\"Tb\".\"number\" & \$1::bigint))::bigint as \"x\"", _ccd_render(Fn.Sum(_CF("number") & 1); conn = _CCD_PG))
  @test occursin("SUM((\"Tb\".\"number\" # \$1::bigint))::bigint as \"x\"", _ccd_render(Fn.Sum(xor(_CF("number"), 1)); conn = _CCD_PG))
  @test occursin("SUM(COALESCE((\$1::integer << \"Tb\".\"number\"), \$2::bigint))::bigint as \"x\"",
                 _ccd_render(Fn.Sum(Fn.Coalesce(1 << _CF("number"), 0)); conn = _CCD_PG))
  @test occursin("SUM((\"Tb\".\"number\" & ?)) as \"x\"", _ccd_render(Fn.Sum(_CF("number") & 1); conn = _CCD_SL))
  # Unchanged: a `sum(integer)` is a `bigint` and divides as an integer on both, and so does a
  # `bigint` that is not summed (`Max`, `Coalesce`); undivided, a `sum(bigint)` reads the same.
  for expr in (Fn.Cast(Fn.Sum("number") / 2, Models.IntegerField()),
               Fn.Cast(Fn.Sum(_CF("number") * _CF("number")) / 2, Models.IntegerField()),
               Fn.Cast(Fn.Max(_CF("number") + 1) / 2, Models.IntegerField()),
               Fn.Cast(Fn.Coalesce("number", 0) / 2, Models.IntegerField()),
               Fn.Cast(Fn.Sum(_CF("number") + 1), Models.IntegerField()),
               Fn.Cast(Fn.Sum(_CF("number") + 1) * 2, Models.IntegerField()),
               Fn.Cast(Fn.Sum(_CF("number") & 1), Models.IntegerField()),
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
    @test _ccd_builds(expr)
  end
  @test _ccd_builds(nothing; run = cte(Fn.Cast(Fn.Max(PormG.CTE("c", "lagc")) / 2, Models.IntegerField())))
  @test _ccd_builds(nothing; run = cte(Fn.Cast(Fn.Sum(PormG.CTE("c", "prev_int")) / 2, Models.IntegerField())))
  # The widest value wins: a float branch makes the `Case` a `float8`, so it is never named as the
  # `bigint` its integer branch alone would be. (Its float branch is a float to the classifier since
  # #1187; this asserts only that the `bigint` rule does not answer for it.)
  for conn in _CCD_ENGINES
    err = _ccd_refusal(Fn.Cast(Fn.Sum(Fn.Case(Fn.When("number__@gt" => 3, then = 1.5), default = 0)) / 2, Models.IntegerField()); conn = conn)
    @test err === nothing || !occursin(literal, _ccd_msg(err))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Sum of a bigint renders ::bigint on PostgreSQL, so it divides as an integer on both engines (#1147 step 2)
# NORMALIZED: the sum of integers means an integer (Django's `Sum` of an integer field, SQLite's sum),
# and PostgreSQL widens `sum(bigint)` to `numeric`, which kept the half once divided. PormG renders it
# back to the `bigint` there, read from the same type walk `_computed_kind` answers, so the SQL and the
# type agree; a sum past the `bigint` range then raises, as SQLite's does. Expected SQL, PostgreSQL:
#   SUM("Tb"."laps_total")::bigint           (a BigIntegerField)
#   SUM(CASE … THEN $2::bigint ELSE $3::bigint END)::bigint   (an integer Case)
# and bare `SUM(x)` where PostgreSQL's sum is already the meaning: `sum(int4)` is a `bigint`, a
# float's a `double`, and a `Case` with a float branch is a `float8`. SQLite renders bare everywhere.
# A shifted `bigint` is one too (#1153: `SUM(("Tb"."laps_total" << $1::integer))::bigint`); a `Floor` over a
# `Mod` is a fraction (`Mod` is `numeric`), whose nearest integer SQLite truncates (#1028).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1147: Sum of a bigint renders ::bigint on PostgreSQL and divides as an integer on both engines" begin
  pg(expr) = _ccd_render(expr; conn = _CCD_PG)
  sl(expr) = _ccd_render(expr; conn = _CCD_SL)
  @test occursin("SUM(\"Tb\".\"laps_total\")::bigint as \"x\"", pg(Fn.Sum("laps_total")))
  @test occursin("SUM(\"Tb\".\"laps_total\") as \"x\"", sl(Fn.Sum("laps_total")))
  for col in ("number", "points"), render in (pg, sl)
    @test occursin("SUM(\"Tb\".\"$(col)\") as \"x\"", render(Fn.Sum(col)))
  end
  int_case = Fn.Sum(Fn.Case(Fn.When("number__@gt" => 3, then = 1), default = 0))
  @test occursin("SUM(CASE WHEN \"Tb\".\"number\" > \$1 THEN \$2::bigint ELSE \$3::bigint END)::bigint as \"x\"", pg(int_case))
  @test occursin("SUM(CASE WHEN \"Tb\".\"number\" > ? THEN ? ELSE ? END) as \"x\"", sl(int_case))
  float_case = Fn.Sum(Fn.Case(Fn.When("number__@gt" => 3, then = 1.5), default = 0))
  @test occursin("END) as \"x\"", pg(float_case)) && !occursin("::bigint as \"x\"", pg(float_case))
  # Divided: refused on both engines before #1147; now built on both.
  divided = Fn.Cast(Fn.Sum("laps_total") / 2, Models.IntegerField())
  @test _ccd_builds(divided)
  @test occursin("((SUM(\"Tb\".\"laps_total\")::bigint / \$1::bigint))::integer as \"x\"", pg(divided))
  @test occursin("CAST((SUM(\"Tb\".\"laps_total\") / ?) AS INTEGER) as \"x\"", sl(divided))
  # #1153: a shift has its left operand's type, so a shifted `bigint` sums to one and is cast back too.
  shifted = Fn.Cast(Fn.Sum(_CF("laps_total") << 1) / 2, Models.IntegerField())
  @test _ccd_builds(shifted)
  @test occursin("((SUM((\"Tb\".\"laps_total\" << \$1::integer))::bigint / \$2::bigint))::integer as \"x\"", pg(shifted))
  @test occursin("CAST((SUM((\"Tb\".\"laps_total\" << ?)) / ?) AS INTEGER) as \"x\"", sl(shifted))
  # A `Floor` over a `Mod` is a fraction to the classifier: cast to an integer, SQLite departs (#1028).
  floor_mod = Fn.Cast(Fn.Floor(Fn.Mod("number", 3)) / 2, Models.IntegerField())
  _ccd_expect(floor_mod; departs = _SL_ONLY, issue = "#1028", named = "arithmetic over `FLOOR(…)` over `MOD(…)`")
  @test occursin("((FLOOR((MOD((\"Tb\".\"number\")::numeric, (\$1::bigint)::numeric))::numeric) / \$2::bigint))::integer as \"x\"", pg(floor_mod))
end

# ─────────────────────────────────────────────────────────────────────────────
# Floor/Ceil/Abs over an integer date part keep the integer, so divided it builds (#1135, #1147)
# #1135 read a date part through the transform ladder and counted the parts both engines compute as
# integers as whole numbers — the `EXTRACT` fields but `EPOCH` and the sub-second ones, `@quarter`,
# `@quadrimester`, `@week_day` — and refused them under `FLOOR`/`CEIL`/`ABS`, divided: PostgreSQL
# rendered `FLOOR((EXTRACT(YEAR FROM "Tb"."born")::integer)::numeric) / $1::bigint` and kept the half.
# #1147: such a part is an integer to the type walk, so the function keeps it on PostgreSQL too.
# Expected SQL, PostgreSQL:
#   ((FLOOR((EXTRACT(YEAR FROM "Tb"."born")::integer)::numeric)::integer / $1::bigint))::integer
# and SQLite's `FLOOR(CAST(strftime('%Y', …) AS INTEGER)) / ?`: integer division on both engines.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1135, #1147: Floor/Ceil/Abs over an integer date part, divided, build on both engines" begin
  for conn in _CCD_ENGINES
    for expr in (
        Fn.Cast(Fn.Floor("born__@year") / 2, Models.IntegerField()),
        Fn.Cast(Fn.Ceil("born__@month") / 2, Models.CharField()),
        Fn.Cast(Fn.Floor("born__@quarter") / 2, Models.IntegerField()),
        Fn.Cast(Fn.Floor("born__@quadrimester") / 2, Models.IntegerField()),
        Fn.Cast(Fn.Abs("born__@week_day") / 2, Models.IntegerField()),
        Fn.Cast(Fn.Floor("start_at__@second") / 2, Models.IntegerField()),
        # The explicit function is the same node the path builds.
        Fn.Cast(Fn.Abs(Fn.Extract("born", "year")) / 2, Models.IntegerField()),
        Fn.Cast(Fn.Floor(Fn.Extract("born", "dow")) / 2, "numeric(10,1)"),
        Fn.Concat("surname", Fn.Floor("born__@year") / 2),
        # Unchanged: a text transform is not a whole number, a date part is whole undivided or under
        # `*`, and divided directly or summed it divides as an integer on both engines.
        Fn.Cast(Fn.Floor("born__@yyyy_mm"), Models.CharField()),
        Fn.Cast(Fn.Floor("born__@year"), Models.IntegerField()),
        Fn.Cast(Fn.Floor("born__@day") * 2, Models.IntegerField()),
        Fn.Cast(_CF("born__@year") / 2, Models.IntegerField()),
        Fn.Cast(Fn.Sum("born__@year") / 2, Models.IntegerField()))
      @test _ccd_refusal(expr; conn = conn) === nothing
    end
  end
  @test occursin("((FLOOR((EXTRACT(YEAR FROM \"Tb\".\"born\")::integer)::numeric)::integer / \$1::bigint))::integer as \"x\"",
                 _ccd_render(Fn.Cast(Fn.Floor("born__@year") / 2, Models.IntegerField()); conn = _CCD_PG))
  @test occursin("CAST((FLOOR(CAST(strftime('%Y', \"Tb\".\"born\") AS INTEGER)) / ?) AS INTEGER) as \"x\"",
                 _ccd_render(Fn.Cast(Fn.Floor("born__@year") / 2, Models.IntegerField()); conn = _CCD_SL))
  # `ABS` over an integer date part renders PostgreSQL's own integer `abs`, with no cast.
  @test occursin("ABS((EXTRACT(DOW FROM \"Tb\".\"born\")::integer + 1))",
                 _ccd_render(Fn.Abs("born__@week_day"); conn = _CCD_PG))
  # `EPOCH` stays fractional on PostgreSQL (`EXTRACT(EPOCH …)` is `numeric`), so it is no integer to
  # keep and no whole number to refuse; SQLite has no `EPOCH` part at all.
  @test _ccd_refusal(Fn.Cast(Fn.Floor(Fn.Extract("start_at", "epoch")) / 2, Models.IntegerField()); conn = _CCD_PG) === nothing
  @test occursin("FLOOR((EXTRACT(EPOCH FROM \"Tb\".\"start_at\"))::numeric) as \"x\"",
                 _ccd_render(Fn.Floor(Fn.Extract("start_at", "epoch")); conn = _CCD_PG))
  # Review of #1135: a part SQLite cannot render raises there (category 4), so it has no SQLite answer
  # to split from, and PostgreSQL keeps rendering it. `@quarter` is a node of its own on both engines;
  # an `EXTRACT` `QUARTER` field is PostgreSQL's alone.
  for part in ("century", "quarter", "timezone_hour")
    expr = Fn.Cast(Fn.Floor(Fn.Extract("start_at", part)) / 2, Models.IntegerField())
    @test _ccd_refusal(expr; conn = _CCD_PG) === nothing
    @test _ccd_refusal(expr; conn = _CCD_SL) isa PormG.BackendCapabilityError
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1087: the precision, the scale and a Decimal exponent are bounded before they size a BigInt
# PostgreSQL's own bound on `numeric(p, s)` is 1000: past it the server refuses the type, so the
# overflow check reads a larger size as 1001 and leaves it to the server. A huge or tiny Decimal
# exponent is decided without building the power of ten — on every engine, since the classifier runs
# before the departure is asked; the refusal itself is SQLite's (#1040, #1087 meaning).
# ─────────────────────────────────────────────────────────────────────────────
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
  @test _ccd_builds(Fn.Cast(Fn.Value(100), "numeric(99999999999999999999)"))
  _ccd_expect(Fn.Cast(Fn.Value(2.675), "numeric(1001,2)"); departs = _SL_ONLY, issue = "#1040")
  _ccd_expect(Fn.Cast("points", "numeric(1001,2)"); departs = _SL_ONLY, issue = "#1040")
  # A zero Decimal is zero on both engines, whatever its exponent.
  @test _ccd_builds(Fn.Cast(Fn.Value(Decimal(0, 0, -5)), "numeric(10,2)"))
  # A huge or tiny Decimal exponent is decided without building the power of ten.
  huge = Fn.Cast(Fn.Value(Decimal(0, 1, 10^9)), "numeric(10,2)")
  for conn in _CCD_ENGINES
    started = time(); _ccd_refusal(huge; conn = conn)
    @test time() - started < 5
  end
  _ccd_expect(huge; departs = _SL_ONLY, issue = "#1087", named = "a Decimal literal with more than 2000 digits before the point")
  # A Decimal is an AbstractFloat, and Base's `isinteger` calls 1e-30 whole: it used to pass the
  # #1040 scale rule as a whole number. PostgreSQL makes it `0.00`, SQLite keeps it.
  _ccd_expect(Fn.Cast(Fn.Value(Decimal(0, 1, -30)), "numeric(10,2)"); departs = _SL_ONLY, issue = "#1040",
              named = "a Decimal literal with 30 decimal places")
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
# `2.67`), a last-digit difference — representation — documented rather than refused. Text is no
# number to round: EXPLICIT INTENT (#1147 step 2), refused on every engine, a JSON value included,
# naming the cast that says it holds a number.
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

@testset "#1061: Round(x, d) refuses text on every engine, a JSON value included (explicit intent)" begin
  text = [
    "surname"             => "the text column `surname`",
    Fn.Value("1.555")     => "a string literal",
    "payload__score"      => "the JSONField `payload__score`",
  ]
  for (operand, named) in text, d in (1, 2)
    for msg in _ccd_refused_everywhere(Fn.Round(operand, d); issue = "#1061")
      @test occursin("Round(…, $(d)) rounds a number, and $(named) is text", msg)
      @test occursin("PormG does not read text as a number for you", msg)
      @test occursin("Round(Cast(x, FloatField()), $(d))", msg)
    end
  end
  # Wherever it renders.
  positions = (
    ("values",            q -> q.values("x" => Fn.Round("surname", 2))),
    ("filter right-hand", q -> q.filter("number__@gte" => Fn.Round("surname", 2))),
    ("Case branch",       q -> q.values("c" => Fn.Case([Fn.When("id" => 1, then = Fn.Round("surname", 2))], default = 0))),
  )
  for (label, position) in positions
    _ccd_refused_everywhere(nothing; issue = "#1061", run = conn -> _ccd_sql((q = CCD.Ccd_driver.objects; position(q); q); conn = conn))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1061: a Round has at most d places for a cast to read
# `Round(x, 2)` cast to a scale of two or more has nothing left to round, so it builds on both. Cast to
# a narrower scale it means the value rounded again, which SQLite does not do: refused there (#1040).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1061: a Round has at most d places for a cast to read" begin
  rating() = (s = CCD.Ccd_team.objects; s.filter("id" => OuterRef("team")); s.values("rating"); s)
  for conn in _CCD_ENGINES
    for operand in ("price", "points", Fn.Avg("number"), Subquery(rating()))
      @test _ccd_refusal(Fn.Cast(Fn.Round(operand, 2), "numeric(10,2)"); conn = conn) === nothing
      @test _ccd_refusal(Fn.Cast(Fn.Round(operand, 2), "numeric(10,3)"); conn = conn) === nothing
    end
    @test _ccd_refusal(Fn.Round(Fn.Round("price", 2), 2); conn = conn) === nothing
    @test _ccd_refusal(Fn.Coalesce(Fn.Round("points", 2), 0; output_field = "numeric(10,2)"); conn = conn) === nothing
  end
  # Wider than the scale: PostgreSQL rounds a two-place value cast to one place, SQLite keeps it.
  _ccd_expect(Fn.Cast(Fn.Round("price", 2), "numeric(10,1)"); departs = _SL_ONLY, issue = "#1040", named = "`ROUND(…)`")
end

# The string, Float64 and Decimal labels this classifier writes, on whichever engine refuses. A Float32
# literal and arithmetic over a literal are named by #1027's `Concat` labels, pinned in the #1057
# testset below.
@testset "#1040: a string, Float64 or Decimal literal is named by its digits, not its value (#971)" begin
  marker = "s3cr3t1044"
  for (expr, named, departs) in ((Fn.Round(Fn.Value(marker), 2), "a string literal", (postgres = true, sqlite = true)),   # explicit intent
                                 (Fn.Cast(Fn.Value(marker), "numeric(10,2)"), "a string literal", _SL_ONLY),
                                 (Fn.Cast(Fn.Value(1044.123456), "numeric(10,2)"), "a Float64 literal with 6 decimal places", _SL_ONLY),
                                 (Fn.Cast(Fn.Value(Decimal(0, 1044123, -3)), "numeric(10,2)"), "a Decimal literal with 3 decimal places", _SL_ONLY)),
      (conn, refuses) in ((_CCD_PG, departs.postgres), (_CCD_SL, departs.sqlite))
    err = _ccd_refusal(expr; conn = conn)
    if refuses
      msg = _ccd_msg(err)
      @test err isa QueryBuildError && occursin(named, msg)
      @test !occursin(marker, msg) && !occursin("1044.123", msg) && !occursin("1044123", msg)
    else
      @test err === nothing
    end
  end
end

# #1027's literal labels, and every label built over one (`arithmetic over …`), name the literal by
# its type. Each route that reaches them: `Concat` when built, and `Concat`, `Cast` and `Round` when
# rendered — a cast to an integer through `_cast_divergent_operand`, and a cast to `numeric(p, s)`
# through `_scale_divergent_operand`'s fall-through. Each is checked on the engine that refuses it:
# `Concat` on every engine, a cast on SQLite (meaning). Every marker holds `1057` or `2057`, which
# nothing else in these messages does.
@testset "#1057: a Concat or Cast refusal never prints the literal (#971)" begin
  everywhere = (postgres = true, sqlite = true)
  cases = (
    (() -> Fn.Concat("surname", 1057.25), "a Float64 literal", everywhere),
    (() -> Fn.Concat("surname", Fn.Value(Decimal(0, 1057125, -3))), "a Decimal literal", everywhere),
    (() -> Fn.Concat("surname", Fn.Value(DateTime(2057, 1, 5))), "a DateTime literal", everywhere),
    (() -> Fn.Concat("surname", Fn.Value(Minute(1057))), "a duration literal", everywhere),
    (() -> Fn.Concat(Fn.Value("|"), _CF("number") * 1057.25), "arithmetic over a Float64 literal", everywhere),
    (() -> Fn.Concat(Fn.Value("|"), Fn.Max(Fn.Value(1057.25))), "`MAX(…)` over a Float64 literal", everywhere),
    (() -> Fn.Cast(Fn.Value(1057.25), Models.IntegerField()), "a Float64 literal", _SL_ONLY),
    (() -> Fn.Cast(_CF("number") + 1057.25, "numeric(10,0)"), "arithmetic over a Float64 literal", _SL_ONLY),
    (() -> Fn.Cast(Fn.Max(Fn.Value(1057.25)), Models.IntegerField()), "`MAX(…)` over a Float64 literal", _SL_ONLY),
    (() -> Fn.Cast(Fn.Value(Float32(1057.25)), "numeric(10,2)"), "a Float32 literal", _SL_ONLY),
  )
  for (build, named, departs) in cases, (conn, refuses) in ((_CCD_PG, departs.postgres), (_CCD_SL, departs.sqlite))
    err = try _ccd_render(build(); conn = conn); nothing catch e; e end
    if refuses
      msg = _ccd_msg(err)
      @test err isa QueryBuildError && occursin(named, msg)
      @test !occursin("1057", msg) && !occursin("2057", msg)
    else
      @test err === nothing
    end
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
# (PostgreSQL rounds `1.5` to `2`, SQLite truncates it to `1`: refused on SQLite, #1028), `Concat`
# (explicit intent, every engine), and the alias filter. A cast of it to text is representation and
# builds on both (#1147).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1078: an unscaled dec cast is typed as decimal is" begin
  for t in ("dec", "DEC", "Dec")
    @test PormG.QueryBuilder._sql_type_field(t) isa Models.sDecimalField
  end
  for t in ("dec", "decimal")
    _ccd_expect(Fn.Cast(Fn.Cast("points", t), Models.IntegerField()); departs = _SL_ONLY, issue = "#1028",
                named = "a value cast to $(t)")
    @test _ccd_builds(Fn.Cast(Fn.Cast("number", t), Models.CharField()))
    _ccd_refused_everywhere(Fn.Concat("surname", Fn.Cast("number", t)); issue = "#1027", named = "a value cast to $(t)")
    for conn in _CCD_ENGINES
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
end

# ─────────────────────────────────────────────────────────────────────────────
# A decimal or mixed quotient is a fraction on both engines; SQLite casts its dividend (#1147 review, #1150)
# SQLite's NUMERIC affinity stores a whole `DecimalField` value (`15.00`) as an INTEGER, and a value
# that is one of several (`Coalesce("number", 0.5)`, a `Case` with an integer and a float branch,
# `Least("number", "points")`, a window with a fractional `default`) is that row's own value there,
# an integer on the rows the whole one supplies. So `x / 2` was `7` on those rows where PostgreSQL,
# which resolves the value to a `numeric` or a `float8`, keeps `7.5`: the #1147 review refused it on
# SQLite under a cast, and a bare quotient split silently. #1150: SQLite casts the dividend to REAL
# (expected SQL below), so the quotient is `7.5` on both engines, and a cast to text of it is
# representation, built everywhere. A declared decimal over an integer, and whole text cast to
# `numeric`, are decimals the same way. `NullIf(a, b)` has `a`'s type, and PostgreSQL, which resolves
# it with `b`, casts it back: `(NULLIF("Tb"."number", $1::double precision))::integer`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1147 review, #1150: a decimal or mixed quotient is a fraction on both engines; to text it builds" begin
  for expr in (
      Fn.Cast(_CF("price") / 2, "text"),
      Fn.Cast(Fn.Sum("price") / Fn.Count("id"), "text"),
      Fn.Cast(Fn.Max("price") / 2, "text"),
      Fn.Cast(Fn.Round(_CF("price") / 2, 1), "text"),
      Fn.Cast(Fn.Coalesce("number", 0.5) / 2, "text"),
      Fn.Cast(Fn.Coalesce("number", "points") / 2, "text"),
      Fn.Cast(Fn.Least("number", "points") / 2, "text"),
      Fn.Cast(Fn.Case([Fn.When("active" => true, then = _CF("number"))], default = 0.5) / 2, "text"),
      Fn.Cast(Fn.Floor(Fn.Coalesce("number", 0.5)) / 2, "text"),
      Fn.Cast(Fn.Cast("number", "numeric") / 2, "text"),
      Fn.Cast(Fn.Coalesce("number", 0; output_field = "numeric") / 2, "text"),
      Fn.Cast(Fn.Case([Fn.When("active" => true, then = _CF("number"))], default = 0; output_field = "numeric") / 2, "text"),
      Fn.Cast(Fn.Cast("surname", "numeric") / 2, "text"),
      Fn.Cast(Fn.NullIf("number", 0.5) / 2, "text"),
      Fn.Cast(Fn.NullIf("number", "points") / 2, "text"))
    @test _ccd_builds(expr)
  end
  sl(expr) = _ccd_render(expr; conn = _CCD_SL)
  pg(expr) = _ccd_render(expr; conn = _CCD_PG)
  @test occursin("CAST((CAST(\"Tb\".\"price\" AS REAL) / ?) AS TEXT) as \"x\"", sl(Fn.Cast(_CF("price") / 2, "text")))
  @test occursin("((\"Tb\".\"price\" / \$1::bigint))::text as \"x\"", pg(Fn.Cast(_CF("price") / 2, "text")))
  @test occursin("(CAST(COALESCE(\"Tb\".\"number\", ?) AS REAL) / ?) as \"x\"", sl(Fn.Coalesce("number", 0.5) / 2))
  @test occursin("((COALESCE(\"Tb\".\"number\", \$1::double precision) / \$2::bigint))::text as \"x\"",
                 pg(Fn.Cast(Fn.Coalesce("number", 0.5) / 2, "text")))
  @test occursin("(CAST(CAST(\"Tb\".\"number\" AS NUMERIC) AS REAL) / ?) as \"x\"", sl(Fn.Cast("number", "numeric") / 2))
  # `NullIf` over an integer and a fraction is the integer: PostgreSQL casts it back, SQLite returns it.
  @test occursin("((NULLIF(\"Tb\".\"number\", \$1::double precision))::integer / \$2::bigint) as \"x\"", pg(Fn.NullIf("number", 0.5) / 2))
  @test occursin("(NULLIF(\"Tb\".\"number\", ?) / ?) as \"x\"", sl(Fn.NullIf("number", 0.5) / 2))
  @test occursin("(NULLIF(\"Tb\".\"number\", \$1::bigint) / \$2::bigint) as \"x\"", pg(Fn.NullIf("number", 0) / 2))
  # So it is no fraction to the cast and `Concat` rules: an integer quotient, and an integer's text.
  for expr in (Fn.Cast(Fn.NullIf("number", 0.5) / 2, Models.IntegerField()), Fn.Concat(Fn.Value("-"), Fn.NullIf("number", 0.5)))
    @test _ccd_builds(expr)
  end
  # A float `a` is a float: its nearest integer is the #1028 meaning SQLite truncates.
  _ccd_expect(Fn.Cast(Fn.NullIf("points", 1), Models.IntegerField()); departs = _SL_ONLY, issue = "#1028",
              named = "`NULLIF(…)` over the FloatField `points`")
  # A side that is a REAL on every row already needs no cast: a float literal, a `FloatField` column.
  @test occursin("(\"Tb\".\"price\" / ?) as \"x\"", sl(_CF("price") / 2.0))
  @test occursin("(\"Tb\".\"points\" / ?) as \"x\"", sl(_CF("points") / 2))
  @test occursin("(\"Tb\".\"price\" / \"Tb\".\"points\") as \"x\"", sl(_CF("price") / _CF("points")))
  # An integer quotient is an integer quotient on both: no cast.
  @test occursin("(\"Tb\".\"number\" / ?) as \"x\"", sl(_CF("number") / 2))
  # Built as before: a float divisor, the cast alone, a float column divided, and whole values only.
  for expr in (Fn.Cast(_CF("price") / 2.0, "text"), Fn.Cast(Fn.Coalesce("number", 0.5) / 2.0, "text"),
               Fn.Cast("price", "text"), Fn.Cast(_CF("points") / 2, "text"),
               Fn.Cast(Fn.Coalesce("number", 1) / 2, Models.IntegerField()), Fn.Sum(Fn.Coalesce("number", 0.5)))
    @test _ccd_builds(expr)
  end
  # A fraction to an integer is still the #1028 meaning SQLite truncates.
  _ccd_expect(Fn.Cast(Fn.Floor("price") / 2, Models.IntegerField()); departs = _SL_ONLY, issue = "#1028",
              named = "`FLOOR(…)` over the DecimalField `price`")
  _ccd_expect(Fn.Cast(Fn.Coalesce("number", 0.5) / 2, Models.IntegerField()); departs = _SL_ONLY, issue = "#1028",
              named = "`COALESCE(…)` over a Float64 literal")
  # `Sum` over a mixed value is a float on PostgreSQL: no `::bigint`.
  @test !occursin("::bigint as", _ccd_render(Fn.Sum(Fn.Coalesce("number", 0.5)); conn = _CCD_PG))
  # In `Concat` the quotient is a number: explicit intent on every engine, pointing to a cast to text.
  msgs = _ccd_refused_everywhere(Fn.Concat(Fn.Value("-"), _CF("price") / 2); issue = "#1027")
  @test all(m -> occursin("\"text\")", m), msgs)
  # A CTE `Avg` over a decimal: a decimal, divided as REAL on SQLite too.
  avg_cte(conn) = (body = CCD.Ccd_driver.objects; body.values("team", "a" => Fn.Avg("price"));
                   q = CCD.Ccd_driver.objects; q.with("c" => body, join_field = "team" => "team");
                   q.values("x" => Fn.Cast(Fn.Max(PormG.CTE("c", "a")) / 2, "text")); _ccd_sql(q; conn = conn))
  for expr in (Fn.Cast(Fn.Cast("points", "numeric") / 2, "text"), Fn.Cast(Fn.Coalesce("points", 0) / 2, "text"),
               Fn.Cast(Fn.Coalesce("points", 0; output_field = "numeric") / 2, "text"),
               Fn.Cast(Fn.NullIf("points", 1) / 2, "text"))
    @test _ccd_builds(expr)
  end
  @test _ccd_builds(nothing; run = avg_cte)
end

# ─────────────────────────────────────────────────────────────────────────────
# A CTE column answers the division and text rules as its body expression does (#1034 phase 3, step 1)
# The CTE model types each column with one field (`Count` an integer, `Sum` an integer whatever it
# sums, `Avg` its operand's field), which cannot say what the rules ask: whether the column is a
# `bigint` on PostgreSQL, a whole number PostgreSQL computes as `numeric`, or a value with no single
# text. So the outer query asks the column's BODY expression. This pins what each answer does to the
# outer query, through every rule that reads it, on shapes the expression-kind matrix cannot build
# (its models have no JSON field):
# - a body `Sum(F("laps_total") + F("payload__n"))` sums a `bigint` with a value the walk cannot type,
#   so PostgreSQL's `sum(bigint)` is a `numeric`: divided, refused there (#1111), built on SQLite;
# - a body `Count` is a `bigint` on PostgreSQL: summed beside an untyped value, the same (#1111). Beside
#   an integer column the walk names the sum, and PostgreSQL renders `SUM(…)::bigint` (#1147), so it builds;
# - a body `Avg` has no single integer: cast to one, refused on SQLite (#1028);
# - a body JSON key lookup is the key's value, not the document, and a zero-scale decimal is whole:
#   `Concat` and a scaled cast over them build.
# The messages name the CTE column and, in parentheses, what its body is. Expected SQL where it builds,
# `Cast(CTE("c", "w"), "text")`: the body `SUM(("Tb"."laps_total" + "Tb"."payload" #>> '{"n"}')) as "w"`
# read as `("R1_1"."w")::text` on PostgreSQL; `SUM(("Tb"."laps_total" + json_extract("Tb"."payload",
# '$.n'))) as "w"` read as `CAST("R1_1"."w" AS TEXT)` on SQLite.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034: a CTE column answers the division and text rules as its body expression does" begin
  function withcte(outer)
    q = CCD.Ccd_driver.objects
    body = CCD.Ccd_driver.objects
    body.values("id",
                "w"    => Fn.Sum(_CF("laps_total") + _CF("payload__n")),   # a `sum(bigint)` the walk cannot type
                "cnt"  => Fn.Count("id"),                                    # a `bigint`, typed as an integer
                "bf"   => _CF("laps_total") * _CF("points"),                 # a float, with a `bigint` side
                "avgl" => Fn.Avg("laptime"),
                "avgp" => Fn.Avg("points"),
                "mxg"  => Fn.Max("grid"),                                    # a zero-scale decimal
                "drv"  => "payload__driver")                                 # a JSON key's value
    q.with("c" => body, join_field = "id" => "id")
    q.values("x" => outer)
    return q
  end
  cte(outer) = conn -> _ccd_sql(withcte(outer); conn = conn)
  w = "the CTE column `CTE(\"c\", \"w\")` (`SUM(…)` over the BigIntegerField `laps_total`)"
  # The whole number PostgreSQL computes as `numeric`, divided: under `Coalesce`, an extremum, `Floor`
  # and an outer `Sum`, to an integer and to a scaled numeric.
  for outer in (Fn.Cast(Fn.Coalesce(PormG.CTE("c", "w"), 0) / 2, Models.IntegerField()),
                Fn.Cast(Fn.Max(PormG.CTE("c", "w")) / 2, "numeric(10,1)"),
                Fn.Cast(Fn.Floor(PormG.CTE("c", "w")) / 2, Models.IntegerField()),
                Fn.Cast(Fn.Sum(Fn.Coalesce(PormG.CTE("c", "w"), 0)) / 2, Models.IntegerField()))
    _ccd_expect(nothing; departs = _PG_ONLY, issue = "#1111", named = w, run = cte(outer))
  end
  # The `bigint` column summed beside a value the walk cannot type, and beside one it can.
  _ccd_expect(nothing; departs = _PG_ONLY, issue = "#1111", named = "the CTE column `CTE(\"c\", \"cnt\")` (`COUNT(…)`)",
              run = cte(Fn.Cast(Fn.Sum(Fn.Coalesce(PormG.CTE("c", "cnt"), "payload__n")) / 2, Models.IntegerField())))
  _ccd_expect(nothing; departs = _PG_ONLY, issue = "#1111", named = "the CTE column `CTE(\"c\", \"cnt\")` (`COUNT(…)`)",
              run = cte(Fn.Cast(Fn.Sum(Fn.Greatest(PormG.CTE("c", "cnt"), "payload__n")) / 2, Models.IntegerField())))
  @test _ccd_builds(nothing; run = cte(Fn.Cast(Fn.Sum(Fn.Coalesce(PormG.CTE("c", "cnt"), "number")) / 2, Models.IntegerField())))
  # A float with a `bigint` side: the float decides, so the cast to an integer is SQLite's truncation.
  _ccd_expect(nothing; departs = _SL_ONLY, issue = "#1028",
              named = "the CTE column `CTE(\"c\", \"bf\")` (arithmetic over the FloatField `points`)",
              run = cte(Fn.Cast(Fn.Sum(Fn.Coalesce(PormG.CTE("c", "bf"), "payload__n")) / 2, Models.IntegerField())))
  # An average, of an interval or of a float, cast to an integer.
  for col in ("avgl", "avgp")
    _ccd_expect(nothing; departs = _SL_ONLY, issue = "#1028", named = "the CTE column `CTE(\"c\", \"$(col)\")` (`AVG(…)`)",
                run = cte(Fn.Cast(PormG.CTE("c", col), Models.IntegerField())))
  end
  # Explicit intent: an average in `Concat`, on every engine.
  _ccd_refused_everywhere(nothing; issue = "#1027", named = "the CTE column `CTE(\"c\", \"avgp\")` (`AVG(…)`)",
                          run = cte(Fn.Concat("surname", PormG.CTE("c", "avgp"))))
  # Built: the JSON key's value and the zero-scale decimal in `Concat`, the decimal to a wider scale,
  # and the `numeric` sum to text.
  for outer in (Fn.Concat("surname", PormG.CTE("c", "drv")), Fn.Concat("surname", PormG.CTE("c", "mxg")),
                Fn.Cast(PormG.CTE("c", "mxg"), "numeric(10,2)"), Fn.Cast(PormG.CTE("c", "w"), "text"))
    @test _ccd_builds(nothing; run = cte(outer))
  end
end
