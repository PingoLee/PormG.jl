# ============================================================
# test/unit/test_sqlorder_orientation.jl
#
# SQLOrder orientation whitelist (#77).
#
# CONTRACT being tested:
#   `SQLOrder.orientation` is interpolated into the rendered ORDER BY clause, so every
#   construction path (keyword constructor, positional constructor, deepcopy) must whitelist
#   the direction to ASC/DESC — case/whitespace-insensitive, stored uppercase. An
#   injection-shaped direction (e.g. "ASC; DROP TABLE drivers --") must raise ArgumentError
#   at construction and never reach SQL rendering. The documented string API
#   (.order_by("-field")) already normalizes before construction and is unaffected.
#
# Deterministic, DB-free constructor tests. Mutation gate: reverting the inner-constructor
# whitelist in querybuilder/types.jl (#77) lets the payload construct successfully and flow
# verbatim into ORDER BY, so every rejection assertion below fails.
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
    # Positional path (the one deepcopy delegates to) normalizes identically.
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
      # Positional constructor (deepcopy's path) is guarded by the same whitelist.
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
  # deepcopy re-runs the positional constructor; a valid order must survive the round-trip
  # unchanged (the whitelist re-validates an already-normalized value harmlessly).
  # ───────────────────────────────────────────────────────────────────────────
  @testset "deepcopy of a valid SQLOrder survives re-validation" begin
    o = SQLOrder(SQLField("surname", "surname"); orientation="desc", nulls=:first)
    c = deepcopy(o)
    @test c.orientation == "DESC"
    @test c.nulls === :first
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Render-time guard: SQLOrder is mutable, so a post-construction reassignment bypasses the
  # constructor whitelist. get_order_query re-validates before interpolation, so the payload
  # still raises instead of reaching SQL — mirroring the window path's render-time check.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "post-construction mutation is caught at render time" begin
    # Construct validly, then smuggle the payload past the constructor by direct mutation.
    o = SQLOrder(SQLField("surname", "surname"); orientation="ASC")
    o.orientation = "ASC; DROP TABLE drivers --"

    q = DriverOrientModel.objects
    q.order_by(o)
    # Rendering must raise — never emit the payload into the SQL string.
    err = try
      q.list(show_query=:sql)
      nothing
    catch e
      e
    end
    @test err isa PormGError
    @test occursin("DESC", string(err))   # the whitelist error, naming the valid options

    # Sanity (negative case): the same query shape with a valid order renders fine.
    q_ok = DriverOrientModel.objects
    q_ok.order_by(SQLOrder(SQLField("surname", "surname"); orientation="ASC"))
    sql = q_ok.list(show_query=:sql)
    @test occursin("ORDER BY", sql)
    @test occursin("ASC", sql)
  end

end
