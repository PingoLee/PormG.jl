using Test
using PormG
const CP = PormG.ConnectionPool   # match the sibling pool tests' idiom (avoids a redefinition clash)

# ─────────────────────────────────────────────────────────────────────────────
# Direct-handoff connection-pool wait (#124)
#
# DB-free: mock pools (own struct, no `waiters` field → exercises the module-level registry).
# Covers: the handoff/mode helpers (deterministic), instant wake on release, FIFO/no-barging,
# timeout still throws PoolTimeoutError, the timeout↔handoff race, empty-slot materialize (from
# _discard_connection!), SQLite mode-typed handoff (split read/write), and the sweep race a
# handoff carrying only a slot index left open (#584).
# ─────────────────────────────────────────────────────────────────────────────

mutable struct FakeHandoffConn
  id::Int
  closed::Bool
end
FakeHandoffConn(id::Int) = FakeHandoffConn(id, false)
Base.close(c::FakeHandoffConn) = (c.closed = true; nothing)

# PG-shaped mock: PostgresConnectionPool's exact fields + an id counter. No `waiters` field.
mutable struct MockPGHandoff <: PormG.PormGPostgres
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
  nid::Int
end
MockPGHandoff(n::Int) = MockPGHandoff(Any[nothing for _ in 1:n], fill(true, n), "mock://pg", n, ReentrantLock(), 0)
PormG.backend_connect(p::MockPGHandoff; kwargs...) = FakeHandoffConn(p.nid += 1)
PormG.backend_is_alive(::MockPGHandoff, c) = c isa FakeHandoffConn && !c.closed

# SQLite-shaped mock: SQLiteConnectionPool's exact fields (incl. split read/write layout).
mutable struct MockSQLiteHandoff <: PormG.PormGSQLite
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
end
function MockSQLiteHandoff(n::Int; split::Bool = false)
  MockSQLiteHandoff(Any[nothing for _ in 1:n], fill(true, n), "mock://sqlite", n,
                    split && n > 1, 1, 0, ReentrantLock(), ReentrantLock(), 0)
end
PormG.backend_connect(p::MockSQLiteHandoff; kwargs...) = FakeHandoffConn(p.nid += 1)
PormG.backend_is_alive(::MockSQLiteHandoff, c) = c isa FakeHandoffConn && !c.closed

# Busy-wait until `pred()` or a deadline; returns whether it became true.
function _wait_until(pred; timeout = 3.0, step = 0.005)
  t0 = time()
  while time() - t0 < timeout
    pred() && return true
    sleep(step)
  end
  return pred()
end

# Saturate the pool to its ceiling (pool_size * 10) and return the held connections.
_saturate(p) = [CP.acquire_connection(p; timeout_seconds = 5) for _ in 1:(p.pool_size * CP.POOL_EXPANSION_FACTOR)]

@testset "handoff/mode helpers (deterministic)" begin
  # _slot_fits_mode: PG homogeneous; SQLite split typed.
  pg = MockPGHandoff(1)
  @test CP._slot_fits_mode(pg, 1, :any)
  sl = MockSQLiteHandoff(3; split = true)   # writer_slot = 1
  @test CP._slot_fits_mode(sl, 1, :any)              # :any → any slot
  @test CP._slot_fits_mode(sl, 1, :write)            # writer slot fits :write
  @test !CP._slot_fits_mode(sl, 2, :write)           # reader slot does NOT fit :write
  @test CP._slot_fits_mode(sl, 2, :read)             # reader slot fits :read
  @test CP._slot_fits_mode(sl, 1, :read)             # writer slot is the :read fallback
  sl_plain = MockSQLiteHandoff(3; split = false)
  @test CP._slot_fits_mode(sl_plain, 2, :write)      # non-split → every slot fits every mode

  # _handoff_or_free!: with a parked waiter, the slot is handed off (stays leased); without, freed.
  p = MockPGHandoff(1)
  c = CP.acquire_connection(p)                        # lease slot 1
  @test p.available == [false]
  w = CP.PoolWaiter(:any)
  push!(CP._waiters_for(p), w)
  Base.lock(() -> CP._handoff_or_free!(p, 1), p.lock) # simulate a release handing slot 1 to w
  @test take!(w.chan) == (1, c)                       # waiter received the slot AND its handle (#584)
  @test w.done
  @test p.available == [false]                        # slot stays LEASED for the waiter (no free)
  @test isempty(CP._waiters_for(p))                   # waiter dequeued

  # No waiter → slot returns to available.
  Base.lock(() -> CP._handoff_or_free!(p, 1), p.lock)
  @test p.available == [true]
