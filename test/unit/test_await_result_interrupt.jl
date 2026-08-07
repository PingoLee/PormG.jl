# ============================================================
# test/unit/test_await_result_interrupt.jl
#
# An ABANDONED await must never return its connection to the pool (#315).
#
# CONTRACT being tested:
#   `await_result` releases the pooled connection in its `finally`. That is correct when the await
#   ENDED — the query returned rows, or the database refused the statement — because the driver is
#   then done with the connection. It is wrong when the await was ABANDONED by a cancellation
#   (Ctrl-C), because the driver is still mid-operation:
#
#     * PostgreSQL — libpq has an unconsumed result queued on the socket. `backend_is_alive` is
#       `PQstatus(conn) == CONNECTION_OK`, which stays TRUE for such a connection, so neither
#       `release_connection` nor the next `acquire_connection` can tell it apart from a healthy one.
#       The next borrower then fails with "another command is already in progress" — forever.
#     * SQLite — the global async worker is still binding/stepping on that very handle. Handing it
#       back lets a second borrower run statements on it concurrently, and closing it (renew or
#       discard) frees it under the worker. That is the use-after-free class that produced an
#       EXCEPTION_ACCESS_VIOLATION on Windows once already.
#
#   So an abandoned await hands the connection to `_recover_abandoned_connection!` instead:
#   cancel → bounded wait for the driver to let go → drain → release if clean, renew/discard if not,
#   and if it never lets go, empty the slot WITHOUT closing the handle and close it later.
#
# Deterministic and DB-free: behavioral mock pools carry the exact fields the pool machinery reads
# (see test_fetch_retry_transaction.jl for the pattern) and gate every asynchronous step, so no
# assertion races the detached recovery task. The SQLite testset drives the REAL global worker.
#
# Reverting the fix (restoring the unconditional `release_connection` in await_result's `finally`)
# fails these synchronously — the old release happened INSIDE the finally, before `await_result`
# returned, so there is no race to lose. Each testset names its own revert signature below.
# ============================================================

using Test
using PormG

# No DB drivers needed: every backend_* call in these flows dispatches to the mock methods below,
# so this file runs without the LibPQ/SQLite weakdep extensions.

const CP = PormG.ConnectionPool

# ── Fake driver handle: tracks close, AND whether the driver was still on it at close time ──
# (structs live at file top level — Julia forbids type definitions inside @testset blocks)
#
# `closed_while_busy` is the use-after-free assertion in mock form. `busy` is set by the mock
# "driver" for as long as it is using the handle; a `close` landing in that window is exactly what
# frees a SQLite handle out from under `sqlite3_step`.
mutable struct FakeConn315
  id::Int
  closed::Bool
  closed_while_busy::Bool
  busy::Threads.Atomic{Bool}
end
FakeConn315(id::Int) = FakeConn315(id, false, false, Threads.Atomic{Bool}(false))
function Base.close(c::FakeConn315)
  c.busy[] && (c.closed_while_busy = true)
  c.closed = true
  return nothing
end

# ── PG-shaped mock: PostgresConnectionPool's exact fields + recovery knobs ──
#
# Counters are atomic because the recovery routine runs on a DETACHED task, so the test task reads
# them concurrently. `drain_gate`, when non-nothing, parks the recovery inside the drain — that is
# how the assertions below observe the slot mid-recovery instead of racing it.
mutable struct MockPGPool315 <: PormG.PormGPostgres
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
  cancels::Threads.Atomic{Int}          # backend_cancel_query! calls
  drains::Threads.Atomic{Int}           # backend_drain_connection! calls
  renewals::Threads.Atomic{Int}         # backend_renew_connection calls
  drain_clean::Any                      # what backend_drain_connection! reports (Any: a contract-
                                        # violating non-Bool is one of the cases under test)
  drain_gate::Union{Nothing, Channel{Nothing}}
  next_id::Threads.Atomic{Int}
