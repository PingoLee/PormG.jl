using Test
using PormG
include(joinpath(@__DIR__, "..", "load_drivers.jl"))   # MySQL: `load` checks the driver extension
const CP = PormG.ConnectionPool

# ─────────────────────────────────────────────────────────────────────────────
# A MySQL slot idle past `validate_after_idle` is pinged before it is handed out (#1548)
#
# DB-free: mock MySQL pools whose `backend_ping` can fail, block or be interrupted. MySQL's checkout
# probe (`backend_is_alive`) is `isopen`, which answers `true` for a connection the server closed past
# its `wait_timeout`, so the first statement after a quiet period raised `OperationalError` and the pool
# renewed the slot only after it. Now a checkout pings a slot whose `PoolMonitorState.last_used` is older
# than the threshold, off `pool.lock` (#1540), and a failed ping renews the slot BEFORE the caller has
# it: no statement was sent, so nothing is a statement failure and no other slot is swept.
#
# Every task here is a sticky `@async` task on one thread, so the mock ping's `sleep` is the yield point
# that lets the main task run while a ping is in flight.
# ─────────────────────────────────────────────────────────────────────────────

mutable struct FakeConn1548
  id::Int
  closed::Bool
  server_closed::Bool   # the server dropped it: `isopen` still says yes, a ping raises
end
FakeConn1548(id::Int) = FakeConn1548(id, false, false)
Base.close(c::FakeConn1548) = (c.closed = true; nothing)

mutable struct MockMySQL1548 <: PormG.PormGMySQL
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
  nid::Int
  connects::Int
  pings::Vector{Int}        # the id of each handle pinged, in order
  ping_delay::Float64
  ping_interrupt::Bool      # the next ping raises InterruptException (a Ctrl-C during the round trip)
  refuse_connects::Bool     # every connect fails, as against a server that is down
  ping_timeouts::Vector{Float64}   # the bound each ping was given (#1618)
  alive_delay::Float64      # each checkout probe takes this long, so a scan spends time before its ping (#1618)
end
function MockMySQL1548(n::Int)
  p = MockMySQL1548(Any[nothing for _ in 1:n], fill(true, n), "mock://mysql", n, ReentrantLock(),
                    0, 0, Int[], 0.0, false, false, Float64[], 0.0)
  for i in 1:n
    p.connections[i] = FakeConn1548(p.nid += 1)
  end
  return p
end

function PormG.backend_connect(p::MockMySQL1548; kwargs...)
  p.connects += 1
  p.refuse_connects && error("mock: Can't connect to MySQL server (2003)")
  return FakeConn1548(p.nid += 1)
end
function PormG.backend_is_alive(p::MockMySQL1548, c)   # local, like `isopen`
  p.alive_delay > 0 && sleep(p.alive_delay)
  return c isa FakeConn1548 && !c.closed
end
PormG.backend_is_permanent_connect_error(::MockMySQL1548, e) = false
function PormG.backend_ping(p::MockMySQL1548, c::FakeConn1548, timeout_seconds::Float64)::Nothing
  push!(p.pings, c.id)
  push!(p.ping_timeouts, timeout_seconds)
  p.ping_delay > 0 && sleep(p.ping_delay)
  if p.ping_interrupt
    p.ping_interrupt = false
    throw(InterruptException())
  end
  c.server_closed && error("mock: Lost connection to MySQL server (2013)")
  return nothing
end

# A pool of `n` warm slots with idle validation at `after` seconds, and slot clocks set `idle` seconds ago.
function _idle_pool_1548(n::Int; after::Real = 60, idle::Real = 0)
  p = MockMySQL1548(n)
  CP.enable_idle_validation!(p; after = after)
  st = CP._monitor_state(p)
  fill!(st.last_used, time() - idle)
  return p
end

