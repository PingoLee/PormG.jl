using Test
using PormG
using Logging
const CP = PormG.ConnectionPool   # match the sibling pool tests' idiom

# ─────────────────────────────────────────────────────────────────────────────
# Connection-leak detection (#127).
#
# DB-free: a file-local mock pool (own struct, no monitor fields → exercises the module-level
# PoolMonitorState registry). `_leak_check!` is driven DIRECTLY; the shared checkout timestamp in
# CP._POOL_MONITOR[pool].last_used is backdated to force a "held too long" without sleeping. Covers:
# warn once past threshold, silent on re-scan (leak_warned), reset + re-warn on a new lease, released
# slot never warned, below-threshold no warn, disabled = no-op.
# ─────────────────────────────────────────────────────────────────────────────

mutable struct FakeLeakConn
  id::Int
  closed::Bool
end
FakeLeakConn(id::Int) = FakeLeakConn(id, false)
Base.close(c::FakeLeakConn) = (c.closed = true; nothing)

mutable struct MockPGLeak <: PormG.PormGPostgres
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
  nid::Int
end
MockPGLeak(n::Int) = MockPGLeak(Any[nothing for _ in 1:n], fill(true, n), "mock://pg", n, ReentrantLock(), 0)
PormG.backend_connect(p::MockPGLeak; kwargs...) = FakeLeakConn(p.nid += 1)
PormG.backend_is_alive(::MockPGLeak, c) = c isa FakeLeakConn && !c.closed

# Lease one connection and return (conn, slot_index).
function _lease_one(p)
  c = CP.acquire_connection(p)
  return c, findfirst(!, p.available)
end

@testset "leak: warns once past threshold, silent on re-scan" begin
  p = MockPGLeak(2)
  CP.enable_leak_detection!(p; threshold = 1.0)
  c, i = _lease_one(p)
  st = CP._POOL_MONITOR[p]
  st.last_used[i] -= 100.0                       # held ~100s, well past the 1s threshold
  @test st.leak_warned[i] == false

  @test_logs (:warn, r"leak_detection_threshold") CP._leak_check!(p)
  @test st.leak_warned[i] == true                # marked, so it won't re-warn

  @test_logs min_level = Logging.Warn CP._leak_check!(p)   # second scan is silent

  CP.release_connection(p, c)
end

@testset "leak: a new lease resets the warn and can warn again" begin
  p = MockPGLeak(1)
  CP.enable_leak_detection!(p; threshold = 1.0)
  c, i = _lease_one(p)
  st = CP._POOL_MONITOR[p]
  st.last_used[i] -= 100.0
  @test_logs (:warn, r"held") CP._leak_check!(p)
  CP.release_connection(p, c)                    # touch resets leak_warned[i] = false

  c2, i2 = _lease_one(p)                          # re-lease the same slot
  @test st.leak_warned[i2] == false               # reset by checkout
  st.last_used[i2] -= 100.0
  @test_logs (:warn, r"held") CP._leak_check!(p)  # a genuinely new leak warns again
  CP.release_connection(p, c2)
end

@testset "leak: released (free) slot is never warned" begin
  p = MockPGLeak(2)
  CP.enable_leak_detection!(p; threshold = 1.0)
  c, i = _lease_one(p)
  CP.release_connection(p, c)                    # slot i now free (available[i] == true)
  st = CP._POOL_MONITOR[p]
  st.last_used[i] -= 100.0                        # even if its timestamp is ancient…
  @test_logs min_level = Logging.Warn CP._leak_check!(p)   # …a free slot can't leak → no warn
end

@testset "leak: below threshold does not warn" begin
  p = MockPGLeak(1)
  CP.enable_leak_detection!(p; threshold = 60.0)
  c, i = _lease_one(p)
  CP._POOL_MONITOR[p].last_used[i] -= 5.0        # held only 5s, under the 60s threshold
  @test_logs min_level = Logging.Warn CP._leak_check!(p)
  CP.release_connection(p, c)
end

@testset "leak: disabled pool is a no-op" begin
  p = MockPGLeak(1)                               # never opted in
  c, _ = _lease_one(p)
  @test CP._monitor_state(p) === nothing || CP._monitor_state(p).leak_threshold == 0.0
  @test_logs min_level = Logging.Warn CP._leak_check!(p)   # no state / threshold 0 → no warn, no error
  CP.release_connection(p, c)
end

@testset "leak: warn redacts the connection string (never log secrets)" begin
  p = MockPGLeak(1)
  p.connection_string = "host=localhost user=bob password=hunter2"   # secret-bearing
  CP.enable_leak_detection!(p; threshold = 1.0)
  c, i = _lease_one(p)
  CP._POOL_MONITOR[p].last_used[i] -= 100.0
  logs, _ = Test.collect_test_logs(min_level = Logging.Warn) do
    CP._leak_check!(p)
  end
  @test length(logs) == 1
  cs = String(Dict(logs[1].kwargs)[:connection_string])
  @test occursin("user=****", cs) && occursin("password=****", cs)   # redacted…
  @test !occursin("bob", cs) && !occursin("hunter2", cs)             # …and the secrets are gone
  CP.release_connection(p, c)
end

@testset "leak→reap merge keeps per-slot clocks (#127 unified monitor state)" begin
  # enable_leak_detection! creates the state; a LATER enable_reaping! must merge config into the
  # SAME state without resetting created_at/last_used — the clocks measure true open/last-use
  # instants (documented in enable_reaping!'s docstring), not time-since-enable.
  p = MockPGLeak(1)
  CP.enable_leak_detection!(p; threshold = 5.0)
  st = CP._POOL_MONITOR[p]
  st.created_at[1] -= 100.0; st.last_used[1] -= 100.0    # age the slot before reaping opts in
  before = (st.created_at[1], st.last_used[1])
  CP.enable_reaping!(p; idle_timeout = 10.0, max_lifetime = 50.0)
  @test CP._POOL_MONITOR[p] === st                        # merged, not overwritten
  @test st.config.idle_timeout == 10.0 && st.config.max_lifetime == 50.0
  @test st.leak_threshold == 5.0                          # leak config preserved
  @test (st.created_at[1], st.last_used[1]) == before     # clocks NOT reset by the re-config
end
