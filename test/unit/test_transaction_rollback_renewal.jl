# ============================================================
# test/unit/test_transaction_rollback_renewal.jl
#
# Failed ROLLBACK → connection renewed or discarded, never returned dirty (#71).
#
# CONTRACT being tested:
#   When a transaction body throws AND the ROLLBACK itself fails, `_run_in_transaction_impl`
#   must NOT hand the connection back to the pool as-is (it may still hold an open/aborted
#   transaction that `backend_is_alive` cannot detect). Instead the `finally` renews the
#   connection in its slot via `reconnect_db` (releasing the RENEWED handle — the slot is
#   replaced in place and `release_connection` matches by identity), or — if renewal also
#   fails — discards the slot (`nothing` + available) so the next borrower opens a fresh
#   physical connection. The transaction body's ORIGINAL error must keep propagating, and
#   SQLite's benign "no transaction is active" rollback error must still release normally.
#
# Deterministic and DB-free: behavioral mock pools carry the exact fields the pool machinery
# reads (acquire/release/reconnect are generic over PormGPostgres/PormGSQLite), fake driver
# handles track `close`, and `backend_*` overrides on the mock types simulate driver failures.
# The PG mock fails ROLLBACK *inside* the `@async` task so `Base.fetch` surfaces a
# TaskFailedException — the wrapped form the real async paths produce; the SQLite mock fails
# it on the real global async worker. Reverting the fix (releasing the dirty handle from the
# `finally`) fails the slot-identity assertions — the mutation gate.
# ============================================================

using Test
using PormG

# No DB drivers needed: every backend_* call in these flows dispatches to the mock methods
# below, so this file runs without the LibPQ/SQLite weakdep extensions.

const CP = PormG.ConnectionPool

# ── Fake driver handle: tracks whether the pool cleanup closed it ──
# (structs live at file top level — Julia forbids type definitions inside @testset blocks)
mutable struct FakeConn71
  id::Int
  closed::Bool
end
FakeConn71(id::Int) = FakeConn71(id, false)
Base.close(c::FakeConn71) = (c.closed = true; nothing)

# ── PG-shaped mock: PostgresConnectionPool's exact fields + failure knobs ──
mutable struct MockPGPool71 <: PormG.PormGPostgres
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
  fail_rollback::Bool     # ROLLBACK task throws (inside the task → TaskFailedException)
  fail_renew::Bool        # backend_renew_connection throws → reconnect_db → nothing → discard
  renew_in_place::Bool    # renew returns the SAME handle (LibPQ.reset! semantics)
  next_id::Int            # id source for freshly "connected"/renewed FakeConn71s
  executed::Vector{String}
end
MockPGPool71(; fail_rollback::Bool = false, fail_renew::Bool = false, renew_in_place::Bool = false) =
  MockPGPool71(Any[FakeConn71(1)], [true], "mock://pg", 1, ReentrantLock(),
               fail_rollback, fail_renew, renew_in_place, 1, String[])

PormG.backend_is_alive(::MockPGPool71, conn) = conn isa FakeConn71 && !conn.closed
PormG.backend_connect(pool::MockPGPool71; kwargs...) = FakeConn71(pool.next_id += 1)
function PormG.backend_execute_async(pool::MockPGPool71, conn, sql::String, params)
  push!(pool.executed, sql)
  # Fail INSIDE the task (like a real async driver failure) so Base.fetch throws a
  # TaskFailedException and the rollback catch exercises _unwrap_async_exception.
  return @async begin
    if pool.fail_rollback && startswith(sql, "ROLLBACK")
      error("mock: rollback refused")
    end
    nothing
  end
end
function PormG.backend_renew_connection(pool::MockPGPool71, conn; kwargs...)
  pool.fail_renew && error("mock: renew refused")
  return pool.renew_in_place ? conn : FakeConn71(pool.next_id += 1)
end

# ── SQLite-shaped mock: SQLiteConnectionPool's exact fields + a rollback-error knob.
#    Statements funnel through the REAL global async worker → backend_execute, proving the
#    PG/SQLite policy alignment on the actual SQLite code path. ──
mutable struct MockSQLitePool71 <: PormG.PormGSQLite
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  split_read_write::Bool
  writer_slot::Int
  reader_cursor::Int
  lock::ReentrantLock
  write_lock::ReentrantLock
  rollback_error_msg::Union{Nothing, String}  # nothing → ROLLBACK succeeds
  next_id::Int
end
MockSQLitePool71(; rollback_error_msg::Union{Nothing, String} = nothing) =
  MockSQLitePool71(Any[FakeConn71(1)], [true], "mock://sqlite", 1, false, 1, 0,
                   ReentrantLock(), ReentrantLock(), rollback_error_msg, 1)

