"""
#1147 — `Abs`, `Floor` and `Ceil` over an integer keep it on PostgreSQL, as SQLite does.

`Dialect` rendered `ABS((x)::numeric)`, `FLOOR((x)::numeric)` and `CEIL((x)::numeric)` on PostgreSQL
for every operand (since 2026-02, when a bound parameter could still be untyped). Over an integer the
value was then a `numeric`, so `Floor("grid") / 2` kept the half on PostgreSQL (`3.5`) and divided as
integers on SQLite (`3`): PormG made PostgreSQL the engine that departs from the integer the function
means, and #1111/#1135 refused the division on both engines to hide it.

Over an operand the type walk names as an integer (`_integer_operand_kind`: a column, a literal, a
count, a cast to an integer, an integer date part, or one of these functions over one), PostgreSQL now
renders `ABS(x)` — its own `abs(int2|int4|int8)` — and `FLOOR((x)::numeric)::<type>`, cast back to the
operand's own type: it has no `floor(integer)`, and a bare `FLOOR(int)` resolves to `double precision`,
which is inexact past 2^53. Every other operand keeps the cast. SQLite renders as before.

#1196 adds `Round` over an integer, which is that integer on both engines: PostgreSQL renders
`ROUND((x)::numeric)::<type>` and SQLite the integer itself, binding no places (the last testsets).

Everything renders through mock connections — no live database, no fixture.

julia --project=test/integration test/unit/test_integer_floor_ceil_abs.jl
"""

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: inspect_query

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`, so a
# shared key would let another file's settings decide this file's dialect.
struct IfcMockSQLite <: PormG.PormGSQLite end
struct IfcMockPostgres <: PormG.PormGPostgres end
const _IFC_SL = IfcMockSQLite()
const _IFC_PG = IfcMockPostgres()
PormG.backend_sqlite_version(::IfcMockSQLite) = 3045000

PormG.config["ifc_mock"] = PormG.Configuration.Settings(
  connections = _IFC_SL, change_data = true, db_def_folder = "ifc_mock",
)

module IfcModels
import PormG
import PormG.Models

Ifc_result = Models.Model("ifc_result",
  resultid = Models.IDField(),
  grid     = Models.IntegerField(null = true),
  position = Models.PositiveSmallIntegerField(null = true),
  laps     = Models.BigIntegerField(null = true),
  points   = Models.FloatField(null = true),
  price    = Models.DecimalField(max_digits = 10, decimal_places = 2, null = true),
  date     = Models.DateField(null = true),
)

PormG.Models.set_models(@__MODULE__, "ifc_mock")
end

const IFC = IfcModels
const _IFC_FN = PormG.Functions
const _IFC_F = PormG.QueryBuilder.F

_ifc_render(expr; conn) =
  inspect_query((q = IFC.Ifc_result.objects; q.values("x" => expr); q); connection = conn)[:sql_text]

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL keeps an integer operand's type; everything else keeps the `::numeric` cast
# Expected SQL is the projected column, per operand type. `ABS` needs no cast over an integer; `FLOOR`
# and `CEIL` cast back to the operand's own integer type (`smallint`, `integer`, `bigint`), so the value
# reads back as that type. A float or decimal operand, and arithmetic the type walk does not name, keep
# `(x)::numeric` exactly as before.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1147: PostgreSQL renders Abs/Floor/Ceil over an integer without leaving its type" begin
  pg(expr) = _ifc_render(expr; conn = _IFC_PG)
  @test occursin("ABS(\"Tb\".\"grid\") as \"x\"", pg(_IFC_FN.Abs("grid")))
  @test occursin("FLOOR((\"Tb\".\"grid\")::numeric)::integer as \"x\"", pg(_IFC_FN.Floor("grid")))
  @test occursin("CEIL((\"Tb\".\"grid\")::numeric)::integer as \"x\"", pg(_IFC_FN.Ceil("grid")))
  @test occursin("FLOOR((\"Tb\".\"resultid\")::numeric)::bigint as \"x\"", pg(_IFC_FN.Floor("resultid")))
  @test occursin("CEIL((\"Tb\".\"laps\")::numeric)::bigint as \"x\"", pg(_IFC_FN.Ceil("laps")))
  @test occursin("FLOOR((\"Tb\".\"position\")::numeric)::smallint as \"x\"", pg(_IFC_FN.Floor("position")))
  @test occursin("ABS(COUNT(\"Tb\".\"resultid\")) as \"x\"", pg(_IFC_FN.Abs(_IFC_FN.Count("resultid"))))
  @test occursin("FLOOR(((ROUND((\"Tb\".\"points\")::numeric, \$1::integer))::integer)::numeric)::integer as \"x\"",
                 pg(_IFC_FN.Floor(_IFC_FN.Cast(_IFC_FN.Round("points"), Models.IntegerField()))))
  @test occursin("FLOOR((EXTRACT(YEAR FROM \"Tb\".\"date\")::integer)::numeric)::integer as \"x\"",
                 pg(_IFC_FN.Floor("date__@year")))
  # Nested: the inner function keeps the integer, so the outer one is over an integer too.
  @test occursin("FLOOR((ABS(\"Tb\".\"grid\"))::numeric)::integer as \"x\"", pg(_IFC_FN.Floor(_IFC_FN.Abs("grid"))))
  # A `Lag`'s `default` is one of its values (review of #1147): an integer literal binds as `bigint`,
  # so the window is an `int8` and the cast back is `::bigint` — `::integer` would overflow on a
  # default past 2^31 — and a float default makes it no integer at all.
  lag(default) = PormG.QueryBuilder.Lag("grid"; default = default, over = PormG.QueryBuilder.WindowOver(order_by = ["resultid"]))
  @test occursin(r"FLOOR\(\(LAG\(\"Tb\".\"grid\", \$1::integer, \$2::bigint\) OVER \([^)]*\)\)::numeric\)::bigint as \"x\"",
                 pg(_IFC_FN.Floor(lag(5_000_000_000))))
  @test occursin(r"FLOOR\(\(LAG\(\"Tb\".\"grid\"[^)]*\) OVER \([^)]*\)\)::numeric\) as \"x\"", pg(_IFC_FN.Floor(lag(3.5))))
  @test occursin(r"FLOOR\(\(LAG\(\"Tb\".\"grid\"[^)]*\) OVER \([^)]*\)\)::numeric\)::integer as \"x\"", pg(_IFC_FN.Floor(lag(missing))))
  @test occursin(r"ABS\(LAG\(\"Tb\".\"grid\"", pg(_IFC_FN.Abs(PormG.QueryBuilder.Lag("grid"; over = PormG.QueryBuilder.WindowOver(order_by = ["resultid"])))))
  # Not an integer to the walk: the cast stays.
  @test occursin("ABS((\"Tb\".\"points\")::numeric) as \"x\"", pg(_IFC_FN.Abs("points")))
  @test occursin("FLOOR((\"Tb\".\"price\")::numeric) as \"x\"", pg(_IFC_FN.Floor("price")))
  # #1147 step 2: `+` over two integers is an integer to the walk (`int4 + int8` is `int8`, the literal
  # binds `$1::bigint`), so `Ceil` over it casts back to `bigint` as over a `bigint` column.
  @test occursin("CEIL(((\"Tb\".\"grid\" + \$1::bigint))::numeric)::bigint as \"x\"", pg(_IFC_FN.Ceil(_IFC_F("grid") + 1)))
  # #1147 step 2: PostgreSQL widens `sum(bigint)` to `numeric`, and PormG renders it back to the
  # `bigint` (`SUM(x)::bigint`), so `Floor` over it is over an integer and casts back too.
  @test occursin("FLOOR((SUM(\"Tb\".\"laps\")::bigint)::numeric)::bigint as \"x\"", pg(_IFC_FN.Floor(_IFC_FN.Sum("laps"))))
  @test occursin("FLOOR((SUM(\"Tb\".\"grid\"))::numeric)::bigint as \"x\"", pg(_IFC_FN.Floor(_IFC_FN.Sum("grid"))))
end

# ─────────────────────────────────────────────────────────────────────────────
# A bitwise operator, a shift and a Subquery over an integer are integers to the walk (#1153)
# Both engines compute these as integers, but the walk named none of them, so PostgreSQL kept
# `FLOOR((x)::numeric)`: divided, it kept the half SQLite drops (`Floor(F("grid") & 3) / 2` read
# `1.5` against `1`), and nothing refused it. The walk now types `&`, `|`, `xor` as arithmetic
# (`int4 & int8` is `int8`), `~` as its operand, a shift as its LEFT operand (a literal there binds
# `::integer`), and a `Subquery` as its inner projection's own kind. Expected SQL, PostgreSQL:
#   FLOOR((("Tb"."grid" & $1::bigint))::numeric)::bigint
#   CEIL((("Tb"."grid" << $1::integer))::numeric)::integer
#   FLOOR(((SELECT "R1"."grid" … LIMIT $1 ))::numeric)::integer
# SQLite renders as before (`FLOOR(("Tb"."grid" & ?))`).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1153: Floor/Ceil/Abs over a bitwise operator, a shift or an integer Subquery keep the integer on PostgreSQL" begin
  # One line, so a pinned subquery reads as the text it is.
  pg(expr) = replace(_ifc_render(expr; conn = _IFC_PG), r"\s+" => " ")
  sl(expr) = replace(_ifc_render(expr; conn = _IFC_SL), r"\s+" => " ")
  @test occursin("FLOOR(((\"Tb\".\"grid\" & \$1::bigint))::numeric)::bigint as \"x\"", pg(_IFC_FN.Floor(_IFC_F("grid") & 3)))
  @test occursin("CEIL(((\"Tb\".\"grid\" | \"Tb\".\"position\"))::numeric)::integer as \"x\"",
                 pg(_IFC_FN.Ceil(_IFC_F("grid") | _IFC_F("position"))))
  @test occursin("ABS((\"Tb\".\"grid\" # \$1::bigint)) as \"x\"", pg(_IFC_FN.Abs(xor(_IFC_F("grid"), 1))))
  @test occursin("FLOOR((~(\"Tb\".\"laps\"))::numeric)::bigint as \"x\"", pg(_IFC_FN.Floor(~_IFC_F("laps"))))
  # A shift has its left operand's type, whatever it shifts by: an `integer` column stays one, and
  # a literal on the left binds `::integer`.
  @test occursin("CEIL(((\"Tb\".\"grid\" << \$1::integer))::numeric)::integer as \"x\"", pg(_IFC_FN.Ceil(_IFC_F("grid") << 1)))
  @test occursin("FLOOR(((\"Tb\".\"laps\" >> \$1::integer))::numeric)::bigint as \"x\"", pg(_IFC_FN.Floor(_IFC_F("laps") >> 1)))
  @test occursin("FLOOR(((\$1::integer << \"Tb\".\"grid\"))::numeric)::integer as \"x\"", pg(_IFC_FN.Floor(1 << _IFC_F("grid"))))
  # Divided, both engines divide an integer.
  @test occursin("(FLOOR(((\"Tb\".\"grid\" & \$1::bigint))::numeric)::bigint / \$2::bigint) as \"x\"",
                 pg(_IFC_FN.Floor(_IFC_F("grid") & 3) / 2))
  @test occursin("(FLOOR((\"Tb\".\"grid\" & ?)) / ?) as \"x\"", sl(_IFC_FN.Floor(_IFC_F("grid") & 3) / 2))
  # A `Subquery` is its inner projection's own kind, typed while the inner build still resolves it.
  inner(col) = IFC.Ifc_result.objects.filter("resultid" => PormG.QueryBuilder.OuterRef("resultid")).values(col).limit(1)
  sub(col) = PormG.QueryBuilder.Subquery(inner(col))
  @test occursin(r"FLOOR\(\(\(SELECT \"R1\"\.\"grid\" [^)]*\)\)::numeric\)::integer as \"x\"", pg(_IFC_FN.Floor(sub("grid"))))
  @test occursin(r"ABS\(\(SELECT \"R1\"\.\"laps\" [^)]*\)\) as \"x\"", pg(_IFC_FN.Abs(sub("laps"))))
  # Not an integer: a float column through a `Subquery` keeps the cast and is not cast back.
  @test occursin(r"FLOOR\(\(\(SELECT \"R1\"\.\"points\" [^)]*\)\)::numeric\) as \"x\"", pg(_IFC_FN.Floor(sub("points"))))
  # SQLite is unchanged.
  @test occursin("FLOOR((\"Tb\".\"grid\" & ?)) as \"x\"", sl(_IFC_FN.Floor(_IFC_F("grid") & 3)))
  @test occursin(r"FLOOR\(\(SELECT \"R1\"\.\"grid\" [^)]*\)\) as \"x\"", sl(_IFC_FN.Floor(sub("grid"))))
end

# ─────────────────────────────────────────────────────────────────────────────
# The cast's original reason stays covered: a literal is bound typed
# `b0642e96` cast every operand to `numeric` when a bound parameter could reach `abs` untyped, which
# PostgreSQL cannot resolve (`abs(unknown)` is not unique). An integer literal now binds `$1::bigint`,
# which `abs(bigint)` resolves, and a float literal keeps its cast. Expected SQL: `ABS($1::bigint)`,
# never `ABS($1)`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1147: an integer literal reaches ABS/FLOOR/CEIL typed, never as a bare parameter" begin
  pg(expr) = _ifc_render(expr; conn = _IFC_PG)
  @test occursin("ABS(\$1::bigint) as \"x\"", pg(_IFC_FN.Abs(_IFC_FN.Value(-5))))
  @test occursin("FLOOR((\$1::bigint)::numeric)::bigint as \"x\"", pg(_IFC_FN.Floor(_IFC_FN.Value(7))))
  @test !occursin(r"ABS\(\$1\)", pg(_IFC_FN.Abs(_IFC_FN.Value(-5))))
  @test occursin(r"ABS\(\(\$1(::[a-z ]+)?\)::numeric\) as \"x\""i, pg(_IFC_FN.Abs(_IFC_FN.Value(-5.5))))
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite renders as before
# SQLite's `abs`/`floor`/`ceil` already keep an integer operand's type, so its SQL does not change:
# `ABS("Tb"."grid")`, `FLOOR("Tb"."grid")`, `CEIL("Tb"."grid")`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1147: SQLite's Abs/Floor/Ceil render unchanged" begin
  sl(expr) = _ifc_render(expr; conn = _IFC_SL)
  @test occursin("ABS(\"Tb\".\"grid\") as \"x\"", sl(_IFC_FN.Abs("grid")))
  @test occursin("FLOOR(\"Tb\".\"grid\") as \"x\"", sl(_IFC_FN.Floor("grid")))
  @test occursin("CEIL(\"Tb\".\"resultid\") as \"x\"", sl(_IFC_FN.Ceil("resultid")))
  @test occursin("FLOOR(\"Tb\".\"points\") as \"x\"", sl(_IFC_FN.Floor("points")))
end

# ─────────────────────────────────────────────────────────────────────────────
# The SQL and the type walk read one fact
# `_computed_kind` answers the operand's integer kind exactly where `Dialect` renders it, so the type
# the walk names is the type the SQL produces: `CInt32` for an integer column, `CInt64` for a bigint,
# `CInt16` for a smallint, and `numeric` (a width-less `CDecimal`) where the cast stays.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1147: the walk's kind is the rendered type, on PostgreSQL" begin
  QB = PormG.QueryBuilder
  # The kinds themselves are pinned by the expression-kind matrix (`Abs int`, `Abs bigint`, `Floor
  # int`, `Ceil int`, `Floor year part`); here, the rule methods that state them.
  ck(name, k) = QB._computed_kind(Val(name), QB._result_rule(Val(name)), k, _IFC_PG)
  for name in (:ABS, :FLOOR, :CEIL), k in (PormG.CInt16(), PormG.CInt32(), PormG.CInt64())
    @test ck(name, k) == k
  end
  for name in (:ABS, :FLOOR, :CEIL), k in (PormG.CFloat64(), PormG.CDecimal(10, 2), nothing)
    @test ck(name, k) == PormG.CDecimal(nothing, nothing)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A CTE column is its expression's own type, not its read kind
