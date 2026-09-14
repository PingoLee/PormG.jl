# ============================================================
# test/unit/test_sqlorder_orientation.jl
#
# SQLOrder orientation whitelist (#77).
#
# CONTRACT being tested:
#   `SQLOrder.orientation` is interpolated into the rendered ORDER BY clause, so every
#   construction path (keyword constructor, positional constructor) must whitelist the
#   direction to ASC/DESC — case/whitespace-insensitive, stored uppercase. An injection-shaped
#   direction (e.g. "ASC; DROP TABLE drivers --") must raise a `PormGError` at construction and
#   never reach SQL rendering. Since #540 `SQLOrder` is an immutable `struct`, so construction is
#   the ONLY time an orientation is ever set: there is no post-construction write to guard
#   against, and the render-time re-validation that existed for that case is gone. The
#   documented string API (.order_by("-field")) already normalizes before construction and is
#   unaffected.
#
# Deterministic, DB-free constructor tests. Mutation gate: reverting the inner-constructor
# whitelist in querybuilder/types.jl (#77) lets the payload construct successfully and flow
# verbatim into ORDER BY, so every rejection assertion below fails; reverting the `struct`
# (#540) lets the `setfield!` assertion below store a payload instead of throwing.
# ============================================================

using Test
using PormG
using PormG.Models: Model, IDField, CharField
using PormG.QueryBuilder: SQLField, SQLOrder

# ── Mock backend for full-render tests ──────────────────────────────────────────────────────
# A mock PostgreSQL marker (no DB round-trip), mirroring the pattern in test_order_by_nulls.jl,
# so the render-time guard can be exercised through the public order_by/list(show_query=:sql) path.
struct MockPG_OrientGuard <: PormG.PormGPostgres end

DriverOrientModel = Model("drivers_orientation",
  id = IDField(),
  surname = CharField(),
)
DriverOrientModel.connect_key = "orientation_guard_pg"
PormG.config["orientation_guard_pg"] = PormG.Configuration.Settings(
  connections = MockPG_OrientGuard(),
  change_data = true,
)