end
MockPGPool315(; drain_clean = true, drain_gate = nothing) =
  MockPGPool315(Any[FakeConn315(1)], [true], "mock://pg", 1, ReentrantLock(),
                Threads.Atomic{Int}(0), Threads.Atomic{Int}(0), Threads.Atomic{Int}(0),
                drain_clean, drain_gate, Threads.Atomic{Int}(1))

PormG.backend_is_alive(::MockPGPool315, conn) = conn isa FakeConn315 && !conn.closed
PormG.backend_connect(pool::MockPGPool315; kwargs...) =
  FakeConn315(Threads.atomic_add!(pool.next_id, 1) + 1)
function PormG.backend_renew_connection(pool::MockPGPool315, conn; kwargs...)
  Threads.atomic_add!(pool.renewals, 1)
  return FakeConn315(Threads.atomic_add!(pool.next_id, 1) + 1)
end
PormG.backend_cancel_query!(pool::MockPGPool315, conn) =
  (Threads.atomic_add!(pool.cancels, 1); nothing)
function PormG.backend_drain_connection!(pool::MockPGPool315, conn)
  Threads.atomic_add!(pool.drains, 1)
  pool.drain_gate === nothing || take!(pool.drain_gate)   # park the recovery here on demand
  return pool.drain_clean
end

# ── SQLite-shaped mock: SQLiteConnectionPool's exact fields + the same knobs ──
# Statements funnel through the REAL global async worker → backend_execute, so the abandoned-await
# behaviour is proven on the actual SQLite code path rather than a stand-in.
mutable struct MockSQLitePool315 <: PormG.PormGSQLite
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  split_read_write::Bool
  writer_slot::Int
  reader_cursor::Int
  lock::ReentrantLock
  write_lock::ReentrantLock
  cancels::Threads.Atomic{Int}
  drains::Threads.Atomic{Int}
  renewals::Threads.Atomic{Int}
  drain_clean::Bool
  work_gate::Union{Nothing, Channel{Nothing}}   # blocks the worker INSIDE backend_execute
  next_id::Threads.Atomic{Int}
end
MockSQLitePool315(; drain_clean::Bool = true, work_gate = nothing) =
  MockSQLitePool315(Any[FakeConn315(1)], [true], "mock://sqlite", 1, false, 1, 0,
                    ReentrantLock(), ReentrantLock(),
                    Threads.Atomic{Int}(0), Threads.Atomic{Int}(0), Threads.Atomic{Int}(0),
                    drain_clean, work_gate, Threads.Atomic{Int}(1))

PormG.backend_is_alive(::MockSQLitePool315, conn) = conn isa FakeConn315 && !conn.closed
PormG.backend_connect(pool::MockSQLitePool315; read_only::Bool = false) =
  FakeConn315(Threads.atomic_add!(pool.next_id, 1) + 1)
function PormG.backend_renew_connection(pool::MockSQLitePool315, conn; read_only::Bool = false)
  Threads.atomic_add!(pool.renewals, 1)
  return FakeConn315(Threads.atomic_add!(pool.next_id, 1) + 1)
end
PormG.backend_cancel_query!(pool::MockSQLitePool315, conn) =
  (Threads.atomic_add!(pool.cancels, 1); nothing)
function PormG.backend_drain_connection!(pool::MockSQLitePool315, conn)
  Threads.atomic_add!(pool.drains, 1)
  return pool.drain_clean
end
# Runs on the global SQLite worker thread — keep it pure (no @test in here). `conn.busy` is set for
# exactly as long as the worker is on the handle, which is the window a release or close must not
# land in.
function PormG.backend_execute(pool::MockSQLitePool315, conn, sql::String, params)
  conn.busy[] = true
  try
    pool.work_gate === nothing || take!(pool.work_gate)
    return NamedTuple[]
  finally
    conn.busy[] = false
  end
end

# Busy-wait until `pred()` or a deadline; returns whether it became true. (Named for this file so it
# cannot collide with the sibling pool tests' copy when the whole suite runs in one process.)
function _wait_until_315(pred; timeout = 5.0, step = 0.005)
  t0 = time()
  while time() - t0 < timeout
    pred() && return true
    sleep(step)
  end
  return pred()
end

