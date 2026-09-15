using Test
using Logging
using PormG
# Half of these testsets open a real temp-file SQLite pool, so the weakdep driver extension must be
# active — `runtests.jl` loads it for the suite; this line makes the file runnable on its own.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const CP = PormG.ConnectionPool

# ─────────────────────────────────────────────────────────────────────────────
# close_pool!: bounded drain, then close (#47)
#
# Before #47, `close_pool!` closed every slot under `pool.lock` with a bare `close(conn)`,
# regardless of whether a borrower still held it, bypassing `_close_driver_handle!` (the #327 seam
# that defers a SQLite close while the global async worker still has statements for the handle).
# The observable was a Windows `mktempdir` cleanup warning: the SQLite file handle was still open
# when the temp dir was removed. These tests pin the new contract — wait up to `drain_seconds` for
# leases to return, then take and close every slot OUTSIDE the lock through the seam, and warn once
# with the count of connections that were still checked out.
#
# Hermetic: temp-file SQLite for the real-driver paths, a real `PostgresConnectionPool` stuffed
# with fake handles for the PostgreSQL twin (nothing connects). Each testset names the assertion
# that fails against the pre-#47 body, so none of them is theater.
# ─────────────────────────────────────────────────────────────────────────────

# A fake PostgreSQL handle. `close` records whether the owning pool's lock was held at the moment
# of the close — that is how the "closes outside the lock" rule is observed mechanically, not by
# timing. In a single-task test `islocked(lock)` is exactly "held by the closer".
mutable struct FakePGConn47
  closed::Bool
  closed_under_lock::Bool
  lock::ReentrantLock
end
FakePGConn47(lock::ReentrantLock) = FakePGConn47(false, false, lock)
Base.close(c::FakePGConn47) = (c.closed_under_lock = islocked(c.lock); c.closed = true; nothing)
Base.isopen(c::FakePGConn47) = !c.closed

# Poll until `pred()` or a deadline; returns whether it became true. Same shape as the sibling
# pool tests' `_wait_until`, uniquely named because every unit file lands in one module.
function _wait_until_47(pred; timeout = 5.0, step = 0.005)
  t0 = time()
  while time() - t0 < timeout
    pred() && return true
    sleep(step)
  end
  return pred()
end

# The drain warning, and only it, out of a `collect_test_logs` result.
_drain_warns_47(logs) = filter(l -> l.level == Logging.Warn && occursin("checked out", l.message), logs)

_sqlite_pool_47(dir) = CP.SQLiteConnectionPool(joinpath(dir, "drain.sqlite"); pool_size = 2, split_read_write = false)

# ─────────────────────────────────────────────────────────────────────────────
# close_pool!: a borrower that releases inside the drain window is not cut off
#
# The releaser is a sticky `@async` task created BEFORE the close, so it can only run once the
# closer yields — which the new body does inside its drain wait, and the old body never did. The
# gate is `fetch(t) === true`: under the old body the slot was already closed and nil'd by the time
# the releaser ran, so its identity scan missed and it returned `false`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "close_pool! drains a lease that is released inside the window (#47)" begin
  mktempdir() do dir
    pool = _sqlite_pool_47(dir)
    c1 = CP.acquire_connection(pool)
    @test isopen(c1)
    t = @async CP.release_connection(pool, c1)      # runs at the closer's first yield

    # Default drain budget: the release lands on the first 50 ms poll, so no warn is logged.
    @test_logs min_level = Logging.Warn CP.close_pool!(pool)

    @test Base.fetch(t) === true                    # the slot was still in the pool when released
    @test !isopen(c1)                               # ...and then closed by close_pool!
    @test all(pool.available)
    @test all(c -> c === nothing, pool.connections)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# close_pool!: leases that never return are force-closed after the budget, with one warning