@testset "SQLOrder orientation whitelist (#77)" begin

  # ───────────────────────────────────────────────────────────────────────────
  # Valid directions construct and are stored normalized (uppercased, trimmed), so the
  # renderer only ever interpolates the literal tokens ASC or DESC.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "valid orientations normalize to uppercase" begin
    @test SQLOrder(SQLField("surname", "surname"); orientation="ASC").orientation == "ASC"
    @test SQLOrder(SQLField("surname", "surname"); orientation="DESC").orientation == "DESC"
    @test SQLOrder(SQLField("surname", "surname"); orientation="asc").orientation == "ASC"      # case-insensitive
    @test SQLOrder(SQLField("surname", "surname"); orientation=" Desc ").orientation == "DESC"  # whitespace-tolerant
    # Positional path normalizes identically.
    @test SQLOrder(SQLField("surname", "surname"), nothing, "desc", "surname", nothing).orientation == "DESC"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Injection-shaped directions are rejected at construction — on the keyword AND the
  # positional path — never reaching SQL. This is the #77 acceptance criterion.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "injection-shaped orientations raise at construction" begin
    for bad in ("ASC; DROP TABLE drivers --", "DESC --", "ASC, (SELECT 1)", "")
      # Keyword constructor (the direct-construction path the issue flags).
      @test_throws PormGError SQLOrder(SQLField("surname", "surname"); orientation=bad)
      # Positional constructor is guarded by the same whitelist.
      @test_throws PormGError SQLOrder(SQLField("surname", "surname"), nothing, bad, "surname", nothing)
    end

    # The rejection must fail loudly and name the valid options — not silently default.
    # ("DESC" is the discriminating check: the injected payload itself contains "ASC".)
    err = try
      SQLOrder(SQLField("surname", "surname"); orientation="ASC; DROP TABLE drivers --")
      nothing
    catch e
      e
    end
    @test err isa PormGError
    @test occursin("ASC", string(err))
    @test occursin("DESC", string(err))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # deepcopy goes through Base's generic path since #540 — the hand-written method that re-ran
  # the whitelist is gone, because a frozen struct cannot hold an invalid orientation in the
  # first place. A valid order must survive the round-trip with every slot intact, and the copy
  # must not share the mutable `SQLField` (the #112 copy discipline, now satisfied by Base).
  # ───────────────────────────────────────────────────────────────────────────
  @testset "deepcopy of a valid SQLOrder preserves its slots through Base's generic path" begin
    o = SQLOrder(SQLField("surname", "surname"); orientation="desc", nulls=:first)
    c = deepcopy(o)
    @test c.orientation == "DESC"
    @test c.nulls === :first
    @test c.field.field == "surname"
    @test c.field !== o.field
  end

  # ───────────────────────────────────────────────────────────────────────────
  # #540 — a post-construction reassignment is UNREPRESENTABLE: `SQLOrder` is an immutable struct,
  # so the payload that used to be smuggled past the constructor by direct mutation now fails at
  # the assignment itself. That is what let #540 delete the render-time re-validation in
  # `get_order_query`: there is no second writer to guard against. The negative case (a valid
  # order renders) stays, proving the deletion removed a guard and not the rendering.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "post-construction mutation is unrepresentable (#540)" begin
    @test !ismutabletype(SQLOrder)
    o = SQLOrder(SQLField("surname", "surname"); orientation="ASC")
    # `setfield!` on an immutable struct throws — the payload never lands, in the node or in SQL.
    @test_throws ErrorException (o.orientation = "ASC; DROP TABLE drivers --")
    @test o.orientation == "ASC"

    # Sanity (negative case): the same query shape with a valid order renders fine.
    q_ok = DriverOrientModel.objects
    q_ok.order_by(SQLOrder(SQLField("surname", "surname"); orientation="ASC"))
    sql = q_ok.list(show_query=:sql)
    @test occursin("ORDER BY", sql)
    @test occursin("ASC", sql)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # #540 — `last()` inverts an ordering term by CONSTRUCTING a new one. `_invert_order` flips the
  # direction and any EXPLICIT NULLS placement (`:first` ↔ `:last`; an unset `nothing` stays unset
  # so the renderer keeps its orientation-derived default), and leaves the caller's term untouched
  # — the property that makes freezing the struct safe for the one path that used to write into it.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "_invert_order constructs the reversed term (#540)" begin
    QB = PormG.QueryBuilder
    o = SQLOrder(SQLField("surname", "surname"); orientation="ASC", nulls=:first)
    r = QB._invert_order(o)
    @test r.orientation == "DESC"
    @test r.nulls === :last
    @test r.field === o.field           # the field rides across by reference, not re-parsed
    # The original is untouched — it is a value the caller may still hold.
    @test o.orientation == "ASC"
    @test o.nulls === :first

    # Both directions, both placements, and `nothing` stays `nothing`.
    d = SQLOrder(SQLField("surname", "surname"); orientation="DESC", nulls=:last)
    @test QB._invert_order(d).orientation == "ASC"
    @test QB._invert_order(d).nulls === :first
    @test QB._invert_order(SQLOrder(SQLField("surname", "surname"); orientation="ASC")).nulls === nothing
    # Involution: inverting twice is the identity on every slot.
    rr = QB._invert_order(QB._invert_order(o))
    @test rr.orientation == o.orientation && rr.nulls === o.nulls
    # A non-SQLOrder ordering term passes through untouched (best effort, as before).
    @test QB._invert_order("surname") == "surname"

    # Through the public surface: `last()` renders the inverted term — ASC NULLS FIRST becomes
    # DESC NULLS LAST — while the caller's own query keeps the order it declared (`last()` copies).
    q = DriverOrientModel.objects
    q.order_by(o)
    sql = q.last(show_query=:sql)
    @test occursin("DESC", sql)
    @test occursin("NULLS LAST", sql)
    @test !occursin("NULLS FIRST", sql)
    @test q.object.order[1].orientation == "ASC"
    @test q.object.order[1].nulls === :first
  end

end
