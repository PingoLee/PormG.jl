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
#
# NOTE (#289): `names(PormG)` reports exported names AND ones declared `public` (Julia 1.11+), so
# this set is the *public* surface, not the *exported* one — the two now differ by exactly the two
# `public` entries at the bottom. A bare `using PormG` still brings only the exported names into
# scope; `public` records "this is API" for tooling, `?`, and Documenter's `Private = false`.
const EXPECTED_TOPLEVEL = Set([
    # Query builder
    # `CTE` (#444) is a CTE-column reference object, a query primitive like F/OuterRef/Subquery.
    :object, :get, :Q, :Qor, :F, :Exists, :OuterRef, :Subquery, :CTE, :Interval, :show_query, :inspect_query,
    # Rows & exceptions
    :PormGRow, :pk, :DoesNotExist, :MultipleObjectsReturned, :PoolTimeoutError, :PoolConnectError, :pool_stats,
    # Semantic error taxonomy (#231): PormGError root + query-builder subtypes
    :PormGError, :FieldAccessError, :UnknownFieldError, :LazyTraversalError, :FilterError,
    :QueryBuildError, :UnsafeMutationError, :InvalidValueError, :WritesDisabledError, :UnsupportedConnectionError,
    # Taxonomy completion (#239): schema, configuration and migration errors. ConfigurationError
    # and MigrationError are abstract umbrellas (like FieldAccessError).
    :FieldValidationError, :ModelDefinitionError,
    :ConfigurationError, :InvalidConfigurationError,
    :MigrationError, :InvalidMigrationError,
    # Taxonomy edges (#261): PoolError is the connection-pool umbrella; error_message is the
    # uniform way to read a caught PormGError (the structured subtypes have no `.msg`).
    :PoolError, :error_message,
    # #268 audit naming pass: renamed PermissionError→WritesDisabledError (in the taxonomy line
    # above), plus the capability split, the PROTECT-delete type, and the definition-time umbrella.
    :BackendCapabilityError, :ProtectedError, :DefinitionError,
    # #268 the database-error boundary: what the database itself refused, once a statement reached
    # it. `TransactionError` is transaction-API misuse — nothing was sent.
    :DatabaseError, :IntegrityError, :OperationalError, :StatementError, :TransactionError,
    # Bulk operations
    :bulk_insert, :bulk_update, :bulk_copy, :allocate_primary_keys, :resync_sequences,
    # Async API
    :fetch_async, :await_result, :FetchTask,
    # Transactions
    :run_in_transaction, :atomic, :with_savepoint, :with_tx_context, :in_transaction_context,
    # Locking
    :with_advisory_lock,
    # #276: SQLite now enforces foreign keys; this is the supported way to suspend that for a block
    # (data repair, out-of-order bulk loads, planting a deliberate violation in a test).
    :without_foreign_keys,
    # Utilities & lifecycle
    :upgrade_guide, :register_ignore_tables!,
    Symbol("@import_models"), Symbol("@models_module"), Symbol("@pormg_debug"),
    # #201 kept `setup` / `install_ai_skills` OUT of `export` — they are maximally generic names
    # for one-off helpers, and every example calls them qualified. That still holds: neither is
    # exported, so a bare `using PormG` does not bind them. #289 additionally declares them
    # `public`, which is what puts them in `names(PormG)` and therefore in this set — recording
    # that they ARE API (as docs/src/api.md already stated) without widening `using`.
    :setup, :install_ai_skills,
])

