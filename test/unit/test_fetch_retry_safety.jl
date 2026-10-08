# ============================================================
# test/unit/test_fetch_retry_safety.jl
#
# fetch() re-runs a statement after a lost connection only when it provably never ran (#1042).
#
# CONTRACT being tested:
#   A lost connection is two decisions in `fetch`. Renewing the failed slot and retiring the idle
#   ones happens for EVERY lost connection (`backend_is_connection_error`). Re-running the statement
#   happens only when `backend_is_retry_safe` also says the statement never ran. A codeless drop
#   (the socket went away, with no SQLSTATE) can come after the server received the statement, so an
#   autocommit write may already have committed. Re-running it would apply the write twice.
#
# Deterministic and DB-free. The mock "driver" records a statement as committed BEFORE it fails,
# which is the #1025 capture's shape: the relay cut the socket while the backend was still running
# the statement. Two sentinels stand for the two kinds of drop. Both are lost connections; only one
# is retry-safe. Reverting the fix (an unconditional retry in fetch's catch) runs the write a second
# time and emits the "Lost connection" warn, which fails the commit-count and strict-log assertions.
# ============================================================

using Test
using PormG

# No DB drivers needed: every backend_* call below dispatches to the mock methods, as in
# test_fetch_retry_transaction.jl, whose mock pools these copy.

const CP = PormG.ConnectionPool

# ── Fake driver handle ──
mutable struct FakeConn1042
  id::Int
  closed::Bool
end
FakeConn1042(id::Int) = FakeConn1042(id, false)
Base.close(c::FakeConn1042) = (c.closed = true; nothing)

# ── The two drops. Their own types, so the classifiers are exercised by type as the real ones are. ──
# The socket went away with no SQLSTATE: "SSL SYSCALL error: EOF detected", "server closed the
# connection unexpectedly". The statement may have run.
struct MockCodelessDrop1042 <: Exception end
Base.showerror(io::IO, ::MockCodelessDrop1042) = print(io, "mock: socket closed mid-statement")
# The server said the backend is gone (57P01), or the driver refused before sending. It never ran.
struct MockNeverRan1042 <: Exception end
Base.showerror(io::IO, ::MockNeverRan1042) = print(io, "mock: backend gone before the statement ran")

# ── PG-shaped mock: PostgresConnectionPool's exact fields + failure knobs ──
mutable struct MockPGPool1042 <: PormG.PormGPostgres
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
  fail_prefix::Union{Nothing, String}  # statements with this prefix fail while fail_times > 0
  fail_times::Int                      # one-shot budget: a re-run would succeed
  fail_kind::Symbol                    # :codeless (ran, then dropped) or :never_ran
  next_id::Int
  executed::Vector{String}             # every statement the "driver" received, in order
  committed::Vector{String}            # every statement that took effect on the "server"
  renewals::Int
end
function MockPGPool1042(n::Int = 1; fail_prefix::Union{Nothing, String} = nothing,
                        fail_times::Int = 0, fail_kind::Symbol = :codeless)
  MockPGPool1042(Any[FakeConn1042(i) for i in 1:n], fill(true, n), "mock://pg", n, ReentrantLock(),
                 fail_prefix, fail_times, fail_kind, n, String[], String[], 0)
end

PormG.backend_is_alive(::MockPGPool1042, conn) = conn isa FakeConn1042 && !conn.closed
PormG.backend_connect(pool::MockPGPool1042; kwargs...) = FakeConn1042(pool.next_id += 1)
function PormG.backend_renew_connection(pool::MockPGPool1042, conn; kwargs...)
  pool.renewals += 1
  return FakeConn1042(pool.next_id += 1)
end

# What the "server" does with one statement: a codeless drop commits it first, then loses the socket
# before the client reads the reply; a never-ran drop fails before it takes effect.
function _mock_server_1042!(pool, sql::String)
  push!(pool.executed, sql)
  if pool.fail_prefix !== nothing && pool.fail_times > 0 && startswith(sql, pool.fail_prefix)
    pool.fail_times -= 1
    pool.fail_kind === :codeless || throw(MockNeverRan1042())
    push!(pool.committed, sql)
    throw(MockCodelessDrop1042())
  end
  push!(pool.committed, sql)
  return NamedTuple[]
end

# Fail INSIDE the task, like a real async driver failure, so fetch's catch unwraps it.
PormG.backend_execute_async(pool::MockPGPool1042, conn, sql::String, params) =
  @async _mock_server_1042!(pool, sql)
PormG.backend_is_connection_error(::MockPGPool1042, e) = e isa Union{MockCodelessDrop1042, MockNeverRan1042}
# Typed on the sentinel, as the real drivers type theirs on their exception types; any other
# exception reaches core's default, `false`.
PormG.backend_is_retry_safe(::MockPGPool1042, ::MockNeverRan1042) = true