#
# Two leased slots, nobody releases, a 0.1 s budget. Exactly ONE warn carrying `in_use = 2`, both
# handles closed, and the pool is still usable afterwards (the next acquire re-materializes).
# Gate: the old body took no kwarg and never warned.
# ─────────────────────────────────────────────────────────────────────────────
@testset "close_pool! force-closes after the drain budget and warns once (#47)" begin
  mktempdir() do dir
    pool = _sqlite_pool_47(dir)
    c1 = CP.acquire_connection(pool)
    c2 = CP.acquire_connection(pool)

    logs, _ = Test.collect_test_logs(() -> CP.close_pool!(pool; drain_seconds = 0.1))
    warns = _drain_warns_47(logs)
    @test length(warns) == 1                        # one line for the pool, not one per slot
    @test Dict(warns[1].kwargs)[:in_use] == 2
    @test Dict(warns[1].kwargs)[:adapter] == "SQLite"

    @test !isopen(c1) && !isopen(c2)                # force-closed
    @test all(pool.available)
    @test all(c -> c === nothing, pool.connections)

    # Reusable: the emptied slots re-materialize on demand, as after reaping (#125).
    c3 = CP.acquire_connection(pool)
    @test isopen(c3)
    @test CP.release_connection(pool, c3) === true
    @test_logs min_level = Logging.Warn CP.close_pool!(pool)
    @test !isopen(c3)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# close_pool!: a SQLite handle the async worker still owns is deferred, not freed under it
#
# Bumping the #327 ledger by hand is pure bookkeeping (an IdDict entry — no worker involvement)
# and says "the global worker still has a statement for this handle". `close_pool!` must take
# the slot out of circulation but leave the handle OPEN until the ledger drains; the old body
# closed it on the spot. This is also the proof that the close goes through
# `_close_driver_handle!` rather than a bare `close`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "close_pool! defers a SQLite handle with outstanding worker work (#327 seam, #47)" begin
  mktempdir() do dir
    pool = _sqlite_pool_47(dir)
    c1 = CP.acquire_connection(pool)
    CP._sqlite_pending_inc!(c1)                     # "the worker is still on this handle"
    try
      @test_logs (:warn, r"checked out") match_mode = :any CP.close_pool!(pool; drain_seconds = 0)

      @test isopen(c1)                              # NOT closed under the worker
      @test all(c -> c === nothing, pool.connections)   # ...but out of circulation
      @test all(pool.available)
    finally
      CP._sqlite_pending_dec!(c1)                   # the worker lets go
    end
    @test _wait_until_47(() -> !isopen(c1))         # the deferred close lands
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# close_pool!: the PostgreSQL twin closes outside the lock and warns with the count
#
# A real `PostgresConnectionPool` (concrete dispatch — the #147 mock-skip fallback must NOT catch
# it) whose slots hold fake handles: slot 1 leased, slot 2 idle. Gate: the old body closed inside
# `Base.lock(pool.lock) do`, so `closed_under_lock` was true for both handles, and it never warned.
# ─────────────────────────────────────────────────────────────────────────────
@testset "close_pool! PostgreSQL twin: closes outside pool.lock, warns once (#47)" begin
  pg = CP.PostgresConnectionPool("dummy-connection-string"; pool_size = 2)
  a = FakePGConn47(pg.lock)
  b = FakePGConn47(pg.lock)
  pg.connections[1] = a; pg.available[1] = false     # leased
  pg.connections[2] = b                              # idle

  logs, _ = Test.collect_test_logs(() -> CP.close_pool!(pg; drain_seconds = 0.05))
  warns = _drain_warns_47(logs)
  @test length(warns) == 1
  @test Dict(warns[1].kwargs)[:in_use] == 1
  @test Dict(warns[1].kwargs)[:adapter] == "PostgreSQL"

  @test a.closed && b.closed
  @test !a.closed_under_lock && !b.closed_under_lock   # a driver close can block on I/O
  @test all(pg.available)
  @test all(c -> c === nothing, pg.connections)
end