# The CTE body recorded only each column's READ kind, which a `Rank`, an integer `Case` or a plain
# integer column does not have (the driver reads them back as integers already). So
# `Floor(CTE("c", "rk"))` kept `FLOOR((…)::numeric)` on PostgreSQL, and divided by 2 kept the half
# SQLite drops (`2.5` against `2`). The body now records each column's `_expression_kind` too.
# Expected SQL on PostgreSQL: the cast back to the column's type — `::bigint` for a ranking window and
# an integer `Case` (its literals bind as `bigint`), `::integer` for an `integer` column — and no cast
# back over an `Avg`, which is no integer: its floor of `7.5` is `7` on both engines, a `numeric`/`REAL`.
# SQLite renders `FLOOR("…"."rk")` as before. Found reviewing #1156, the duplicate of this step.
# ─────────────────────────────────────────────────────────────────────────────
_ifc_window() = PormG.QueryBuilder.WindowOver(order_by = ["grid", "resultid"])
function _ifc_cte_body()
  b = IFC.Ifc_result.objects
  b.values("resultid", "g" => "grid",
           "rk" => PormG.QueryBuilder.Rank(over = _ifc_window()),
           "dr" => PormG.QueryBuilder.DenseRank(over = _ifc_window()),
           "rn" => PormG.QueryBuilder.RowNumber(over = _ifc_window()),
           "cs" => _IFC_FN.Case(_IFC_FN.When("grid__@gt" => 10, then = 7), default = 3))
  return b
