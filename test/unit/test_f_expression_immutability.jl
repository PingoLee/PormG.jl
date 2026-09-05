"""
Unit coverage for #457 — an `F` comparison builds a new expression and never mutates its operand.

Until this, the six comparison overloads (`== != > < >= <=`) wrote `operation`/`operand` onto the
LEFT-hand `FExpression` and returned that same object whenever `f.operation === nothing`. Arithmetic
(`+ - * /`) never did. That asymmetry cost two distinct defects, and both are covered here:

  - **A self-cycle → StackOverflowError.** `f = F("sku"); g = (f == f)` stored `f` on `f`, so
    `g.operand === g`. Every recursive walker over the expression then ran forever. On the `on()` /
    `cjoin()` route the first one reached is the custom `Base.deepcopy(::FExpression)`: the depth-capped
    handle sweep in `_prefix_join_filter` runs first and returns cleanly, and the `deepcopy` on the very
    next line is what overflows — so the guard was reached and simply was not the thing that could help.
    `.filter(...)` overflowed in the render walker instead. Julia reports either as *"program state may
    be corrupted"*, from a spelling ordinary user code can write.
  - **Silent wrong SQL from a reused handle.** `f = F("note"); f > "a"; f < "z"` rendered
    `(("note" > ?) < ?)`: the second comparison found the operation the first had written and nested
    it. A handle bound to a name was single-use, and nothing in the API said so.

The fix is a shape change, not a guard: comparisons return a new expression, exactly as arithmetic
already did, which makes THIS cycle **unrepresentable** rather than caught. That follows the prior
art — Django's `Combinable`, SQLAlchemy's `ClauseElement`, Ecto's query AST, jOOQ and peewee all
build a new node and leave the operand untouched, and none of them carries a depth guard for it.

Scope, precisely: what is gone is the F-expression SELF-cycle. A user can still build a CONTAINER
cycle from exported spellings — `q = Q("x" => 1); push!(q, q)` — which is why the depth cap in
`_guard_no_handle` (`ctes.jl`) stays and is not dead weight.

Everything renders through mock connections — no live database.

Sibling coverage:
  - `test_cte_reference.jl` → the `_guard_no_handle` depth cap, which survives #457 for the one route
                              left: `FExpression` is mutable, so an internal `g.operand = g` is still
                              one assignment away. Its testset hand-builds the cycle now.
  - `test_alignment_sqlite.jl` → parameter ordering for the predicates built here.
"""

using Test
using PormG
using PormG.Models

# Mock connections under a dedicated config key so this file cannot contaminate (or be contaminated
# by) other unit files sharing Main in runtests.jl. Only the connection TYPE matters — dispatch picks
# SQLite `?` / PostgreSQL `$N` rendering.
struct FImmutMockSQLite <: PormG.PormGSQLite end
struct FImmutMockPostgres <: PormG.PormGPostgres end
const _FI_SL = FImmutMockSQLite()
const _FI_PG = FImmutMockPostgres()
PormG.backend_sqlite_version(::FImmutMockSQLite) = 3045000

PormG.config["f_immut_mock"] = PormG.Configuration.Settings(
  connections = _FI_SL,
  change_data = true,
  db_def_folder = "f_immut_mock",
)

# The #457 reproduction fixture, verbatim from the issue body: a parent/child pair with a nullable
# ForeignKey, so `on(...)` and `cjoin(...)` both have a relation to hang a predicate on.
module FImmutModels
import PormG
import PormG.Models

Fi_parent = Models.Model("fi_parent",
  id  = Models.IDField(),
  sku = Models.CharField(),
)

Fi_child = Models.Model("fi_child",
  id     = Models.IDField(),
  parent = Models.ForeignKey(Fi_parent, on_delete = "CASCADE", related_name = "fi_kids", null = true),
  note   = Models.CharField(null = true),
)

PormG.Models.set_models(@__MODULE__, "f_immut_mock")
end

const FI = FImmutModels
import PormG.QueryBuilder: F, FExpression, inspect_query

_fi_sql(q; conn = _FI_SL)    = inspect_query(q; connection = conn)[:sql_text]
_fi_params(q; conn = _FI_SL) = inspect_query(q; connection = conn)[:parameters]

