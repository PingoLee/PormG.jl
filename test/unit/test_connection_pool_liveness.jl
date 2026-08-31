# ============================================================
# test/unit/test_connection_pool_liveness.jl
#
# Pool liveness after a SERVER-SIDE kill (#442).
#
# CONTRACT being tested — two independent halves:
#
#   1. A connection the liveness probe REJECTS is retired: closed and removed from its slot,
#      not silently overwritten. Before #442 the acquire scan assigned the fresh handle straight
#      over `pool.connections[i]`, so the dead driver object was dropped on the floor for a GC
#      finalizer to close. Harmless while the probe almost never fired; a real leak once the probe
#      became strong enough to reject an idle backend the server had killed.
#
#   2. When a failure is CLASSIFIED as a lost connection, every OTHER idle slot is retired too.
#      A dropped connection is almost never solitary — a restart, a failover or an admin sweep
#      kills every backend at once — and `fetch`'s reconnect-retry deliberately re-acquires through
#      the normal pool path, which would otherwise hand back another corpse. Observed in production:
#      one PostgreSQL restart, then three failures spread over six minutes, two of them minutes
#      after the server was healthy again.
#
# What this file CANNOT cover: the probe itself. The #442 fix to `backend_is_alive` lives in
# `ext/PormGLibPQExt.jl` (consume pending socket input before trusting `PQstatus`), and every mock
# here defines its own `backend_is_alive` — so no mock can reach `PQconsumeInput`. That half is
# proven against a real killed backend in `test/integration/test_connection_pool.jl`.
#
# Deterministic and DB-free: behavioral mock pools carrying the exact fields the pool machinery
# reads (the pattern from test_transaction_rollback_renewal.jl / test_fetch_retry_transaction.jl),
# with an `alive` flag the test flips to simulate a backend the server terminated.
#
# The one exception is the final testset, which pins the REAL PostgreSQL classifier against the
# message a real `pg_terminate_backend` produces — so this file loads the driver extensions.
# ============================================================

using Test
using PormG

# The mock flows need no drivers (every backend_* call dispatches to the methods below), but the
# classifier testset at the end exercises the LibPQ extension's own method.
include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const CP = PormG.ConnectionPool

# ── Fake driver handle ──
# `alive` is what a server-side kill flips: the handle is still open client-side (`closed` stays
# false, exactly as libpq's `PQstatus` would still read CONNECTION_OK), but the backend behind it
# is gone. `close_count` — not just a Bool — because the acquire loop revisits a rejected slot after
# its `before_connect` hook detour, and closing the same handle twice would be a real defect.
mutable struct FakeConn442
  id::Int
  closed::Bool
  alive::Bool
  close_count::Int
end
FakeConn442(id::Int) = FakeConn442(id, false, true, 0)
Base.close(c::FakeConn442) = (c.closed = true; c.close_count += 1; nothing)

# Driver-shaped "connection lost" sentinel — its own TYPE, not a message match, so the classifier
# is exercised the way the real ones are (see the note in test_fetch_retry_transaction.jl).
struct MockConnLost442 <: Exception end
Base.showerror(io::IO, ::MockConnLost442) = print(io, "mock: connection lost")

# A failure that is NOT a dropped connection (a syntax error, say). Proves the sweep is gated on
# classification rather than on "any statement failed".
struct MockPlainFail442 <: Exception end
Base.showerror(io::IO, ::MockPlainFail442) = print(io, "mock: syntax error near \"boom\"")

# ── PG-shaped mock: PostgresConnectionPool's exact fields + probe/failure knobs ──
mutable struct MockPGLive442 <: PormG.PormGPostgres
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
  next_id::Int                         # id source for freshly "connected"/renewed handles
  probes::Int                          # how many times backend_is_alive ran
  fail_prefix::Union{Nothing, String}  # statements with this prefix fail while fail_times > 0
  fail_times::Int                      # one-shot budget: the retry's re-run succeeds
  fail_kind::Symbol                    # :conn_lost (classified → retry+sweep) or :plain
  executed::Vector{String}             # every statement the "driver" received, in order
  renewals::Int                        # how many times backend_renew_connection ran
