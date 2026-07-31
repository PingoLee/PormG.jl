# ============================================================
# test/unit/test_fetch_retry_transaction.jl
#
# fetch() lost-connection retry must never fire inside a transaction (#138).
#
# CONTRACT being tested:
#   `fetch`'s catch-and-retry recovers from a lost connection ONLY when the failed task
#   acquired its own pool connection (no transaction context, no caller-pinned `conn`).
#   Inside `run_in_transaction`, a connection error must propagate to the transaction
#   wrapper — which rolls back and renews/discards the pinned connection (#71) — because
#   the retry would re-run the statement on a fresh AUTOCOMMIT session (silently committing
#   a write that should die with the transaction), and reconnect_db + await_result would
#   swap and release the transaction's pool slot mid-transaction, handing a session with an
#   open transaction to the next borrower. Every mainstream framework (Django, SQLAlchemy,
#   Rails 7.1 connection_retries, Go database/sql, Ecto) enforces this same rule: invalidate
#   and propagate inside a transaction; the application retries the whole transaction.
#
# Deterministic and DB-free: behavioral mock pools carry the exact fields the pool machinery
# reads (see test_transaction_rollback_renewal.jl for the pattern), inject a one-shot
# connection-flavored failure into the executed statement, and override
# backend_is_connection_error so the retry branch is reachable under the mock. Reverting the
# fix (dropping the `conn === nothing && !fetch_task.in_transaction` guard in fetch's catch)
# re-runs the statement, emits the "Lost connection" warn, and lets the transaction commit
# as if nothing failed — failing the execution-count, log, and error assertions below.
# ============================================================

using Test
using PormG

# No DB drivers needed: every backend_* call in these flows dispatches to the mock methods
# below, so this file runs without the LibPQ/SQLite weakdep extensions.

const CP = PormG.ConnectionPool

# #268: the pool wraps driver failures in the taxonomy, so the mock's "connection lost" reaches the
# caller as an `OperationalError` carrying the original on `.cause` — not as the bare
# `ErrorException` these tests used to assert. Check all three facts rather than just the type:
#
#   * the KIND is what the retry gate reads, so a misclassification (`:statement`) would silently
#     disable the #138 reconnect path while a type-only assertion still passed;
#   * `.cause` must be the driver's own exception, or apps lose SQLSTATE-level detail;
#   * the text must still reach the caller, so a wrapper that swallowed the message fails here.
#
# It also pins that classification reaches a MOCK pool at all: these mocks define
# `backend_is_connection_error` on their concrete type, and the core default classifier is what
# consults it. An extension method typed on the abstract marker would shadow that and break this.
function assert_wrapped_conn_loss_138(err)
  @test err isa PormG.OperationalError
  @test err.cause isa MockConnLost138
  @test occursin("mock: connection lost", PormG.error_message(err))
end

# ── Fake driver handle: tracks whether the pool cleanup closed it ──
# (structs live at file top level — Julia forbids type definitions inside @testset blocks)
mutable struct FakeConn138
  id::Int
  closed::Bool
end
FakeConn138(id::Int) = FakeConn138(id, false)
Base.close(c::FakeConn138) = (c.closed = true; nothing)

# ── Driver-shaped "connection lost" sentinel ──
# Deliberately its own TYPE rather than `error("mock: connection lost")`, because the real
# classifiers recognize a mid-query drop by type: LibPQ matches
# `e isa LibPQ.Errors.UnknownError && string(e) == "…UnknownError(\"\")"`. A substring-matching
# mock cannot detect a `_driver_cause` regression at fetch's retry gate — Julia's default `show`
# recursively prints `.cause`, so `occursin(…, string(wrapper))` keeps answering `true` even when
# the classifier is handed the WRAPPER instead of the driver exception (#268).
struct MockConnLost138 <: Exception end
Base.showerror(io::IO, ::MockConnLost138) = print(io, "mock: connection lost")

# ── PG-shaped mock: PostgresConnectionPool's exact fields + failure knobs ──
mutable struct MockPGPool138 <: PormG.PormGPostgres
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
  fail_prefix::Union{Nothing, String}  # statements with this prefix fail while fail_times > 0
  fail_times::Int                      # one-shot budget: the retry's re-run would succeed
  fail_rollback::Bool                  # ROLLBACK task throws → the #71 renewal path engages
  next_id::Int                         # id source for freshly "connected"/renewed FakeConn138s
  executed::Vector{String}             # every statement the "driver" received, in order
  renewals::Int                        # how many times backend_renew_connection ran
end
MockPGPool138(; fail_prefix::Union{Nothing, String} = nothing, fail_times::Int = 0,
                fail_rollback::Bool = false) =
  MockPGPool138(Any[FakeConn138(1)], [true], "mock://pg", 1, ReentrantLock(),
                fail_prefix, fail_times, fail_rollback, 1, String[], 0)