@testset "F comparison immutability (#457)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # Every comparison operator returns a NEW expression and leaves the handle pristine.
  # This is the root-cause assertion: both defects below are consequences of the six overloads
  # writing onto their left operand. Checked per operator, since they were six copy-pasted bodies.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "each of the six operators leaves its operand untouched" begin
    for (op, sql_op) in ((==, "="), (!=, "!="), (>, ">"), (<, "<"), (>=, ">="), (<=, "<="))
      f = F("note")
      built = op(f, "x")

      # The handle is not the result, and still carries no operation of its own.
      @test built !== f
      @test f.operation === nothing
      @test f.operand === nothing

      # The built expression is the comparison the caller asked for, over the handle's column.
      @test built isa FExpression
      @test built.operation == sql_op
      @test built.operand == "x"
      @test built.field_name isa String && built.field_name == "note"
      @test built.column == "note"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Every slot survives the rebuild, including the three a public `F(...)` handle cannot vary.
  # `_compare` promises to carry the handle's other fields across unchanged, but `F(::String)` always
  # yields `aggregate=false, _as=nothing, kwargs=Dict()` — so dropping any of those three would render
  # identically in every test above and go unnoticed. Build a handle with all eight slots non-default
  # and check the rebuild field by field.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "the rebuilt expression carries every slot of the handle" begin
    for (op, sql_op) in ((==, "="), (!=, "!="), (>, ">"), (<, "<"), (>=, ">="), (<=, "<="))
      handle = PormG.QueryBuilder.FExpression(
        field_name = "points", operation = nothing, operand = nothing,
        function_name = "WEIRD", column = "points_col", aggregate = true,
        _as = "an_alias", kwargs = Dict{String,Any}("k" => 1),
      )
      built = op(handle, 3)

      # The two slots the comparison sets.
      @test built.operation == sql_op
      @test built.operand == 3
      # The six it must carry across untouched.
      @test built.field_name isa String && built.field_name == "points"
      @test built.function_name == "WEIRD"
      @test built.column == "points_col"
      @test built.aggregate == true
      @test built._as == "an_alias"
      @test built.kwargs == Dict{String,Any}("k" => 1)

      # `kwargs` is copied, not shared, so a later build writing into one cannot reach the handle.
      @test built.kwargs !== handle.kwargs
      # And the handle itself is still a bare handle.
      @test handle.operation === nothing
      @test handle.operand === nothing
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # An expression that ALREADY carries an operation still nests, rather than being flattened.
  # `_compare`'s two branches are behaviourally different and only the first one changed; this pins
  # the second so a future simplification cannot collapse `(F("id") + 1) == 5` into a wrong shape.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a comparison over a composed expression nests it" begin
    nested = (F("id") + 1) == 5

    @test nested.operation == "="
    @test nested.operand == 5
    # The whole arithmetic expression became the left-hand side, not just its column.
    @test nested.field_name isa FExpression
    @test nested.field_name.operation == "+"
    @test nested.column == ""
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `f == f` is not a cycle any more, and renders as an ordinary tautology.
  # THE test for this issue. Pre-#457 each of these three routes was a StackOverflowError that took
  # the session down with it — so a regression here does not fail politely, it kills the process.
  # `sku = sku` is what SQLAlchemy and Django emit for the same input; PormG matches them.
  #
  # Every route below is handed the SAME `g` built from ONE handle compared with ITSELF. That is
  # load-bearing and easy to get wrong: spelling it `F("sku") == F("sku")` inline builds TWO distinct
  # handles, which never cycled even under the old mutating overloads (the left one simply stored the
  # right one), so those assertions would pass against the very bug this testset exists to catch.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a self-comparison builds no cycle and renders on every route" begin
    f = F("sku")
    g = (f == f)

    # The structural claim, without which the routes below prove nothing about cycles.
    # Note WHERE the cycle was broken: the right operand is still the very handle that was passed in
    # (`g.operand === f`), and it does not need to be a copy. What changed is that the RESULT is a
    # new object, so the thing holding `f` is no longer `f` — `g.operand === g` was the cycle, and
    # that is what is now impossible. Asserting `g.operand !== f` would be asserting a copy the fix
    # does not make and does not need.
    @test g !== f
    @test g.operand === f
    @test g.operand !== g
    @test g.operand isa FExpression
    @test f.operation === nothing    # and the handle came through the comparison unchanged

    # Route 1 — `on()`, the spelling the issue reports. The predicate is forced onto the joined
    # model, so BOTH sides resolve to the FK's alias.
    q_on = FI.Fi_child.objects
    q_on.on("parent", g)
    q_on.values("id", "parent__sku")
    sql_on = _fi_sql(q_on)
    @test occursin("JOIN \"fi_parent\"", sql_on)
    @test occursin(r"\"Tb_1\"\.\"sku\" = \"Tb_1\"\.\"sku\"", sql_on)

    # Route 2 — `cjoin()`, the issue's second acceptance item. Same helper, same refusal surface.
    q_cj = FI.Fi_child.objects
    q_cj.cjoin("parent" => "Fi_parent", filters = [g], warn = false)
    q_cj.values("id")
    @test occursin(r"\"Tb_1\"\.\"sku\" = \"Tb_1\"\.\"sku\"", _fi_sql(q_cj))

    # Route 3 — `filter()`. Not named in the issue, but it accepted the cycle and overflowed at
    # RENDER time, which is why the fix had to be in the expression rather than in the join guards.
    q_fl = FI.Fi_parent.objects
    q_fl.filter(g)
    @test occursin(r"\"Tb\"\.\"sku\" = \"Tb\"\.\"sku\"", _fi_sql(q_fl))

    # One `g` went through all three builds and came out unchanged — the routes consume the
    # expression, they do not claim it.
    @test g.operand === f
    @test f.operation === nothing
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A handle bound to a name survives being compared, and yields independent predicates.
  # The silent half of #457: pre-fix the second comparison nested the first, rendering
  # `(("note" > ?) < ?)` — one wrong predicate and one dropped, with no error anywhere.
  # Asserted on BOTH dialects, since the bug is in the expression and must be gone from each.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a reused handle yields independent predicates" begin
    pts = F("note")

    q = FI.Fi_child.objects
    q.filter(pts > "a", pts < "z")

    sql_sl = _fi_sql(q)
    # Two separate predicates over the bare column — NOT one nested inside the other.
    @test occursin(r"\"Tb\"\.\"note\" > \?", sql_sl)
    @test occursin(r"\"Tb\"\.\"note\" < \?", sql_sl)
    @test _fi_params(q) == Any["a", "z"]

    # PostgreSQL renders `$N`; the same two predicates, the same two bound values, in text order.
    sql_pg = _fi_sql(q; conn = _FI_PG)
    @test occursin(r"\"Tb\"\.\"note\" > \$1", sql_pg)
    @test occursin(r"\"Tb\"\.\"note\" < \$2", sql_pg)
    @test _fi_params(q; conn = _FI_PG) == Any["a", "z"]

    # Reuse across two SEPARATE queries is the same claim from the other direction: the first query
    # must not have consumed the handle.
    q1 = FI.Fi_child.objects; q1.filter(pts > "a")
    q2 = FI.Fi_child.objects; q2.filter(pts < "z")
    @test _fi_params(q1) == Any["a"]
    @test _fi_params(q2) == Any["z"]
    @test occursin(r"\"Tb\"\.\"note\" < \?", _fi_sql(q2))
    @test !occursin(">", _fi_sql(q2))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Control: legitimately nested F arithmetic still resolves (acceptance item 3 of the issue).
  # A depth-cap fix could have satisfied the cycle tests while silently truncating this; the shape
  # fix cannot, and this is what says so.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "nested F arithmetic still resolves" begin
    q = FI.Fi_parent.objects
    q.values("id", "calc" => F("id") + F("id") * 2)

    sql = _fi_sql(q)
    @test occursin(r"\(\"Tb\"\.\"id\" \+ \(\"Tb\"\.\"id\" \* \?\)\)", sql)
    @test _fi_params(q) == Any[2]

    # Arithmetic was already non-mutating; pinned here so the two families cannot drift apart again.
    h = F("id")
    _ = h + 1
    @test h.operation === nothing
  end

end