end
function MockPGLive442(n::Int = 1; fail_prefix::Union{Nothing, String} = nothing,
                       fail_times::Int = 0, fail_kind::Symbol = :conn_lost)
  conns = Any[FakeConn442(i) for i in 1:n]
  MockPGLive442(conns, fill(true, n), "mock://pg", n, ReentrantLock(), n, 0,
                fail_prefix, fail_times, fail_kind, String[], 0)
end

# The probe a server-side kill defeats: `alive` is false but the handle is not closed.
function PormG.backend_is_alive(pool::MockPGLive442, conn)
  pool.probes += 1
  return conn isa FakeConn442 && !conn.closed && conn.alive
end
PormG.backend_connect(pool::MockPGLive442; kwargs...) = FakeConn442(pool.next_id += 1)
function PormG.backend_renew_connection(pool::MockPGLive442, conn; kwargs...)
  pool.renewals += 1
  return FakeConn442(pool.next_id += 1)
end
function PormG.backend_execute_async(pool::MockPGLive442, conn, sql::String, params)
  push!(pool.executed, sql)
  # Fail INSIDE the task (like a real async driver failure) so Base.fetch throws a
  # TaskFailedException and fetch's catch exercises _unwrap_async_exception.
  return @async begin
    if pool.fail_prefix !== nothing && pool.fail_times > 0 && startswith(sql, pool.fail_prefix)
      pool.fail_times -= 1
      throw(pool.fail_kind === :conn_lost ? MockConnLost442() : MockPlainFail442())
    end
    NamedTuple[]
  end
end
PormG.backend_is_connection_error(::MockPGLive442, e) = e isa MockConnLost442

# ── SQLite-shaped mock: SQLiteConnectionPool's exact fields (PG/SQLite stay aligned) ──
mutable struct MockSQLiteLive442 <: PormG.PormGSQLite
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  split_read_write::Bool
  writer_slot::Int
  reader_cursor::Int
  lock::ReentrantLock
  write_lock::ReentrantLock
  next_id::Int
  probes::Int
end
function MockSQLiteLive442(n::Int = 1)
  conns = Any[FakeConn442(i) for i in 1:n]
  MockSQLiteLive442(conns, fill(true, n), "mock://sqlite", n, false, 1, 0,
                    ReentrantLock(), ReentrantLock(), n, 0)
end
function PormG.backend_is_alive(pool::MockSQLiteLive442, conn)
  pool.probes += 1
  return conn isa FakeConn442 && !conn.closed && conn.alive
end
PormG.backend_connect(pool::MockSQLiteLive442; read_only::Bool = false) =
  FakeConn442(pool.next_id += 1)

# ─────────────────────────────────────────────────────────────────────────────
# (1) A probe-rejected handle is CLOSED and replaced — not overwritten and leaked.
# Reverting the fix (dropping the `push!(dead_handles, …)` retirement in acquire_connection's
# branch (B)) leaves `victim.closed === false`: the pool still hands back a healthy connection,
# so only the close assertions catch it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a probe-rejected connection is retired, not overwritten (#442)" begin
  pool = MockPGLive442(1)
  victim = pool.connections[1]

  victim.alive = false                        # the server killed this backend; handle still open
  @test victim.closed === false

  fresh = CP.acquire_connection(pool)
  @test fresh isa FakeConn442
  @test fresh !== victim                      # a corpse is never handed out
  @test fresh.alive
  @test pool.connections[1] === fresh         # the slot now holds the replacement
  @test victim.closed === true                # …and the dead handle was closed, not leaked
  @test victim.close_count == 1               # exactly once, despite the before_connect detour

  CP.release_connection(pool, fresh)
  @test pool.available == [true]