PormG.backend_is_alive(::MockPGPool138, conn) = conn isa FakeConn138 && !conn.closed
PormG.backend_connect(pool::MockPGPool138; kwargs...) = FakeConn138(pool.next_id += 1)
function PormG.backend_execute_async(pool::MockPGPool138, conn, sql::String, params)
  push!(pool.executed, sql)
  # Fail INSIDE the task (like a real async driver failure) so Base.fetch throws a
  # TaskFailedException and the fetch/rollback catches exercise _unwrap_async_exception.
  return @async begin
    if pool.fail_rollback && startswith(sql, "ROLLBACK")
      error("mock: rollback refused")
    end
    if pool.fail_prefix !== nothing && pool.fail_times > 0 && startswith(sql, pool.fail_prefix)
      pool.fail_times -= 1
      throw(MockConnLost138())
    end
    NamedTuple[]
  end
end
function PormG.backend_renew_connection(pool::MockPGPool138, conn; kwargs...)
  pool.renewals += 1
  return FakeConn138(pool.next_id += 1)
end
# Classify only the injected failure as a lost connection, so the retry branch is
# reachable under the mock (the real drivers match their own message fingerprints).
PormG.backend_is_connection_error(::MockPGPool138, e) = e isa MockConnLost138

# ── SQLite-shaped mock: SQLiteConnectionPool's exact fields + the same knobs.
#    Statements funnel through the REAL global async worker → backend_execute, proving the
#    PG/SQLite policy alignment on the actual SQLite code path. ──
mutable struct MockSQLitePool138 <: PormG.PormGSQLite
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  split_read_write::Bool
  writer_slot::Int
  reader_cursor::Int
  lock::ReentrantLock
  write_lock::ReentrantLock
  fail_prefix::Union{Nothing, String}
  fail_times::Int
  fail_rollback::Bool
  next_id::Int
  executed::Vector{String}
  renewals::Int
end
MockSQLitePool138(; fail_prefix::Union{Nothing, String} = nothing, fail_times::Int = 0,
                    fail_rollback::Bool = false) =
  MockSQLitePool138(Any[FakeConn138(1)], [true], "mock://sqlite", 1, false, 1, 0,
                    ReentrantLock(), ReentrantLock(), fail_prefix, fail_times, fail_rollback,
                    1, String[], 0)

PormG.backend_is_alive(::MockSQLitePool138, conn) = conn isa FakeConn138 && !conn.closed
PormG.backend_connect(pool::MockSQLitePool138; read_only::Bool = false) = FakeConn138(pool.next_id += 1)
function PormG.backend_renew_connection(pool::MockSQLitePool138, conn; read_only::Bool = false)
  pool.renewals += 1
  return FakeConn138(pool.next_id += 1)
end
function PormG.backend_execute(pool::MockSQLitePool138, conn, sql::String, params)
  # Runs on the global SQLite worker thread — keep it pure (no @test in here); a raised
  # error travels back to the caller as the @async task's failure (→ TaskFailedException).
  push!(pool.executed, sql)
  if pool.fail_rollback && startswith(sql, "ROLLBACK")
    error("mock: rollback refused")   # NOT "no transaction is active" → non-benign → renewal
  end
  if pool.fail_prefix !== nothing && pool.fail_times > 0 && startswith(sql, pool.fail_prefix)
    pool.fail_times -= 1
    throw(MockConnLost138())
  end
  return NamedTuple[]
end
PormG.backend_is_connection_error(::MockSQLitePool138, e) = e isa MockConnLost138

