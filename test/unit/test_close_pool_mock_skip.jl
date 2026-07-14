"""
Regression: `close_pool!` (and therefore `Configuration.__cleanup__`) must SKIP any
`PormGPostgres`/`PormGSQLite` value that is not a real connection pool.

Background: SQL-inspection unit tests install lightweight *mock* pools into the global
`PormG.config` (empty structs that subtype `PormGPostgres`/`PormGSQLite` only to satisfy
dialect dispatch — they have none of a real pool's fields). When the combined
`PORMG_INTEGRATION_TESTS=true julia test/runtests.jl` run reaches integration teardown,
`__cleanup__()` walks every `config` entry and calls `close_pool!` on it. Previously
`close_pool!` dispatched on the ABSTRACT `PormGPostgres`/`PormGSQLite` and immediately
touched `pool.lock`, so a leaked mock raised
`FieldError: type <Mock> has no field lock`, aborting cleanup with a spurious error on an
otherwise-green run (and masking any genuine cleanup failure).

Fix: the field-accessing `close_pool!` bodies dispatch on the CONCRETE pool structs
(`PostgresConnectionPool` / `SQLiteConnectionPool`); a no-op fallback covers every other
`PormGPostgres`/`PormGSQLite` (mocks / non-pool markers). This test is DB-free.
"""

using Test
using PormG

const CP = PormG.ConnectionPool

# Mocks like the SQL-inspection suites register in `config`: subtype the pool marker but
# carry none of a real pool's fields.
struct _MockPGNoPool <: PormG.PormGPostgres end
struct _MockSQLiteNoPool <: PormG.PormGSQLite end

@testset "close_pool! skips non-pool mocks; still closes real pools (#147)" begin
  # 1. Non-pool mocks must be skipped (no field access, no throw).
  @test CP.close_pool!(_MockPGNoPool()) === nothing
  @test CP.close_pool!(_MockSQLiteNoPool()) === nothing

  # 2. The Configuration-level wrapper (what __cleanup__ calls) must also tolerate them.
  @test PormG.Configuration.close_pool!(_MockPGNoPool()) === nothing
  @test PormG.Configuration.close_pool!(_MockSQLiteNoPool()) === nothing

  # 3. Real pools are still closed by the concrete-typed methods. A freshly-constructed
  #    pool holds no live handles (all slots `nothing`), so this needs no live database.
  pg = CP.PostgresConnectionPool("dummy-connection-string"; pool_size = 2)
  @test CP.close_pool!(pg) === nothing
  @test all(pg.available)                       # slots reset to available
  @test all(c -> c === nothing, pg.connections) # no live handles left

  sl = CP.SQLiteConnectionPool(":memory:"; pool_size = 2)
  @test CP.close_pool!(sl) === nothing
  @test all(sl.available)
  @test all(c -> c === nothing, sl.connections)
end