end

# ─────────────────────────────────────────────────────────────────────────────
# (2) Same contract on the SQLite twin — the two acquire paths are kept symmetric by hand, so a
# fix applied to only one of them is a live risk.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: a probe-rejected connection is retired too (#442)" begin
  pool = MockSQLiteLive442(1)
  victim = pool.connections[1]
  victim.alive = false

  fresh = CP.acquire_connection(pool)
  @test fresh !== victim
  @test pool.connections[1] === fresh
  @test victim.closed === true
  @test victim.close_count == 1

  CP.release_connection(pool, fresh)
  @test pool.available == [true]
end

# ─────────────────────────────────────────────────────────────────────────────
# (3) `_sweep_stale_idle!` in isolation: retire every idle slot except `keep`, never a leased one.
# Driven directly (no clock, no async) — the three exclusion rules are the whole contract.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_sweep_stale_idle! spares the leased slot and `keep` (#442)" begin
  pool = MockPGLive442(4)
  c1, c2, c3, c4 = pool.connections[1], pool.connections[2], pool.connections[3], pool.connections[4]

  leased = CP.acquire_connection(pool)        # scan order 1..n → slot 1
  @test leased === c1
  @test pool.available[1] === false

  swept = CP._sweep_stale_idle!(pool, c3)     # c3 stands in for the just-renewed handle
  @test swept == 2                            # c2 and c4 only

  @test pool.connections[1] === c1            # LEASED — the borrower still owns this handle
  @test c1.closed === false
  @test pool.connections[3] === c3            # `keep` — the reconnect we just paid for
  @test c3.closed === false

  @test pool.connections[2] === nothing       # retired: emptied…
  @test pool.connections[4] === nothing
  @test c2.closed === true                    # …and closed
  @test c4.closed === true
  @test pool.available[2] === true            # slot stays available → next acquire opens fresh
  @test pool.available[4] === true

  CP.release_connection(pool, leased)
  @test count(!, pool.available) == 0
end

# ─────────────────────────────────────────────────────────────────────────────
# (4) A no-op sweep: nothing to retire when the pool holds only `keep`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_sweep_stale_idle! is a no-op when there is nothing stale (#442)" begin
  pool = MockPGLive442(1)
  keep = pool.connections[1]
  @test CP._sweep_stale_idle!(pool, keep) == 0
  @test pool.connections[1] === keep
  @test keep.closed === false
end

# ─────────────────────────────────────────────────────────────────────────────
# (5) SQLite twin of the sweep — backend-agnostic by construction, pinned by test.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: _sweep_stale_idle! retires the idle slots (#442)" begin
  pool = MockSQLiteLive442(3)
  c1, c2, c3 = pool.connections[1], pool.connections[2], pool.connections[3]

  @test CP._sweep_stale_idle!(pool, c1) == 2
  @test pool.connections[1] === c1
  @test c1.closed === false
  @test pool.connections[2] === nothing && c2.closed === true
  @test pool.connections[3] === nothing && c3.closed === true
end