end

@testset "instant handoff on release (no 100ms poll)" begin
  p = MockPGHandoff(1)
  # Warm up the handoff path (JIT) with one full park→release cycle.
  held = _saturate(p)
  warm = Threads.@spawn CP.acquire_connection(p; timeout_seconds = 5)
  @test _wait_until(() -> length(CP._waiters_for(p)) == 1)
  CP.release_connection(p, held[1]); held[1] = fetch(warm)

  # Park an acquirer, release, and assert the handoff MECHANICALLY rather than by clock (#382).
  #
  # `_handoff_or_free!` runs synchronously inside `release_connection`, under `pool.lock`. So by the
  # time that call returns, the waiter has already been marked `done` and removed from the FIFO — a
  # busy-poll implementation could only have flipped `available[i] = true` and left both untouched.
  # That is the claim this testset exists to make, and it is now stable state rather than a race
  # against the scheduler: the old `elapsed_ms < 90` measured a task spawn, a channel `take!` and a
  # `fetch`, on a unit suite that runs SINGLE-THREADED (no JULIA_NUM_THREADS in CI.yml) where
  # `fetch(parked)` is the first point the parked green task can run at all. A GC pause or a loaded
  # shared runner pushed it over a bound that had only 1.1× of margin.
  #
  # Do NOT assert `isready(w.chan)`: the parked task may already have taken the slot.
  parked = Threads.@spawn CP.acquire_connection(p; timeout_seconds = 5)
  @test _wait_until(() -> length(CP._waiters_for(p)) == 1)
  w = CP._waiters_for(p)[1]              # capture the waiter BEFORE the release consumes it
  t0 = time()
  CP.release_connection(p, held[2])
  @test w.done                           # handed a slot under pool.lock — not timed out, not polled
  @test isempty(CP._waiters_for(p))      # …and dequeued synchronously by that same release
  got = fetch(parked)
  elapsed_ms = (time() - t0) * 1000
  @test got isa FakeHandoffConn
  # Loose sanity bound only — the two assertions above are the real gate.
  #
  # Measured warm handoff, 12 samples on the dev machine: 0.012-0.112 ms, median 0.021 ms. That
  # needs `time_ns()`; plain `time()` returns a flat 0.0 here because the cost is below its
  # resolution — which is the whole problem with the old bound. 90 ms was ~4000x the real figure,
  # so it never discriminated a direct handoff from a poll; it only asserted that the machine had
  # not stalled. The bound below keeps the "did it hang?" signal with the ~20x margin used in
  # test_connection_pool_timeout.jl:103, and is not sensitive to load.
  @test elapsed_ms < 5000

  # Clean up + no leak.
  held[2] = got
  for c in held; CP.release_connection(p, c); end
  @test count(!, p.available) == 0
end

@testset "FIFO — longest waiter served first, no barging" begin
  p = MockPGHandoff(1)
  held = _saturate(p)

  a = Threads.@spawn CP.acquire_connection(p; timeout_seconds = 5)
  @test _wait_until(() -> length(CP._waiters_for(p)) == 1)   # A parked first
  b = Threads.@spawn CP.acquire_connection(p; timeout_seconds = 5)
  @test _wait_until(() -> length(CP._waiters_for(p)) == 2)   # B parked second

  # Release ONE slot → the oldest waiter (A) must be the one served.
  CP.release_connection(p, held[1])
  @test _wait_until(() -> istaskdone(a))
  @test !istaskdone(b)                                        # B still parked (only one slot freed)
  @test length(CP._waiters_for(p)) == 1                       # exactly B remains
  ca = fetch(a)
  @test ca isa FakeHandoffConn

  # Release another → B served.
  CP.release_connection(p, held[2])
  @test _wait_until(() -> istaskdone(b))
  cb = fetch(b)
  @test cb isa FakeHandoffConn

  held[1] = ca; held[2] = cb
  for c in held; CP.release_connection(p, c); end
  @test count(!, p.available) == 0
end