# ── SQLite-shaped mock: the same knobs through the REAL global worker → backend_execute ──
mutable struct MockSQLitePool1042 <: PormG.PormGSQLite
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
  fail_kind::Symbol
  next_id::Int
  executed::Vector{String}
  committed::Vector{String}
  renewals::Int
end
function MockSQLitePool1042(n::Int = 1; fail_prefix::Union{Nothing, String} = nothing,
                            fail_times::Int = 0, fail_kind::Symbol = :codeless)
  MockSQLitePool1042(Any[FakeConn1042(i) for i in 1:n], fill(true, n), "mock://sqlite", n, false, 1, 0,
                     ReentrantLock(), ReentrantLock(), fail_prefix, fail_times, fail_kind, n,
                     String[], String[], 0)
end

PormG.backend_is_alive(::MockSQLitePool1042, conn) = conn isa FakeConn1042 && !conn.closed
PormG.backend_connect(pool::MockSQLitePool1042; read_only::Bool = false) = FakeConn1042(pool.next_id += 1)
function PormG.backend_renew_connection(pool::MockSQLitePool1042, conn; read_only::Bool = false)
  pool.renewals += 1
  return FakeConn1042(pool.next_id += 1)
end
# Runs on the global SQLite worker thread: no @test in here.
PormG.backend_execute(pool::MockSQLitePool1042, conn, sql::String, params) = _mock_server_1042!(pool, sql)
PormG.backend_is_connection_error(::MockSQLitePool1042, e) = e isa Union{MockCodelessDrop1042, MockNeverRan1042}
PormG.backend_is_retry_safe(::MockSQLitePool1042, ::MockNeverRan1042) = true

function fetch_or_error_1042(pool, sql)
  try
    CP.fetch(pool, sql)
    return nothing
  catch e
    return e
  end
end

const INSERT_1042 = "INSERT INTO results (driverid, points) VALUES (1, 25);"
const NOT_RETRIED_1042 = r"Lost connection to database\. The pool was recovered, but the statement is not retried"

# ─────────────────────────────────────────────────────────────────────────────
# (1) ACCEPTANCE CRITERION (#1042): a codeless drop after the write committed is NOT re-run.
#
# The INSERT reaches the "server" and commits, then the socket goes away before the client reads
# CommandComplete. The caller gets the OperationalError, the write exists exactly once, and the pool
# still recovers: the failed slot is renewed and the idle siblings are retired. The strict @test_logs
# admits exactly the "not retried" warn, so a "Lost connection … Retrying" warn fails it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PG: a codeless drop after the commit is not re-run (#1042)" begin
  pool = MockPGPool1042(3; fail_prefix = "INSERT", fail_times = 1)
  doomed = pool.connections[1]                       # the scan picks slot 1 → this one fails
  sibling2, sibling3 = pool.connections[2], pool.connections[3]

  err = @test_logs (:warn, NOT_RETRIED_1042) fetch_or_error_1042(pool, INSERT_1042)

  @test err isa PormG.OperationalError               # the drop reaches the caller…
  @test err.cause isa MockCodelessDrop1042           # …as the driver's own failure
  @test count(==(INSERT_1042), pool.committed) == 1  # ← the write took effect exactly once
  @test count(==(INSERT_1042), pool.executed) == 1   # ← and was never sent again

  # Recovery is unchanged: the failed slot is renewed…
  @test pool.renewals == 1
  @test pool.connections[1] !== doomed
  # …and the idle siblings the same event killed are retired.
  @test pool.connections[2] === nothing && sibling2.closed === true
  @test pool.connections[3] === nothing && sibling3.closed === true
  @test count(!, pool.available) == 0                # nothing leaked
end

# ─────────────────────────────────────────────────────────────────────────────
# (2) A statement that provably never ran is still retried once — the #442 recovery survives.
# Same pool and statement; the only difference is the kind of drop.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PG: a drop before the statement ran is retried once (#1042)" begin
  pool = MockPGPool1042(3; fail_prefix = "INSERT", fail_times = 1, fail_kind = :never_ran)
  sibling2 = pool.connections[2]

  rows = @test_logs (:warn, r"Lost connection to database") CP.fetch(pool, INSERT_1042)

  @test rows == NamedTuple[]                         # the retry's result reaches the caller
  @test count(==(INSERT_1042), pool.executed) == 2   # failed once, re-ran once
  @test count(==(INSERT_1042), pool.committed) == 1  # and took effect once: the first never ran
  @test pool.renewals == 1
  @test pool.connections[2] === nothing && sibling2.closed === true
  @test count(!, pool.available) == 0
end