# ─────────────────────────────────────────────────────────────────────────────
# (6) ACCEPTANCE CRITERION (#442): `fetch`'s lost-connection retry retires the rest of the pool.
#
# This is the production failure. One statement dies on a dropped connection; the retry renews
# that one slot and re-acquires through the normal pool path. Without the sweep the remaining
# slots still hold connections the same event killed, and each is discovered separately, one
# failed statement at a time — minutes after the server came back.
#
# Reverting the fix (dropping the `_sweep_stale_idle!` call from fetch's retry branch) leaves
# slots 2 and 3 holding their original handles: the statement-count and renewal assertions still
# pass, and only the retirement assertions below catch it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "fetch's lost-connection retry sweeps the rest of the pool (#442)" begin
  pool = MockPGLive442(3; fail_prefix = "SELECT", fail_times = 1)
  doomed = pool.connections[1]                # the scan picks slot 1 → this one fails
  sibling2, sibling3 = pool.connections[2], pool.connections[3]

  rows = @test_logs (:warn, r"Lost connection to database") begin
    CP.fetch(pool, "SELECT 1;")
  end
  @test rows == NamedTuple[]                                          # the retry succeeded
  @test count(sql -> startswith(sql, "SELECT"), pool.executed) == 2   # failed once, re-ran once
  @test pool.renewals == 1                             # the failing slot was renewed…
  @test pool.connections[1] !== doomed                 # …and its slot holds the replacement

  # The other two slots were idle and are now retired — the retry could not draw a corpse.
  @test pool.connections[2] === nothing
  @test pool.connections[3] === nothing
  @test sibling2.closed === true
  @test sibling3.closed === true
  @test pool.available[2] === true && pool.available[3] === true

  @test count(!, pool.available) == 0                  # nothing leaked; every slot released
end

# ─────────────────────────────────────────────────────────────────────────────
# (7) The sweep is gated on CLASSIFICATION, not on "a statement failed". An ordinary error must
# leave every pooled connection in place — otherwise a SQL typo churns the whole pool.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an unclassified statement error leaves the pool untouched (#442)" begin
  pool = MockPGLive442(3; fail_prefix = "SELECT", fail_times = 1, fail_kind = :plain)
  before = copy(pool.connections)

  err = try
    CP.fetch(pool, "SELECT boom;")
    nothing
  catch e
    e
  end

  @test err isa PormG.PormGError                        # wrapped by the taxonomy, still raised
  @test !(err.cause isa MockConnLost442)
  @test count(sql -> startswith(sql, "SELECT"), pool.executed) == 1   # no retry — not a drop
  @test pool.renewals == 0
  @test pool.connections == before                      # every slot untouched…
  @test all(c -> c.closed === false, before)            # …and nothing closed
  @test count(!, pool.available) == 0
end

# ─────────────────────────────────────────────────────────────────────────────
# (8) The claim that makes the sweep safe under concurrency.
#
# `fetch`'s retry renews a connection `await_result` has ALREADY released, so its slot is idle for
# the whole renew+sweep window. Two tasks whose queries died together both reach that branch: without
# the claim, the one that finishes first sweeps — and CLOSES — the connection the other is still
# inside `LibPQ.reset!` on, costing that task its retry. The same window is what would let the
# acquire probe take a connection's driver semaphore, under `pool.lock`, while `reset!` holds it
# across a blocking `PQreset` — stalling every task on the pool (the #327 stall, from the other side).
#
# Both hazards reduce to one invariant, and this is it: a CLAIMED slot is invisible to the sweep.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_claim_idle_slot! protects a slot from a concurrent sweep (#442)" begin
  pool = MockPGLive442(3)
  c1, c2, c3 = pool.connections[1], pool.connections[2], pool.connections[3]

  @test CP._claim_idle_slot!(pool, c2) === true     # idle → claimed, and we are the claimer
  @test pool.available[2] === false                 # …which is exactly "leased"

  # A concurrent task now sweeps, keeping only its own renewed handle (c1).
  @test CP._sweep_stale_idle!(pool, c1) == 1        # c3 only — c2 is protected by the claim
  @test pool.connections[2] === c2                  # the renewing task's handle survives…
  @test c2.closed === false                         # …and was NOT closed under it
  @test pool.connections[3] === nothing && c3.closed === true

  # A second claimer must NOT also think it owns the slot (or it would double-release).
  @test CP._claim_idle_slot!(pool, c2) === false

  CP.release_connection(pool, c2)                   # the claimer puts it back exactly once
  @test pool.available[2] === true
end

