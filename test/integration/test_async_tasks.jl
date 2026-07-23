# ─────────────────────────────────────────────────────────────────────────────
# Async task concurrency (#198): "tasks are the async API"
# PormG's contract for per-query async execution is Julia's task system: every
# terminal (list(), count(), …) already yields to the scheduler while the DB
# round-trip is in flight (fetch → fetch_async → await_result), so wrapping the
# ordinary sync call in Threads.@spawn / @async IS the async query API. These
# tests pin that contract: task-wrapped queries return exactly what the sync
# path returns (PG + SQLite), fan-out leaks no pool connections, and the
# ScopedValue transaction context propagates into spawned tasks (the mechanism
# behind the "don't fan out queries inside a transaction" guidance in
# docs/src/async.md).
# ─────────────────────────────────────────────────────────────────────────────
if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

using Test

# ─────────────────────────────────────────────────────────────────────────────
# Parity: a task-wrapped list() returns exactly the sync list() rows
# The issue-#198 regression: the async path is the sync path (same SQL, same
# post-processing, same Vector{PormGRow}) — only the awaiting differs. Ordered
# by primary key so the element-wise comparison is deterministic.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Threads.@spawn list() parity with sync list()" begin
    # Sync baseline. order_by makes row order deterministic on both backends.
    sync_query = M.Driver.objects
    sync_query.filter("nationality" => "Brazilian")
    sync_query.order_by("driverid")
    sync_rows = sync_query.list()
    @test !isempty(sync_rows)   # guard: a vacuously-empty comparison proves nothing

    # Async arm: build the handler INSIDE the task (each `.objects` access
    # returns a fresh handler, and terminals deepcopy before building — no
    # shared mutable state between the sync and async arms).
    t = Threads.@spawn M.Driver.objects.filter(
        "nationality" => "Brazilian"
    ).order_by("driverid").list()
    spawn_rows = fetch(t)   # Base.fetch on a Task — this is the whole async API

    @test length(spawn_rows) == length(sync_rows)
    @test [r[:driverid] for r in spawn_rows] == [r[:driverid] for r in sync_rows]
    @test [r[:surname] for r in spawn_rows] == [r[:surname] for r in sync_rows]

    # Same contract holds for @async (current-thread task): both spellings are
    # documented in docs/src/async.md — the DB wait is a scheduler yield either way.
    t2 = @async M.Driver.objects.filter(
        "nationality" => "Brazilian"
    ).order_by("driverid").list()
    async_rows = fetch(t2)
    @test [r[:driverid] for r in async_rows] == [r[:driverid] for r in sync_rows]
    @test [r[:surname] for r in async_rows] == [r[:surname] for r in sync_rows]
end

# ─────────────────────────────────────────────────────────────────────────────
# Fan-out: @sync + @spawn over independent queries matches sync baselines and
# returns every pooled connection. Unlike an un-awaited fetch_async (which
# holds its connection until await_result), a task-wrapped terminal acquires
# AND releases its connection inside the task — so even a forgotten task
# cannot leak. Busy-count is compared against a pre-fan-out baseline (same
# robustness pattern as test_connection_pool.jl). No simultaneous-checkout
# assertion here: SQLite serializes through its shared async worker.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Concurrent fan-out matches sync baselines and leaks nothing" begin
    settings = PormG.config[PORMG_DB_FOLDER]
    years = 2010:2019

    # Sync baselines first (sequential, no concurrency in play).
    expected = [M.Race.objects.filter("year" => y).count() for y in years]
    @test any(>(0), expected)   # guard: the fixture must actually cover these seasons

    # Baseline of busy (checked-out) pool slots before the fan-out.
    base_busy = count(!, settings.connections.available)

    # One task per season, all in flight together; fetch preserves input order.
    tasks = [Threads.@spawn M.Race.objects.filter("year" => y).count() for y in years]
    got = fetch.(tasks)
    @test got == expected

    # Every connection the fan-out used was returned to the pool.
    @test count(!, settings.connections.available) == base_busy
end

# ─────────────────────────────────────────────────────────────────────────────
# asyncmap: the one-liner fan-out spelling documented in docs/src/async.md.
# Result order matches input order by construction.
# ─────────────────────────────────────────────────────────────────────────────
@testset "asyncmap parity" begin
    years = 2010:2019
    expected = [M.Race.objects.filter("year" => y).count() for y in years]
    got = asyncmap(y -> M.Race.objects.filter("year" => y).count(), collect(years))
    @test got == expected
end

# ─────────────────────────────────────────────────────────────────────────────
# Raw-SQL escape hatch: fetch_async(settings, sql) → await_result. Anchors the
# rewritten docs/src/api.md "Async Execution" example: fetch_async takes RAW
# SQL only (never a query handler — the phantom fetch_async(handler) form from
# the old docs does not exist). Also pins await_result's documented idempotence
# (second await returns the cached result, no double-release).
# ─────────────────────────────────────────────────────────────────────────────
@testset "raw-SQL fetch_async parity with the query path" begin
    settings = PormG.config[PORMG_DB_FOLDER]

    task = fetch_async(settings, "SELECT count(*) FROM driver")
    result = await_result(task)
    df = DataFrame(result)
    @test df[1, 1] == M.Driver.objects.count()

    # Idempotent await: same object back, connection released exactly once.
    @test await_result(task) === result
end

# ─────────────────────────────────────────────────────────────────────────────
# Transaction context propagates into spawned tasks (ScopedValue semantics).
# This is the mechanism behind the async-guide warning: a task spawned INSIDE
# run_in_transaction inherits the pinned transaction connection, so fanning
# out queries inside a transaction gives zero concurrency (they all serialize
# on one connection) — fan out whole transactions instead. BEGIN/COMMIT only,
# no writes, so the testset is read-only on both backends.
# ─────────────────────────────────────────────────────────────────────────────
@testset "tx context propagates into spawned tasks" begin
    settings = PormG.config[PORMG_DB_FOLDER]

    # Outside any transaction: no pinned connection to inherit.
    @test fetch(Threads.@spawn get_tx_connection() !== nothing) == false

    # Inside: the spawned task sees the transaction's pinned connection.
    seen = Ref(false)
    PormG.run_in_transaction(settings) do
        seen[] = fetch(Threads.@spawn get_tx_connection() !== nothing)
    end
    @test seen[]
end
