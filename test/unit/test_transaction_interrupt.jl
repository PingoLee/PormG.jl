# ============================================================
# test/unit/test_transaction_interrupt.jl
#
# An ABANDONED await inside a TRANSACTION or ADVISORY-LOCK lifecycle must never return its
# connection to the pool, and must never reuse it either (#322 — the #315 twin).
#
# CONTRACT being tested:
#   #315 fixed `await_result`. Three sites kept the same defect, because they await the driver
#   directly instead of going through `fetch`:
#
#     1. `_run_in_transaction_impl`'s BEGIN. `tx_started` is set AFTER the await returns, so an
#        interrupt in flight leaves it `false`: no ROLLBACK is issued, and the terminal
#        `finalize_transaction_connection!` takes its plain-release branch and hands back a
#        connection the driver is still on. Only the BEGIN window is fixed here. An interrupt landing
#        while a query is IN FLIGHT inside the body is a different case, deliberately left alone:
#        `await_result` does nothing for an in-transaction await, so the ROLLBACK serializes behind
#        the abandoned query and the connection comes back CLEAN (verified against a live
#        PostgreSQL) — at the cost of a Ctrl-C that returns only after the cancelled query's
#        remaining runtime. One interrupt is therefore slow, not poisonous, which is why it is not
#        this issue. A SECOND interrupt onto that blocked ROLLBACK *is* a real bug — it renews
#        synchronously and closes a SQLite handle the worker is still inside — but it belongs to the
#        #71 renewal path, and is tracked separately. These tests cover NEITHER; the "interrupt in
#        the body" testsets below pin the between-statements case only.
#     2. `with_transaction`. `rollback_failed` is `false` for any sql that is not a plain
#        ROLLBACK, so both of its release points released a dirty handle.
#     3. `AdvisoryLock`. Worse consequence: the `finally` releases unconditionally AND its UNLOCK
#        runs on the dirty connection and fails — so a session-level `pg_advisory_lock` goes back
#        into the pool still held, forever.
#
#   All three now route to `_recover_abandoned_connection!(pool, conn, handle; force_renew = true)`:
#   cancel → bounded wait for the driver to let go → renew, on a DETACHED task.
#
#   `force_renew` is the part that is NOT inherited from #315. The plain path drains and releases a
#   clean connection, but draining answers a question about the WIRE: PostgreSQL's
#   `_drain_postgres_connection!` consumes queued PGresults and never reads `PQtransactionStatus`.
#   A BEGIN that DID land before the interrupt therefore drains perfectly clean — and releasing it
#   puts an open transaction back in the pool (#71 in a new place). A held advisory lock is invisible
#   to a drain for the same reason. So these callers renew unconditionally.
#
#   The PRECISION half matters as much as the fix: an `InterruptException` raised by the caller's own
#   `f()` is also "abandoned" by `_await_abandoned`, but the connection is CLEAN there and holds an
#   OPEN transaction (or a live lock). Skipping its ROLLBACK/UNLOCK would be a new bug, not the fix.
#   Two testsets below exist only to pin that.
#
# Deterministic and DB-free, in the idiom of test_await_result_interrupt.jl (#315) and
# test_transaction_rollback_renewal.jl (#71): behavioral mock pools carry the exact fields the pool
# machinery reads, counters are atomic because recovery runs on a detached task, and a `renew_gate`
# parks that task INSIDE `backend_renew_connection` so "the slot is still leased" is observed rather
# than raced. The SQLite testset drives the REAL global worker with a REAL interrupt.
#
# Each testset names its own reverted-fix signature. Mutation-tested: every guard here was run
# against the unfixed code and fails there.
# ============================================================

using Test
using PormG

# No DB drivers needed: every backend_* call in these flows dispatches to the mock methods below,
# so this file runs without the LibPQ/SQLite weakdep extensions.

const CP = PormG.ConnectionPool
const AL = PormG.AdvisoryLock

# ── Fake driver handle: tracks close, AND whether the driver was still on it at close time ──
# (structs live at file top level — Julia forbids type definitions inside @testset blocks)
#
# `closed_while_busy` is the use-after-free assertion in mock form: `busy` is set by the mock
# "driver" for as long as it is using the handle, and a `close` landing in that window is exactly
# what frees a SQLite handle out from under `sqlite3_step`.
mutable struct FakeConn322
  id::Int
  closed::Bool
  closed_while_busy::Bool
  busy::Threads.Atomic{Bool}
