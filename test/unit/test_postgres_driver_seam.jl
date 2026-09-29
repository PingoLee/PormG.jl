# ============================================================
# test/unit/test_postgres_driver_seam.jl
#
# The PostgreSQL driver is a property of the pool (#785).
#
# CONTRACT being tested:
#   `PostgresConnectionPool{D}` carries its driver in the type (`:libpq` by default), so a second
#   PostgreSQL extension can dispatch on it instead of overwriting LibPQ's methods, which are typed on
#   the `PormGPostgres` marker. Every other `PormGPostgres` — the unit suite's mock pools — keeps
#   answering `:libpq`. An unknown driver is refused at construction. A pool configured for another
#   driver is never served by the LibPQ extension, and the missing-driver fallback names the right
#   package. The LibPQ hint text is unchanged (docs/src/index.md quotes it).
#
# Hermetic: pools build lazily, and the only connect attempts below are refused before any I/O.
# ============================================================

using Test
using PormG

# SQLite/LibPQ are weakdeps since #34 — load the driver extensions so the backend hooks resolve.
include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const CP = PormG.ConnectionPool

struct _DriverSeamMockPG <: PormG.PormGPostgres end
struct _DriverSeamUnknownPG <: PormG.PormGPostgres end
PormG.postgres_driver(::_DriverSeamUnknownPG) = :mystery

@testset "the default pool is LibPQ, and its shape is unchanged (#785)" begin
  pool = CP.PostgresConnectionPool("host=localhost dbname=x user=y")
  @test pool isa CP.PostgresConnectionPool{:libpq}
  @test pool isa CP.PostgresConnectionPool
  @test pool isa PormG.PormGPostgres
  @test PormG.postgres_driver(pool) === :libpq
  @test fieldnames(typeof(pool)) == (:connections, :available, :connection_string, :pool_size,
                                     :pool_timeout, :fail_fast_on_connect, :lock)

  # The positional form (src/precompile.jl) stays a LibPQ pool.
  positional = CP.PostgresConnectionPool(Any[], Bool[], "dummy", 0, 1.0, true, ReentrantLock())
  @test positional isa CP.PostgresConnectionPool{:libpq}

  # A pool that is not a PostgresConnectionPool — every unit-suite mock — answers LibPQ.
  @test PormG.postgres_driver(_DriverSeamMockPG()) === :libpq
end

@testset "the driver is chosen at construction and validated (#785)" begin
  pool = CP.PostgresConnectionPool("host=localhost dbname=x user=y"; driver = :postgres)
  @test pool isa CP.PostgresConnectionPool{:postgres}
  @test PormG.postgres_driver(pool) === :postgres

  @test_throws PormG.InvalidConfigurationError CP.PostgresConnectionPool("host=h"; driver = :pq)
  # The inner constructor is the only way in, so naming the parameter directly is checked too.
  @test_throws PormG.InvalidConfigurationError CP.PostgresConnectionPool{:bogus}(
    Any[], Bool[], "dummy", 0, 1.0, true, ReentrantLock())
  @test_throws PormG.InvalidConfigurationError CP.PostgresConnectionPool{Int}(
    Any[], Bool[], "dummy", 0, 1.0, true, ReentrantLock())
end

@testset "the missing-driver fallback names the pool's driver (#785)" begin
  # The extra positional argument matches ONLY the varargs fallback in src/Backend.jl, so this pins
  # the fallback whether or not a driver extension is loaded (the test_error_taxonomy.jl trick).
  fallback_message(pool) = try
    PormG.backend_connect(pool, :force_varargs_fallback)
    nothing
  catch e
    e isa PormG.InvalidConfigurationError ? PormG.error_message(e) : e
  end
  libpq_pool = CP.PostgresConnectionPool("host=h")
  postgres_pool = CP.PostgresConnectionPool("host=h"; driver = :postgres)

  @test fallback_message(libpq_pool) == PormG._PG_DRIVER_HINT
  @test fallback_message(_DriverSeamMockPG()) == PormG._PG_DRIVER_HINT
  msg = fallback_message(postgres_pool)
  @test msg isa String
  @test occursin("using Postgres", msg)
  @test !occursin("using LibPQ", msg)

  # A mock answering a driver no real pool can have still gets the typed error, not a KeyError
  # escaping the fallback.
  unknown_msg = fallback_message(_DriverSeamUnknownPG())
  @test unknown_msg isa String
  @test occursin("mystery", unknown_msg)
end

@testset "the LibPQ extension never serves a pool configured for another driver (#785)" begin
  @test Base.get_extension(PormG, :PormGLibPQExt) !== nothing

  # A NUL makes the LibPQ extension's own preflight throw its NUL message, so getting the driver
  # refusal instead proves the refusal came first and libpq was never reached.
  postgres_pool = CP.PostgresConnectionPool("host=h dbname=x\0y"; driver = :postgres)
  err = try
    PormG.backend_connect(postgres_pool)
    nothing
  catch e
    e
  end
  @test err isa PormG.InvalidConfigurationError
  @test occursin("using Postgres", PormG.error_message(err))
  @test !occursin("NUL", PormG.error_message(err))

  # The same pool through the pool API: the refusal is permanent, so it fails fast rather than
  # waiting out pool_timeout, and the cause is the refusal.
  pool = CP.PostgresConnectionPool("host=h dbname=x"; driver = :postgres, pool_size = 1, pool_timeout = 30)
  t0 = time()
  err = try
    CP.acquire_connection(pool)
    nothing
  catch e
    e
  end
  @test err isa CP.PoolConnectError
  @test err.cause isa PormG.InvalidConfigurationError
  @test time() - t0 < 10

  # The LibPQ pool still reaches the LibPQ preflight (its NUL message), not the refusal.
  libpq_pool = CP.PostgresConnectionPool("host=h dbname=x\0y")
  err = try
    PormG.backend_connect(libpq_pool)
    nothing
  catch e
    e
  end
  @test err isa PormG.InvalidConfigurationError
  @test occursin("NUL", PormG.error_message(err))
end
