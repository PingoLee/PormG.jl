# ============================================================
# test/unit/test_commit_failure_release.jl
#
# Failed COMMIT holds the connection until ROLLBACK runs; released/healed exactly once (#139).
#
# CONTRACT being tested:
#   The manual BEGIN/COMMIT/ROLLBACK lifecycles (both migration lifecycles and delete()) must
#   NOT return the transaction's connection to the pool on a FAILED COMMIT and then issue ROLLBACK
#   on the already-released connection (a use-after-release + double-release race). The connection
#   must stay leased through the cleanup ROLLBACK and be released — or renewed/discarded if that
#   ROLLBACK left it dirty (#71) — exactly once, in a single terminal `finally`.
#
#   The fix routes every such lifecycle through one shared, exported helper,
#   `finalize_transaction_connection!(pool, conn; rollback_error)`: COMMIT and ROLLBACK both run
#   with `release_conn=false` (they never release), and the `finally` calls the helper, which
#   releases the connection, or renews/discards it when a non-benign `rollback_error` is supplied.
#   This mirrors `run_in_transaction`'s single-`finally` release (the one lifecycle that was never
#   subject to #139), so all four finalize identically.
#
# Deterministic and DB-free: behavioral mock pools carry the exact fields the pool machinery reads
# (acquire/release/reconnect are generic over PormGPostgres/PormGSQLite), fake driver handles track
# `close`, and `backend_*` overrides simulate a failing COMMIT and/or ROLLBACK. A `fail_commit`
# task throws INSIDE the `@async`/worker so `Base.fetch` surfaces a TaskFailedException — the wrapped
# form the real async paths produce. Each mock snapshots `available[slot]` at the instant ROLLBACK
# is issued (`available_at_rollback`): the fixed pattern keeps it `false` (still leased); the
# pre-fix pattern (COMMIT with `release_conn=true`) flips it `true` before ROLLBACK — the mutation
# gate, contrasted directly below.
#
# NOTE: the real migration/delete callers are not DB-free (they drive the ORM history table, the
# query builder, and filesystem archiving), so this file locks the shared helper and the exact
# lifecycle CALL SEQUENCE the callers now use, through the real `with_transaction` primitive. The
# refactored `_run_in_transaction_impl` gets its own real-code coverage from the #71 suite
# (test/unit/test_transaction_rollback_renewal.jl); the real callers' success paths are covered by
# the integration transaction/migration tests.
# ============================================================

using Test
using PormG

# No DB drivers needed: every backend_* call in these flows dispatches to the mock methods below.
const CP = PormG.ConnectionPool

# ── Fake driver handle: tracks whether the pool cleanup closed it ──
# (structs live at file top level — Julia forbids type definitions inside @testset blocks)
mutable struct FakeConn139
  id::Int
  closed::Bool
end
FakeConn139(id::Int) = FakeConn139(id, false)
Base.close(c::FakeConn139) = (c.closed = true; nothing)

# ── PG-shaped mock: PostgresConnectionPool's exact fields + failure knobs + rollback snapshot ──
mutable struct MockPGPool139 <: PormG.PormGPostgres
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
  fail_commit::Bool      # COMMIT task throws (inside the task → TaskFailedException)
  fail_rollback::Bool    # ROLLBACK task throws (non-benign → renewal)
  fail_renew::Bool       # backend_renew_connection throws → reconnect_db → nothing → discard
  next_id::Int
  executed::Vector{String}
  available_at_rollback::Union{Nothing, Bool}  # available[slot] snapshot when ROLLBACK is issued
  conn_at_rollback::Any                        # the conn ROLLBACK ran on
end
MockPGPool139(; fail_commit::Bool = false, fail_rollback::Bool = false, fail_renew::Bool = false) =
  MockPGPool139(Any[FakeConn139(1)], [true], "mock://pg", 1, ReentrantLock(),
                fail_commit, fail_rollback, fail_renew, 1, String[], nothing, nothing)

