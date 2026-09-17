# ============================================================
# test/unit/test_discard_not_found_close.jl
#
# A handle the pool no longer holds is closed by whoever took it out — never a second time (#585).
#
# CONTRACT being tested:
#   `_discard_connection!(pool, conn)` empties `conn`'s slot and closes the handle. When the handle
#   is NOT in any slot (`found == false`) it has already been taken out by another party — the
#   `close_pool!` sweep (#47), the reaper (#125), a stale-idle sweep (#442) or a renewal (#71) — and
#   that taker owns the close. Closing again here used to be harmless only because the second close
#   was serialized behind the first under `pool.lock`; since #47 closes run OUTSIDE the lock (and on
#   SQLite may be deferred onto a task until the global worker's ledger drains, #327), two closers of
#   one handle can overlap. LibPQ's `close` is CAS-guarded; SQLite.jl's `_close_db!` is not, so two
#   concurrent `sqlite3_close_v2` calls on the same pointer are a real double free.
#
#   The same rule applies to the second closer: `_recover_abandoned_connection!`'s timeout branch
#   discards with `close_handle = false` and closes later itself — but only if its discard found the
#   slot. If the sweep took the slot first, the sweep's (possibly deferred) closer and this task were
#   both keyed to the same moment — the abandoned statement finishing — and closed within one poll
#   window of each other.
#
# Deterministic and DB-free: mock pools carry the exact fields the pool machinery reads, and the
# fake handle COUNTS its closes (a Bool cannot tell one close from two). The SQLite twins bump the
# #327 ledger by hand — pure bookkeeping, no worker involvement — so the sweep's close is the
# deferred kind, which is the overlap the issue describes.
#
# Reverting the fix (closing regardless of `found`; closing unconditionally after the timeout wait)
# turns every `closes[] == 1` below into 2 — each testset names that gate.
# ============================================================

using Test
using Logging
using PormG

const CP = PormG.ConnectionPool

# ── Fake driver handle: counts closes ──
# (structs live at file top level — Julia forbids type definitions inside @testset blocks)
mutable struct FakeConn585
  id::Int
  closes::Threads.Atomic{Int}     # atomic: the deferred closers run on their own tasks
end
FakeConn585(id::Int) = FakeConn585(id, Threads.Atomic{Int}(0))
Base.close(c::FakeConn585) = (Threads.atomic_add!(c.closes, 1); nothing)
Base.isopen(c::FakeConn585) = c.closes[] == 0

# ── PG-shaped mock: PostgresConnectionPool's exact fields + the recovery-path generics ──
mutable struct MockPGPool585 <: PormG.PormGPostgres
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
  next_id::Threads.Atomic{Int}
  cancels::Threads.Atomic{Int}    # backend_cancel_query! calls — "the recovery task got going"
end
MockPGPool585() = MockPGPool585(Any[FakeConn585(1)], [true], "mock://pg", 1, ReentrantLock(),
                                Threads.Atomic{Int}(1), Threads.Atomic{Int}(0))
PormG.backend_is_alive(::MockPGPool585, c) = c isa FakeConn585 && isopen(c)
PormG.backend_connect(p::MockPGPool585; kwargs...) = FakeConn585(Threads.atomic_add!(p.next_id, 1) + 1)
PormG.backend_renew_connection(p::MockPGPool585, c; kwargs...) = FakeConn585(Threads.atomic_add!(p.next_id, 1) + 1)
PormG.backend_cancel_query!(p::MockPGPool585, c) = (Threads.atomic_add!(p.cancels, 1); nothing)
PormG.backend_drain_connection!(::MockPGPool585, c) = true

# ── SQLite-shaped mock: SQLiteConnectionPool's exact fields, so `_close_driver_handle!` takes the
# deferred (#327) path when the ledger says the worker still has statements for the handle ──
mutable struct MockSQLitePool585 <: PormG.PormGSQLite
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  split_read_write::Bool
  writer_slot::Int
  reader_cursor::Int
  lock::ReentrantLock
  write_lock::ReentrantLock
  next_id::Threads.Atomic{Int}
  cancels::Threads.Atomic{Int}
end
MockSQLitePool585() = MockSQLitePool585(Any[FakeConn585(1)], [true], "mock://sqlite", 1, false, 1, 0,
                                        ReentrantLock(), ReentrantLock(),
                                        Threads.Atomic{Int}(1), Threads.Atomic{Int}(0))
PormG.backend_is_alive(::MockSQLitePool585, c) = c isa FakeConn585 && isopen(c)
PormG.backend_connect(p::MockSQLitePool585; kwargs...) = FakeConn585(Threads.atomic_add!(p.next_id, 1) + 1)
PormG.backend_renew_connection(p::MockSQLitePool585, c; kwargs...) = FakeConn585(Threads.atomic_add!(p.next_id, 1) + 1)
PormG.backend_cancel_query!(p::MockSQLitePool585, c) = (Threads.atomic_add!(p.cancels, 1); nothing)
PormG.backend_drain_connection!(::MockSQLitePool585, c) = true

# Poll until `pred()` or a deadline; returns whether it became true. Uniquely named — every unit
# file lands in one module.
function _wait_until_585(pred; timeout = 5.0, step = 0.005)
  t0 = time()
  while time() - t0 < timeout
    pred() && return true
    sleep(step)
  end
  return pred()
end

# Deferred closers poll the #327 ledger every 50 ms, so two of them released by the same event land
# within about one poll of each other. Waiting an order of magnitude longer before reading the
# counter is what makes "exactly one" a claim about the second closer, not about timing.
const _SECOND_CLOSER_GRACE = 0.5

