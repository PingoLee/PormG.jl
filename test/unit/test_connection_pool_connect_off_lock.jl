using Test
using PormG
const CP = PormG.ConnectionPool

# ─────────────────────────────────────────────────────────────────────────────
# A connect runs OFF `pool.lock` (#1540)
#
# DB-free: mock pools whose `backend_connect` sleeps. `acquire_connection` used to call
# `backend_connect` inside `Base.lock(pool.lock)`, in all three places it opens a connection (a
# handed-off slot, an empty or dead slot, an expansion). For the whole connect, every other
# operation on the pool waited behind it: a `release_connection` could not give a finished
# connection back, an acquirer that would have found a live idle handle could not look, and
# `timeout_seconds` did not bound that wait, because the deadline is read after the lock is taken.
# Against a host that drops packets that is the OS connect timeout, about two minutes on Linux.
#
# Now the slot is RESERVED under the lock (leased, empty), the connect runs without it, and the lock
# is taken again to install the handle. A leased empty slot is a state the pool already had (a
# discard-origin #124 handoff being materialized), so the sweep, the reaper and identity-matched
# release/discard already leave it alone; the sweep testset below pins that.
#
# Every task here is a sticky `@async` task on one thread, so the mock's `sleep` is the yield point
# that lets the main task run while a connect is in flight. Gate: on the unpatched code each timed
# assertion waits out the whole connect (2 s), against a bound of 0.5 s.
# ─────────────────────────────────────────────────────────────────────────────

mutable struct FakeSlowConn1540
  id::Int
  closed::Bool
end
FakeSlowConn1540(id::Int) = FakeSlowConn1540(id, false)
Base.close(c::FakeSlowConn1540) = (c.closed = true; nothing)

mutable struct MockPGSlow1540 <: PormG.PormGPostgres
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
  nid::Int
  delay::Float64            # seconds each connect takes (0 = instant)
  connecting::Int           # connects in flight right now
  peak::Int                 # the most connects ever in flight at once
  fail_next::Int            # connects still to refuse, after their delay
end
MockPGSlow1540(n::Int) = MockPGSlow1540(Any[nothing for _ in 1:n], fill(true, n), "mock://pg", n, ReentrantLock(), 0, 0.0, 0, 0, 0)

mutable struct MockSQLiteSlow1540 <: PormG.PormGSQLite
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  split_read_write::Bool
  writer_slot::Int
  reader_cursor::Int
  lock::ReentrantLock
  write_lock::ReentrantLock
  nid::Int
  delay::Float64
  connecting::Int
  peak::Int
  read_only_seen::Vector{Bool}   # the `read_only` each connect was asked for, in order
  fail_next::Int
end
MockSQLiteSlow1540(n::Int; split::Bool = false) =
  MockSQLiteSlow1540(Any[nothing for _ in 1:n], fill(true, n), "mock://sqlite", n, split && n > 1, 1, 0,
                     ReentrantLock(), ReentrantLock(), 0, 0.0, 0, 0, Bool[], 0)

const _Slow1540 = Union{MockPGSlow1540, MockSQLiteSlow1540}

function _slow_connect_1540(p::_Slow1540)
  p.connecting += 1
  p.peak = max(p.peak, p.connecting)
  try
    p.delay > 0 && sleep(p.delay)
  finally
    p.connecting -= 1
  end
  if p.fail_next > 0
    p.fail_next -= 1
    error("mock: connection refused")                 # a restart, as the client sees it
  end
  return FakeSlowConn1540(p.nid += 1)
end
PormG.backend_connect(p::MockPGSlow1540; kwargs...) = _slow_connect_1540(p)
function PormG.backend_connect(p::MockSQLiteSlow1540; read_only::Bool = false)
  push!(p.read_only_seen, read_only)
  return _slow_connect_1540(p)
end
PormG.backend_is_alive(::_Slow1540, c) = c isa FakeSlowConn1540 && !c.closed
PormG.backend_is_permanent_connect_error(::_Slow1540, e) = false   # ambiguous: retried, never fast-failed

function _wait_until_1540(pred; timeout = 5.0, step = 0.005)
  t0 = time()
  while time() - t0 < timeout
    pred() && return true
    sleep(step)
  end
  return pred()
end

_mocks_1540() = (("PG", () -> MockPGSlow1540(2)), ("SQLite", () -> MockSQLiteSlow1540(2)))