# What: a slot returned to the pool less than `validate_after_idle` ago is handed out without a ping.
# SQL: none. Why: "a busy slot pays nothing" — the ping is a round trip per checkout otherwise.
@testset "#1548: a slot idle under the threshold is not pinged" begin
  p = _idle_pool_1548(1; after = 60, idle = 5)
  c = CP.acquire_connection(p; timeout_seconds = 1)
  @test c === p.connections[1]
  @test isempty(p.pings)
  CP.release_connection(p, c)
end

# What: a slot idle past the threshold is pinged once, and a live answer hands it out as it is, with its
# idle clock reset. SQL: none (COM_PING). Why: the ping is the only way MySQL's checkout sees the server.
@testset "#1548: a slot idle past the threshold is pinged, and kept when it answers" begin
  p = _idle_pool_1548(1; after = 60, idle = 120)
  original = p.connections[1]
  c = CP.acquire_connection(p; timeout_seconds = 1)
  @test c === original
  @test p.pings == [original.id]
  @test p.connects == 0
  @test time() - CP._monitor_state(p).last_used[1] < 5     # the lease reset the clock
  CP.release_connection(p, c)
  c2 = CP.acquire_connection(p; timeout_seconds = 1)       # just returned: no second ping
  @test c2 === original && length(p.pings) == 1
  CP.release_connection(p, c2)
end

# What: a slot whose server closed it fails the ping; the caller gets a NEW handle in the same slot, the
# old one is closed, and the other idle slot is left alone. SQL: none. Why: renewing before the send is
# what keeps the first statement after a quiet period from raising `OperationalError` — and since no
# statement ran, it is not a statement failure: no sweep retires the pool's other idle connections.
@testset "#1548: a failed ping renews the slot before the caller has it" begin
  p = _idle_pool_1548(2; after = 60, idle = 120)
  dead, other = p.connections[1], p.connections[2]
  dead.server_closed = true
  c = CP.acquire_connection(p; timeout_seconds = 1)
  @test c !== dead && c isa FakeConn1548 && !c.server_closed
  @test p.connections[1] === c && !p.available[1]
  @test dead.closed
  @test p.connects == 1
  @test p.pings == [dead.id]
  @test !other.closed && p.connections[2] === other && p.available[2]   # not swept
  CP.release_connection(p, c)
end

# What: while one checkout waits on a slow ping, another caller borrows a different slot and returns it.
# SQL: none. Why: a ping is a round trip; under `pool.lock` it would stall every acquire and release
# behind it, the #1540 defect for connects. Gate: under the lock the second acquire waits the whole 2 s.
@testset "#1548: the ping runs off the pool's lock" begin
  p = _idle_pool_1548(2; after = 60, idle = 0)
  CP._monitor_state(p).last_used[1] = time() - 120          # only slot 1 is idle past the threshold
  p.ping_delay = 2.0
  slow = @async CP.acquire_connection(p; timeout_seconds = 5)
  while isempty(p.pings)
    yield()
  end
  t0 = time()
  c2 = CP.acquire_connection(p; timeout_seconds = 5)
  @test time() - t0 < 0.5
  @test c2 === p.connections[2]
  CP.release_connection(p, c2)
  @test CP.pool_stats(p).in_use == 1                        # slot 1, being pinged, counts as in use
  c1 = fetch(slow)
  @test c1 === p.connections[1]
  CP.release_connection(p, c1)
end

# What: a Ctrl-C during the ping propagates, and the pinged handle is closed rather than returned; the
# slot is free and empty. SQL: none. Why: the interrupt may leave a half-read COM_PING reply on the
# connection, and handing that to the next caller would give it someone else's reply.
@testset "#1548: an interrupt during the ping retires the handle" begin
  p = _idle_pool_1548(1; after = 60, idle = 120)
  pinged = p.connections[1]
  p.ping_interrupt = true
  @test_throws InterruptException CP.acquire_connection(p; timeout_seconds = 1)
  @test pinged.closed
  @test p.connections[1] === nothing && p.available[1]
  c = CP.acquire_connection(p; timeout_seconds = 1)          # the slot connects afresh
  @test c isa FakeConn1548 && c !== pinged && p.connects == 1
  CP.release_connection(p, c)
end