@testset "timeout still throws PoolTimeoutError" begin
  p = MockPGHandoff(1)                    # ceiling 10
  held = _saturate(p)
  err = try
    CP.acquire_connection(p; timeout_seconds = 1, max_retries = 3)
    nothing
  catch e
    e
  end
  @test err isa PormG.PoolTimeoutError
  @test err.adapter == "PostgreSQL"
  @test err.pool_size == 1
  @test err.max_size == 10
  @test err.attempts >= 1
  @test err.elapsed_seconds >= 0.0
  @test occursin(r"raise pool_size"i, sprint(showerror, err))
  for c in held; CP.release_connection(p, c); end
end

@testset "timeout↔handoff race — exactly one delivery, consistent state" begin
  # The `w.done` compare-and-set under pool.lock serializes the two producers (a release-handoff
  # and the timeout Timer), so exactly one ever delivers to the waiter's cap-1 channel. Drive the
  # primitives directly (the acquire timeout is whole-seconds, too coarse for a 20ms race).

  # (a) handoff first → the slot is delivered; a later timeout is a no-op.
  p = MockPGHandoff(1)
  c = CP.acquire_connection(p)                               # lease slot 1
  w = CP.PoolWaiter(:any); push!(CP._waiters_for(p), w)
  Base.lock(() -> CP._handoff_or_free!(p, 1), p.lock)
  CP._pool_wait_timeout!(p, w)                               # w already done → must no-op
  @test isready(w.chan) && take!(w.chan) == (1, c)           # the (slot, handle) pair, not the timeout
  @test !isready(w.chan)                                     # exactly one item ever
  @test w.done && isempty(CP._waiters_for(p))
  @test p.available == [false]                               # slot stays leased for the handed waiter

  # (b) timeout first → the sentinel is delivered; a later handoff just frees the slot.
  p2 = MockPGHandoff(1)
  CP.acquire_connection(p2)
  w2 = CP.PoolWaiter(:any); push!(CP._waiters_for(p2), w2)
  CP._pool_wait_timeout!(p2, w2)
  Base.lock(() -> CP._handoff_or_free!(p2, 1), p2.lock)      # no waiter left → frees slot
  @test isready(w2.chan) && take!(w2.chan) == CP._POOL_WAIT_TIMEOUT
  @test !isready(w2.chan)
  @test w2.done && isempty(CP._waiters_for(p2))
  @test p2.available == [true]

  # (c) concurrent stress: race the two producers on real threads; exactly one delivery each time.
  for _ in 1:200
    p3 = MockPGHandoff(1)
    CP.acquire_connection(p3)                                # lease slot 1
    w3 = CP.PoolWaiter(:any); push!(CP._waiters_for(p3), w3)
    t1 = Threads.@spawn Base.lock(() -> CP._handoff_or_free!(p3, 1), p3.lock)
    t2 = Threads.@spawn CP._pool_wait_timeout!(p3, w3)
    wait(t1); wait(t2)
    item = take!(w3.chan)                                    # exactly one item present (else this hangs)
    handed = item isa Tuple && item[1] == 1                  # a (slot, handle) pair (#584) …
    @test handed || item == CP._POOL_WAIT_TIMEOUT            # … or the timeout sentinel
    @test !isready(w3.chan)                                  # never a second (no double delivery/lease)
    @test w3.done && isempty(CP._waiters_for(p3))
    @test handed ? (p3.available == [false]) : (p3.available == [true])   # state matches the winner
  end
end

@testset "empty-slot handoff materializes a fresh connection (_discard_connection!)" begin
  p = MockPGHandoff(1)
  held = _saturate(p)
  parked = Threads.@spawn CP.acquire_connection(p; timeout_seconds = 5)
  @test _wait_until(() -> length(CP._waiters_for(p)) == 1)

  # Discard a held conn: frees a `nothing` slot and hands it to the waiter, which must materialize.
  victim = held[1]
  CP._discard_connection!(p, victim)
  got = fetch(parked)
  @test got isa FakeHandoffConn
  @test !(got === victim)          # a NEW connection was created for the handed-off empty slot
  @test victim.closed              # the discarded conn was closed

  held[1] = got
  for c in held; CP.release_connection(p, c); end
  @test count(!, p.available) == 0
end