PormG.backend_is_alive(::MockPGPool139, conn) = conn isa FakeConn139 && !conn.closed
PormG.backend_connect(pool::MockPGPool139; kwargs...) = FakeConn139(pool.next_id += 1)
function PormG.backend_execute_async(pool::MockPGPool139, conn, sql::String, params)
  push!(pool.executed, sql)
  if startswith(sql, "ROLLBACK")
    # Snapshot on the CALLER's task, the instant the ROLLBACK statement is issued.
    pool.available_at_rollback = pool.available[1]
    pool.conn_at_rollback = conn
  end
  return @async begin
    pool.fail_commit   && startswith(sql, "COMMIT")   && error("mock: commit refused")
    pool.fail_rollback && startswith(sql, "ROLLBACK") && error("mock: rollback refused")
    NamedTuple[]   # empty result table: DataFrame(...) → 0 rows, so migration reads see an empty DB
  end
end
function PormG.backend_renew_connection(pool::MockPGPool139, conn; kwargs...)
  pool.fail_renew && error("mock: renew refused")
  return FakeConn139(pool.next_id += 1)
end

# ── SQLite-shaped mock: SQLiteConnectionPool's exact fields; statements funnel through the REAL
#    global async worker → backend_execute, proving the policy on the actual SQLite code path. ──
mutable struct MockSQLitePool139 <: PormG.PormGSQLite
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  split_read_write::Bool
  writer_slot::Int
  reader_cursor::Int
  lock::ReentrantLock
  write_lock::ReentrantLock
  fail_commit::Bool
  rollback_error_msg::Union{Nothing, String}   # nothing → ROLLBACK succeeds
  next_id::Int
  executed::Vector{String}
  available_at_rollback::Union{Nothing, Bool}
  conn_at_rollback::Any
end
MockSQLitePool139(; fail_commit::Bool = false, rollback_error_msg::Union{Nothing, String} = nothing) =
  MockSQLitePool139(Any[FakeConn139(1)], [true], "mock://sqlite", 1, false, 1, 0,
                    ReentrantLock(), ReentrantLock(), fail_commit, rollback_error_msg, 1,
                    String[], nothing, nothing)

PormG.backend_is_alive(::MockSQLitePool139, conn) = conn isa FakeConn139 && !conn.closed
PormG.backend_connect(pool::MockSQLitePool139; read_only::Bool = false) = FakeConn139(pool.next_id += 1)
PormG.backend_renew_connection(pool::MockSQLitePool139, conn; read_only::Bool = false) = FakeConn139(pool.next_id += 1)
function PormG.backend_execute(pool::MockSQLitePool139, conn, sql::String, params)
  # Runs on the global SQLite worker; sequential vs. the caller via Base.fetch. Keep it pure.
  push!(pool.executed, sql)
  if startswith(sql, "ROLLBACK")
    pool.available_at_rollback = pool.available[1]
    pool.conn_at_rollback = conn
  end
  pool.fail_commit && startswith(sql, "COMMIT") && error("mock: commit refused")
  if pool.rollback_error_msg !== nothing && startswith(sql, "ROLLBACK")
    error(pool.rollback_error_msg)
  end
  return NamedTuple[]
end

# ── Minimal concrete SQLConn wrapper (like Configuration.Settings): <: SQLConn but NOT a
#    PormGPostgres/PormGSQLite, so finalize_transaction_connection!(::SQLConn, ...) dispatches to
#    the delegating overload that delete() relies on (settings is a Settings, not a raw pool). ──
mutable struct MockSettings139 <: PormG.SQLConn
  connections::Any
end

# ── The FIXED lifecycle call sequence the migration/delete callers now use (single terminal
#    finally). Mirrors runner.jl / deletion.jl: BEGIN self-acquires, COMMIT and ROLLBACK never
#    release, one finally finalizes. Returns (conn, caught_error_or_nothing). ──
function run_fixed_lifecycle_139(pool, begin_sql)
  _, conn = CP.with_transaction(pool, begin_sql)
  local rollback_error = nothing
  try
    # (body succeeded) → COMMIT (which fails in these tests)
    CP.with_transaction(pool, "COMMIT;", conn = conn, release_conn = false)
    return conn, nothing
  catch e
    try
      CP.with_transaction(pool, "ROLLBACK;", conn = conn, release_conn = false)
    catch rb
      rollback_error = rb
    end
    return conn, e
  finally
    CP.finalize_transaction_connection!(pool, conn; rollback_error = rollback_error)
  end
