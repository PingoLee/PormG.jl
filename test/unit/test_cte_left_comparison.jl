"""
A `CTE(...)` column handle on the LEFT of a comparison operator (#1529).

`CTE("g", "n")` had no comparison methods, so on the left of an operator it fell through to Base:
`CTE("g", "n") == 5` answered a bare `false` (from `Base.==`), which `filter` then reported, and
`CTE("g", "n") > 5` was a raw `MethodError` from `isless`. That is the #536 defect class, closed then
for `F`, `Joined` and the functions by giving each a comparison family and an `isequal` that stays
total; `CTEReference` got neither. As the right side (`F("x") == CTE(…)`, #444) it already worked.

Pinned here:

  1. Each of the six comparisons builds an `FExpression` whose filter renders the predicate the filter
     pair `"g__n__@<op>" => x` renders, with the same parameters, on PostgreSQL and SQLite, against a
     value and against a column. (`F("g__n")` is no oracle: a `__` path cannot reach a declared CTE
     from an `F`, #492, so the handle is the only operator spelling there is.)
  2. `isequal` stays total, so a handle keys a `Dict` and a `Set`.
  3. An operand outside the comparison vocabulary, `missing` and `desc = true` raise `QueryBuildError`.
  4. A CTE column over a JSON key on the left compares as the key lookup does (#1511), as the pair
     `"g__k__@gt" => 5` does, and refuses a column on its right (#811).

DB-free: mock connections only.

julia --project=test/integration test/unit/test_cte_left_comparison.jl
"""

using Test
using PormG
using PormG.Models

struct CteLeftMockSQLite <: PormG.PormGSQLite end
struct CteLeftMockPostgres <: PormG.PormGPostgres end
const _CLC_SL = CteLeftMockSQLite()
const _CLC_PG = CteLeftMockPostgres()
PormG.backend_sqlite_version(::CteLeftMockSQLite) = 3045000

PormG.config["cte_left_cmp_mock"] = PormG.Configuration.Settings(
  connections = _CLC_PG, change_data = true, db_def_folder = "cte_left_cmp_mock",
)

module CteLeftModels
import PormG
import PormG.Models
# F1-shaped: a result row with points and a JSON document of per-race extras.
Clc_result = Models.Model("clc_result",
  id      = Models.IDField(),
  points  = Models.IntegerField(null = true),
  payload = Models.JSONField(null = true),
)
PormG.Models.set_models(@__MODULE__, "cte_left_cmp_mock")
end
const CLC = CteLeftModels
import PormG.QueryBuilder: inspect_query, CTE

_clc_sql(q, conn) = inspect_query(q; connection = conn)
function _clc_query(cond)
  body = CLC.Clc_result.objects
  body.values("id", "n" => "points", "k" => "payload__n")
  q = CLC.Clc_result.objects
  q.with("g" => body, join_field = "id" => "id", join_type = "INNER")
  q.values("id")
  q.filter(cond)
  return q
end
_clc_where(sql) = strip(split(sql, "WHERE ")[end])
_clc_refusal(f) = Base.CoreLogging.with_logger(() -> (try f(); nothing catch e; e end), Base.CoreLogging.NullLogger())

