using Test
using Logging
using PormG
# Every testset opens a real temp-file SQLite pool, so the weakdep driver extension must be active —
# `runtests.jl` loads it for the suite; this line makes the file runnable on its own.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const CP = PormG.ConnectionPool

# ─────────────────────────────────────────────────────────────────────────────
# SQLite pool + shared async worker under sustained concurrent load (#128)
#
# The #37 leak guard (`test/integration/test_connection_pool.jl`) is PostgreSQL-only: on SQLite
# every statement is serialized through ONE global worker task, so N concurrent fetches need not
# check out N distinct slots, and the "N held at once" assertion is skipped there. Nothing exercised
# the SQLite pool + worker under repeated load. The soak below runs the same workload twice,
# hermetically (temp file, no fixture), because the two SQLite pool shapes fail differently:
#
#   split read/write   never expands (`can_expand = !split_read_write`), so 8 borrowers on 2 slots
#                      park on the #124 direct handoff every round — the contention path
#   shared (non-split) expands lazily up to the ceiling — the growth path
#
# After every round the invariants are asserted MECHANICALLY, never by wall clock:
#
#   in_use == 0 and waiting == 0     every lease came back, no waiter is left parked
#   size (see each testset)          the shape-specific bound a leaked slot would break
#   #327 ledger empty, queue empty   the worker is provably off every pooled handle
#   row count == writes issued       the work actually happened, exactly once
#
# Nothing here is a known bug; it is the coverage gap #128 names, and it would catch a slot or
# ledger entry that failed to come back.
# ─────────────────────────────────────────────────────────────────────────────

const _SOAK_ROUNDS = 6    # repeated identical rounds — a leak accumulates across them
const _SOAK_TASKS  = 8    # concurrent borrowers per round (> pool_size on both shapes)
const _SOAK_ITERS  = 10   # statements per task per round, alternating write / read

# One round of the workload: `_SOAK_TASKS` tasks, each alternating a parameterized INSERT (takes
# the writer slot on a split pool) and an awaited async COUNT (reader cursor). A `@test` inside a
# spawned task has no enclosing testset, so a failure throws and surfaces at `wait` as a
# `TaskFailedException` — loud, though as an error rather than a recorded Fail.
function _soak_round!(pool, round::Int)
  tasks = map(1:_SOAK_TASKS) do k
    Threads.@spawn begin
      for i in 1:_SOAK_ITERS
        if isodd(i)
          # Positional `?` binds through `DBInterface.execute(stmt, params)` in the SQLite extension.
          CP.fetch(pool, "INSERT INTO soak_lap (driver, ms) VALUES (?, ?);", ["driver_$k", round * 1000 + i])
        else
          # The async form + `await_result` is what the ORM's list() does (a `FetchTask` is not a
          # `Task` — `Base.fetch` on it would be the identity, and the lease would never return).
          rows = CP.await_result(CP.fetch_async(pool, "SELECT COUNT(*) AS n FROM soak_lap WHERE driver = ?;", ["driver_$k"]))
          @test length(rows) == 1                 # materialized rowtable, one COUNT row
        end
      end
    end
  end
  foreach(wait, tasks)
  return nothing
end

# The shape-independent invariants, read in one `pool.lock` snapshot plus the worker-side ledger.
function _soak_assert_settled!(pool)
  s = PormG.pool_stats(pool)
  @test s.in_use == 0                    # every lease came back
  @test s.waiting == 0                   # nobody is left parked on a slot that never freed
  # The #327 ledger: the worker holds no queued or executing statement for any pooled handle.
  @test all(c -> c === nothing || CP._sqlite_outstanding(c) == 0, pool.connections)
  @test !isready(CP._sqlite_async_work_queue)   # nothing left behind in the queue
  return s
end

_soak_writes() = count(isodd, 1:_SOAK_ITERS) * _SOAK_TASKS * _SOAK_ROUNDS