# What: a slot handed to a parked caller (#124 handoff, branch A) is pinged too when it sat idle past the
# threshold. SQL: none. Why: both checkout branches reach the same live handle; one without the ping would
# hand a server-closed connection to exactly the caller that waited for it.
@testset "#1548: a handed-off slot idle past the threshold is pinged" begin
  p = _idle_pool_1548(1; after = 60, idle = 120)
  handed = p.connections[1]
  handed.server_closed = true
  p.available[1] = false
  owned = CP._OwnedSlot((1, handed))                         # what the handoff delivered
  c = CP._acquire_connection!(p, owned, 1.0, 300)
  @test p.pings == [handed.id]
  @test handed.closed && c !== handed && p.connections[1] === c
  @test owned[] === nothing
  CP.release_connection(p, c)
end

# What: a failed ping followed by a failed connect gives the slot back empty and raises the pool's
# connect error at the deadline. SQL: none. Why: the slot was reserved for the renewal, and a connect
# failure must not leave it leased to nobody (#1535). Before #1548 the same outage raised
# `OperationalError` from the statement; the upgrade entry records the difference.
@testset "#1548: a failed ping then a failed connect frees the slot and raises PoolConnectError" begin
  p = _idle_pool_1548(1; after = 60, idle = 120)
  dead = p.connections[1]
  dead.server_closed = true
  p.refuse_connects = true
  @test_throws PormG.PoolConnectError CP.acquire_connection(p; timeout_seconds = 0.5)
  @test dead.closed
  @test p.connections[1] === nothing && p.available[1]
  @test CP.pool_stats(p).in_use == 0
end

# What: `validate_after_idle` is 60 s on MySQL when connection.yml leaves it out, an explicit value wins,
# and 0 turns it off. SQL: none. Why: the default is the fix — an operator who never heard of the key
# still gets it — and a setting that cannot be turned off would cost a round trip nobody asked for.
@testset "#1548: validate_after_idle defaults to 60 on MySQL; explicit values win" begin
  for (line, expected) in (("", 60.0), ("  validate_after_idle: 5\n", 5.0), ("  validate_after_idle: 0\n", 0.0),
                           ("  validate_after_idle: 60s\n", 60.0))   # unreadable: the default, not off
    mktempdir() do root
      dir = joinpath(root, "db_my_unit")
      mkpath(dir)
      write(joinpath(dir, "connection.yml"),
            "test:\n  adapter: MySQL\n  host: 127.0.0.1\n  port: 3307\n  username: u\n  password: p\n" *
            "  database: f1\n" * line * "  config:\n    change_db: true\n    change_data: true\n")
      PormG.Configuration.load(dir; env = "test")
      try
        pool = PormG.config[dir].connections
        st = CP._monitor_state(pool)
        @test (st === nothing ? 0.0 : st.validate_after_idle) == expected
      finally
        PormG.Configuration.unregister_connection(dir)
      end
    end
  end
end

# What: on PostgreSQL and SQLite a threshold above 0 raises `BackendCapabilityError` naming the feature;
# 0 is accepted and changes nothing. SQL: none. Why: their checkout probe already asks the connection every
# time, so the setting would do nothing there — refused rather than silently ignored (#1129).
@testset "#1548: validate_after_idle above 0 is refused on PostgreSQL and SQLite" begin
  for pool in (CP.PostgresConnectionPool("host=localhost dbname=f1"), CP.SQLiteConnectionPool(":memory:"))
    err = try
      CP.enable_idle_validation!(pool; after = 30)
      nothing
    catch e
      e
    end
    @test err isa PormG.BackendCapabilityError
    @test occursin("validate_after_idle", PormG.error_message(err))
    @test CP._default_validate_after_idle(pool) == 0.0
    @test CP.enable_idle_validation!(pool; after = 0) === pool
    @test CP._monitor_state(pool) === nothing
  end
  mktempdir() do root
    dir = joinpath(root, "db_sl_unit")
    mkpath(dir)
    write(joinpath(dir, "connection.yml"),
          "test:\n  adapter: SQLite\n  database: '$(joinpath(root, "f1.sqlite"))'\n  validate_after_idle: 30\n" *
          "  config:\n    change_db: true\n    change_data: true\n")
    @test_throws PormG.BackendCapabilityError PormG.Configuration.load(dir; env = "test")
    # Refused before its pool stays installed: a second `load` (a REPL retry, an `__init__` after a
    # module-body load) raises again instead of finding a loaded configuration.
    @test !haskey(PormG.config, dir) || PormG.config[dir].connections === nothing
    @test_throws PormG.BackendCapabilityError PormG.Configuration.load(dir; env = "test")
    haskey(PormG.config, dir) && PormG.Configuration.unregister_connection(dir)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1618: the idle ping is bounded by what is left of the checkout's deadline
