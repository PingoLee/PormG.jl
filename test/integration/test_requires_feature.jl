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

# ─────────────────────────────────────────────────────────────────────────────
# `by_engine` and `only_on` give each engine its own row and never borrow another's (#1179)
# `by_engine(postgres = …, sqlite = …)` must return this run's row; a call that leaves this engine
# out must raise an error naming it — not return another engine's value — and an unknown key raises
# on every engine. `only_on(:engine, why)` must answer yes on its own engine with nothing recorded,
# and no elsewhere with exactly one `Broken` result carrying `why` and an `ENGINE_SKIPS` entry. No
# SQL is involved: the helpers read `_engine_key`, which has no fallback.
# Why: they replace the inline `isa PormGPostgres ? A : B` branches whose `else` a backend added
# later (#1130) would inherit. A helper that fell back to a default would rebuild that `else` in one
# place; this pins that it does not. db_2 and db_sl each exercise the other engine's absent row.
# ─────────────────────────────────────────────────────────────────────────────
@testset "by_engine and only_on: a row per engine, no fallback (#1179)" begin
    me = engine_key()
    @test me === PormG.Kernel._engine_key(PormG.config[PORMG_DB_FOLDER].connections)
    @test me in ENGINE_KEYS
    other = first(k for k in ENGINE_KEYS if k !== me)

    @test by_engine(; NamedTuple{(me, other)}(("mine", "theirs"))...) == "mine"
    missing_row = try by_engine(; NamedTuple{(other,)}(("theirs",))...); nothing catch e; e end
    @test missing_row isa ErrorException && occursin("no expectation for engine :$(me)", missing_row.msg)
    @test_throws ErrorException by_engine(; NamedTuple{(me, :postgress)}((1, 2))...)   # a typo'd key

    n = length(ENGINE_SKIPS)
    ts = @testset "only_on(:$(me))" begin
        @test only_on(me, "runs here")
    end
    @test isempty(filter(r -> r isa Test.Broken, ts.results)) && length(ENGINE_SKIPS) == n

    ts = @testset "only_on(:$(other))" begin
        @test !only_on(other, "pinned to the other engine")
    end
    broken = filter(r -> r isa Test.Broken, ts.results)
    @test length(broken) == 1 && length(ENGINE_SKIPS) == n + 1
    @test occursin("pinned to the other engine", only(broken).orig_expr)
    @test last(ENGINE_SKIPS) == only(broken).orig_expr
    pop!(ENGINE_SKIPS)   # a probe, not a skip: keep it out of the run's report
    @test_throws ErrorException only_on(:postgress, "a typo'd engine")
end