PormG.backend_is_alive(::MockSQLitePool71, conn) = conn isa FakeConn71 && !conn.closed
PormG.backend_connect(pool::MockSQLitePool71; read_only::Bool = false) = FakeConn71(pool.next_id += 1)
PormG.backend_renew_connection(pool::MockSQLitePool71, conn; read_only::Bool = false) = FakeConn71(pool.next_id += 1)
function PormG.backend_execute(pool::MockSQLitePool71, conn, sql::String, params)
  # Runs on the global SQLite worker thread — keep it pure (no @test in here); the raised
  # error travels back to the caller as the @async task's failure (→ TaskFailedException).
  if pool.rollback_error_msg !== nothing && startswith(sql, "ROLLBACK")
    error(pool.rollback_error_msg)
  end
  return NamedTuple[]
end

# Run a transaction whose body throws ErrorException("boom") and return the caught value —
# every testset asserts the BODY error propagates (never the rollback/renewal error).
function run_failing_tx_71(pool)
  try
    CP.run_in_transaction(pool) do
      error("boom")
    end
    return nothing
  catch e
    return e
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Transactions (#71): PG failed ROLLBACK → slot renewed, original error preserved
# The dirty handle must be replaced in its slot (reconnect_db) and CLOSED, the slot must be
# available again, the next borrower must get the renewed handle, and the caller must see
# the body's "boom" — not the rollback error. Also gates the structured @error log.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PG failed rollback renews the pooled connection (#71)" begin
  pool = MockPGPool71(fail_rollback = true)
  old = pool.connections[1]

  err = @test_logs (:error, r"Failed to rollback transaction") match_mode=:any begin
    run_failing_tx_71(pool)
  end

  @test err isa ErrorException && err.msg == "boom"   # root cause wins, not "rollback refused"
  @test pool.connections[1] !== old                   # slot renewed (identity changed)
  @test pool.connections[1] isa FakeConn71 && pool.connections[1].id == 2
  @test pool.available[1] === true                    # renewed handle released (not the stale one)
  @test old.closed === true                           # dirty handle closed, not leaked to GC
  # BEGIN and ROLLBACK were issued; COMMIT never was (the body threw before it).
  @test any(sql -> startswith(sql, "BEGIN"), pool.executed)
  @test any(sql -> startswith(sql, "ROLLBACK"), pool.executed)
  @test !any(sql -> startswith(sql, "COMMIT"), pool.executed)
  # The next borrower gets the RENEWED connection, never the dirty one.
  c = CP.acquire_connection(pool)
  @test c === pool.connections[1] && c !== old
  CP.release_connection(pool, c)
end

# ─────────────────────────────────────────────────────────────────────────────
# Transactions (#71): PG in-place renewal (LibPQ.reset! semantics) → same handle, NOT closed
# backend_renew_connection may reset the connection IN PLACE and return the SAME object
# (LibPQ.reset!). The cleanup must then release that handle without closing it — closing a
# live, just-reset connection would kill it. Mutation gate for the `new_conn !== conn` guard.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PG in-place renewal releases the reset handle unclosed (#71)" begin
  pool = MockPGPool71(fail_rollback = true, renew_in_place = true)
  old = pool.connections[1]

  err = @test_logs (:error, r"Failed to rollback transaction") match_mode=:any begin
    run_failing_tx_71(pool)
  end

  @test err isa ErrorException && err.msg == "boom"
  @test pool.connections[1] === old                   # reset in place: same object stays in the slot
  @test pool.available[1] === true                    # and it was released (identity trap avoided)
  @test old.closed === false                          # a live reset handle must NOT be closed
end

# ─────────────────────────────────────────────────────────────────────────────
# Transactions (#71): PG renewal failure → slot discarded, next acquire reconnects fresh
# When reconnect_db cannot renew (driver renewal throws), the dirty handle must be closed and
# its slot cleared (`nothing` + available) so the next borrower opens a brand-new physical
# connection through the existing empty-slot acquire path.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PG renewal failure discards the slot (#71)" begin
  pool = MockPGPool71(fail_rollback = true, fail_renew = true)
  old = pool.connections[1]

  err = @test_logs (:error, r"Failed to rollback transaction") match_mode=:any begin
    run_failing_tx_71(pool)
  end

  @test err isa ErrorException && err.msg == "boom"
  @test pool.connections[1] === nothing               # slot cleared, not left holding the dirty handle
  @test pool.available[1] === true                    # slot reusable
  @test old.closed === true                           # dirty handle closed
  # Next borrower triggers backend_connect on the empty slot → a fresh connection.
  c = CP.acquire_connection(pool)
  @test c isa FakeConn71 && c !== old
  @test pool.connections[1] === c                     # slot repopulated
  CP.release_connection(pool, c)
end

# ─────────────────────────────────────────────────────────────────────────────
# Transactions (#71): SQLite benign "no transaction is active" → plain release, no renewal
# SQLite auto-rolls-back some failures; a ROLLBACK then fails with "no transaction is active"
# and the connection is CLEAN — it must be released as-is (same object, not closed, no fresh
# handle created). This also gates the unwrap fix: the error arrives wrapped in a
# TaskFailedException (via the global worker task), whose string() does NOT contain the
# driver message — without _unwrap_async_exception the benign case would be misclassified
# as a failed rollback and pointlessly renewed, failing the identity assertion below.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite benign rollback error releases the connection as-is (#71)" begin
  pool = MockSQLitePool71(rollback_error_msg = "cannot rollback - no transaction is active")
  old = pool.connections[1]

  err = run_failing_tx_71(pool)

  @test err isa ErrorException && err.msg == "boom"
  @test pool.connections[1] === old                   # NOT renewed: same object stays in the slot
  @test pool.available[1] === true                    # released normally
  @test old.closed === false                          # never closed
  @test pool.next_id == 1                             # no fresh handle was ever created
end

# ─────────────────────────────────────────────────────────────────────────────
# Transactions (#71): SQLite non-benign rollback failure → renewal (PG/SQLite alignment)
# Same policy as PG, proven through the REAL SQLite path: BEGIN/ROLLBACK funnel through the
# global async worker into backend_execute, the rollback failure surfaces wrapped, and the
# cleanup renews the slot and closes the dirty handle (releasing its file write-lock — an
# aborted BEGIN IMMEDIATE would otherwise hold it until GC).
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite non-benign rollback failure renews the connection (#71)" begin
  pool = MockSQLitePool71(rollback_error_msg = "disk I/O error")
  old = pool.connections[1]

  err = @test_logs (:error, r"Failed to rollback transaction") match_mode=:any begin
    run_failing_tx_71(pool)
  end

  @test err isa ErrorException && err.msg == "boom"
  @test pool.connections[1] !== old                   # slot renewed
  @test pool.connections[1] isa FakeConn71 && pool.connections[1].id == 2
  @test pool.available[1] === true
  @test old.closed === true                           # dirty handle closed promptly
end

# ─────────────────────────────────────────────────────────────────────────────
# Transactions (#71): with_transaction ROLLBACK failure → renewal (sibling-path heal)
# delete() and both migration lifecycles issue their ROLLBACK through the shared
# with_transaction(..., release_conn=true) primitive, not run_in_transaction. A failed
# ROLLBACK there must renew/discard the connection exactly like the tx wrapper does —
# releasing it dirty was the same #71 defect on a sibling path.
# ─────────────────────────────────────────────────────────────────────────────
@testset "with_transaction failed ROLLBACK renews the connection (#71)" begin
  pool = MockPGPool71(fail_rollback = true)
  old = pool.connections[1]

  # Mirror the runner/delete() catch pattern: the caller holds the tx connection and
  # asks with_transaction to roll back and release it.
  conn = CP.acquire_connection(pool)
  @test conn === old
  err = @test_logs (:error, r"Failed to execute SQL transaction") match_mode=:any begin
    try
      CP.with_transaction(pool, "ROLLBACK;", conn = conn, release_conn = true)
      nothing
    catch e
      e
    end
  end

  @test err !== nothing                               # the rollback failure propagates
  @test pool.connections[1] !== old                   # slot renewed, dirty handle gone
  @test pool.available[1] === true                    # renewed handle released
  @test old.closed === true                           # dirty handle closed
end

# ─────────────────────────────────────────────────────────────────────────────
# Transactions (#71): with_transaction benign SQLite rollback error → plain release
# The benign "no transaction is active" classification must apply on the shared
# primitive too: the connection is clean, so it is released as-is (same object,
# not closed, no fresh handle created).
# ─────────────────────────────────────────────────────────────────────────────
@testset "with_transaction benign SQLite rollback releases as-is (#71)" begin
  pool = MockSQLitePool71(rollback_error_msg = "cannot rollback - no transaction is active")
  old = pool.connections[1]

  conn = CP.acquire_connection(pool; mode = :write)
  @test conn === old
  err = try
    CP.with_transaction(pool, "ROLLBACK;", conn = conn, release_conn = true)
    nothing
  catch e
    e
  end

  @test err !== nothing                               # the driver error still propagates
  @test pool.connections[1] === old                   # NOT renewed
  @test pool.available[1] === true                    # released normally
  @test old.closed === false                          # never closed
  @test pool.next_id == 1                             # no fresh handle was ever created
end

# ─────────────────────────────────────────────────────────────────────────────
# Transactions (#71): _discard_connection! on an unpooled handle → false, still closed
# The not-found path (e.g. the slot was already replaced by a concurrent reconnect) must
# warn-and-return-false, but the handle is still best-effort closed so it never leaks.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_discard_connection! not-found path still closes the handle (#71)" begin
  pool = MockPGPool71()
  stray = FakeConn71(99)                              # never lived in this pool

  found = @test_logs (:warn, r"not found") match_mode=:any begin
    CP._discard_connection!(pool, stray)
  end

  @test found === false
  @test stray.closed === true                         # closed even when unpooled
  @test pool.connections[1] isa FakeConn71            # pool untouched
  @test pool.available[1] === true
end