end
FakeConn322(id::Int) = FakeConn322(id, false, false, Threads.Atomic{Bool}(false))
function Base.close(c::FakeConn322)
  c.busy[] && (c.closed_while_busy = true)
  c.closed = true
  return nothing
end

# ── PG-shaped mock: PostgresConnectionPool's exact fields + failure/gate knobs ──
#
# Statement counters are ATOMIC rather than a `Vector{String}` log: the mock's `@async` statement
# tasks and the detached recovery task both write while the test task reads, and the one fact each
# testset needs ("was a ROLLBACK issued at all?") is a count, not an order.
#
# `renew_gate`, when non-nothing, parks `backend_renew_connection` — which is where `force_renew`
# recovery goes — so the mid-recovery pool state is observed deterministically. (#315's file gates
# the DRAIN for the same purpose; `force_renew` skips the drain, so the park point moves.)
mutable struct MockPGPool322 <: PormG.PormGPostgres
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
  interrupt_sql::Union{Nothing, String}   # sql prefix whose task raises InterruptException
  fail_sql::Union{Nothing, String}        # sql prefix whose task raises an ordinary error
  begins::Threads.Atomic{Int}
  rollbacks::Threads.Atomic{Int}
  commits::Threads.Atomic{Int}
  unlocks::Threads.Atomic{Int}
  cancels::Threads.Atomic{Int}
  drains::Threads.Atomic{Int}
  renewals::Threads.Atomic{Int}
  renew_gate::Union{Nothing, Channel{Nothing}}
  next_id::Threads.Atomic{Int}
end
MockPGPool322(; interrupt_sql = nothing, fail_sql = nothing, renew_gate = nothing) =
  MockPGPool322(Any[FakeConn322(1)], [true], "mock://pg", 1, ReentrantLock(),
                interrupt_sql, fail_sql,
                Threads.Atomic{Int}(0), Threads.Atomic{Int}(0), Threads.Atomic{Int}(0),
                Threads.Atomic{Int}(0), Threads.Atomic{Int}(0), Threads.Atomic{Int}(0),
                Threads.Atomic{Int}(0), renew_gate, Threads.Atomic{Int}(1))

_matches_322(prefix, sql) = prefix !== nothing && startswith(sql, prefix)

PormG.backend_is_alive(::MockPGPool322, conn) = conn isa FakeConn322 && !conn.closed
PormG.backend_connect(pool::MockPGPool322; kwargs...) =
  FakeConn322(Threads.atomic_add!(pool.next_id, 1) + 1)
function PormG.backend_renew_connection(pool::MockPGPool322, conn; kwargs...)
  Threads.atomic_add!(pool.renewals, 1)
  pool.renew_gate === nothing || take!(pool.renew_gate)   # park the recovery here on demand
  return FakeConn322(Threads.atomic_add!(pool.next_id, 1) + 1)
end
PormG.backend_cancel_query!(pool::MockPGPool322, conn) =
  (Threads.atomic_add!(pool.cancels, 1); nothing)
PormG.backend_drain_connection!(pool::MockPGPool322, conn) =
  (Threads.atomic_add!(pool.drains, 1); true)   # always "clean" — force_renew must renew anyway

function PormG.backend_execute_async(pool::MockPGPool322, conn, sql::String, params)
  startswith(sql, "BEGIN")   && Threads.atomic_add!(pool.begins, 1)
  startswith(sql, "ROLLBACK") && Threads.atomic_add!(pool.rollbacks, 1)
  startswith(sql, "COMMIT")  && Threads.atomic_add!(pool.commits, 1)
  startswith(sql, "SELECT pg_advisory_unlock") && Threads.atomic_add!(pool.unlocks, 1)
  return @async begin
    _matches_322(pool.interrupt_sql, sql) && throw(InterruptException())
    _matches_322(pool.fail_sql, sql) && error("mock: statement refused")
    # Advisory-lock queries are read for a boolean; everything else discards the result.
    startswith(sql, "SELECT pg_") ? Any[(true,)] : NamedTuple[]
  end
end