end

# ── The PRE-FIX (buggy) sequence: COMMIT/ROLLBACK with release_conn=true. Reproduced only to
#    show it releases the connection BEFORE ROLLBACK (available_at_rollback === true) — the exact
#    #139 hazard the fixed sequence avoids. Characterizes with_transaction's unchanged behavior. ──
function run_buggy_lifecycle_139(pool, begin_sql)
  _, conn = CP.with_transaction(pool, begin_sql)
  try
    CP.with_transaction(pool, "COMMIT;", conn = conn, release_conn = true)
    return conn, nothing
  catch e
    try
      CP.with_transaction(pool, "ROLLBACK;", conn = conn, release_conn = true)
    catch _
    end
    return conn, e
  end
end

# ── Drive the REAL PormG.Migrations._execute_migration_lifecycle (not a reproduction) against the
#    mock, so a future revert of the caller's `release_conn` is caught by CI. The mock returns empty
#    result tables (so the migration reads the DB as empty → no idempotency skip), no-ops the DDL and
#    the history INSERTs, and throws on COMMIT. The 2nd arg is `settings::SQLConn`; since #186 a pool is
#    no longer <: SQLConn, we pass a MockSettings139 (a Settings-like SQLConn wrapping the pool) — it is
#    only touched by archiving, which the COMMIT-failure rethrow never reaches. Returns the error/nothing. ──
function run_real_migration_lifecycle_139(pool)
  settings = MockSettings139(pool)
  try
    PormG.Migrations._execute_migration_lifecycle(
      pool, settings,
      String["CREATE TABLE _pormg_t139 (id integer);"],
      "CREATE TABLE _pormg_t139 (id integer);",
      "v139", "commit_fail_mig", "chk139", false)
    return nothing
  catch e
    return e
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# finalize_transaction_connection! — the shared terminal release/heal helper
# ─────────────────────────────────────────────────────────────────────────────
@testset "finalize_transaction_connection! releases a clean connection (#139)" begin
  pool = MockPGPool139()
  conn = CP.acquire_connection(pool)
  @test pool.available[1] === false                     # leased

  @test CP.finalize_transaction_connection!(pool, conn) === nothing   # rollback_error defaults to nothing
  @test pool.connections[1] === conn                    # same handle, not renewed
  @test pool.available[1] === true                      # released
  @test conn.closed === false                           # a clean connection is never closed
end

@testset "finalize_transaction_connection! renews on a non-benign rollback error (#139/#71)" begin
  pool = MockPGPool139()
  conn = CP.acquire_connection(pool)

  CP.finalize_transaction_connection!(pool, conn; rollback_error = ErrorException("disk I/O error"))
  @test pool.connections[1] !== conn                    # slot renewed
  @test pool.connections[1] isa FakeConn139 && pool.connections[1].id == 2
  @test pool.available[1] === true                      # renewed handle released
  @test conn.closed === true                            # dirty handle closed
end

@testset "finalize_transaction_connection! discards when renewal also fails (#139/#71)" begin
  pool = MockPGPool139(fail_renew = true)
  conn = CP.acquire_connection(pool)

  CP.finalize_transaction_connection!(pool, conn; rollback_error = ErrorException("disk I/O error"))
  @test pool.connections[1] === nothing                 # slot cleared
  @test pool.available[1] === true
  @test conn.closed === true
end

@testset "finalize_transaction_connection! treats benign SQLite rollback errors as clean (#139/#71)" begin
  pool = MockSQLitePool139()
  conn = CP.acquire_connection(pool; mode = :write)

  CP.finalize_transaction_connection!(pool, conn; rollback_error = ErrorException("cannot rollback - no transaction is active"))
  @test pool.connections[1] === conn                    # NOT renewed: clean, released as-is
  @test pool.available[1] === true
  @test conn.closed === false
  @test pool.next_id == 1                               # no fresh handle created
end