# ─────────────────────────────────────────────────────────────────────────────
# (3) The SQLite twin of (1), through the real global worker. SQLite's extension defines no
# `backend_is_retry_safe`, so no SQLite failure is re-run; the mock pins the core rule both backends share.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: a codeless drop after the commit is not re-run (#1042)" begin
  pool = MockSQLitePool1042(1; fail_prefix = "INSERT", fail_times = 1)
  doomed = pool.connections[1]

  err = @test_logs (:warn, NOT_RETRIED_1042) fetch_or_error_1042(pool, INSERT_1042)

  @test err isa PormG.OperationalError
  @test err.cause isa MockCodelessDrop1042
  @test count(==(INSERT_1042), pool.committed) == 1
  @test count(==(INSERT_1042), pool.executed) == 1
  @test pool.renewals == 1                           # still renewed
  @test pool.connections[1] !== doomed
  @test pool.available == [true]
end

@testset "SQLite: a drop before the statement ran is retried once (#1042)" begin
  pool = MockSQLitePool1042(1; fail_prefix = "INSERT", fail_times = 1, fail_kind = :never_ran)

  rows = @test_logs (:warn, r"Lost connection to database") CP.fetch(pool, INSERT_1042)

  @test rows == NamedTuple[]
  @test count(==(INSERT_1042), pool.executed) == 2
  @test count(==(INSERT_1042), pool.committed) == 1
  @test pool.renewals == 1
end

# ─────────────────────────────────────────────────────────────────────────────
# (4) The unclaimed path obeys the same rule.
#
# When a parked waiter is handed the failed slot before fetch's catch runs, the slot is not renewed
# (#584) and the statement used to re-run through normal acquisition regardless. That path is a
# second place a write could be applied twice, so it is gated separately.
#
# Set up as in test_connection_pool_liveness.jl's #584 testset: sticky `@async` tasks on one thread,
# every other slot leased so W has to park. T's INSERT commits and drops; T's finally hands slot 1 to
# W; T finds it unclaimed and, being codeless, raises instead of parking on a retry.
# ─────────────────────────────────────────────────────────────────────────────
function _wait_until_1042(pred; timeout = 5.0, step = 0.005)
  t0 = time()
  while time() - t0 < timeout
    pred() && return true
    sleep(step)
  end
  return pred()
end

@testset "PG: the unclaimed path does not re-run a codeless drop either (#1042)" begin
  pool = MockPGPool1042(1; fail_prefix = "INSERT", fail_times = 1)
  c1 = pool.connections[1]
  held = [CP.acquire_connection(pool; timeout_seconds = 5) for _ in 1:CP._pool_ceiling(pool)]
  @test held[1] === c1
  @test CP.release_connection(pool, c1) === true         # slot 1 is the only idle slot

  T, W = @test_logs (:warn, NOT_RETRIED_1042) begin       # strict: the "not retried" warn only
    T = @async fetch_or_error_1042(pool, INSERT_1042)     # takes slot 1; the INSERT commits, then drops
    W = @async CP.acquire_connection(pool; timeout_seconds = 5)
    @test _wait_until_1042(() -> istaskdone(W) && istaskdone(T))
    (T, W)
  end
  @test fetch(W) === c1                                   # W was handed the slot with c1 in place
  err = fetch(T)
  @test err isa PormG.OperationalError                    # T raised instead of waiting to retry
  @test err.cause isa MockCodelessDrop1042
  @test count(==(INSERT_1042), pool.executed) == 1        # ← never sent again
  @test count(==(INSERT_1042), pool.committed) == 1
  @test pool.renewals == 0                                # an unclaimed slot is never renewed (#584)
  @test isempty(CP._waiters_for(pool))                    # T did not park on a retry

  CP.release_connection(pool, c1)
  for c in held[2:end]; CP.release_connection(pool, c); end
  @test count(!, pool.available) == 0                     # nothing leaked
end

# ─────────────────────────────────────────────────────────────────────────────
# (5) The core default: `false`, and it never throws. It runs inside fetch's catch, where a throw
# would replace the failure being reported; a pool or driver that defines no method gets no retry.
# A multi-result failure is retry-safe when any one of its errors is: that one is the server's word.
# ─────────────────────────────────────────────────────────────────────────────
@testset "backend_is_retry_safe defaults to false, recursing into CompositeException (#1042)" begin
  pool = MockPGPool1042(1)
  @test PormG.backend_is_retry_safe(pool, MockCodelessDrop1042()) === false
  @test PormG.backend_is_retry_safe(pool, ErrorException("server closed the connection unexpectedly")) === false
  @test PormG.backend_is_retry_safe(pool, MockNeverRan1042()) === true
  @test PormG.backend_is_retry_safe(pool, CompositeException([MockCodelessDrop1042(), MockNeverRan1042()])) === true
  @test PormG.backend_is_retry_safe(pool, CompositeException([MockCodelessDrop1042()])) === false
  @test PormG.backend_is_retry_safe(pool, CompositeException(Exception[])) === false
  @test PormG.backend_is_retry_safe(MockSQLitePool1042(1), ErrorException("disk I/O error")) === false
end
