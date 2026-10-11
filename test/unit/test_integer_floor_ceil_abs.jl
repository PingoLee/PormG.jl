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
  @test occursin("CEIL(((\"Tb\".\"grid\" + \$1::bigint))::numeric) as \"x\"", pg(_IFC_FN.Ceil(_IFC_F("grid") + 1)))
  # `Sum` of a `bigint` is a `numeric` on PostgreSQL, so `Floor` over it keeps the cast.
  @test occursin("FLOOR((SUM(\"Tb\".\"laps\"))::numeric) as \"x\"", pg(_IFC_FN.Floor(_IFC_FN.Sum("laps"))))
  @test occursin("FLOOR((SUM(\"Tb\".\"grid\"))::numeric)::bigint as \"x\"", pg(_IFC_FN.Floor(_IFC_FN.Sum("grid"))))
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