# ─────────────────────────────────────────────────────────────────────────────
# #1529: each comparison with the handle on the left builds the filter pair's predicate
# Expected: `CTE("g", "n") op x` is an `FExpression` whose left is the handle, and a filter on it renders
# the predicate `"g__n__@<op>" => x` renders, in parentheses, with the same parameters —
# `("R1_1"."n" > $1)` on PostgreSQL — for a value and for a column on the right.
# Why it matters: `filter(CTE("g", "n") == 5)` reported the `false` Base handed it, and `>` was a
# `MethodError`, so the one spelling that disambiguates a colliding CTE name could not sit on the left.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1529: a CTE handle on the left builds the comparison its filter pair builds" begin
  ops = (("==", "g__n", (a, b) -> a == b), ("!=", "g__n__@ne", (a, b) -> a != b),
         (">", "g__n__@gt", (a, b) -> a > b), ("<", "g__n__@lt", (a, b) -> a < b),
         (">=", "g__n__@gte", (a, b) -> a >= b), ("<=", "g__n__@lte", (a, b) -> a <= b))
  for (label, key, cmp) in ops
    node = cmp(CTE("g", "n"), 5)
    @test (label, node isa PormG.QueryBuilder.FExpression) == (label, true)
    @test (label, isequal(node.field_name, CTE("g", "n"))) == (label, true)
    for conn in (_CLC_PG, _CLC_SL), rhs in (5, F("points"))
      got = _clc_sql(_clc_query(cmp(CTE("g", "n"), rhs)), conn)
      ref = _clc_sql(_clc_query(key => rhs), conn)
      tag = (label, nameof(typeof(conn)), rhs isa Int ? "value" : "column")
      # The operator spelling types its parameter on PostgreSQL (`$1::bigint`), as `F("points") > 5`
      # does on a model column, where the pair binds it bare; the predicate is otherwise the pair's.
      @test (tag, occursin("(" * _clc_where(ref[:sql_text]) * ")", replace(got[:sql_text], "::bigint" => ""))) == (tag, true)
      @test (tag, got[:parameters]) == (tag, ref[:parameters])
    end
  end
  @test occursin("(\"R1_1\".\"n\" > \$1::bigint)", _clc_sql(_clc_query(CTE("g", "n") > 5), _CLC_PG)[:sql_text])
  # The same shape as `F` on a model column, which is what the handle replaces.
  @test occursin("(\"R1\".\"points\" > \$1::bigint)", _clc_sql(_clc_query(F("points") > 5), _CLC_PG)[:sql_text])
  # A handle on both sides is a column comparison too.
  @test occursin("\"R1_1\".\"n\" = \"R1_1\".\"id\"",
                 _clc_sql(_clc_query(CTE("g", "n") == CTE("g", "id")), _CLC_PG)[:sql_text])
end

# ─────────────────────────────────────────────────────────────────────────────
# #1529: isequal stays total and the refusals are the F family's
# Expected: `isequal` answers `true` for an equal handle and `false` for anything else without calling
# `==` (so a `Dict` and a `Set` work); an operand outside the comparison vocabulary (`1//2`), `missing`
# and `desc = true` raise `QueryBuildError`, as `F` and `Joined` do.
# Why it matters: once `==` builds a predicate, the generic `isequal` fallback would throw a `TypeError`
# inside `Dict`/`Set`, and an unsupported operand must not answer `false` again.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1529: isequal stays total; unsupported operands and desc are refused" begin
  c = CTE("g", "n")
  @test isequal(c, CTE("g", "n"))
  @test !isequal(c, CTE("g", "k"))
  @test !isequal(c, "g__n") && !isequal(c, 5) && !isequal(c, missing)
  @test length(Set([c, CTE("g", "n"), CTE("g", "k")])) == 2
  @test Dict(c => 1)[CTE("g", "n")] == 1
  @test length(unique([c, CTE("g", "n")])) == 1   # `==` on a Vector reaches `==` and builds (#541)
  for bad in (() -> c == 1 // 2, () -> c > 1 // 2, () -> c == missing, () -> c < missing,
              () -> CTE("g", "n"; desc = true) > 5)
    @test _clc_refusal(bad) isa PormG.QueryBuildError
  end
  @test occursin("desc = true", PormG._emsg(sprint(showerror, _clc_refusal(() -> CTE("g", "n"; desc = true) == 5)); color = false))
end

# ─────────────────────────────────────────────────────────────────────────────
# #1529: a CTE column over a JSON key on the left compares as the key lookup does
# Expected: `CTE("g", "k") > 5` renders and binds as the pair `"g__k__@gt" => 5` (the #1511 key
# comparison: `::numeric` on PostgreSQL, the native value on SQLite), and a column on its right raises
# #811's `FilterError`, as the pair `"g__k__@gt" => F("points")` does.
# Why it matters: the new left side must reach the key path the string spelling reaches, or the two
# spellings of one comparison would bind differently.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1529: a CTE column over a JSON key on the left compares as the key lookup" begin
  for conn in (_CLC_PG, _CLC_SL)
    got = _clc_sql(_clc_query(CTE("g", "k") > 5), conn)
    ref = _clc_sql(_clc_query("g__k__@gt" => 5), conn)
    @test occursin("(" * _clc_where(ref[:sql_text]) * ")", got[:sql_text])
    @test got[:parameters] == ref[:parameters]
    e = _clc_refusal(() -> _clc_sql(_clc_query(CTE("g", "k") > F("points")), conn))
    @test e isa PormG.FilterError
    @test _clc_refusal(() -> _clc_sql(_clc_query("g__k__@gt" => F("points")), conn)) isa PormG.FilterError
  end
  @test occursin("::numeric > \$1", _clc_sql(_clc_query(CTE("g", "k") > 5), _CLC_PG)[:sql_text])
end