# ─────────────────────────────────────────────────────────────────────────────
# (9) The claim's remaining edges: a handle whose slot is gone, and the fact that a leased slot is
# never probed (which is what keeps the probe off a connection mid-`reset!`).
# ─────────────────────────────────────────────────────────────────────────────
@testset "_claim_idle_slot! edges, and a leased slot is never probed (#442)" begin
  pool = MockPGLive442(2)
  orphan = FakeConn442(99)
  @test CP._claim_idle_slot!(pool, orphan) === false   # not in the pool at all → nobody's to claim

  # A leased slot is skipped by the acquire scan, so its connection is never handed to the probe.
  leased = CP.acquire_connection(pool)                 # slot 1
  probes_before = pool.probes
  other = CP.acquire_connection(pool)                  # must take slot 2, not re-probe slot 1
  @test other !== leased
  @test pool.probes - probes_before == 1               # exactly one probe: slot 2's

  CP.release_connection(pool, leased)
  CP.release_connection(pool, other)
  @test count(!, pool.available) == 0
end

# ─────────────────────────────────────────────────────────────────────────────
# (10) The classifier is the third leg of #442, and the one that made the other two unreachable for
# the reported failure. `_sweep_stale_idle!` only runs once a failure is CLASSIFIED as a lost
# connection — and a real `pg_terminate_backend` produces a message that matched NONE of the
# pre-#442 patterns, so the statement propagated instead of retrying.
#
# The text below is verbatim from a live PostgreSQL 16 kill, captured while verifying this fix; it
# is character-for-character what the #442 production report logged.
#
# These proxies are `ErrorException`s, so they deliberately exercise ONLY the codeless fallback —
# step (3) of the classifier. That is the right level for them: a connection dropped mid-query really
# does arrive without a SQLSTATE. The SQLSTATE half is covered separately in the next testset, with
# real `PQResultError`s; do not add code-bearing cases here, they would silently never reach step (3).
# ─────────────────────────────────────────────────────────────────────────────
@testset "backend_is_connection_error recognizes a server-side kill (#442)" begin
  pg = CP.PostgresConnectionPool("host=localhost dbname=x user=y")

  # The regression: exactly what a live `pg_terminate_backend` delivered.
  @test PormG.backend_is_connection_error(pg, ErrorException(
    "FATAL:  terminating connection due to administrator command
SSL connection has been closed unexpectedly"))

  # Other codeless shapes libpq produces for a lost session.
  @test PormG.backend_is_connection_error(pg, ErrorException(
    "FATAL:  terminating connection due to idle-session timeout"))
  @test PormG.backend_is_connection_error(pg, ErrorException("connection to server was lost"))
  @test PormG.backend_is_connection_error(pg, ErrorException("no connection to the server"))

  # Still recognized (pre-#442 patterns must not regress).
  @test PormG.backend_is_connection_error(pg, ErrorException("server closed the connection unexpectedly"))
  @test PormG.backend_is_connection_error(pg, ErrorException("connection not open"))

  # NOT a dropped connection. A false positive here re-runs a statement that may already have
  # executed, so ordinary failures must stay unclassified.
  @test !PormG.backend_is_connection_error(pg, ErrorException("ERROR:  syntax error at or near \"boom\""))
  @test !PormG.backend_is_connection_error(pg, ErrorException("ERROR:  duplicate key value violates unique constraint"))
  @test !PormG.backend_is_connection_error(pg, ErrorException("ERROR:  deadlock detected"))
  @test !PormG.backend_is_connection_error(pg, ErrorException("FATAL:  password authentication failed for user \"y\""))
end

# ─────────────────────────────────────────────────────────────────────────────
# (11) SQLSTATE beats message text. `string(::PQResultError)` renders the full
# `PQresultErrorMessage`, DETAIL and the `LINE n:` query excerpt included — i.e. USER DATA. An app
# that stores captured PostgreSQL log text (this repo's downstream consumer is an ETL) hits a unique
# violation whose DETAIL quotes the very phrase the classifier matches on. Classifying THAT as a
# dropped connection would hand the caller an `OperationalError` where the contract says
# `IntegrityError`, and make `fetch` renew a healthy connection and flush every idle slot each time.
#
# So a result error carrying a real SQLSTATE is decided by the code alone; only the codeless case
# (LibPQ's synthetic `CUN`, and the non-result exceptions) reaches the message fingerprints.
# ─────────────────────────────────────────────────────────────────────────────
@testset "classification prefers SQLSTATE over message text (#442)" begin
  pg = CP.PostgresConnectionPool("host=localhost dbname=x user=y")
  E = LibPQ.Errors

  # THE TRAP: an integrity error whose DETAIL echoes the connection-kill phrase back at us.
  poisoned = E.UniqueViolation(
    "ERROR:  duplicate key value violates unique constraint \"log_msg_key\"
" *
    "DETAIL:  Key (msg)=(FATAL:  terminating connection due to administrator command) already exists.",
    nothing)
  @test occursin("terminating connection", lowercase(string(poisoned)))   # the bait is really there
  @test !PormG.backend_is_connection_error(pg, poisoned)                  # …and it is not taken
  @test PormG.backend_classify_error(pg, poisoned) === :integrity         # correct type reaches the caller

  # Codes that DO mean the backend is gone are recognized without reading the message at all.
  @test PormG.backend_is_connection_error(pg, E.AdminShutdown("", nothing))          # 57P01
  @test PormG.backend_is_connection_error(pg, E.CrashShutdown("", nothing))          # 57P02
  @test PormG.backend_is_connection_error(pg, E.CannotConnectNow("", nothing))       # 57P03
  @test PormG.backend_is_connection_error(pg, E.ConnectionFailure("", nothing))      # class 08
  @test PormG.backend_is_connection_error(pg, E.ConnectionDoesNotExist("", nothing)) # class 08

  # The codeless case — libpq returned no SQLSTATE, so LibPQ synthesized class "UN". This is what a
  # connection dropped mid-query actually arrives as, and it must still reach the message match.
  codeless = E.PQResultError{E.CUN, E.EUNOWN}(
    "FATAL:  terminating connection due to administrator command
SSL connection has been closed unexpectedly",
    nothing)
  @test PormG.backend_is_connection_error(pg, codeless)

  # The one that targets IDLE POOLED connections, and so matters most to this feature.
  @test PormG.backend_is_connection_error(pg, E.IdleSessionTimeout("", nothing))   # 57P05

  # NEGATIVE SIDE of step (1) — the named codes must not creep to their whole class. Each of these
  # shares a class with something above and is deliberately NOT retryable:
  @test !PormG.backend_is_connection_error(pg, E.QueryCanceled("", nothing))       # 57014 — session alive
  @test !PormG.backend_is_connection_error(pg, E.DatabaseDropped("", nothing))     # 57P04 — retry is futile
  # 08007: the COMMIT OUTCOME IS UNKNOWN. Retrying could double-apply, so class 08 is enumerated by
  # code rather than matched whole.
  @test !PormG.backend_is_connection_error(pg, E.TransactionResolutionUnknown("", nothing))
  @test !PormG.backend_is_connection_error(pg, E.ProtocolViolation("", nothing))   # 08P01
  # A serialization failure must be retried by the caller as a whole transaction, never re-run here.
  @test !PormG.backend_is_connection_error(pg, E.SerializationFailure("", nothing))

  # Other real SQLSTATEs stay unclassified, message notwithstanding.
  @test !PormG.backend_is_connection_error(pg, E.UniqueViolation("duplicate key", nothing))

  # A multi-result execute raises CompositeException, which `_unwrap_async_exception` leaves intact.
  # Without the recursion in step (0) this would be judged on concatenated message text, letting the
  # poisoned DETAIL above back in through a side door.
  @test !PormG.backend_is_connection_error(pg, CompositeException([poisoned, poisoned]))
  @test PormG.backend_is_connection_error(pg, CompositeException([poisoned, E.AdminShutdown("", nothing)]))
end
