# ============================================================
# test/unit/test_connection_pool_timeout.jl
#
# Connection-pool exhaustion → typed PoolTimeoutError (#37).
#
# CONTRACT being tested:
#   When a pool is saturated at its ceiling (pool_size * POOL_EXPANSION_FACTOR) and no connection
#   frees up within the retry/timeout budget, `acquire_connection` throws a typed, catchable
#   `PoolTimeoutError` (NOT a bare String) carrying pool_size / max_size / attempts / elapsed and a
#   "raise pool_size" remedy.
#
# Deterministic and DB-free: a local temp-FILE SQLite pool (not :memory: — that has shared-cache
# semantics that could short-circuit the acquire/expand path) with pool_size=1 has a ceiling of
# 1 * POOL_EXPANSION_FACTOR = 10; acquiring all 10 and requesting an 11th on a short budget exhausts
# it. This is ALSO the proof of PG/SQLite symmetry — the SQLite acquire twin must reach the same
# typed throw. Reverting the throw to a String (or dropping the type) fails the `isa PoolTimeoutError`
# assertion — the mutation gate.
# ============================================================

using Test
using PormG

# SQLite is a weakdep since #34 — load the driver extension so `backend_connect` works when this file
# runs standalone (runtests.jl loads it too; re-loading is idempotent). See test/load_drivers.jl.
include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const CP = PormG.ConnectionPool

@testset "Pool exhaustion throws typed PoolTimeoutError (#37)" begin
  # The ceiling this test depends on: pool_size(1) * POOL_EXPANSION_FACTOR(10) = 10.
  @test CP.POOL_EXPANSION_FACTOR == 10

  tmp = tempname() * ".sqlite"
  # pool_size=1, split_read_write=false → a simple shared pool that expands to the ceiling on demand.
  pool = CP.SQLiteConnectionPool(tmp; pool_size = 1, split_read_write = false)

  held = Any[]
  try
    # Fill the pool to its ceiling (10) and hold every connection — none are released.
    for _ in 1:(1 * CP.POOL_EXPANSION_FACTOR)
      push!(held, CP.acquire_connection(pool))
    end
    @test length(held) == 10

    # The 11th acquire cannot succeed → genuine starvation. Capture the thrown value (cause-check,
    # not a bare `@test_throws`) so we can assert its TYPE, its FIELDS, and its message text.
    err = try
      CP.acquire_connection(pool; timeout_seconds = 1, max_retries = 3)
      nothing
    catch e
      e
    end

    @test err isa PormG.PoolTimeoutError            # a real, catchable Exception — not a String
    @test err.adapter == "SQLite"
    @test err.pool_size == 1
    @test err.max_size == 10                        # pool_size * POOL_EXPANSION_FACTOR
    @test err.attempts >= 1
    @test err.elapsed_seconds >= 0.0
    @test occursin(r"raise pool_size"i, sprint(showerror, err))   # remediation text really present
  finally
    for c in held
      try; CP.release_connection(pool, c); catch; end
    end
    try; CP.close_pool!(pool); catch; end
    isfile(tmp) && rm(tmp; force = true)
  end
end