# The mock's `close_pool!` is the #147 no-op fallback, so the sweep body is called directly — the
# same body the concrete pool structs dispatch to.
_sweep!(pool) = @test_logs (:warn, r"checked out") CP._close_pool_slots!(pool; drain_seconds = 0)

# ─────────────────────────────────────────────────────────────────────────────
# Control: the found path still closes, and exactly once.
# Pins that gating on `found` did not over-fire — the ordinary discard of a leased handle (a failed
# ROLLBACK whose renewal also failed, #71) closes it as before.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_discard_connection! on a pooled handle closes it exactly once (#585)" begin
  pool = MockPGPool585()
  c1 = CP.acquire_connection(pool)

  @test CP._discard_connection!(pool, c1) === true
  @test c1.closes[] == 1
  @test pool.connections[1] === nothing && pool.available[1] === true
end

# ─────────────────────────────────────────────────────────────────────────────
# Not found → not closed: the sweep already owns that close (#585)
# The reachable shape: a borrower whose handle `close_pool!` force-closed reaches
# `_renew_or_discard_connection!` → `reconnect_db` (slot not found) → `_discard_connection!`.
# Gate: `closes[] == 2` when the not-found path closes anyway.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_discard_connection! does not close a handle the sweep already took out (#585)" begin
  pool = MockPGPool585()
  c1 = CP.acquire_connection(pool)                     # leased; the sweep force-closes it
  _sweep!(pool)
  @test c1.closes[] == 1

  found = @test_logs (:warn, r"not found") CP._discard_connection!(pool, c1)
  @test found === false
  @test c1.closes[] == 1                               # ← the second closer stayed out
  @test pool.connections[1] === nothing && pool.available[1] === true   # pool untouched
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite, deferred: two deferred closers on one handle become one (#585)
# The worst case from the issue. The ledger says the global worker still has a statement for c1,
# so the sweep's close is deferred onto a task that polls the ledger. A discard that closed anyway
# would queue a SECOND deferred closer polling the same ledger; both would wake within the same
# 50 ms window and both call `sqlite3_close_v2` on the same pointer. Gate: `closes[] == 2` once the
# ledger drains.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: a discard after a deferred sweep close does not queue a second closer (#585)" begin
  pool = MockSQLitePool585()
  c1 = CP.acquire_connection(pool)
  CP._sqlite_pending_inc!(c1)                          # "the worker is still on this handle"
  try
    _sweep!(pool)
    @test c1.closes[] == 0                             # deferred, not closed under the worker

    found = @test_logs (:warn, r"not found") CP._discard_connection!(pool, c1)
    @test found === false
    @test c1.closes[] == 0                             # …and no immediate close either
  finally
    CP._sqlite_pending_dec!(c1)                        # the worker lets go
  end
  @test _wait_until_585(() -> c1.closes[] >= 1)        # the sweep's deferred close lands
  sleep(_SECOND_CLOSER_GRACE)
  @test c1.closes[] == 1                               # ← and nothing else did
end

# ─────────────────────────────────────────────────────────────────────────────
# Recovery timeout branch: no close when the discard found nothing (#585, second site)
# The connection is leased for the whole recovery, so a sweep in the meantime takes it. The
# recovery's timeout branch then discards (not found) and, before the fix, closed unconditionally
# once its settle probe let go. Gate: `closes[] == 2` after the close budget.
# ─────────────────────────────────────────────────────────────────────────────
@testset "recovery timeout branch skips the close when the sweep already took the slot (#585)" begin
  settle_gate = Channel{Nothing}(1)
  pool = MockPGPool585()
  c1 = CP.acquire_connection(pool)
  _sweep!(pool)                                        # took the leased slot; closed c1 once
  @test c1.closes[] == 1

  handle = @async take!(settle_gate)                   # never settles inside the budgets below
  CP._recover_abandoned_connection!(pool, c1, handle; settle_seconds = 0.05, close_seconds = 0.2)
  @test _wait_until_585(() -> pool.cancels[] == 1)    # the recovery task ran
  sleep(0.05 + 0.2 + _SECOND_CLOSER_GRACE)             # past both budgets
  @test c1.closes[] == 1                               # ← no second close
  @test pool.connections[1] === nothing && pool.available[1] === true

  put!(settle_gate, nothing)                           # let the settle probe exit
  sleep(_SECOND_CLOSER_GRACE)
  @test c1.closes[] == 1                               # ← nor after the driver "let go"
  close(settle_gate)
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite twin of the recovery overlap: the shape the issue calls most likely (#585)
# The sweep's deferred closer waits on the ledger; the recovery waits on its settle probe. Both are
# released by the same event — the abandoned statement finishing — so they used to close within the
# same poll window. Here that event is the ledger decrement plus the gate; exactly one close lands.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: recovery and a deferred sweep close released together close once (#585)" begin
  settle_gate = Channel{Nothing}(1)
  pool = MockSQLitePool585()
  c1 = CP.acquire_connection(pool)
  CP._sqlite_pending_inc!(c1)
  _sweep!(pool)                                        # deferred closer parked on the ledger
  @test c1.closes[] == 0

  handle = @async take!(settle_gate)
  CP._recover_abandoned_connection!(pool, c1, handle; settle_seconds = 0.05, close_seconds = 0.2)
  @test _wait_until_585(() -> pool.cancels[] == 1)
  sleep(0.05 + 0.2 + _SECOND_CLOSER_GRACE)             # past both budgets, ledger still held
  @test c1.closes[] == 0

  CP._sqlite_pending_dec!(c1)                          # the statement finishes…
  put!(settle_gate, nothing)                           # …which is the same moment for both waiters
  @test _wait_until_585(() -> c1.closes[] >= 1)
  sleep(_SECOND_CLOSER_GRACE)
  @test c1.closes[] == 1                               # ← one closer, not two
  close(settle_gate)
end