# Run a transaction whose body issues one INSERT through the retry-capable fetch() wrapper —
# the exact path ORM writes take inside run_in_transaction — and return the caught error.
function run_tx_with_failing_fetch_138(pool)
  try
    CP.run_in_transaction(pool) do
      CP.fetch(pool, "INSERT INTO drivers (surname) VALUES ('Senna');")
    end
    return nothing
  catch e
    return e
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Retry gate (#138): PG connection error inside a transaction → NO retry, full #71 handoff
# The failed INSERT must run exactly once (never re-run on a fresh autocommit session), the
# connection error itself must propagate to the caller, and cleanup must belong to the
# transaction wrapper: ROLLBACK is attempted, fails, and the pinned connection is renewed
# exactly once by _renew_or_discard_connection! — not swapped/released by the fetch retry.
# The STRICT @test_logs (exactly one :error) doubles as the no-"Lost connection"-warn proof.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PG in-tx connection error propagates without retry (#138)" begin
  pool = MockPGPool138(fail_prefix = "INSERT", fail_times = 1, fail_rollback = true)
  old = pool.connections[1]

  err = @test_logs (:error, r"Failed to rollback transaction") begin
    run_tx_with_failing_fetch_138(pool)
  end

  assert_wrapped_conn_loss_138(err)                                          # root error wins
  @test count(sql -> startswith(sql, "INSERT"), pool.executed) == 1           # never re-run
  @test pool.renewals == 1                            # renewed by the #71 path, not the retry
  @test pool.connections[1] !== old                   # slot renewed (identity changed)
  @test pool.available[1] === true                    # renewed handle released, pool consistent
  @test old.closed === true                           # dirty handle closed, not leaked
  # BEGIN and ROLLBACK were issued; COMMIT never was (the body threw before it).
  @test any(sql -> startswith(sql, "BEGIN"), pool.executed)
  @test any(sql -> startswith(sql, "ROLLBACK"), pool.executed)
  @test !any(sql -> startswith(sql, "COMMIT"), pool.executed)
end

# ─────────────────────────────────────────────────────────────────────────────
# Retry gate (#138): PG in-tx connection error, ROLLBACK succeeds → plain release, no renewal
# When the server session survives (only the statement failed as a "connection error"), the
# wrapper's ROLLBACK works and the connection returns to the pool untouched. The zero-pattern
# STRICT @test_logs asserts complete silence: no retry warn, no rollback error.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PG in-tx connection error with clean rollback releases as-is (#138)" begin
  pool = MockPGPool138(fail_prefix = "INSERT", fail_times = 1)
  old = pool.connections[1]

  err = @test_logs begin
    run_tx_with_failing_fetch_138(pool)
  end

  assert_wrapped_conn_loss_138(err)
  @test count(sql -> startswith(sql, "INSERT"), pool.executed) == 1
  @test pool.renewals == 0                            # nothing to heal
  @test pool.connections[1] === old                   # same handle stays in the slot
  @test pool.available[1] === true                    # released normally
  @test old.closed === false
  @test any(sql -> startswith(sql, "ROLLBACK"), pool.executed)
end

# ─────────────────────────────────────────────────────────────────────────────
# Retry gate (#138): PG retry PRESERVED outside transactions — acceptance criterion
# A plain fetch() that loses its connection must still transparently reconnect and re-run:
# statement executed twice, slot renewed once by the retry, result returned, and the
# "Lost connection" warn emitted (STRICT: exactly that one log).
# ─────────────────────────────────────────────────────────────────────────────
@testset "PG out-of-tx lost-connection retry still works (#138)" begin
  pool = MockPGPool138(fail_prefix = "SELECT", fail_times = 1)
  old = pool.connections[1]

  result = @test_logs (:warn, r"Lost connection") begin
    CP.fetch(pool, "SELECT surname FROM drivers;")
  end

  @test result == NamedTuple[]                        # the retry's result reaches the caller
  @test count(sql -> startswith(sql, "SELECT"), pool.executed) == 2  # failed + retried
  @test pool.renewals == 1                            # reconnect_db renewed the slot
  @test pool.connections[1] !== old                   # fresh handle in the slot
  @test pool.available[1] === true                    # and it was released after the retry
end

# ─────────────────────────────────────────────────────────────────────────────
# Retry gate (#138): caller-pinned `conn` never retries
# A caller that pins an explicit connection owns its lifecycle — fetch must not swap the
# pinned handle's pool slot behind the caller's back. The error propagates, silently.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PG caller-pinned conn never retries (#138)" begin
  pool = MockPGPool138(fail_prefix = "SELECT", fail_times = 1)
  conn = CP.acquire_connection(pool)

  err = @test_logs begin                              # STRICT zero logs: no retry warn
    try
      CP.fetch(pool, "SELECT surname FROM drivers;"; conn = conn)
      nothing
    catch e
      e
    end
  end

  assert_wrapped_conn_loss_138(err)
  @test count(sql -> startswith(sql, "SELECT"), pool.executed) == 1
  @test pool.renewals == 0
end

# ─────────────────────────────────────────────────────────────────────────────
# Retry gate (#138): SQLite in-tx connection error → NO retry (PG/SQLite alignment)
# Same contract as the PG twin, proven through the REAL SQLite path: the INSERT funnels
# through the global async worker into backend_execute, fails once, propagates, and the
# wrapper's failed ROLLBACK renews the pinned connection exactly once.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite in-tx connection error propagates without retry (#138)" begin
  pool = MockSQLitePool138(fail_prefix = "INSERT", fail_times = 1, fail_rollback = true)
  old = pool.connections[1]

  err = @test_logs (:error, r"Failed to rollback transaction") begin
    run_tx_with_failing_fetch_138(pool)
  end

  assert_wrapped_conn_loss_138(err)
  @test count(sql -> startswith(sql, "INSERT"), pool.executed) == 1
  @test pool.renewals == 1
  @test pool.connections[1] !== old
  @test pool.available[1] === true
  @test old.closed === true
end

# ─────────────────────────────────────────────────────────────────────────────
# Retry gate (#138): SQLite retry PRESERVED outside transactions
# Alignment twin of the PG out-of-tx case, through the global worker → backend_execute.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite out-of-tx lost-connection retry still works (#138)" begin
  pool = MockSQLitePool138(fail_prefix = "SELECT", fail_times = 1)
  old = pool.connections[1]

  result = @test_logs (:warn, r"Lost connection") begin
    CP.fetch(pool, "SELECT surname FROM drivers;")
  end

  @test result == NamedTuple[]
  @test count(sql -> startswith(sql, "SELECT"), pool.executed) == 2
  @test pool.renewals == 1
  @test pool.connections[1] !== old
  @test pool.available[1] === true
end