# The SQL function library, namespaced under PormG.Functions (NOT exported by PormG).
const EXPECTED_FUNCTIONS = Set([
    :Sum, :Avg, :Count, :Max, :Min,
    :Case, :When,
    :WindowOver, :WindowSpec, :Rank, :DenseRank, :RowNumber, :Lag, :Lead, :FirstValue, :LastValue, :NthValue,
    :Concat, :Lower, :Upper, :Length, :Replace, :Trim, :LTrim, :RTrim,
    :Abs, :Round, :Floor, :Ceil, :Sqrt, :Exp, :Ln, :Power, :Mod,
    :Cast, :Extract, :ToChar, :Value, :Coalesce, :Greatest, :Least, :NullIf,
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

    # ─────────────────────────────────────────────────────────────────────────
    # `public` is not `export` (#289)
    # The set above is `names(PormG)`, which since Julia 1.11 reports exported AND `public` names.
    # That makes it a weaker statement than it looks: a name could enter it by being declared
    # `public` while #201's "qualified-call-only" promise still holds. Pin the distinction, so a
    # future `export setup` cannot slip in behind an unchanged EXPECTED_TOPLEVEL.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "public-but-not-exported lifecycle helpers stay out of `using`" begin
        for n in (:setup, :install_ai_skills)
            @test Base.ispublic(PormG, n)          # API, and Documenter's `Private = false` keeps it
            @test !Base.isexported(PormG, n)       # …but #201 still says: call it qualified
        end

        # The load-bearing half: a bare `using PormG` must not bind them. `names(…; imported=false)`
        # is what `using` consults, so check the binding directly in a throwaway module.
        mod = Module(:PormGUsingProbe)
        Core.eval(mod, :(using PormG))
        for n in (:setup, :install_ai_skills)
            @test !isdefined(mod, n)
        end
        # Control: something genuinely exported DOES arrive, so the probe itself is not vacuous.
        @test isdefined(mod, :object)
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

    # Same contract for Base.last (#208): last() mirrors first() and is allowed to extend Base.last
    # ONLY through the typed `last(::SQLObjectHandler; …)` method (nargs==2). A nullary kwargs-only
    # method would be the same global piracy the #200 guard above forbids for first.
    @testset "no Base.last type piracy — nullary kwargs method (#208)" begin
        pormg_nullary_last = filter(methods(last)) do m
            occursin("PormG", string(parentmodule(m))) && m.nargs == 1
        end
        @test isempty(pormg_nullary_last)
        @test hasmethod(last, Tuple{PormG.QueryBuilder.SQLObjectHandler})
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

    # #202 — the `PormG.QueryBuilder` submodule surface.
    #
    # Decision: `With` WAS exported here as the documented functional CTE form. #305 withdrew that
    # form — the fluent `.with(...)` is now the only public surface — so the binding is gone from
    # the submodule entirely, renamed to the internal `_with` under #281's naming rule.
    # `OP` (operator) is INTERNAL — unexported and undocumented; the public
    # way to build operator predicates is the `"field__@op"` string lookup. The generic names
    # `query`/`update`/`page` were also un-exported so a bare `using PormG.QueryBuilder` stops
    # dumping them into scope.
    #
    # Note: `names(M)` lists a module's EXPORTED symbols; `isdefined(M, s)` is true for any
    # binding whether exported or not. So a name staying defined-but-unexported is exactly the
    # prune we want — explicit `import PormG.QueryBuilder: name` still works.
    @testset "QueryBuilder submodule surface (#202)" begin
        qb_exports = Set(filter(n -> n !== :QueryBuilder, names(PormG.QueryBuilder)))

        # Un-exported from the submodule (still defined, just not dumped by a bare
        # `using PormG.QueryBuilder`): the generic names + the internal `OP` builder.
        for n in (:query, :update, :page, :OP)
            @test !(n in qb_exports)                # no longer exported
            @test isdefined(PormG.QueryBuilder, n)  # …but still reachable by explicit import
        end

        # #305: the whole join/CTE free-function family is internal now. `With` in particular is
        # GONE as a name — not merely un-exported — because #281's rule renames a non-public helper
        # behind `getproperty`. Asserting `!isdefined` rather than just "not exported" is what keeps
        # a future `_with` -> `With` revert from passing silently.
        for n in (:With, :cjoin, :cjoin_on, :on)
            @test !(n in qb_exports)
            @test !isdefined(PormG.QueryBuilder, n)
        end
        # …and the renamed internals do exist, so the family was renamed rather than deleted.
        for n in (:_with, :_cjoin, :_cjoin_on, :_on)
            @test isdefined(PormG.QueryBuilder, n)
            @test !(n in qb_exports)
        end

        # Not promoted onto the top-level surface either (kept off `using PormG`). Load-bearing:
        # fails the moment `With`/`OP` are re-homed at top level.
        @test !isdefined(PormG, :With)
        @test !isdefined(PormG, :OP)
    end
end