# The shape a SIGINT force-thrown into the driver's own result task produces: `Base.fetch` on it
# raises `TaskFailedException` wrapping the `InterruptException`. This is literally the trace in the
# #315 report ("nested task error: InterruptException").
_interrupted_handle() = @async throw(InterruptException())

# Run `await_result` on a fresh abandoned FetchTask and return the error it raised.
function _abandon_via_await_315(pool)
  ft = CP.fetch_async(pool, "SELECT surname FROM drivers;")
  try
    CP.await_result(ft)
    return (ft, nothing)
  catch e
    return (ft, e)
  end
end
PormG.backend_execute_async(pool::MockPGPool315, conn, sql::String, params) = _interrupted_handle()

# ─────────────────────────────────────────────────────────────────────────────
# Detection (#315): both real cancellation shapes must be recognised, and nothing else
# `_await_abandoned` is what decides the connection's fate, so it is unit-tested on its own before
# any pool is involved. The multi-element CompositeException case is why it cannot simply reuse
# `_unwrap_async_exception`, which stops at one.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_await_abandoned recognises a cancellation, not a refused statement (#315)" begin
  # Shape (b): the SIGINT hit the task doing the awaiting.
  @test CP._await_abandoned(InterruptException())

  # Shape (a): the SIGINT was force-thrown into the driver's result task.
  t = @async throw(InterruptException())
  wrapped = try; Base.fetch(t); catch e; e; end
  @test wrapped isa TaskFailedException
  @test CP._await_abandoned(wrapped)

  # LibPQ's handle_result bundles several failed results into ONE CompositeException; the interrupt
  # can be any member. `_unwrap_async_exception` gives up on a multi-element composite — this must not.
  @test CP._await_abandoned(CompositeException([ErrorException("boom"), InterruptException()]))
  @test !CP._await_abandoned(CompositeException([ErrorException("boom"), ErrorException("bang")]))

  # Already across the taxonomy seam (what `fetch`'s catch sees).
  @test CP._await_abandoned(PormG.StatementError("PostgreSQL", InterruptException()))
  @test !CP._await_abandoned(PormG.StatementError("PostgreSQL", ErrorException("syntax error")))

  # Ordinary failures are NOT abandonment — this is the guard against the fix over-firing.
  @test !CP._await_abandoned(ErrorException("relation does not exist"))
  @test !CP._await_abandoned(PormG.PoolTimeoutError("PostgreSQL", 1, 10, 1, 30.0))
end

# ─────────────────────────────────────────────────────────────────────────────
# The slot is NOT returned dirty (#315) — the headline assertion
# The drain gate parks the recovery task mid-flight, so `available[1] === false` is observed
# deterministically rather than raced. The raised error is pinned too: this fix deliberately does
# NOT change what the caller sees.
#
# Reverted-fix signature: the old `finally` calls release_connection SYNCHRONOUSLY, so `available[1]`
# is already `true` on the line after the throw. No timing involved.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an abandoned await leaves the slot leased, not released (#315)" begin
  gate = Channel{Nothing}(1)
  pool = MockPGPool315(drain_gate = gate)
  old = pool.connections[1]

  ft, err = _abandon_via_await_315(pool)

  @test ft.abandoned === true                          # the await was classified as cancelled
  @test pool.available[1] === false                    # ← the fix: slot still leased
  @test pool.connections[1] === old                    # nothing swapped yet
  # The caller-visible error is UNCHANGED by this fix: still the taxonomy wrapper, still carrying
  # the interrupt as its cause. (Surfacing Ctrl-C as a StatementError is its own defect, tracked
  # separately — pinning it here is what stops this PR from changing it by accident.)
  @test err isa PormG.StatementError
  @test err.cause isa InterruptException

  put!(gate, nothing)                                  # let the recovery finish
  @test _wait_until_315(() -> pool.available[1] === true)
  close(gate)
end