# On a network path that drops packets without a reset, an unbounded ping waits for the kernel's TCP
# retransmissions (minutes on Linux), and `acquire_connection(timeout_seconds = …)` waited with it. Core
# now hands the ping the checkout's remaining time (`_ping_timeout`, at least `_MIN_PING_TIMEOUT`); the
# MySQL extension applies it as MySQL.jl's own read deadline, which raises when it expires, and core
# renews the slot as for any failed ping. Reverted-fix signature: the hook is called without a bound
# (a `MethodError` on the 3-argument mock), or with the pool's whole timeout instead of what is left.
# ─────────────────────────────────────────────────────────────────────────────

# What: the bound a checkout hands the ping is what is left of its deadline. SQL: none (COM_PING).
# Why: the ping is the one step of a checkout that waits on the network after the deadline was set.
@testset "#1618: the idle ping is given the checkout's remaining time" begin
  p = _idle_pool_1548(1; after = 60, idle = 120)
  c = CP.acquire_connection(p; timeout_seconds = 7)
  @test length(p.ping_timeouts) == 1
  @test CP._MIN_PING_TIMEOUT <= p.ping_timeouts[1] <= 7.0
  CP.release_connection(p, c)

  # The pool's own `pool_timeout` when the call names none (#126). The mock pool carries no
  # `pool_timeout`, so `DEFAULT_POOL_TIMEOUT` applies.
  st = CP._monitor_state(p)
  fill!(st.last_used, time() - 120)
  c = CP.acquire_connection(p)
  @test length(p.ping_timeouts) == 2
  @test CP._MIN_PING_TIMEOUT <= p.ping_timeouts[2] <= CP.DEFAULT_POOL_TIMEOUT
  CP.release_connection(p, c)
end

# What: time the checkout spent before its ping is not given to the ping again: with a probe that takes
# 1.5 s, a 4 s checkout hands the ping what is left (about 2.5 s), not 4 s. SQL: none.
# Why: the bound is the checkout's deadline, not a fresh timeout per step; the whole timeout here would
# let the checkout overrun its `timeout_seconds` by the time already spent.
@testset "#1618: the time a checkout already spent is not given to the ping again" begin
  p = _idle_pool_1548(1; after = 60, idle = 120)
  p.alive_delay = 1.5
  c = CP.acquire_connection(p; timeout_seconds = 4)
  @test length(p.ping_timeouts) == 1
  @test CP._MIN_PING_TIMEOUT <= p.ping_timeouts[1] <= 3.0
  CP.release_connection(p, c)
end

# What: `_ping_timeout` is the time left before the deadline, with a floor once the deadline is near or
# past. SQL: none. Why: a ping cut off spuriously costs the slot a full reconnect, so the last moment of
# a long wait still gives the ping a second; the floor bounds how far past the deadline a checkout runs.
@testset "#1618: _ping_timeout is the remaining time, never under the floor" begin
  @test CP._ping_timeout(110.0, 100.0) == 10.0
  @test CP._ping_timeout(100.5, 100.0) == CP._MIN_PING_TIMEOUT
  @test CP._ping_timeout(90.0, 100.0) == CP._MIN_PING_TIMEOUT
  @test CP._MIN_PING_TIMEOUT == 1.0
end