# ── SQLite-shaped mock: SQLiteConnectionPool's exact fields + the same knobs ──
# Statements funnel through the REAL global async worker → backend_execute, so the abandoned-await
# behaviour is proven on the actual SQLite code path rather than a stand-in.
mutable struct MockSQLitePool322 <: PormG.PormGSQLite
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  split_read_write::Bool
  writer_slot::Int
  reader_cursor::Int
  lock::ReentrantLock
  write_lock::ReentrantLock
  rollbacks::Threads.Atomic{Int}
  cancels::Threads.Atomic{Int}
  drains::Threads.Atomic{Int}
  renewals::Threads.Atomic{Int}
  work_gate::Union{Nothing, Channel{Nothing}}   # blocks the worker INSIDE backend_execute
  next_id::Threads.Atomic{Int}
end
MockSQLitePool322(; work_gate = nothing) =
  MockSQLitePool322(Any[FakeConn322(1)], [true], "mock://sqlite", 1, false, 1, 0,
                    ReentrantLock(), ReentrantLock(),
                    Threads.Atomic{Int}(0), Threads.Atomic{Int}(0), Threads.Atomic{Int}(0),
                    Threads.Atomic{Int}(0), work_gate, Threads.Atomic{Int}(1))

PormG.backend_is_alive(::MockSQLitePool322, conn) = conn isa FakeConn322 && !conn.closed
PormG.backend_connect(pool::MockSQLitePool322; read_only::Bool = false) =
  FakeConn322(Threads.atomic_add!(pool.next_id, 1) + 1)
function PormG.backend_renew_connection(pool::MockSQLitePool322, conn; read_only::Bool = false)
  Threads.atomic_add!(pool.renewals, 1)
  return FakeConn322(Threads.atomic_add!(pool.next_id, 1) + 1)
end
PormG.backend_cancel_query!(pool::MockSQLitePool322, conn) =
  (Threads.atomic_add!(pool.cancels, 1); nothing)
PormG.backend_drain_connection!(pool::MockSQLitePool322, conn) =
  (Threads.atomic_add!(pool.drains, 1); true)
# Runs on the global SQLite worker thread — keep it pure (no @test in here). `conn.busy` is set for
# exactly as long as the worker is on the handle, which is the window a release or close must not
# land in. Only BEGIN is gated: the point is to hold the worker inside the statement whose await the
# test is about to interrupt.
function PormG.backend_execute(pool::MockSQLitePool322, conn, sql::String, params)
  startswith(sql, "ROLLBACK") && Threads.atomic_add!(pool.rollbacks, 1)
  conn.busy[] = true
  try
    if pool.work_gate !== nothing && startswith(sql, "BEGIN")
      take!(pool.work_gate)
    end
    return NamedTuple[]
  finally
    conn.busy[] = false
  end
end

# Busy-wait until `pred()` or a deadline; returns whether it became true. (Named for this file so it
# cannot collide with the sibling pool tests' copies when the whole suite runs in one process.)
function _wait_until_322(pred; timeout = 5.0, step = 0.005)
  t0 = time()
  while time() - t0 < timeout
    pred() && return true
    sleep(step)
  end
  return pred()
end

