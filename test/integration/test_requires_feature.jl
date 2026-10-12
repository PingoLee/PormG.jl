# test/integration/test_requires_feature.jl
# The `requires(:feature)` helper the feature tests branch on (#1129), defined in common_setup.jl.

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# ─────────────────────────────────────────────────────────────────────────────
# `requires(:feature)` answers from the capability table, and records every skip with its reason
# For every row of the table (`src/capabilities.jl`, #1161), `requires` must give `_supports`'s answer
# for this run's backend. No SQL is involved: it reads the table, not the engine. When it answers no,
# the enclosing testset gains exactly one `Broken` result whose text names the backend and the
# feature, and `FEATURE_SKIPS` one entry. An unknown feature throws.
# Why: a feature test runs its body or asserts the refusal on that answer. A helper that answered by
# engine name would hand a new backend (#1130) one engine's branch, and a skip that said nothing
# would read as a pass. PostgreSQL has every row and SQLite none, so a run on db_2 covers the yes path
# and a run on db_sl the skip path.
# ─────────────────────────────────────────────────────────────────────────────
@testset "requires(:feature) reads the capability table and records each skip (#1129)" begin
    conn = PormG.config[PORMG_DB_FOLDER].connections
    for f in PormG.Kernel._FEATURE_NAMES
        has = PormG.Kernel._supports(conn, f)
        n = length(FEATURE_SKIPS)
        ts = @testset "requires(:$(f))" begin
            @test requires(f) == has
        end
        broken = filter(r -> r isa Test.Broken, ts.results)
        @test length(broken) == !has
        @test length(FEATURE_SKIPS) == n + !has
        if !has
            reason = only(broken).orig_expr
            @test occursin(PormG.Kernel._backend_name(conn), reason)
            @test occursin(":$(f)", reason)
            @test last(FEATURE_SKIPS) == (f, reason)
        end
    end
    @test_throws PormG.InvalidValueError requires(:no_such_feature)
end