@testset "SQLite mode-typed handoff (split read/write)" begin
  # pool_size 2, split → slot 1 = writer, slot 2 = reader. Both slots leased.
  p = MockSQLiteHandoff(2; split = true)
  wconn = CP.acquire_connection(p; mode = :write)     # slot 1 (writer)
  rconn = CP.acquire_connection(p; mode = :read)      # slot 2 (reader)
  @test count(!, p.available) == 2

  # Park a :write waiter. It can ONLY use the writer slot.
  wwaiter = Threads.@spawn CP.acquire_connection(p; mode = :write, timeout_seconds = 5)
  @test _wait_until(() -> length(CP._waiters_for(p)) == 1)

  # Releasing the READER slot must NOT wake the :write waiter — the slot goes back to available.
  # Read the waiter's own state instead of napping and hoping (#382): `_handoff_or_free!` decides
  # under pool.lock inside `release_connection`, so `!w.done` right after it returns is exactly the
  # "was not woken" claim — deterministic, and it does not cost 100ms.
  wwaiter_w = CP._waiters_for(p)[1]
  CP.release_connection(p, rconn)
  @test !wwaiter_w.done                               # mode-incompatible slot → no handoff
  @test p.available[2] == true                        # reader slot freed, not handed to the writer
  @test length(CP._waiters_for(p)) == 1

  # Releasing the WRITER slot wakes the :write waiter.
  CP.release_connection(p, wconn)
  @test _wait_until(() -> istaskdone(wwaiter))
  got_w = fetch(wwaiter)
  @test got_w isa FakeHandoffConn
  CP.release_connection(p, got_w)

  # A :read waiter accepts the writer slot as fallback.
  wconn2 = CP.acquire_connection(p; mode = :write)    # re-lease writer (slot 1)
  rconn2 = CP.acquire_connection(p; mode = :read)     # re-lease reader (slot 2)
  rwaiter = Threads.@spawn CP.acquire_connection(p; mode = :read, timeout_seconds = 5)
  @test _wait_until(() -> length(CP._waiters_for(p)) == 1)
  CP.release_connection(p, wconn2)                    # free the WRITER slot
  @test _wait_until(() -> istaskdone(rwaiter))        # :read accepts it (fallback)
  got_r = fetch(rwaiter)
  @test got_r isa FakeHandoffConn
  CP.release_connection(p, rconn2); CP.release_connection(p, got_r)
  @test count(!, p.available) == 0
end

# ─────────────────────────────────────────────────────────────────────────────
# Release-origin handoff vs a pool sweep: no double lease (#584)
#
# A release hands the slot to a parked waiter with the released handle still IN it, which is
# byte-identical to an ordinary lease. `_close_pool_slots!` (#47) therefore takes that handle out
# and re-opens the slot, and a fresh acquirer can materialize its own handle there — all before the
# waiter has re-taken `pool.lock`. The handoff now carries `(slot, handle)`, and acquire branch A
# refuses a slot that no longer holds what it was handed (or is no longer leased) and retries.
#
# Deterministic on one thread: the waiter is a sticky `@async` task, and nothing between the
# release and the fresh acquire yields (a cap-1 `put!` only notifies; the sweep's `@warn` is
# captured by `@test_logs`, so no stderr write can yield either). `w.done && isready(w.chan)`
# after the release pins that the handoff happened and the waiter has NOT yet consumed it.
# The mock's `close_pool!` is the #147 no-op fallback, so the sweep body is called directly.
#
# Gate against the unpatched body: the waiter returns the fresh acquirer's handle — `fetch(W) === X`
# while X is still held — so the "waiter re-parked" wait below times out.
# ─────────────────────────────────────────────────────────────────────────────
@testset "sweep between a release-handoff and the waiter's wake never double-leases (SQLite split, #584)" begin
  p = MockSQLiteHandoff(2; split = true)               # writer slot 1 is the ONLY :write candidate
  c1 = CP.acquire_connection(p; mode = :write)
  W = @async CP.acquire_connection(p; mode = :write, timeout_seconds = 5)
  @test _wait_until(() -> length(CP._waiters_for(p)) == 1)
  w = CP._waiters_for(p)[1]

  # 2. Release: slot 1 is handed to W under pool.lock — handle still in the slot, leased for W.
  @test CP.release_connection(p, c1) === true
  @test w.done && isready(w.chan)                      # handed, and not yet consumed by W
  @test p.available[1] === false && p.connections[1] === c1

  # 3. Sweep: takes c1 out, closes it, and re-opens slot 1 exactly like an ordinary lease.
  @test_logs (:warn, r"checked out") CP._close_pool_slots!(p; drain_seconds = 0)
  @test c1.closed && p.connections[1] === nothing && p.available[1] === true

  # 4. A fresh acquirer materializes X into slot 1 through branch B, still without yielding.
  X = CP.acquire_connection(p; mode = :write)
  @test p.connections[1] === X && p.available[1] === false

  # 5. Now W runs: (1, c1) was handed, X is there → retry → the writer slot is leased and a split
  #    pool never expands → W parks again. Unpatched, W returns X here instead.
  @test _wait_until(() -> length(CP._waiters_for(p)) == 1)
  @test !istaskdone(W)
  @test PormG.pool_stats(p).in_use == 1                # X is the single holder

  # X's release hands (1, X) to W — only then does W hold X, and X's task no longer does.
  @test CP.release_connection(p, X) === true
  got = fetch(W)
  @test got === X
  @test PormG.pool_stats(p).in_use == 1
  CP.release_connection(p, got)
  @test count(!, p.available) == 0