end
function _ifc_avg_body()
  b = IFC.Ifc_result.objects
  b.values("position", "a" => _IFC_FN.Avg("grid"))
  return b
end
function _ifc_cte_render(expr; conn, body = _ifc_cte_body(), on = "resultid" => "resultid")
  q = IFC.Ifc_result.objects
  q.with("c" => body, join_field = on)
  q.values("x" => expr)
  return inspect_query(q; connection = conn)[:sql_text]
end
_ifc_cte_col(name) = PormG.CTE("c", name)

@testset "#1147: Floor/Ceil/Abs over a CTE ranking, Case or integer column keep its type on PostgreSQL" begin
  pg(expr; kw...) = _ifc_cte_render(expr; conn = _IFC_PG, kw...)
  sl(expr; kw...) = _ifc_cte_render(expr; conn = _IFC_SL, kw...)
  col = "\"[A-Za-z0-9_]+\"\\."
  for name in ("rk", "dr", "rn", "cs")
    @test occursin(Regex("FLOOR\\(\\($(col)\"$(name)\"\\)::numeric\\)::bigint as \"x\""), pg(_IFC_FN.Floor(_ifc_cte_col(name))))
    @test occursin(Regex("CEIL\\(\\($(col)\"$(name)\"\\)::numeric\\)::bigint as \"x\""), pg(_IFC_FN.Ceil(_ifc_cte_col(name))))
    @test occursin(Regex("ABS\\($(col)\"$(name)\"\\) as \"x\""), pg(_IFC_FN.Abs(_ifc_cte_col(name))))
    # Divided, both engines divide an integer: no refusal, and the PostgreSQL dividend is a `bigint`.
    @test occursin(Regex("\\(FLOOR\\(\\($(col)\"$(name)\"\\)::numeric\\)::bigint / \\\$\\d+::bigint\\) as \"x\""),
                   pg(_IFC_FN.Floor(_ifc_cte_col(name)) / 2))
    @test occursin(Regex("\\(FLOOR\\($(col)\"$(name)\"\\) / \\?\\) as \"x\""), sl(_IFC_FN.Floor(_ifc_cte_col(name)) / 2))
    for conn in (_IFC_PG, _IFC_SL)
      @test !isempty(_ifc_cte_render(_IFC_FN.Cast(_IFC_FN.Floor(_ifc_cte_col(name)) / 2, Models.IntegerField()); conn = conn))
      @test !isempty(_ifc_cte_render(_IFC_FN.Sum(_IFC_FN.Floor(_ifc_cte_col(name))); conn = conn))
    end
  end
  @test occursin(Regex("FLOOR\\(\\($(col)\"g\"\\)::numeric\\)::integer as \"x\""), pg(_IFC_FN.Floor(_ifc_cte_col("g"))))
  @test occursin(Regex("FLOOR\\($(col)\"rk\"\\) as \"x\""), sl(_IFC_FN.Floor(_ifc_cte_col("rk"))))
  # An `Avg` column is no integer: the cast stays and nothing is cast back, so the floor of `7.5` is
  # `7` on both engines; divided it keeps the half on both (`3.5`). A cast of that quotient to an
  # integer means the nearest integer (`4`): PostgreSQL rounds to it and builds, SQLite truncates
  # (`3`) and departs, so it is refused on SQLite only (#1028, #1147 step 2).
  avg(expr; conn) = _ifc_cte_render(expr; conn = conn, body = _ifc_avg_body(), on = "position" => "position")
  a = _ifc_cte_col("a")
  @test occursin(Regex("FLOOR\\(\\($(col)\"a\"\\)::numeric\\) as \"x\""), avg(_IFC_FN.Floor(a); conn = _IFC_PG))
  @test occursin(Regex("\\(FLOOR\\(\\($(col)\"a\"\\)::numeric\\) / \\\$\\d+::bigint\\) as \"x\""), avg(_IFC_FN.Floor(a) / 2; conn = _IFC_PG))
  for conn in (_IFC_PG, _IFC_SL)
    @test !isempty(avg(_IFC_FN.Cast(_IFC_FN.Floor(a), Models.IntegerField()); conn = conn))
    @test !isempty(avg(_IFC_FN.Sum(_IFC_FN.Floor(a)); conn = conn))
  end
  @test occursin(Regex("\\(\\(FLOOR\\(\\($(col)\"a\"\\)::numeric\\) / \\\$\\d+::bigint\\)\\)::integer as \"x\""),
                 avg(_IFC_FN.Cast(_IFC_FN.Floor(a) / 2, Models.IntegerField()); conn = _IFC_PG))
  err = try avg(_IFC_FN.Cast(_IFC_FN.Floor(a) / 2, Models.IntegerField()); conn = _IFC_SL); nothing catch e; e end
  @test err isa PormG.QueryBuildError
  msg = replace(sprint(showerror, err), r"\e\[[0-9;]*m" => "")
  @test occursin("(#1028)", msg) && occursin("refuses it on SQLite", msg) && !occursin("PostgreSQL", msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# #1196: `Round` over an integer is that integer, on both engines
# `Round` means its operand's type (Django's `Round` is a `Transform`), and its places add nothing to an
# integer (a negative precision is refused when the expression is built, #1044). Before #1196 it
# rendered `ROUND((x)::numeric, d)` on PostgreSQL, read back as a `Decimal`, and `ROUND(x, d)` on
# SQLite, a REAL read back as a `Float64`. Expected SQL now:
#   PostgreSQL  ROUND(("Tb"."grid")::numeric)::integer    (the operand's own type: ::smallint, ::bigint)
#   SQLite      ("Tb"."grid")                             (its `ROUND` goes through a double, inexact past 2^53)
# with no precision bound on either: the SQLite form has no slot for it, so binding it would misalign
# every later parameter. A float or decimal operand renders exactly as before.
# ─────────────────────────────────────────────────────────────────────────────
_ifc_inspect(expr; conn) =
  inspect_query((q = IFC.Ifc_result.objects; q.values("x" => expr); q); connection = conn)

@testset "#1196: Round over an integer renders that integer, binding no places" begin
  pg(expr) = _ifc_render(expr; conn = _IFC_PG)
  sl(expr) = _ifc_render(expr; conn = _IFC_SL)
  @test occursin("ROUND((\"Tb\".\"grid\")::numeric)::integer as \"x\"", pg(_IFC_FN.Round("grid")))
  @test occursin("ROUND((\"Tb\".\"laps\")::numeric)::bigint as \"x\"", pg(_IFC_FN.Round("laps")))
  @test occursin("ROUND((\"Tb\".\"resultid\")::numeric)::bigint as \"x\"", pg(_IFC_FN.Round("resultid")))
  @test occursin("ROUND((\"Tb\".\"position\")::numeric)::smallint as \"x\"", pg(_IFC_FN.Round("position")))
  @test occursin(r"SELECT\s+\(\"Tb\"\.\"grid\"\) as \"x\"", sl(_IFC_FN.Round("grid")))
  @test occursin(r"SELECT\s+\(\"Tb\"\.\"laps\"\) as \"x\"", sl(_IFC_FN.Round("laps")))
  @test !occursin("ROUND", sl(_IFC_FN.Round("laps")))
  # Places over an integer: the same SQL, and no parameter at all on either engine.
  for conn in (_IFC_PG, _IFC_SL)
    with_places = _ifc_inspect(_IFC_FN.Round("grid", 2); conn = conn)
    @test with_places[:sql_text] == _ifc_inspect(_IFC_FN.Round("grid"); conn = conn)[:sql_text]
    @test isempty(with_places[:parameters])
  end
  # An integer literal is one too: it keeps its own bound value, and the places are not bound.
  @test occursin("ROUND((\$1::bigint)::numeric)::bigint as \"x\"", pg(_IFC_FN.Round(_IFC_FN.Value(7), 3)))
  @test _ifc_inspect(_IFC_FN.Round(_IFC_FN.Value(7), 3); conn = _IFC_SL)[:parameters] == Any[7]
  # Not an integer to the walk: the places bind and the engine's own `ROUND` renders, as before.
  @test occursin("ROUND((\"Tb\".\"points\")::numeric, \$1::integer) as \"x\"", pg(_IFC_FN.Round("points", 2)))
  @test occursin("ROUND(\"Tb\".\"points\", ?) as \"x\"", sl(_IFC_FN.Round("points", 2)))
  @test occursin("ROUND((\"Tb\".\"price\")::numeric, \$1::integer) as \"x\"", pg(_IFC_FN.Round("price", 1)))
  @test occursin("ROUND(\"Tb\".\"price\", ?) as \"x\"", sl(_IFC_FN.Round("price", 1)))
end

# ─────────────────────────────────────────────────────────────────────────────
# #1196: divided, a rounded integer divides as an integer on both engines
# `Round("grid") / 2` over grid 1 read `0.5` on both engines before #1196 (a `numeric` and a REAL);
# the integer it rounds divides to `0`, as `Floor("grid") / 2` has since #1147. Expected SQL:
#   PostgreSQL  (ROUND(("Tb"."grid")::numeric)::integer / $1::bigint)    parameters [2]
#   SQLite      (("Tb"."grid") / ?)                                      parameters [2]
# The places bind nothing, so the divisor is the only parameter. A sum of a rounded `bigint` is a
# `sum(bigint)`, which PostgreSQL widens to `numeric`, so it renders back to the `bigint` (#1147 step 2).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1196: Round over an integer, divided, is integer division on both engines" begin
  for places in (0, 2)
    pg = _ifc_inspect(_IFC_FN.Round("grid", places) / 2; conn = _IFC_PG)
    sl = _ifc_inspect(_IFC_FN.Round("grid", places) / 2; conn = _IFC_SL)
    @test occursin("(ROUND((\"Tb\".\"grid\")::numeric)::integer / \$1::bigint) as \"x\"", pg[:sql_text])
    @test occursin("((\"Tb\".\"grid\") / ?) as \"x\"", sl[:sql_text])
    @test pg[:parameters] == Any[2]
    @test sl[:parameters] == Any[2]
  end
  @test occursin("(SUM(ROUND((\"Tb\".\"laps\")::numeric)::bigint)::bigint / \$1::bigint) as \"x\"",
                 _ifc_render(_IFC_FN.Sum(_IFC_FN.Round("laps")) / 2; conn = _IFC_PG))
  @test occursin("(SUM((\"Tb\".\"laps\")) / ?) as \"x\"", _ifc_render(_IFC_FN.Sum(_IFC_FN.Round("laps")) / 2; conn = _IFC_SL))
end

# ─────────────────────────────────────────────────────────────────────────────
# #1196: the walk's kind for Round is the rendered type, on both engines
# Over an integer, `_computed_kind(:ROUND)` answers the operand's integer kind on PostgreSQL and
# SQLite's one 64-bit integer there, the types `Dialect.ROUND` renders; over anything else the generic
# `:numeric` answer stands (a width-less `numeric` on PostgreSQL, a REAL on SQLite). The meaning
# (`_output_kind`) is the operand's on both, so the computed kind and the meaning now agree.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1196: Round's computed kind over an integer is that integer" begin
  QB = PormG.QueryBuilder
  ck(k, conn) = QB._computed_kind(Val(:ROUND), QB._result_rule(Val(:ROUND)), k, conn)
  for k in (PormG.CInt16(), PormG.CInt32(), PormG.CInt64())
    @test ck(k, _IFC_PG) == k
    @test ck(k, _IFC_SL) == PormG.CInt64()
  end
  for k in (PormG.CFloat64(), PormG.CDecimal(10, 2), nothing)
    @test ck(k, _IFC_PG) == PormG.CDecimal(nothing, nothing)
    @test ck(k, _IFC_SL) == PormG.CFloat64()
  end
end