# ─────────────────────────────────────────────────────────────────────────────
# Ordering (#315): cancel first, drain only once the driver has let go
# Draining while the driver still holds the connection is not merely wasteful — LibPQ's per-connection
# lock is a plain Semaphore(1) held by the result task for the whole query, so the drain would block
# for the runaway query's entire remaining life. PQcancel is the one call safe to issue in that window.
#
# Reverted-fix signature: `cancels` stays 0 forever, so the first _wait_until_315 returns false.
# ─────────────────────────────────────────────────────────────────────────────
@testset "recovery cancels before it touches the connection (#315)" begin
  settle_gate = Channel{Nothing}(1)
  pool = MockPGPool315()
  conn = CP.acquire_connection(pool)
  # A handle that is still in flight: it settles only when the test opens the gate.
  handle = @async (take!(settle_gate); throw(InterruptException()))
  ft = CP.FetchTask(handle, pool, conn, false)

  CP._recover_abandoned_connection!(ft; settle_seconds = 5.0)

  @test _wait_until_315(() -> pool.cancels[] == 1)      # cancel is issued immediately…
  @test pool.drains[] == 0                             # …and nothing else is, while it is in flight
  @test pool.available[1] === false                    # slot stays leased throughout

  put!(settle_gate, nothing)                           # driver lets go
  @test _wait_until_315(() -> pool.drains[] == 1)      # only now is the connection touched
  @test _wait_until_315(() -> pool.available[1] === true)
  close(settle_gate)
end

# ─────────────────────────────────────────────────────────────────────────────
# Clean drain (#315): the SAME handle goes back into the SAME slot
# A connection that drained cleanly is healthy — renewing it would throw away a good session for
# nothing. The pre-gate assertion pins the ORDER, so this cannot pass merely by reaching the right
# end state eventually.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a clean drain releases the same handle (#315)" begin
  gate = Channel{Nothing}(1)
  pool = MockPGPool315(drain_clean = true, drain_gate = gate)
  old = pool.connections[1]

  _abandon_via_await_315(pool)
  @test pool.available[1] === false                    # pre-gate: recovery has NOT released yet

  put!(gate, nothing)
  @test _wait_until_315(() -> pool.available[1] === true)
  @test pool.connections[1] === old                    # same handle, same slot
  @test old.closed === false                           # and it was not thrown away
  @test pool.renewals[] == 0
  @test pool.drains[] == 1
  close(gate)
end

# ─────────────────────────────────────────────────────────────────────────────
# Failed drain (#315): renew the slot instead of releasing it
# This is the branch that actually stops the reported bug when a cancel does not clear the socket:
# the dirty handle is replaced in its slot and closed, so no borrower can ever reach it.
#
# Reverted-fix signature: `renewals` stays 0 and the dirty `old` is back in the pool, available.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a failed drain renews the slot and closes the dirty handle (#315)" begin
  gate = Channel{Nothing}(1)
  pool = MockPGPool315(drain_clean = false, drain_gate = gate)
  old = pool.connections[1]

  _abandon_via_await_315(pool)
  @test pool.available[1] === false

  put!(gate, nothing)
  @test _wait_until_315(() -> pool.renewals[] == 1)
  @test _wait_until_315(() -> pool.available[1] === true)
  @test pool.connections[1] !== old                    # fresh handle in the slot
  @test old.closed === true                            # dirty handle closed, not leaked
  # (No `closed_while_busy` assertion here: this pool's driver never sets `busy`, so it would read
  # `false` whatever the code did. The in-use close is proven where `busy` is really modelled —
  # the never-settling testset below, and the SQLite one.)
  close(gate)
end

# ─────────────────────────────────────────────────────────────────────────────
# A misbehaving backend must not cost the slot (#315)
# `backend_drain_connection!` is documented to return Bool, and NOTHING enforces that — a downstream
# backend override or a future driver could return something else. The recovery is the last code
# holding this slot, so a TypeError there would leave it leased for the life of the process: #315
# again, in a new place. Anything that is not a definite `true` must take the safe branch.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a non-Bool drain result renews the slot rather than losing it (#315)" begin
  pool = MockPGPool315(drain_clean = nothing)          # violates the Bool contract
  old = pool.connections[1]

  _abandon_via_await_315(pool)

  @test _wait_until_315(() -> pool.available[1] === true)   # the slot comes back at all…
  @test pool.renewals[] == 1                           # ← …and via the SAFE branch, which is the point
  # Distinguishes "renewed" from "the outer-catch fallback emptied the slot": the fallback leaves
  # `nothing` behind, and on its own `available[1] === true` cannot tell the two apart.
  @test pool.connections[1] !== nothing
  @test pool.connections[1] !== old
