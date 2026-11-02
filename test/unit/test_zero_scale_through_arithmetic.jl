"""
A zero-scale decimal stays whole through `+`, `-`, `*` and through a `Case` or `Coalesce` (#1550).

`DecimalField(max_digits = 4, decimal_places = 0)` holds whole numbers on every engine: SQLite stores
them as INTEGER, PostgreSQL and MySQL keep scale 0, and `grid + 1`, `grid * 2` stay whole there. Used
directly, `Concat` over `F("grid") + 1` and `Cast(F("grid") + 1, "numeric(10,0)")` build on every
engine. The type walk dropped the places through arithmetic and `Case` (`CDecimal(nothing, nothing)`),
so the same value projected through a CTE column was read as a decimal with places and refused: by
`Concat` on all three engines (#1027) and by the scale check on SQLite (#1040).

The walk now keeps scale 0 through `+`, `-`, `*` of whole operands and through a `Case`/`Coalesce`
whose values agree on their places. Any other scale is still dropped through arithmetic: SQLite
computes it as a REAL, where `0.1 + 0.2` gains digits.

Everything renders through mock connections — no live database, no fixture.

julia -O0 --project=test/integration test/unit/test_zero_scale_through_arithmetic.jl
"""

using Test
using Decimals
using PormG
using PormG.Models
using PormG.QueryBuilder: inspect_query, F
import PormG: QueryBuildError

struct ZsaMockSQLite <: PormG.PormGSQLite end
struct ZsaMockPostgres <: PormG.PormGPostgres end
struct ZsaMockMySQL <: PormG.PormGMySQL end
const _ZSA_SL = ZsaMockSQLite()
const _ZSA_PG = ZsaMockPostgres()
const _ZSA_MY = ZsaMockMySQL()
const _ZSA_ENGINES = (_ZSA_PG, _ZSA_SL, _ZSA_MY)
PormG.backend_sqlite_version(::ZsaMockSQLite) = 3045000

PormG.config["zsa_mock"] = PormG.Configuration.Settings(
  connections = _ZSA_SL, change_data = true, db_def_folder = "zsa_mock",
)

# The F1 shape of #1550's repro: `grid` declared as a zero-scale decimal, `price` with two places.
module ZsaModels
import PormG
import PormG.Models
Race = Models.Model("zsa_race", id = Models.IDField(), name = Models.CharField())
Result = Models.Model("zsa_result",
  id     = Models.IDField(),
  raceid = Models.ForeignKey(Race, on_delete = "CASCADE"),
  grid   = Models.DecimalField(max_digits = 4, decimal_places = 0, null = true),
  price  = Models.DecimalField(max_digits = 10, decimal_places = 2, null = true),
  fee    = Models.DecimalField(max_digits = 12, decimal_places = 2, null = true),
  laps   = Models.IntegerField(null = true),
)
PormG.Models.set_models(@__MODULE__, "zsa_mock")
end

const ZSA = ZsaModels
const ZFn = PormG.Functions

# `outer(CTE("tc", "v"))` projected over a CTE whose column `v` is `inner`.
function _zsa_cte(inner, outer)
  s = ZSA.Result.objects
  s.values("raceid", "v" => inner)
  q = ZSA.Race.objects
  q.with("tc" => s, join_field = "id" => "raceid")
  q.values("name", "o" => outer(PormG.CTE("tc", "v")))
  return q
end
_zsa_direct(e) = (q = ZSA.Result.objects; q.values("o" => e); q)
_zsa_build(q, conn) = inspect_query(q; connection = conn)[:sql_text]
_zsa_error(q, conn) = try _zsa_build(q, conn); nothing catch e; e end
# The type walk's answer for `e`, asked as the expression-kind matrix asks it: of the projected node,
# after the build resolved its paths (the walk reads the memo that fills).
function _zsa_kind(e; conn = _ZSA_PG)
  QB = PormG.QueryBuilder
  instr = QB.build(_zsa_direct(e).object; connection = conn)
  v = only(filter(v -> QB._projection_output_name(v) == "o", instr.object.values))
  return QB._expression_kind(v isa QB.SQLTypeText ? v : v.field, instr)
end