@testset "a release during another caller's connect returns at once (#1540)" begin
  for (label, mk) in _mocks_1540()
    @testset "$label" begin
      p = mk()
      c1 = CP.acquire_connection(p; timeout_seconds = 5)   # slot 1, instant connect
      p.delay = 2.0
      A = @async CP.acquire_connection(p; timeout_seconds = 10)   # slot 2: a 2 s connect
      started = _wait_until_1540(() -> p.connecting == 1)
      # Time first, assert after: a failing `@test` prints, and the first failure report compiles
      # for long enough to hide the wait it is meant to measure.
      reserved = p.available[2] === false && p.connections[2] === nothing
      t0 = time()
      released = CP.release_connection(p, c1)
      release_s = time() - t0
      # The released handle is idle in slot 1: a short-deadline acquirer takes it without waiting.
      t0 = time()
      got = CP.acquire_connection(p; timeout_seconds = 0.2)
      acquire_s = time() - t0

      @test started
      @test reserved                                       # reserved: leased, empty
      @test released === true
      @test release_s < 0.5                                # ← unpatched: ~2 s, behind the connect
      @test acquire_s < 0.5
      @test got === c1

      a = fetch(A)
      @test a isa FakeSlowConn1540 && p.connections[2] === a   # installed into ITS reserved slot
      CP.release_connection(p, got); CP.release_connection(p, a)
      @test count(!, p.available) == 0
    end
  end
end

@testset "at the ceiling, a short-deadline acquirer raises at its deadline, not after the connect (#1540)" begin
  for (label, mk) in (("PG", () -> MockPGSlow1540(1)), ("SQLite", () -> MockSQLiteSlow1540(1)))
    @testset "$label" begin
      p = mk()
      ceiling = p.pool_size * CP.POOL_EXPANSION_FACTOR
      held = [CP.acquire_connection(p; timeout_seconds = 5) for _ in 1:(ceiling - 1)]
      p.delay = 2.0
      A = @async CP.acquire_connection(p; timeout_seconds = 10)   # reserves the last slot
      started = _wait_until_1540(() -> p.connecting == 1)
      t0 = time()                                          # time first, assert after (see above)
      err = try
        CP.acquire_connection(p; timeout_seconds = 0.2)
        nothing
      catch e
        e
      end
      elapsed = time() - t0
      @test started
      @test length(p.connections) == ceiling
      @test err isa PormG.PoolTimeoutError
      @test 0.15 <= elapsed < 1.0                          # ← unpatched: ~2 s, the connect's length

      a = fetch(A)
      push!(held, a)
      for c in held; CP.release_connection(p, c); end
      @test count(!, p.available) == 0
    end
  end
end

@testset "concurrent connects run side by side, and the expansion ceiling still holds (#1540)" begin
  # Reserving an expansion slot is still an append under the lock, so `length(connections)` never
  # passes the ceiling (#37), however many callers connect at once. And they do connect at once now:
  # ten 0.3 s connects take ~0.3 s together, against ~3 s one after another.
  for (label, mk) in (("PG", () -> MockPGSlow1540(1)), ("SQLite", () -> MockSQLiteSlow1540(1)))
    @testset "$label" begin
      p = mk()
      ceiling = p.pool_size * CP.POOL_EXPANSION_FACTOR
      p.delay = 0.3
      t0 = time()
      tasks = [@async CP.acquire_connection(p; timeout_seconds = 10) for _ in 1:ceiling]
      conns = fetch.(tasks)
      elapsed = time() - t0
      @test length(unique(objectid, conns)) == ceiling     # each caller its own handle
      @test length(p.connections) == ceiling
      @test p.peak > 1                                     # ← unpatched: 1, every connect behind the lock
      @test elapsed < 2.0                                  # ← unpatched: ~3 s

      err = try; CP.acquire_connection(p; timeout_seconds = 0.2); nothing; catch e; e; end
      @test err isa PormG.PoolTimeoutError
      @test length(p.connections) == ceiling               # the ceiling held
      for c in conns; CP.release_connection(p, c); end
      @test count(!, p.available) == 0
    end
  end
end

