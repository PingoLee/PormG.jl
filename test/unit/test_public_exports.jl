# ==============================================================================
# UNIT TESTS: Public export surface (pre-publish · issue #35)
#
# Pin the *curated* public API so the surface can't silently regrow. `using PormG`
# must bring exactly the documented top-level names — and NONE of the SQL function
# constructors, which live in `PormG.Functions` to avoid flooding `Main` and colliding
# with `Base`. The documented list lives in docs/src/api.md ("Exported Symbols"); this
# test is the machine-checked counterpart. Adding/removing a public name is a deliberate
# contract change that must update BOTH this set and api.md.
#
# Runs WITHOUT a live database — it only inspects module namespaces.
# ==============================================================================

using Test
using PormG

# The frozen top-level surface of `using PormG` (must match docs/src/api.md exactly).
const EXPECTED_TOPLEVEL = Set([
    # Query builder
    :object, :get, :Q, :Qor, :F, :Exists, :OuterRef, :Subquery, :Interval, :show_query, :inspect_query,
    # Rows & exceptions
    :PormGRow, :pk, :DoesNotExist, :MultipleObjectsReturned, :PoolTimeoutError, :PoolConnectError, :pool_stats,
    # Bulk operations
    :bulk_insert, :bulk_update, :bulk_copy, :allocate_primary_keys,
    # Async API
    :fetch_async, :await_result, :FetchTask,
    # Transactions
    :run_in_transaction, :atomic, :with_savepoint, :with_tx_context, :in_transaction_context,
    # Locking
    :with_advisory_lock,
    # Utilities & lifecycle
    :setup, :install_ai_skills, :upgrade_guide, :tui, :register_ignore_tables!,
    Symbol("@import_models"), Symbol("@models_module"), Symbol("@pormg_debug"),
])

# The SQL function library, namespaced under PormG.Functions (NOT exported by PormG).
const EXPECTED_FUNCTIONS = Set([
    :Sum, :Avg, :Count, :Max, :Min,
    :Case, :When,
    :WindowOver, :WindowSpec, :Rank, :DenseRank, :RowNumber, :Lag, :Lead, :FirstValue, :LastValue, :NthValue,
    :Concat, :Lower, :Upper, :Length, :Replace, :Trim, :LTrim, :RTrim,
    :Abs, :Round, :Floor, :Ceil, :Sqrt, :Exp, :Ln, :Power, :Mod,
    :Cast, :Extract, :To_char, :Value, :Coalesce, :Greatest, :Least, :NullIf,
])

@testset "Public export surface (#35)" begin

    # `names(PormG)` includes the module's own name; drop it, then compare exactly. An
    # exact-set comparison catches BOTH accidental additions (re-flooding) and removals.
    @testset "Top-level surface is exactly the documented set" begin
        actual = Set(filter(n -> n !== :PormG, names(PormG)))
        # Show the precise drift if this fails, so the fix is obvious.
        @test setdiff(actual, EXPECTED_TOPLEVEL) == Set{Symbol}()   # nothing unexpected leaked in
        @test setdiff(EXPECTED_TOPLEVEL, actual) == Set{Symbol}()   # nothing documented went missing
        @test actual == EXPECTED_TOPLEVEL
    end

    # The SQL function constructors must NOT be exported at the top level (the whole point
    # of #35 — these generic names flooded Main and collided with Base).
    @testset "SQL function names are not top-level exports" begin
        toplevel = Set(names(PormG))
        for f in EXPECTED_FUNCTIONS
            @test !(f in toplevel)
        end
    end

    # …but they ARE exported by PormG.Functions, and resolve to the same QueryBuilder bindings.
    @testset "PormG.Functions exports the function library" begin
        fns = Set(filter(n -> n !== :Functions, names(PormG.Functions)))
        @test fns == EXPECTED_FUNCTIONS
        # Same binding as the source of truth (no divergent copy).
        @test PormG.Functions.Count === PormG.QueryBuilder.Count
        @test PormG.Functions.Sum === PormG.QueryBuilder.Sum
    end

    # Clean break (#35): the function constructors have exactly ONE home — PormG.Functions.
    # They are deliberately NOT accessible as `PormG.Sum`, so `using PormG: Sum` fails by
    # design. Pre-publish, we want one obvious namespace rather than a redundant alias.
    @testset "Function names live ONLY in PormG.Functions (no PormG.Sum alias)" begin
        @test !isdefined(PormG, :Sum)
        @test !isdefined(PormG, :Count)
        @test !isdefined(PormG, :Round)
        @test !isdefined(PormG, :Replace)
        # The single home still resolves to the QueryBuilder source of truth:
        @test isdefined(PormG.Functions, :Sum)
        @test PormG.Functions.Sum === PormG.QueryBuilder.Sum
    end

    # `fetch` extends Base.fetch instead of shadowing it (no forced qualification).
    @testset "fetch extends Base.fetch (no shadow)" begin
        @test PormG.ConnectionPool.fetch === Base.fetch
    end

    # No type piracy on Base.first (#200). PormG extends Base.first only through the typed
    # `first(::SQLObjectHandler; …)` method (nargs==2 — the function slot plus a PormG-owned
    # positional arg). A PormG-defined method on Base.first with NO positional argument
    # (nargs==1, only the function slot) has no PormG type to anchor it → global type piracy.
    # The curried `first(; kwargs…)` form was exactly that and was removed.
    #
    # Why Aqua's piracies check didn't catch it (verified against Aqua 0.8): `Aqua.Piracy.is_pirate`
    # DOES flag the nullary method, but `hunt(PormG)`/`test_piracies(PormG)` filter methods by
    # `method.module === PormG` and never recurse into submodules — the method lived in
    # `PormG.QueryBuilder`, so it was dropped before is_pirate saw it. This explicit guard closes
    # that submodule blind spot without depending on Aqua internals.
    @testset "no Base.first type piracy — nullary kwargs method (#200)" begin
        pormg_nullary_first = filter(methods(first)) do m
            occursin("PormG", string(parentmodule(m))) && m.nargs == 1
        end
        @test isempty(pormg_nullary_first)
        # …and the legitimate, non-pirating extension is still there (this is the ONLY way
        # PormG may touch Base.first): a typed method with a PormG positional argument.
        @test hasmethod(first, Tuple{PormG.QueryBuilder.SQLObjectHandler})
    end

    # `close_pool!` was exported by BOTH Configuration and ConnectionPool as *different*
    # functions, which made `PormG.close_pool!` ambiguous (undefined). The dedup leaves
    # Configuration's full-featured version (pool OR db-name String) as the single one.
    @testset "close_pool! is no longer a duplicate export" begin
        @test isdefined(PormG, :close_pool!)
        @test PormG.close_pool! === PormG.Configuration.close_pool!
        # Still accepts a db-name String (the convenience the public version adds).
        @test hasmethod(PormG.close_pool!, Tuple{String})
    end
end