end

# ─────────────────────────────────────────────────────────────────────────────
# Never settles (#315): empty the slot WITHOUT closing the handle
# Past the settle budget the connection is unrecoverable, but the driver may still be inside it —
# on SQLite, inside sqlite3_step. So the slot leaves the pool immediately (nobody can borrow it) and
# the handle is closed only once the driver finally lets go.
#
# Reverted-fix signature (of the `close_handle = false` kwarg specifically): `_discard_connection!`
# closes straight away and `closed_while_busy` is true — a use-after-free in mock form.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a never-settling driver detaches the slot without closing the handle (#315)" begin
  settle_gate = Channel{Nothing}(1)
  pool = MockPGPool315()
  conn = CP.acquire_connection(pool)
  conn.busy[] = true                                   # the "driver" is on this handle
  handle = @async (take!(settle_gate); throw(InterruptException()))
  ft = CP.FetchTask(handle, pool, conn, false)

  CP._recover_abandoned_connection!(ft; settle_seconds = 0.05, close_seconds = 5.0)

  # Both facts in ONE predicate: `_discard_connection!` nils the slot and frees it inside a single
  # `pool.lock` section, but this reader does not hold that lock, so polling them separately could
  # observe the first write without the second.
  @test _wait_until_315(() -> pool.connections[1] === nothing && pool.available[1] === true)
  @test conn.closed === false                          # ← the handle is NOT closed while in use
  @test pool.drains[] == 0                             # nothing tried to read it, either

  conn.busy[] = false
  put!(settle_gate, nothing)                           # driver finally lets go
  @test _wait_until_315(() -> conn.closed === true)     # only now is it closed
  @test conn.closed_while_busy === false
  close(settle_gate)
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite (#315): the worker must be off the connection before anything touches it
# Driven through the REAL global async worker, with a REAL interrupt thrown into the awaiting task
# (shape (b)) — the only configuration in this file where the driver is genuinely still running when
# `await_result` unwinds. That is the EXCEPTION_ACCESS_VIOLATION window, made observable.
#
# Reverted-fix signature: `available[1]` is already true while the worker is mid-backend_execute.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: the worker is off the connection before it is reused (#315)" begin
  work_gate = Channel{Nothing}(1)
  pool = MockSQLitePool315(work_gate = work_gate)
  old = pool.connections[1]

  # Acquire the FetchTask FIRST, so a premature interrupt can only land inside `await_result`.
  ft = CP.fetch_async(pool, "SELECT surname FROM drivers;")
  me = current_task()
  # `schedule(…; error = true)` is only safe on a task that is genuinely PARKED — on a runnable one
  # it would enqueue a second time. What guarantees that here is not the sleep: `sqlite_execute_async`
  # returns a `@async` task, which is STICKY to this thread, so `busy` can only become true after
  # this task has already yielded — and between `fetch_async` and the assertions its only yield point
  # is the park inside `await_result`'s `Base.fetch`. (Keep that in mind before rewriting this with
  # `Threads.@spawn`, which would break the guarantee.) The sleep is slack, not the mechanism.
  Threads.@spawn begin
    # Bail out rather than fire blind: without this, a worker that never starts would deliver the
    # interrupt at an unpredictable line instead of failing cleanly.
    if _wait_until_315(() -> old.busy[])
      sleep(0.05)
      schedule(me, InterruptException(); error = true)
    end
  end

  err = try; CP.await_result(ft); nothing; catch e; e; end

  @test ft.abandoned === true
  @test old.busy[] === true                            # the worker really is still on the handle…
  @test pool.available[1] === false                    # …and the slot was NOT handed back
  @test old.closed === false                           # nor was the handle closed under it
  @test err isa PormG.StatementError && err.cause isa InterruptException

  put!(work_gate, nothing)                             # let the worker finish
  @test _wait_until_315(() -> pool.available[1] === true)
  @test pool.connections[1] === old                    # SQLite has nothing to drain → plain release
  @test old.closed === false                           # a clean handle is never thrown away…
  @test old.closed_while_busy === false                # …and was never closed under the worker
  @test pool.cancels[] == 1
  close(work_gate)
end

# ─────────────────────────────────────────────────────────────────────────────
# Regression (#315): every NON-abandoned path releases exactly as it did before
# The guard against the fix OVER-firing. A successful query and an ordinary database failure must
# both still take the plain `release_connection` branch, on both backends — no cancel, no drain, no
# renewal, and the same connection back in the same slot.
# ─────────────────────────────────────────────────────────────────────────────
mutable struct MockPGPlain315 <: PormG.PormGPostgres
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
  fail::Bool
  cancels::Threads.Atomic{Int}
  drains::Threads.Atomic{Int}
  renewals::Threads.Atomic{Int}
end
MockPGPlain315(; fail::Bool = false) =
  MockPGPlain315(Any[FakeConn315(1)], [true], "mock://pg", 1, ReentrantLock(), fail,
                 Threads.Atomic{Int}(0), Threads.Atomic{Int}(0), Threads.Atomic{Int}(0))
PormG.backend_is_alive(::MockPGPlain315, conn) = conn isa FakeConn315 && !conn.closed
PormG.backend_connect(pool::MockPGPlain315; kwargs...) = FakeConn315(99)
PormG.backend_renew_connection(pool::MockPGPlain315, conn; kwargs...) =
  (Threads.atomic_add!(pool.renewals, 1); FakeConn315(99))
PormG.backend_cancel_query!(pool::MockPGPlain315, conn) =
  (Threads.atomic_add!(pool.cancels, 1); nothing)
PormG.backend_drain_connection!(pool::MockPGPlain315, conn) =
  (Threads.atomic_add!(pool.drains, 1); true)
PormG.backend_execute_async(pool::MockPGPlain315, conn, sql::String, params) =
  @async (pool.fail && error("mock: relation \"drivers\" does not exist"); NamedTuple[])

@testset "un-abandoned awaits release exactly as before (#315)" begin
  @testset "PostgreSQL success" begin
    pool = MockPGPlain315()
    old = pool.connections[1]
    ft = CP.fetch_async(pool, "SELECT surname FROM drivers;")

    @test CP.await_result(ft) == NamedTuple[]
    @test ft.abandoned === false
    @test pool.available[1] === true                   # released synchronously, as always
    @test pool.connections[1] === old
    @test pool.cancels[] == 0 && pool.drains[] == 0 && pool.renewals[] == 0
  end

  @testset "PostgreSQL statement failure" begin
    pool = MockPGPlain315(fail = true)
    old = pool.connections[1]
    ft = CP.fetch_async(pool, "SELECT surname FROM drivers;")

    err = try; CP.await_result(ft); nothing; catch e; e; end
    # Pin the CONCRETE type, mirroring the abandoned twin above: the umbrella `DatabaseError` would
    # still pass if the mock's failure were reclassified, which is the thing worth noticing.
    @test err isa PormG.StatementError
    @test ft.abandoned === false                       # a refused statement is NOT abandonment
    @test pool.available[1] === true
    @test pool.connections[1] === old
    @test pool.cancels[] == 0 && pool.drains[] == 0 && pool.renewals[] == 0
  end

  @testset "SQLite success through the real worker" begin
    pool = MockSQLitePool315()                         # no work_gate → backend_execute returns at once
    old = pool.connections[1]
    ft = CP.fetch_async(pool, "SELECT surname FROM drivers;")

    @test CP.await_result(ft) == NamedTuple[]
    @test ft.abandoned === false
    @test pool.available[1] === true
    @test pool.connections[1] === old
    @test pool.cancels[] == 0 && pool.drains[] == 0 && pool.renewals[] == 0
  end
end