@testset "an interrupt during the connect frees the reserved slot and reaches the caller (#1540)" begin
  # Before #1540 the connect's `catch` took a Ctrl-C for a failed connect and retried it, so the
  # interrupt never reached the caller. Now it propagates, and #1535's `_drop_owned!` gives the
  # reserved slot back. `A` is parked in the mock's `sleep`, so interrupting it is safe.
  for (label, mk) in _mocks_1540()
    @testset "$label" begin
      p = mk()
      p.delay = 30.0
      A = @async CP.acquire_connection(p; timeout_seconds = 60)
      @test _wait_until_1540(() -> p.connecting == 1)
      @test PormG.pool_stats(p).in_use == 1                # the reservation counts as leased

      schedule(A, InterruptException(); error = true)
      @test _wait_until_1540(() -> istaskdone(A))
      @test A.exception isa InterruptException             # ← unpatched: retried, A keeps connecting
      @test PormG.pool_stats(p).in_use == 0
      @test all(p.available) && all(c -> c === nothing, p.connections)

      p.delay = 0.0
      c = CP.acquire_connection(p; timeout_seconds = 5)    # the pool is whole
      CP.release_connection(p, c)
    end
  end
end

@testset "a sweep during the connect leaves the reserved slot to its connector (#1540)" begin
  # `_close_pool_slots!` (#47) takes every handle out, but a leased slot with no handle is left
  # leased: its connector is about to install a handle and lease it to its caller. Flipping it
  # available would let a second acquirer lease that same handle.
  for (label, mk) in _mocks_1540()
    @testset "$label" begin
      p = mk()
      p.delay = 0.5
      A = @async CP.acquire_connection(p; timeout_seconds = 10)
      @test _wait_until_1540(() -> p.connecting == 1)
      i = findfirst(!, p.available)
      @test_logs (:warn, r"checked out") CP._close_pool_slots!(p; drain_seconds = 0)
      @test p.available[i] === false && p.connections[i] === nothing

      a = fetch(A)
      @test p.connections[i] === a && p.available[i] === false
      CP.release_connection(p, a)
      @test p.available[i] === true
    end
  end
end

@testset "a split SQLite pool still opens a reader slot read-only off the lock (#1540)" begin
  p = MockSQLiteSlow1540(2; split = true)                # slot 1 = writer, slot 2 = reader
  w = CP.acquire_connection(p; mode = :write, timeout_seconds = 5)
  r = CP.acquire_connection(p; mode = :read, timeout_seconds = 5)
  @test p.read_only_seen == [false, true]
  @test p.connections[1] === w && p.connections[2] === r
  CP.release_connection(p, w); CP.release_connection(p, r)
end

@testset "a slot freed by a failed connect goes to a caller waiting on a full pool (#1540)" begin
  # A connect into a reserved slot fails. The slot goes back through `_handoff_or_free!(…;
  # skip_retry = true)`: never to a caller that parked after its own failed connect (it paces its own
  # retries), but at once to one that parked because every slot was leased. That caller's timer runs
  # to its deadline and no release may come, so freeing the slot as merely available would strand it
  # there. Here the pool is at its ceiling with the last slot reserved by a failing 0.5 s connect, and
  # B parks behind it with a 5 s deadline. Gate: with every waiter skipped, B times out at 5 s.
  for (label, mk) in (("PG", () -> MockPGSlow1540(1)), ("SQLite", () -> MockSQLiteSlow1540(1)))
    @testset "$label" begin
      p = mk()
      ceiling = p.pool_size * CP.POOL_EXPANSION_FACTOR
      held = [CP.acquire_connection(p; timeout_seconds = 5) for _ in 1:(ceiling - 1)]
      p.delay = 0.5
      p.fail_next = 1
      A = @async(try; CP.acquire_connection(p; timeout_seconds = 3); catch e; e; end)   # reserves the last slot
      started = _wait_until_1540(() -> p.connecting == 1)
      t0 = time()
      B = @async CP.acquire_connection(p; timeout_seconds = 5)
      queued = _wait_until_1540(() -> length(CP._waiters_for(p)) == 1)
      w = queued ? CP._waiters_for(p)[1] : nothing
      p.delay = 0.0                                      # B's own connect, once handed the slot
      b = try; fetch(B); catch e; e; end
      b_s = time() - t0

      @test started && queued
      @test w !== nothing && w.retry === false             # B parked for saturation, not after a failure
      @test b isa FakeSlowConn1540                         # ← with every waiter skipped: PoolTimeoutError
      @test b_s < 2.0                                      # ← …at 5 s

      push!(held, b)
      for c in held; CP.release_connection(p, c); end     # the last release hands A a slot
      a = fetch(A)
      a isa FakeSlowConn1540 && CP.release_connection(p, a)
      @test PormG.pool_stats(p).in_use == 0 && PormG.pool_stats(p).waiting == 0
    end
  end
end