# ─────────────────────────────────────────────────────────────────────────────
# close_pool!: a leased slot with no handle yet stays leased
#
# That state is a discard-origin #124 direct handoff mid-materialization: the waiter that owns the
# slot will store a fresh handle and release it itself. Flipping it available here would let a
# second acquirer lease that fresh handle too. It is still counted in the warning. Gate: the old
# body set `available[i] = true` for every slot unconditionally. This testset documents the
# decision — and its limit: a release-origin handoff keeps its handle in the slot and cannot be
# told from an ordinary lease, so the sweep treats it as one (#584 moves that distinction into
# the handoff itself).
# ─────────────────────────────────────────────────────────────────────────────
@testset "close_pool! leaves a handed-off, not-yet-materialized slot leased (#47)" begin
  pg = CP.PostgresConnectionPool("dummy-connection-string"; pool_size = 2)
  b = FakePGConn47(pg.lock)
  pg.connections[1] = nothing; pg.available[1] = false   # handoff in flight
  pg.connections[2] = b                                  # idle

  logs, _ = Test.collect_test_logs(() -> CP.close_pool!(pg; drain_seconds = 0))
  warns = _drain_warns_47(logs)
  @test length(warns) == 1
  @test Dict(warns[1].kwargs)[:in_use] == 1

  @test pg.available[1] === false                  # untouched: the waiter owns it
  @test pg.connections[1] === nothing
  @test b.closed && pg.connections[2] === nothing && pg.available[2]
  pg.available[1] = true                           # tidy up the fake handoff
end

# ─────────────────────────────────────────────────────────────────────────────
# __cleanup__ (atexit) passes drain_seconds = 0
#
# At exit nobody is coming back to release anything, so the hook must not pay the grace period.
# Observed mechanically: a releaser task created BEFORE `__cleanup__` can only run once the
# closer yields. At budget 0 the closer never yields before taking the slot out, so the release
# misses (`false`, "not found"); with ANY positive budget the drain wait yields, the release lands,
# and the outcome flips to `true` with no warning. So this discriminates "forgot to pass 0" as
# well as the pre-#47 body (which never warned).
# ─────────────────────────────────────────────────────────────────────────────
@testset "__cleanup__ closes pools with drain_seconds = 0 (#47)" begin
  saved = copy(PormG.config)                       # other suites leak entries; isolate the count
  empty!(PormG.config)
  try
    mktempdir() do dir
      pg = CP.PostgresConnectionPool("dummy-connection-string"; pool_size = 1)
      a = FakePGConn47(pg.lock)
      pg.connections[1] = a; pg.available[1] = false     # leased at exit
      PormG.config["drain47"] = PormG.Configuration.Settings(
        connections   = pg,
        db_def_folder = dir,
        change_data   = true,
      )
      # The releaser captures its own "not found" warn so it neither leaks to stderr nor pollutes
      # the closer's log count.
      t = @async Test.collect_test_logs(() -> CP.release_connection(pg, a))

      logs, _ = Test.collect_test_logs(() -> PormG.Configuration.__cleanup__())
      warns = _drain_warns_47(logs)
      @test length(warns) == 1
      @test Dict(warns[1].kwargs)[:in_use] == 1
      @test Dict(warns[1].kwargs)[:drain_seconds] == 0
      @test a.closed

      rlogs, ok = Base.fetch(t)
      @test ok === false                            # the release ran after the take-out
      @test any(l -> occursin("not found in the pool", l.message), rlogs)
    end
  finally
    empty!(PormG.config)
    merge!(PormG.config, saved)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# close_pool!: idempotent, and a late release of a taken-out handle is loud but harmless
#
# A guard rather than a mutation gate: the second close was already a no-op under the old body.
# It pins the documented outcomes — a second call finds no leases and no handles (silent,
# `nothing`), and a borrower releasing a force-closed handle gets the existing "not found" warn
# and `false` rather than a throw.
# ─────────────────────────────────────────────────────────────────────────────
@testset "close_pool! is idempotent; a late release of a closed handle returns false (#47)" begin
  mktempdir() do dir
    pool = _sqlite_pool_47(dir)
    c1 = CP.acquire_connection(pool)
    @test_logs (:warn, r"checked out") match_mode = :any CP.close_pool!(pool; drain_seconds = 0)
    @test !isopen(c1)

    @test (@test_logs min_level = Logging.Warn CP.close_pool!(pool)) === nothing   # second close: silent
    @test (@test_logs (:warn, r"not found in the pool") CP.release_connection(pool, c1)) === false
    @test all(pool.available)
  end
end