# ─────────────────────────────────────────────────────────────────────────────
# Split read/write pool: the #124 handoff under sustained contention
#
# A split pool allocates exactly `pool_size` slots and never expands, so with 8 borrowers on 2
# slots most of each round is spent parked on the direct handoff (`_handoff_or_free!`). The size
# invariant is therefore an EQUALITY: a slot count that moves is a bookkeeping bug, not growth.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite split pool + async worker stay settled under handoff contention (#128)" begin
  mktempdir() do dir
    pool = CP.SQLiteConnectionPool(joinpath(dir, "soak_split.sqlite"); pool_size = 2, split_read_write = true)
    try
      CP.fetch(pool, "CREATE TABLE soak_lap (id INTEGER PRIMARY KEY AUTOINCREMENT, driver TEXT NOT NULL, ms INTEGER NOT NULL);")
      for round in 1:_SOAK_ROUNDS
        _soak_round!(pool, round)
        s = _soak_assert_settled!(pool)
        @test s.size == pool.pool_size       # a split pool never expands: exactly the writer + reader slots
      end
      total = CP.fetch(pool, "SELECT COUNT(*) AS n FROM soak_lap;")
      @test total[1].n == _soak_writes()     # every write landed exactly once
    finally
      CP.close_pool!(pool)   # #47: drains, closes outside the lock, through the #327 seam
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Shared (non-split) pool: lazy expansion stays bounded by real concurrency
#
# A shared pool grows on demand up to `pool_size * POOL_EXPANSION_FACTOR`. The bound that a leaked
# slot would break is the number of CONCURRENT borrowers: with every lease returned, the pool can
# never need more slots than tasks that ever held one at once. (How far it grows within that bound
# is scheduling-dependent, so "no growth after round N" is deliberately NOT asserted — `in_use == 0`
# already is the leak signal.)
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite shared pool + async worker stay bounded while expanding under load (#128)" begin
  mktempdir() do dir
    pool = CP.SQLiteConnectionPool(joinpath(dir, "soak_shared.sqlite"); pool_size = 2, split_read_write = false)
    try
      CP.fetch(pool, "CREATE TABLE soak_lap (id INTEGER PRIMARY KEY AUTOINCREMENT, driver TEXT NOT NULL, ms INTEGER NOT NULL);")
      ceiling = CP._pool_ceiling(pool)
      for round in 1:_SOAK_ROUNDS
        _soak_round!(pool, round)
        s = _soak_assert_settled!(pool)
        @test pool.pool_size <= s.size <= min(ceiling, _SOAK_TASKS)   # never more slots than real concurrency
      end
      total = CP.fetch(pool, "SELECT COUNT(*) AS n FROM soak_lap;")
      @test total[1].n == _soak_writes()
    finally
      CP.close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# release_connection after reconnect_db: the renewed handle frees the slot, the stale one cannot
#
# #128's audit item, pinned as a CONTRACT (the semantics predate this file; the one #128-specific
# gate is the warn text naming the renewed handle). `reconnect_db` swaps a fresh handle into the
# slot IN PLACE and leaves it leased; `release_connection` matches by identity. So the rule is
# "release what is in the slot now": releasing the renewed handle frees it, releasing the ORIGINAL
# warns "not found", returns false, and leaves the slot leased — that is the one stranding shape,
# shown here so the next reader sees the consequence (`in_use` stays 1). Both in-tree callers
# honour the rule: `_renew_or_discard_connection!` and `fetch`'s reconnect-and-retry release the
# renewed handle. Renewal does NOT close the old handle — that is the caller's job.
# ─────────────────────────────────────────────────────────────────────────────
@testset "release_connection after reconnect_db frees the slot only with the renewed handle (#128)" begin
  mktempdir() do dir
    pool = CP.SQLiteConnectionPool(joinpath(dir, "renew.sqlite"); pool_size = 1, split_read_write = false)
    try
      conn = CP.acquire_connection(pool)
      @test PormG.pool_stats(pool).in_use == 1

      new_conn = CP.reconnect_db(pool, conn)
      @test new_conn !== nothing
      @test new_conn !== conn                  # SQLite renewal is always a fresh handle
      @test pool.connections[1] === new_conn   # swapped in place...
      @test pool.available[1] === false        # ...and still leased: renewal does not release
      @test isopen(conn)                       # the old handle is left to the caller

      # The stranding shape: the stale handle is not in any slot, so nothing is freed.
      @test (@test_logs (:warn, r"not found in the pool.*renewed handle") CP.release_connection(pool, conn)) === false
      @test PormG.pool_stats(pool).in_use == 1

      # The contract: release what the slot holds now.
      @test CP.release_connection(pool, new_conn) === true
      @test PormG.pool_stats(pool).in_use == 0
      @test pool.connections[1] === new_conn   # idle, reusable

      close(conn)                              # what `_renew_or_discard_connection!` does for callers
      @test !isopen(conn)
    finally
      CP.close_pool!(pool)
    end
  end
end