# ─────────────────────────────────────────────────────────────────────────────
# The headline (#322): an interrupt during BEGIN never releases the connection
# The renew gate parks the detached recovery inside `backend_renew_connection`, so "still leased,
# nothing swapped" is observed rather than raced. `rollbacks == 0` is asserted too: the fix must
# reach the right end state WITHOUT starting to issue ROLLBACKs for a transaction that may never
# have opened — the behaviour the current code deliberately avoids.
#
# Reverted-fix signature: the old `finalize_transaction_connection!(…; rollback_error = nothing)`
# releases SYNCHRONOUSLY inside the finally, so `available[1]` is already `true` on the line after
# the throw and `renewals` stays 0 forever. No timing involved.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PG: an interrupted BEGIN renews the slot instead of releasing it (#322)" begin
  gate = Channel{Nothing}(1)
  pool = MockPGPool322(interrupt_sql = "BEGIN", renew_gate = gate)
  old = pool.connections[1]

  err = try
    CP.run_in_transaction(() -> error("body must never run"), pool)
    nothing
  catch e
    e
  end

  # The caller-visible error is UNCHANGED by this fix — still the taxonomy wrapper carrying the
  # interrupt as its cause, exactly as #315 pinned it for the plain-query path.
  @test err isa PormG.StatementError
  @test err.cause isa InterruptException

  @test pool.begins[] == 1
  @test pool.rollbacks[] == 0                          # no ROLLBACK for a BEGIN that may not have taken
  @test _wait_until_322(() -> pool.renewals[] == 1)     # ← the fix: recovery reached renewal…
  @test pool.available[1] === false                    # …and the slot is still leased while it does
  @test pool.connections[1] === old                    # nothing swapped yet
  @test pool.drains[] == 0                             # force_renew skips the drain entirely
  @test pool.cancels[] == 1                            # the cancel still runs first

  put!(gate, nothing)                                  # let the recovery finish
  @test _wait_until_322(() -> pool.available[1] === true)
  @test pool.connections[1] !== old                    # fresh handle in the slot
  @test pool.connections[1] !== nothing                # renewed, not emptied by the outer fallback
  @test old.closed === true                            # the dirty handle is closed, not leaked
  close(gate)
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite (#322): the worker must be off the connection before anything touches it
# Driven through the REAL global async worker with a REAL interrupt thrown into the awaiting task —
# the only configuration where the driver is genuinely still running when the transaction unwinds.
# That is the EXCEPTION_ACCESS_VIOLATION window, made observable.
#
# Reverted-fix signature: `available[1]` is already true while the worker is mid-backend_execute.
# The issue's own suggested one-liner fails here too, differently: it renews SYNCHRONOUSLY, so
# `closed_while_busy` is true — a use-after-free in mock form.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: an interrupted BEGIN IMMEDIATE never closes a handle in use (#322)" begin
  work_gate = Channel{Nothing}(1)
  pool = MockSQLitePool322(work_gate = work_gate)
  old = pool.connections[1]

  me = current_task()
  # `schedule(…; error = true)` is only safe on a task that is genuinely PARKED — on a runnable one
  # it would enqueue a second time. What guarantees that here is not the sleep: `sqlite_execute_async`
  # returns a `@async` task, which is STICKY to this thread, so `busy` can only become true after this
  # task has already yielded — and its only yield point before the assertions is the park inside
  # `_await_tx_statement`'s `Base.fetch`. (Keep that in mind before rewriting this with
  # `Threads.@spawn`, which would break the guarantee.) The sleep is slack, not the mechanism.
  Threads.@spawn begin
    # Bail out rather than fire blind: without this, a worker that never starts would deliver the
    # interrupt at an unpredictable line instead of failing cleanly.
    if _wait_until_322(() -> old.busy[])
      sleep(0.05)
      schedule(me, InterruptException(); error = true)
    end
  end

  err = try
    CP.run_in_transaction(() -> error("body must never run"), pool)
    nothing
  catch e
    e
  end

  @test err isa PormG.StatementError && err.cause isa InterruptException
  @test old.busy[] === true                            # the worker really is still on the handle…
  @test pool.available[1] === false                    # …and the slot was NOT handed back
  @test old.closed === false                           # nor was the handle closed under it
  @test pool.rollbacks[] == 0

  put!(work_gate, nothing)                             # let the worker finish
  @test _wait_until_322(() -> pool.renewals[] == 1)
  @test _wait_until_322(() -> pool.available[1] === true)
  @test pool.connections[1] !== old                    # renewed — the BEGIN IMMEDIATE may have taken
  @test old.closed === true
  @test old.closed_while_busy === false                # ← never closed under the worker
  @test pool.cancels[] == 1
  @test pool.drains[] == 0
  close(work_gate)
end

# ─────────────────────────────────────────────────────────────────────────────
# PRECISION (#322): an interrupt BETWEEN statements in the body still rolls back
# The guard against the fix OVER-firing, and the reason the branch is gated on `!tx_started` rather
# than on `_await_abandoned(e)` alone. Here the connection is CLEAN and holds an OPEN transaction:
# skipping the ROLLBACK and renewing would throw away a session for nothing and, worse, would make
# `_await_abandoned` — which answers `true` for ANY InterruptException — the sole decider.
#
# Scope note: the body here raises WITHOUT a query in flight, which is the case this asserts. An
# interrupt landing while a body query IS in flight is the out-of-scope case described in the file
# header — it does not reach this branch either, and nothing here claims it is handled.
#
# Signature if the `!tx_started` gate is dropped (verified, not assumed): the ROLLBACK still fires —
# that branch is independently gated — so `rollbacks` stays 1 and only the connection's fate changes.
# `available[1]` is `false` when the call returns and `cancels`/`renewals` reach 1. Which is why this
# testset asserts the FATE and not just the ROLLBACK: the ROLLBACK alone catches nothing here.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PG: an interrupt in the transaction body still rolls back and releases (#322)" begin
  pool = MockPGPool322()
  old = pool.connections[1]

  err = try
    CP.run_in_transaction(() -> throw(InterruptException()), pool)
    nothing
  catch e
    e
  end

  @test err isa InterruptException                     # the body's own error, unwrapped
  @test pool.begins[] == 1
  @test pool.rollbacks[] == 1                          # ← the ROLLBACK the fix must NOT skip
  @test pool.available[1] === true                     # released synchronously, as before
  @test pool.connections[1] === old                    # the same, clean handle
  @test pool.cancels[] == 0 && pool.renewals[] == 0    # recovery never involved
end

# ─────────────────────────────────────────────────────────────────────────────
# PRECISION (#322): a BEGIN the database genuinely refused is unchanged
# The other half of the over-firing guard. A refused statement leaves the connection clean, so it
# must take the plain release it always did — no cancel, no renewal, same handle back in the slot.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PG: a genuinely refused BEGIN still releases plainly (#322)" begin
  pool = MockPGPool322(fail_sql = "BEGIN")
  old = pool.connections[1]

  err = try
    CP.run_in_transaction(() -> error("body must never run"), pool)
    nothing
  catch e
    e
  end

  @test err isa PormG.DatabaseError
  @test pool.rollbacks[] == 0
  @test pool.available[1] === true
  @test pool.connections[1] === old
  @test pool.cancels[] == 0 && pool.renewals[] == 0
end

# ─────────────────────────────────────────────────────────────────────────────
# `with_transaction` (#322): both release points, and neither regression
# Site 2 of the issue. `rollback_failed` is `false` for every sql that is not a plain ROLLBACK, so
# the old code released a dirty handle from the `catch` (acquired-here) and from the `finally`
# (`release_conn = true`) alike. Both now go through the same `_finish_statement_connection!`.
#
# Reverted-fix signature (both abandoned cases): `available[1]` true immediately, `renewals` 0.
# ─────────────────────────────────────────────────────────────────────────────
@testset "with_transaction recovers an abandoned await at both release points (#322)" begin
  @testset "acquired here, release_conn = false (the catch)" begin
    gate = Channel{Nothing}(1)
    pool = MockPGPool322(interrupt_sql = "BEGIN", renew_gate = gate)
    old = pool.connections[1]

    err = try; CP.with_transaction(pool, "BEGIN;"); nothing; catch e; e; end

    @test err isa PormG.DatabaseError
    @test _wait_until_322(() -> pool.renewals[] == 1)
    @test pool.available[1] === false                  # still leased mid-recovery
    @test pool.connections[1] === old
    @test pool.drains[] == 0

    put!(gate, nothing)
    @test _wait_until_322(() -> pool.available[1] === true)
    @test pool.connections[1] !== old
    @test old.closed === true
    close(gate)
  end

  @testset "caller-owned conn, release_conn = true (the finally)" begin
    gate = Channel{Nothing}(1)
    pool = MockPGPool322(interrupt_sql = "COMMIT", renew_gate = gate)
    conn = CP.acquire_connection(pool)

    err = try
      CP.with_transaction(pool, "COMMIT;", conn = conn, release_conn = true)
      nothing
    catch e
      e
    end

    @test err isa PormG.DatabaseError
    @test _wait_until_322(() -> pool.renewals[] == 1)
    @test pool.available[1] === false

    put!(gate, nothing)
    @test _wait_until_322(() -> pool.available[1] === true)
    @test pool.connections[1] !== conn
    @test conn.closed === true
    close(gate)
  end

  # #71 must survive the new branch: a failed ROLLBACK is NOT an abandoned await, so it keeps its
  # SYNCHRONOUS renewal — no `_wait_until_322` here, deliberately. If the ordering in
  # `_finish_statement_connection!` were wrong (abandoned tested after rollback_failed, or the two
  # confused), this is what notices.
  @testset "a failed ROLLBACK still renews synchronously (#71 preserved)" begin
    pool = MockPGPool322(fail_sql = "ROLLBACK")
    conn = CP.acquire_connection(pool)

    try
      CP.with_transaction(pool, "ROLLBACK;", conn = conn, release_conn = true)
    catch
    end

    @test pool.renewals[] == 1                         # already done when the call returned
    @test pool.available[1] === true
    @test pool.connections[1] !== conn
    @test pool.cancels[] == 0                          # NOT the abandoned path
  end

  @testset "an ordinary statement failure still releases plainly" begin
    pool = MockPGPool322(fail_sql = "SELECT 1")
    conn = CP.acquire_connection(pool)

    try
      CP.with_transaction(pool, "SELECT 1;", conn = conn, release_conn = true)
    catch
    end

    @test pool.available[1] === true
    @test pool.connections[1] === conn
    @test pool.renewals[] == 0 && pool.cancels[] == 0
  end

  @testset "success releases exactly as before" begin
    pool = MockPGPool322()
    conn = CP.acquire_connection(pool)

    result, back = CP.with_transaction(pool, "SELECT 1;", conn = conn, release_conn = true)

    @test back === conn
    @test pool.available[1] === true
    @test pool.connections[1] === conn
    @test pool.renewals[] == 0 && pool.cancels[] == 0 && pool.drains[] == 0
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# `force_renew` (#322): a clean drain is not evidence, so do not ask
# The kwarg exists because `backend_drain_connection!` reports on the WIRE. This mock always reports
# clean, which is precisely the case that would release an open transaction back into the pool.
#
# Reverted-fix signature: `drains == 1` and `renewals == 0` — the connection is released instead.
# ─────────────────────────────────────────────────────────────────────────────
@testset "force_renew renews even when the connection drains clean (#322)" begin
  pool = MockPGPool322()
  conn = CP.acquire_connection(pool)
  handle = @async throw(InterruptException())          # already settled when recovery starts

  CP._recover_abandoned_connection!(pool, conn, handle; force_renew = true, settle_seconds = 5.0)

  @test _wait_until_322(() -> pool.renewals[] == 1)
  @test pool.drains[] == 0                             # ← never even asked
  @test _wait_until_322(() -> pool.available[1] === true)
  @test pool.connections[1] !== conn
  @test conn.closed === true
end

# The never-settles branch is shared with #315 and must be unaffected by `force_renew`: past the
# budget the slot leaves the pool WITHOUT closing (the driver may still be inside the handle), and
# the handle is closed only once it finally lets go. Renewal must NOT happen — renewing would close
# the handle in place, which is the use-after-free this branch exists to avoid.
@testset "force_renew still detaches rather than renewing a never-settling handle (#322)" begin
  settle_gate = Channel{Nothing}(1)
  pool = MockPGPool322()
  conn = CP.acquire_connection(pool)
  conn.busy[] = true                                   # the "driver" is on this handle
  handle = @async (take!(settle_gate); throw(InterruptException()))

  CP._recover_abandoned_connection!(pool, conn, handle;
                                    settle_seconds = 0.05, close_seconds = 5.0, force_renew = true)

  # Both facts in ONE predicate: `_discard_connection!` nils the slot and frees it inside a single
  # `pool.lock` section, but this reader does not hold that lock, so polling them separately could
  # observe the first write without the second.
  @test _wait_until_322(() -> pool.connections[1] === nothing && pool.available[1] === true)
  @test conn.closed === false                          # ← NOT closed while in use
  @test pool.renewals[] == 0                           # renewal would have closed it in place
  @test pool.drains[] == 0

  conn.busy[] = false
  put!(settle_gate, nothing)                           # driver finally lets go
  @test _wait_until_322(() -> conn.closed === true)     # only now is it closed
  @test conn.closed_while_busy === false
  close(settle_gate)
end

# The FetchTask arity is now a delegate to the (pool, conn, handle) method. #315's suite exercises it
# heavily; this pins that the delegate forwards kwargs, which those tests cannot see.
@testset "the FetchTask arity still delegates, kwargs included (#322)" begin
  pool = MockPGPool322()
  conn = CP.acquire_connection(pool)
  ft = CP.FetchTask((@async throw(InterruptException())), pool, conn, false)

  CP._recover_abandoned_connection!(ft; force_renew = true)

  @test _wait_until_322(() -> pool.renewals[] == 1)
  @test pool.drains[] == 0                             # the kwarg reached the primary method
end

# ─────────────────────────────────────────────────────────────────────────────
# AdvisoryLock (#322): an orphaned session lock is the worst consequence of the three
# Site 3. A `pg_advisory_lock` is bound to the SESSION, so a connection returned to the pool while
# holding one holds it for the life of the process — and the UNLOCK that would have released it is
# itself issued on the poisoned connection and fails. Renewal is the remedy, not a fallback:
# reconnecting ends the session, which drops the lock.
#
# Reverted-fix signature: `release_connection` in the finally → `available[1]` true immediately,
# `renewals` 0, and `connections[1] === old` — the same handle, still holding the lock.
# ─────────────────────────────────────────────────────────────────────────────
@testset "AdvisoryLock: an interrupted UNLOCK renews the connection (#322)" begin
  gate = Channel{Nothing}(1)
  pool = MockPGPool322(interrupt_sql = "SELECT pg_advisory_unlock", renew_gate = gate)
  old = pool.connections[1]

  # The lock IS taken and the body DOES run — only the release is interrupted. That is the shape
  # where the old code leaked the lock, and it is also what exercises the re-read of
  # `await_state.abandoned` after the unlock attempt.
  result = PormG.with_advisory_lock(() -> :body_ran, pool, "k322_unlock")

  @test result === :body_ran                           # the unlock failure is warned, not raised
  @test pool.unlocks[] == 1                            # it really was attempted
  @test _wait_until_322(() -> pool.renewals[] == 1)    # ← and its cancellation was noticed
  @test pool.available[1] === false

  put!(gate, nothing)
  @test _wait_until_322(() -> pool.available[1] === true)
  @test pool.connections[1] !== old                    # renewed → the session, and its lock, is gone
  @test old.closed === true
  close(gate)
end

@testset "AdvisoryLock: an interrupted lock query never issues an UNLOCK on it (#322)" begin
  gate = Channel{Nothing}(1)
  pool = MockPGPool322(interrupt_sql = "SELECT pg_try_advisory_lock", renew_gate = gate)
  old = pool.connections[1]

  err = try
    PormG.with_advisory_lock(() -> :body_ran, pool, "k322_try")
    nothing
  catch e
    e
  end

  @test err isa PormG.DatabaseError
  # `unlocks == 0` is a property rather than the mutation gate here (`got_lock` is false either way).
  # `renewals` is the gate: the old code released this connection straight back into the pool.
  @test pool.unlocks[] == 0
  @test _wait_until_322(() -> pool.renewals[] == 1)
  @test pool.available[1] === false

  put!(gate, nothing)
  @test _wait_until_322(() -> pool.available[1] === true)
  @test pool.connections[1] !== old
  close(gate)
end

# ─────────────────────────────────────────────────────────────────────────────
# PRECISION (#322): an interrupt in the LOCK BODY still unlocks and releases
# The advisory-lock twin of the transaction-body guard, and the reason abandonment is recorded per
# AWAIT (`_LockAwaitState`) instead of being recomputed from whatever error reaches the `finally`.
# Here the connection never left a clean state and the lock is genuinely held — skipping the UNLOCK
# would leak exactly the lock this fix exists to protect.
#
# Signature if the finally classified the propagating error instead: `unlocks == 0`, `renewals == 1`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "AdvisoryLock: an interrupt in the body still unlocks and releases (#322)" begin
  pool = MockPGPool322()
  old = pool.connections[1]

  err = try
    PormG.with_advisory_lock(() -> throw(InterruptException()), pool, "k322_body")
    nothing
  catch e
    e
  end

  @test err isa InterruptException
  @test pool.unlocks[] == 1                            # ← the UNLOCK the fix must NOT skip
  @test pool.available[1] === true                     # plain release
  @test pool.connections[1] === old
  @test pool.cancels[] == 0 && pool.renewals[] == 0
end

@testset "AdvisoryLock: an uninterrupted lock releases exactly as before (#322)" begin
  pool = MockPGPool322()
  old = pool.connections[1]

  @test PormG.with_advisory_lock(() -> :ok, pool, "k322_clean") === :ok
  @test pool.unlocks[] == 1
  @test pool.available[1] === true
  @test pool.connections[1] === old
  @test pool.cancels[] == 0 && pool.renewals[] == 0 && pool.drains[] == 0
end
