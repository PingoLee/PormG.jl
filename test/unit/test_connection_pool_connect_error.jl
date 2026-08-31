# ============================================================
# test/unit/test_connection_pool_connect_error.jl
#
# Connect-failure classification + fast-fail → typed PoolConnectError (#72, AC2).
#
# CONTRACT being tested:
#   When `acquire_connection` cannot OPEN a physical connection (permanently-bad string: bad password,
#   missing role/db, an unopenable SQLite path) it must NOT wait the full pool_timeout and then blame
#   pool saturation. It fast-fails (when the error is classified permanent AND fail_fast_on_connect is
#   on) with a catchable `PoolConnectError` carrying the underlying driver cause + a redacted connection
#   string. A healthy-but-saturated pool still raises `PoolTimeoutError` (covered in
#   test_connection_pool_timeout.jl); the two paths must stay distinct.
#
# Deterministic and server-free: a SQLite pool pointed at a path whose PARENT directory does not exist
# makes SQLite raise CANTOPEN ("unable to open database file") on every connect attempt — the realistic
# "permanent" SQLite case. Classification itself is a pure, message-substring function, tested directly.
# ============================================================

using Test
using PormG

# SQLite/LibPQ are weakdeps since #34 — load the driver extensions so the backend hooks resolve.
include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const CP = PormG.ConnectionPool

@testset "backend_is_permanent_connect_error classifies auth/cantopen only (#72)" begin
  # Pools build lazily (no connect), so these are safe to construct with dummy strings.
  pg = CP.PostgresConnectionPool("host=localhost dbname=x user=y")
  sl = CP.SQLiteConnectionPool(":memory:")

  # NOTE: the classifier is a pure `lowercase(string(e))` substring match, so proxying the driver
  # messages with ErrorException tests exactly the classification contract. The PG *end-to-end* path
  # (a real LibPQ.PQConnectionError from a live server) is left to the integration suite; SQLite is
  # exercised end-to-end below against a real SQLiteException.
  # PostgreSQL — permanent (config/auth) classes fast-fail…
  @test PormG.backend_is_permanent_connect_error(pg, ErrorException("FATAL: password authentication failed for user \"y\""))
  @test PormG.backend_is_permanent_connect_error(pg, ErrorException("FATAL: role \"y\" does not exist"))
  @test PormG.backend_is_permanent_connect_error(pg, ErrorException("FATAL: database \"x\" does not exist"))
  @test PormG.backend_is_permanent_connect_error(pg, ErrorException("no pg_hba.conf entry for host \"1.2.3.4\""))
  # …but host/DNS/network stay AMBIGUOUS (must NOT fast-fail — could be a transient blip).
  @test !PormG.backend_is_permanent_connect_error(pg, ErrorException("could not translate host name \"db\" to address"))
  @test !PormG.backend_is_permanent_connect_error(pg, ErrorException("could not connect to server: Connection timed out"))

  # SQLite — unopenable path is permanent; a locked/disk error is not a permanent OPEN failure.
  @test PormG.backend_is_permanent_connect_error(sl, SQLite.SQLiteException("unable to open database file"))
  @test !PormG.backend_is_permanent_connect_error(sl, SQLite.SQLiteException("database is locked"))
end

# A SQLite pool that can never open a connection (parent directory of the DB file does not exist →
# SQLITE_CANTOPEN). `close_pool!` on such a pool is a harmless no-op (nothing was ever opened).
_unopenable_sqlite_pool(; kwargs...) =
  CP.SQLiteConnectionPool(joinpath(tempname(), "db.sqlite"); kwargs...)

@testset "fast-fail raises PoolConnectError (not PoolTimeoutError) well under the deadline (#72)" begin
  # Warm the connect→classify→raise path on a THROWAWAY pool before measuring (#382). Everything
  # below the measurement is JIT-sensitive — SQLite's connect, the permanent-error classifier, the
  # PoolConnectError construction — and none of it is what the assertion is about.
  #
  # Not a nicety: run this file on its own and the cold path took 1.33-1.41 s here, so `elapsed < 1.0`
  # FAILED on unmodified main. It passes inside `test/runtests.jl` only because earlier testsets
  # happen to warm it, which makes the rung-1 "run the one file" workflow report a phantom failure.
  # Warm, the same call is ~0.2 s, so the 1.0 s bound recovers a real 5x margin against the 5 s
  # deadline it exists to exclude.
  warmup = _unopenable_sqlite_pool(pool_size = 1)
  try; CP.acquire_connection(warmup; timeout_seconds = 5); catch; end
  try; CP.close_pool!(warmup); catch; end

  pool = _unopenable_sqlite_pool(pool_size = 1)     # fail_fast_on_connect defaults to true
  try
    t0 = time()
    err = try
      CP.acquire_connection(pool; timeout_seconds = 5)   # would wait 5s if it did NOT fast-fail
      nothing
    catch e; e end
    elapsed = time() - t0

    @test err isa PormG.PoolConnectError               # truthful type — NOT PoolTimeoutError
    @test !(err isa PormG.PoolTimeoutError)
    @test err.adapter == "SQLite"
    @test err.cause isa SQLite.SQLiteException          # underlying driver cause preserved
    @test err.attempts >= 1
    @test 0.0 <= err.elapsed_seconds < 1.0              # the field itself reflects the fast-fail, not the 5s budget
    @test elapsed < 1.0                                 # MUTATION GATE: fast-fail, not the 5s deadline
    @test occursin("could not open", sprint(showerror, err))
    @test occursin("unable to open database file", sprint(showerror, err))   # cause surfaced in message
  finally
    try; CP.close_pool!(pool); catch; end
  end
end

@testset "fail_fast_on_connect=false waits to the deadline, still PoolConnectError (#72)" begin
  # Same unopenable pool, but fast-fail disabled → it must fall through to the normal wait-to-deadline
  # path (proving the toggle) and STILL surface the truthful PoolConnectError (not PoolTimeoutError).
  pool = _unopenable_sqlite_pool(pool_size = 1, fail_fast_on_connect = false)
  try
    t0 = time()
    err = try
      CP.acquire_connection(pool; timeout_seconds = 1)
      nothing
    catch e; e end
    elapsed = time() - t0

    @test err isa PormG.PoolConnectError               # truthful cause even without fast-fail
    @test err.cause isa SQLite.SQLiteException
    @test elapsed >= 0.8                               # discriminator: it waited ~the full 1s budget
  finally
    try; CP.close_pool!(pool); catch; end
  end
end
