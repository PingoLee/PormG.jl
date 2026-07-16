# ─────────────────────────────────────────────────────────────────────────────
# Connection pool: no connection leak under concurrent async fan-out (#37)
# Fires N un-awaited fetch_async calls (each acquires its connection *synchronously* before it
# returns) so N connections are held at once, then awaits all and asserts the pool's busy-count
# returns to its baseline. Proves both real concurrency (N held simultaneously) and full release.
# ─────────────────────────────────────────────────────────────────────────────
if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

using Test

@testset "Connection pool: no leak under concurrent async (#37)" begin
    settings = PormG.config[PORMG_DB_FOLDER]
    pool = settings.connections

    # Baseline count of *busy* (not-available) slots — should be 0 between tests, but we compare
    # against whatever it is now so the leak check is robust to any pre-existing checkouts.
    base_in_use = count(!, pool.available)

    # Cap N to the pool's pre-sized capacity so we never exhaust it (a misconfigured
    # PORMG_TEST_POOL_SIZE below N would otherwise make fetch_async block+throw mid-setup).
    N = min(15, pool.pool_size)
    # `fetch_async` acquires its connection SYNCHRONOUSLY before returning the task handle (only the
    # query body runs async), so each started task holds a connection until awaited. Build inside the
    # try so the finally releases whatever was started even if one fails partway.
    tasks = Any[]
    try
        for _ in 1:N
            push!(tasks, fetch_async(settings, "SELECT 1"))
        end
        # (1) Real concurrency + no premature release: N connections held SIMULTANEOUSLY.
        # Guarded to PostgreSQL — SQLite serializes work through a shared async worker/queue, so N
        # concurrent fetches may not check out N distinct slots there (the check would fail spuriously
        # with no leak). The baseline invariant (2) below still runs on both backends.
        if pool isa PormG.PormGPostgres
            @test count(!, pool.available) >= N
        end
    finally
        foreach(await_result, tasks)   # await → each task's finally releases its connection
    end

    # (2) No leak: every one of the N connections was returned → busy-count back to baseline.
    @test count(!, pool.available) == base_in_use
end


# ─────────────────────────────────────────────────────────────────────────────
# Direct-handoff wait under real contention (#124)
# Far more concurrent acquirers than the pool's ceiling → many tasks must PARK and be woken by
# direct handoff on release. Asserts every task completes (no starvation / PoolTimeoutError) and
# every connection is returned. Uses a DEDICATED small pool (ceiling = 2×10 = 20) built from the
# same connection string, so we force parking without touching the shared fixture pool or opening
# hundreds of connections.
# ─────────────────────────────────────────────────────────────────────────────
@testset "direct-handoff wait under contention (#124)" begin
    cfg = PormG.config[PORMG_DB_FOLDER].connections
    pool = cfg isa PormG.PormGPostgres ?
        PormG.ConnectionPool.PostgresConnectionPool(cfg.connection_string; pool_size = 2) :
        PormG.ConnectionPool.SQLiteConnectionPool(cfg.connection_string; pool_size = 2)
    try
        N = 40                                  # ≫ ceiling (20) → guaranteed parking + handoff
        ok = fill(false, N)
        @sync for i in 1:N
            Threads.@spawn begin
                conn = PormG.ConnectionPool.acquire_connection(pool; timeout_seconds = 30)
                try
                    sleep(0.005)                # hold briefly so contention actually builds up
                finally
                    PormG.ConnectionPool.release_connection(pool, conn)
                end
                ok[i] = true
            end
        end
        @test all(ok)                           # all N acquired+released — no starvation, no timeout
        @test count(!, pool.available) == 0     # every connection returned — no leak
    finally
        PormG.ConnectionPool.close_pool!(pool)
    end
end