@testset "finalize_transaction_connection! SQLConn overload delegates to the pool (#139)" begin
  # delete() passes a Settings (a SQLConn wrapper), not a raw pool, so it dispatches here.
  pool = MockPGPool139()
  conn = CP.acquire_connection(pool)
  settings = MockSettings139(pool)

  # #186: a pool and a Settings are now DISTINCT type families — a pool is NOT a SQLConn (it's a
  # PormGBackend); only the Settings wrapper is a SQLConn. That separation is exactly what makes the
  # two finalize_transaction_connection! overloads (pool vs SQLConn) dispatch to the right one.
  @test !(pool isa PormG.SQLConn)
  @test pool isa PormG.PormGBackend
  @test settings isa PormG.SQLConn

  @test CP.finalize_transaction_connection!(settings, conn) === nothing   # <: SQLConn, not a pool
  @test pool.connections[1] === conn                    # delegated to pool.connections and released
  @test pool.available[1] === true
  # And the renew path still routes through the delegation.
  conn2 = CP.acquire_connection(pool)
  CP.finalize_transaction_connection!(settings, conn2; rollback_error = ErrorException("disk I/O error"))
  @test pool.connections[1] !== conn2                   # renewed via the wrapped pool
  @test pool.available[1] === true
end

# ─────────────────────────────────────────────────────────────────────────────
# Fixed lifecycle: a failed COMMIT keeps the connection leased through ROLLBACK
# ─────────────────────────────────────────────────────────────────────────────
@testset "PG failed COMMIT holds the connection until ROLLBACK, releases once (#139)" begin
  pool = MockPGPool139(fail_commit = true)
  old = pool.connections[1]

  conn, err = @test_logs (:error, r"Failed to execute SQL transaction") match_mode = :any begin
    run_fixed_lifecycle_139(pool, "BEGIN;")
  end

  @test err !== nothing && occursin("commit refused", string(CP._unwrap_async_exception(err)))   # the COMMIT failure propagates
  @test pool.available_at_rollback === false            # STILL LEASED when ROLLBACK is issued (the #139 fix)
  @test pool.conn_at_rollback === conn                  # ROLLBACK ran on the transaction's own connection
  @test pool.executed == ["BEGIN;", "COMMIT;", "ROLLBACK;"]
  # ROLLBACK succeeded → clean release, exactly once.
  @test conn === old
  @test pool.connections[1] === conn                    # not renewed
  @test pool.available[1] === true                      # released
  @test conn.closed === false
end

@testset "SQLite failed COMMIT holds the connection until ROLLBACK, releases once (#139)" begin
  pool = MockSQLitePool139(fail_commit = true)
  old = pool.connections[1]

  conn, err = @test_logs (:error, r"Failed to execute SQL transaction") match_mode = :any begin
    run_fixed_lifecycle_139(pool, "BEGIN IMMEDIATE TRANSACTION;")
  end

  @test err !== nothing && occursin("commit refused", string(CP._unwrap_async_exception(err)))
  @test pool.available_at_rollback === false            # still leased at ROLLBACK time
  @test pool.conn_at_rollback === conn
  @test pool.executed == ["BEGIN IMMEDIATE TRANSACTION;", "COMMIT;", "ROLLBACK;"]
  @test conn === old
  @test pool.connections[1] === conn
  @test pool.available[1] === true
  @test conn.closed === false
end

# ─────────────────────────────────────────────────────────────────────────────
# Contrast: the PRE-FIX sequence releases the connection BEFORE ROLLBACK (the #139 bug)
# This runs green on today's code (with_transaction's COMMIT-release-on-failure is unchanged);
# it proves the `available_at_rollback === false` assertion above genuinely discriminates the fix.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PG pre-fix sequence (COMMIT release_conn=true) releases before ROLLBACK — the #139 hazard" begin
  pool = MockPGPool139(fail_commit = true)

  _conn, err = @test_logs (:error, r"Failed to execute SQL transaction") match_mode = :any begin
    run_buggy_lifecycle_139(pool, "BEGIN;")
  end

  @test err !== nothing
  @test pool.available_at_rollback === true             # connection already returned to the pool → use-after-release