end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL twin of the sweep race (#584)
#
# Same five steps on the PG mock, which expands up to its ceiling, so the pool is saturated first
# to make the second acquirer park. After the sweep every slot is empty and available, so the
# waiter's retry materializes a fresh handle into the next empty slot rather than re-parking.
# Gate: unpatched, `fetch(W) === X`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "sweep between a release-handoff and the waiter's wake never double-leases (PG, #584)" begin
  p = MockPGHandoff(1)
  held = _saturate(p)                                  # 10 slots leased, ceiling reached
  W = @async CP.acquire_connection(p; timeout_seconds = 5)
  @test _wait_until(() -> length(CP._waiters_for(p)) == 1)
  w = CP._waiters_for(p)[1]

  c1 = held[1]
  @test CP.release_connection(p, c1) === true
  @test w.done && isready(w.chan)
  @test p.available[1] === false && p.connections[1] === c1

  @test_logs (:warn, r"checked out") CP._close_pool_slots!(p; drain_seconds = 0)
  @test all(c -> c === nothing, p.connections) && all(p.available)

  X = CP.acquire_connection(p)                          # branch B → slot 1
  @test p.connections[1] === X

  got = fetch(W)                                        # W runs now
  @test got isa FakeHandoffConn
  @test got !== X                                       # ← unpatched: the same handle, twice
  @test p.connections[2] === got                        # retried through the scan → next empty slot
  @test PormG.pool_stats(p).in_use == 2
  # `held[2:end]` were force-closed by the sweep and are strays now — releasing them would only
  # warn "not found", so they are left alone; the two live leases are what must come back.
  CP.release_connection(p, X); CP.release_connection(p, got)
  @test count(!, p.available) == 0
end

# ─────────────────────────────────────────────────────────────────────────────
# Discard-origin handoff still materializes across a sweep (#584)
#
# The other handoff shape: `_discard_connection!` empties the slot BEFORE handing it over, so the
# waiter is handed `(slot, nothing)`. The sweep leaves a leased-but-empty slot alone (#47), and the
# waiter's re-check must accept "still empty, still leased" and materialize a fresh handle — the
# identity check must not turn the discard-origin shape into a spurious retry.
# ─────────────────────────────────────────────────────────────────────────────
@testset "discard-origin handoff still materializes across a sweep (#584)" begin
  p = MockPGHandoff(1)
  held = _saturate(p)
  W = @async CP.acquire_connection(p; timeout_seconds = 5)
  @test _wait_until(() -> length(CP._waiters_for(p)) == 1)
  w = CP._waiters_for(p)[1]

  victim = held[1]
  @test CP._discard_connection!(p, victim) === true    # slot 1 emptied, handed as (1, nothing)
  @test w.done && isready(w.chan)
  @test p.connections[1] === nothing && p.available[1] === false

  @test_logs (:warn, r"checked out") CP._close_pool_slots!(p; drain_seconds = 0)
  @test p.connections[1] === nothing && p.available[1] === false   # leased-empty stays leased (#47)

  got = fetch(W)
  @test got isa FakeHandoffConn && got !== victim
  @test p.connections[1] === got && p.available[1] === false      # materialized into ITS slot
  CP.release_connection(p, got)
  @test p.available[1] === true
end
