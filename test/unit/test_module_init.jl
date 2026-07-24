# ==============================================================================
# UNIT TESTS: Module-body side effects → __init__() (issue #203)
#
# With cached precompilation a Julia module body runs ONLY in the precompile worker;
# loading from cache does not re-run it. So top-level side effects never run at runtime.
# #203 moved the atexit(Configuration.__cleanup__) pool-cleanup hook into a new
# PormG.__init__(), and removed the module-body ENV write plus the dead, precompile-baked
# `const PORMG_ENV = ENV["PORMG_ENV"]`.
#
# Julia exposes no API to enumerate atexit hooks, so we assert the STRUCTURAL fix (the
# __init__ exists; the dead const is gone) and the hook's BEHAVIOR (__cleanup__ closes a
# pool registered in `config`). DB-free (SQLite :memory:).
# ==============================================================================

using Test
using PormG

# A closeable sentinel so the cleanup's close()+nil-out of a *live* handle is observable — otherwise the
# connections assertion is vacuously green on a fresh (all-nothing) pool. Own type → not type piracy.
mutable struct _ClosableSentinel203
    closed::Bool
end
Base.close(s::_ClosableSentinel203) = (s.closed = true; nothing)

@testset "Module init side-effects moved out of module body (#203)" begin
    # Core fix: PormG.__init__ now exists. The atexit(Configuration.__cleanup__) registration lives
    # here, so it runs at runtime instead of only in the precompile worker (where it was dead).
    @test isdefined(PormG, :__init__)
    @test PormG.__init__ isa Function
    @test PormG.__init__() === nothing        # safe to invoke; only (re)registers the atexit hook

    # The dead, precompile-baked `const PORMG_ENV = ENV["PORMG_ENV"]` (old constants.jl:26) is gone —
    # never read, and an unguarded include-time ENV read (a KeyError landmine).
    @test !isdefined(PormG, :PORMG_ENV)

    # The atexit target `__cleanup__` walks `config` and closes each registered pool. Prove it does so
    # non-trivially: a freshly-built pool is already all-available, so first flip a slot to in-use, then
    # assert cleanup reset it (a no-op __cleanup__ would leave the slot false → this test would fail).
    # Isolate `config` (snapshot → empty → restore) so other tests' pools are untouched.
    saved = copy(PormG.config)
    try
        empty!(PormG.config)
        pool = PormG.ConnectionPool.SQLiteConnectionPool(":memory:"; pool_size = 2)
        sentinel = _ClosableSentinel203(false)
        pool.connections[1] = sentinel   # a live handle in slot 1...
        pool.available[1] = false        # ...checked out, so both the close and the slot reset are observable
        PormG.config["__test203__"] = PormG.Configuration.Settings(connections = pool)

        @test PormG.Configuration.__cleanup__() === nothing
        @test all(pool.available)                        # discriminating: cleanup reset the in-use slot
        @test sentinel.closed                            # discriminating: close() was invoked on the live handle
        @test all(c -> c === nothing, pool.connections)  # discriminating: the live handle's slot was nilled
    finally
        empty!(PormG.config)
        merge!(PormG.config, saved)
    end
end