# ─────────────────────────────────────────────────────────────────────────────
# Expected: `Concat(Value("v="), CTE("tc", "v"))` over `v = F("grid") + 1` (and `* 2`, `grid + laps`,
# an undeclared `Case` whose branches are `grid` and `0`) builds on PostgreSQL, SQLite and MySQL —
# `CONCAT($1::text, "tc"."v")` / `COALESCE(?, '') || COALESCE("tc"."v", '')` / `CONCAT_WS('', ?, …)` —
# as the same expression does directly. Before #1550 the CTE column was refused with #1027 ("the
# DecimalField `CTE("tc", "v")` is not text"). Why it matters: a CTE column answers what its body's
# expression answers; refusing it there and not directly is a false refusal of a whole number.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1550: Concat over a CTE column of zero-scale arithmetic builds, as it does directly" begin
  concat(x) = ZFn.Concat(ZFn.Value("v="), x)
  for inner in (F("grid") + 1, F("grid") * 2, F("grid") - 3, F("grid") + F("laps"),
                ZFn.Case(ZFn.When("laps__@gt" => 0, then = F("grid")), default = 0),
                ZFn.Coalesce("grid", "laps")), conn in _ZSA_ENGINES
    @test _zsa_error(_zsa_direct(concat(inner)), conn) === nothing
    @test _zsa_error(_zsa_cte(inner, concat), conn) === nothing
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Expected: `Cast(CTE("tc", "v"), "numeric(10,0)")` over `v = F("grid") + 1` builds on SQLite
# (`CAST("tc"."v" AS NUMERIC(10,0))`), as `Cast(F("grid") + 1, "numeric(10,0)")` does. Before #1550,
# SQLite refused it as the cast's rounding (#1040: "means the value rounded to the scale of
# numeric(10,0); SQLite computes every digit of it") although the value is whole and nothing rounds.
# PostgreSQL and MySQL built it before and still do. Why it matters: #1040 guards a fraction a cast
# rounds away on one engine only; a whole number has none.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1550: a zero-scale cast of a CTE column of whole arithmetic builds on SQLite" begin
  cast(x) = ZFn.Cast(x, "numeric(10,0)")
  for conn in _ZSA_ENGINES
    @test _zsa_error(_zsa_direct(cast(F("grid") + 1)), conn) === nothing
    @test _zsa_error(_zsa_cte(F("grid") + 1, cast), conn) === nothing
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Expected: a decimal WITH places stays refused, directly and through a CTE: `Concat` over
# `F("price") + 1` raises #1027 on every engine, and over a `Case` mixing `grid` (scale 0) with
# `price` (scale 2) too. Why it matters: only a whole value is whole — the fix must not turn a decimal
# with a fraction into one, nor let arithmetic promise places SQLite's REAL does not keep.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1550: a decimal with places is still refused, through arithmetic and a mixed Case" begin
  concat(x) = ZFn.Concat(ZFn.Value("v="), x)
  for inner in (F("price") + 1, F("grid") * F("price"),
                ZFn.Case(ZFn.When("laps__@gt" => 0, then = F("grid")), default = F("price"))), conn in _ZSA_ENGINES
    @test _zsa_error(_zsa_cte(inner, concat), conn) isa QueryBuildError
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Expected: the type walk names `F("grid") + 1`, `* 2` and `+ laps` `CDecimal(nothing, 0)`, a `Case`
# over `grid` and an integer `CDecimal(nothing, 0)`, and `F("price") + 1` and `F("grid") / 2`
# `CDecimal(nothing, nothing)`. No SQL. Why it matters: the walk is the one answer to "what type is
# this?" (#1034); the classifiers above read it, and a reader that trusted the old answer refused a
# whole number (#1484's review found one).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1550: the type walk keeps scale 0 through whole arithmetic and an agreeing Case" begin
  QB = PormG.QueryBuilder
  kind(e) = _zsa_kind(e)
  whole = QB.CDecimal(nothing, 0)
  @test kind(F("grid") + 1) == whole
  @test kind(F("grid") * 2) == whole
  @test kind(F("grid") + F("laps")) == whole
  @test kind(ZFn.Case(ZFn.When("laps__@gt" => 0, then = F("grid")), default = 0)) == whole
  @test kind(F("price") + 1) == QB.CDecimal(nothing, nothing)
  @test kind(F("grid") / 2) == QB.CDecimal(nothing, nothing)
  @test kind(ZFn.Case(ZFn.When("laps__@gt" => 0, then = F("grid")), default = F("price"))) == QB.CDecimal(nothing, nothing)
end

# ─────────────────────────────────────────────────────────────────────────────
# Expected: a `Case` over two decimals that agree on their places but not their precision (`price`
# `(10,2)`, `fee` `(12,2)`) is `CDecimal(nothing, 2)`, so a CTE column over it casts to `numeric(10,2)`
# on SQLite (`CAST("tc"."v" AS NUMERIC(10,2))`, nothing to round: each row is one of the two columns'
# values), as the `Case` does directly; to `numeric(10,1)` it is still refused there (#1040), and a `Case`
# mixing places (`grid` with `price`) is still width-less. Why it matters: `_unify_decimals` claims a
# scale only where every branch has it, and the scale check must keep refusing a cast that rounds.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1550: a Case over decimals that agree on their places keeps them" begin
  QB = PormG.QueryBuilder
  agree() = ZFn.Case(ZFn.When("laps__@gt" => 0, then = F("price")), default = F("fee"))
  @test _zsa_kind(agree()) == QB.CDecimal(nothing, 2)
  @test _zsa_kind(ZFn.Case(ZFn.When("laps__@gt" => 0, then = F("grid")), default = F("price"))) == QB.CDecimal(nothing, nothing)
  cast(type) = x -> ZFn.Cast(x, type)
  @test _zsa_error(_zsa_direct(cast("numeric(10,2)")(agree())), _ZSA_SL) === nothing
  @test _zsa_error(_zsa_cte(agree(), cast("numeric(10,2)")), _ZSA_SL) === nothing
  err = _zsa_error(_zsa_cte(agree(), cast("numeric(10,1)")), _ZSA_SL)
  @test err isa QueryBuildError && occursin("(#1040)", sprint(showerror, err))
end
