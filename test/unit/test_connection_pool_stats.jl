using Test
using PormG
const CP = PormG.ConnectionPool   # match the sibling pool tests' idiom

# ─────────────────────────────────────────────────────────────────────────────
# Public pool_stats snapshot (#127).
#
# DB-free: a file-local mock pool with hand-set `available`/`connections` vectors exercises the count
# expressions directly (no real connections needed). `waiting` reads the #124 `_POOL_WAITERS` registry,
# so we push PoolWaiters straight into it. Verifies the derived identity size == in_use + available and
# that only non-done waiters are counted.
# ─────────────────────────────────────────────────────────────────────────────

mutable struct MockStatsPool <: PormG.PormGPostgres
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
end

@testset "pool_stats reports accurate counts" begin
  # base 3, grown to 4 slots: slot1 leased(open), slot2 free(open idle), slot3 free(nothing),
  # slot4 leased(open) — an overflow slot.
  p = MockStatsPool(Any["c1", "c2", nothing, "c4"], Bool[false, true, true, false], "mock://pg", 3, ReentrantLock())

  s = PormG.pool_stats(p)
  @test s.pool_size == 3
  @test s.size == 4                         # slots allocated so far
  @test s.in_use == 2                       # slots 1 and 4 leased
  @test s.available == 2                    # slots 2 and 3 free
  @test s.size == s.in_use + s.available    # derived identity
  @test s.ceiling == 3 * CP.POOL_EXPANSION_FACTOR
  @test s.waiting == 0                      # no waiters registered

  # waiting counts only non-done #124 waiters parked for this pool.
  w_live = CP.PoolWaiter(:any)
  w_done = CP.PoolWaiter(:any); w_done.done = true
  CP._POOL_WAITERS[p] = [w_live, w_done]
  try
    @test PormG.pool_stats(p).waiting == 1   # only the live waiter
  finally
    delete!(CP._POOL_WAITERS, p)
  end
end

@testset "pool_stats on a fresh, fully-available pool" begin
  p = MockStatsPool(Any[nothing, nothing], Bool[true, true], "mock://pg", 2, ReentrantLock())
  s = PormG.pool_stats(p)
  @test (s.pool_size, s.size, s.in_use, s.available, s.ceiling, s.waiting) == (2, 2, 0, 2, 20, 0)
end