end

# ─────────────────────────────────────────────────────────────────────────────
# Failed COMMIT AND failed ROLLBACK → renew/discard exactly once, never released dirty (#139+#71)
# ─────────────────────────────────────────────────────────────────────────────
@testset "PG failed COMMIT then failed ROLLBACK renews the connection once (#139/#71)" begin
  pool = MockPGPool139(fail_commit = true, fail_rollback = true)
  old = pool.connections[1]

  conn, err = @test_logs (:error, r"Failed to execute SQL transaction") match_mode = :any begin
    run_fixed_lifecycle_139(pool, "BEGIN;")
  end

  @test err !== nothing && occursin("commit refused", string(CP._unwrap_async_exception(err)))   # root cause wins, not "rollback refused"
  @test pool.available_at_rollback === false            # leased through the (failing) ROLLBACK
  @test conn === old
  @test pool.connections[1] !== old                     # slot renewed (dirty handle never returned)
  @test pool.connections[1] isa FakeConn139 && pool.connections[1].id == 2
  @test pool.available[1] === true                      # renewed handle released, exactly once
  @test old.closed === true                             # dirty handle closed
end

@testset "SQLite failed COMMIT then failed ROLLBACK renews the connection once (#139/#71)" begin
  pool = MockSQLitePool139(fail_commit = true, rollback_error_msg = "disk I/O error")
  old = pool.connections[1]

  conn, err = @test_logs (:error, r"Failed to execute SQL transaction") match_mode = :any begin
    run_fixed_lifecycle_139(pool, "BEGIN IMMEDIATE TRANSACTION;")
  end

  @test err !== nothing && occursin("commit refused", string(CP._unwrap_async_exception(err)))
  @test pool.available_at_rollback === false
  @test conn === old
  @test pool.connections[1] !== old                     # renewed
  @test pool.connections[1] isa FakeConn139 && pool.connections[1].id == 2
  @test pool.available[1] === true
  @test old.closed === true
end

# ─────────────────────────────────────────────────────────────────────────────
# Real callers: drive the actual migration lifecycle through a failed COMMIT (#139)
# These invoke PormG.Migrations._execute_migration_lifecycle directly, so they catch a future
# revert of the caller's `release_conn=false` back to `true` (the pre-fix bug) — which the
# reproduction-based testsets above cannot. Under the pre-fix code the failed COMMIT releases the
# connection, flipping available_at_rollback to `true`, so these assertions would fail.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Real PG migration lifecycle: failed COMMIT holds the connection until ROLLBACK (#139)" begin
  pool = MockPGPool139(fail_commit = true)
  old = pool.connections[1]

  err = @test_logs (:error, r"Error applying migrations") match_mode = :any begin
    run_real_migration_lifecycle_139(pool)
  end

  @test err !== nothing                                 # the COMMIT failure propagates out of the real lifecycle
  @test pool.available_at_rollback === false            # conn still leased when the lifecycle's ROLLBACK runs
  @test pool.conn_at_rollback === old                   # ROLLBACK ran on the transaction's own connection
  @test any(s -> startswith(s, "COMMIT"),   pool.executed)
  @test any(s -> startswith(s, "ROLLBACK"), pool.executed)
  @test pool.available[1] === true                      # released exactly once by the terminal finally
  @test pool.connections[1] === old                     # clean release (the lifecycle's ROLLBACK succeeded)
  @test old.closed === false
end

@testset "Real SQLite migration lifecycle: failed COMMIT holds the connection until ROLLBACK (#139)" begin
  pool = MockSQLitePool139(fail_commit = true)
  old = pool.connections[1]

  err = @test_logs (:error, r"Error applying migrations") match_mode = :any begin
    run_real_migration_lifecycle_139(pool)
  end

  @test err !== nothing
  @test pool.available_at_rollback === false
  @test pool.conn_at_rollback === old
  @test any(s -> startswith(s, "COMMIT"),   pool.executed)
  @test any(s -> startswith(s, "ROLLBACK"), pool.executed)
  @test pool.available[1] === true
  @test pool.connections[1] === old
end
