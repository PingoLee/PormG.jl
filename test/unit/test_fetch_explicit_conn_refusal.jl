"""
A caller's own `conn` stays the caller's when a check refuses the statement before the driver call
(#960, then #970).

Two checks run before the driver is called — `_normalize_manual_params` (SQLite's
`sqlite_bind_value` refuses a value it cannot bind) and `_refuse_nul` (#951). #960 found that a
throw from either one left a `conn` passed to `fetch` leased while `fetch` released it on every other
outcome, and fixed it by releasing on the refusal too. #970 settled the rule instead: a passed
`conn` is **borrowed**, so no funnel releases it on any outcome — the refusal included — and the
caller releases it once. `test_conn_ownership.jl` pins the whole funnel × outcome table; this file
keeps the refusal row for both checks, on both engines.

Pinned here, with no server:

  1. **PostgreSQL (mock pool)** — a NUL refusal through `fetch`, `fetch_async` and
     `with_transaction_async` leaves the caller's lease in place, the driver is never called, and
     the caller's own release succeeds without a warning.
  2. **The transaction context is not the caller's `conn`** — a refusal with no `conn` inside
     `with_tx_context` leaves the transaction's lease alone.
  3. **SQLite (real pool)** — the same, for a NUL and for a manual param `sqlite_bind_value` refuses.

julia --project=test/integration test/unit/test_fetch_explicit_conn_refusal.jl
"""

using Test
using Logging
using PormG
# Standalone runs need the SQLite extension for the real-engine half (runtests.jl loads it too).
include(joinpath(@__DIR__, "..", "load_drivers.jl"))
const CP = PormG.ConnectionPool   # match the sibling pool tests' idiom

const NUL960 = "SEN\0hidden"

# A refusal is expected; anything else (including no throw) fails the caller's `isa` test.
refused960(f) = try f(); nothing catch e e end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL mock pool
# A real slot table (so `acquire_connection`, `release_connection` and `pool_stats` run their actual
# bookkeeping) over fake handles. The driver records every call and fails, so a statement that got
# through shows up in `SENT960`.
# ─────────────────────────────────────────────────────────────────────────────
mutable struct FakeConn960
  id::Int
  closed::Bool
end
Base.close(c::FakeConn960) = (c.closed = true; nothing)

mutable struct MockPG960 <: PormG.PormGPostgres
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
  nid::Int
end
MockPG960(n::Int) = MockPG960(Any[nothing for _ in 1:n], fill(true, n), "mock://pg", n, ReentrantLock(), 0)
PormG.backend_connect(p::MockPG960; kwargs...) = FakeConn960(p.nid += 1, false)
PormG.backend_is_alive(::MockPG960, c) = c isa FakeConn960 && !c.closed

const SENT960 = String[]
struct Reached960 <: Exception end
function PormG.backend_execute_async(::MockPG960, conn, sql::String, params)
  push!(SENT960, sql)
  throw(Reached960())
end

@testset "#960/#970: PostgreSQL — a refusal leaves an explicit conn with the caller" begin
  p = MockPG960(2)
  empty!(SENT960)

  # `fetch`, the funnel apps call, `fetch_async` under it — the params and the statement text — and
  # `with_transaction_async`. Every one leaves the caller's `conn` leased, and the caller's own
  # release then finds it (a handle the funnel had already released would make it a second
  # release of a slot someone else may hold).
  for call in (c -> CP.fetch(p, "SELECT \$1::text"; params = [NUL960], conn = c),
               c -> CP.fetch_async(p, "SELECT \$1::text"; params = [NUL960], conn = c),
               c -> CP.fetch(p, "SELECT '$NUL960'"; conn = c),
               c -> CP.with_transaction_async(p, "SELECT \$1::text"; params = (NUL960,), conn = c))
    c = CP.acquire_connection(p)
    @test CP.pool_stats(p).in_use == 1
    e = @test_logs min_level = Logging.Warn refused960(() -> call(c))
    @test e isa PormG.InvalidValueError
    @test CP.pool_stats(p).in_use == 1
    @test (@test_logs min_level = Logging.Warn CP.release_connection(p, c)) === true
    @test CP.pool_stats(p).in_use == 0
  end
  @test isempty(SENT960)

  # The control: with no `conn`, the refusal still happens before the acquire, so nothing is leased.
  e = refused960(() -> CP.fetch(p, "SELECT \$1::text"; params = [NUL960]))
  @test e isa PormG.InvalidValueError
  @test CP.pool_stats(p).in_use == 0
  @test isempty(SENT960)
end

@testset "#960: PostgreSQL — a refusal inside a transaction leaves the transaction's lease alone" begin
  # With no `conn`, `fetch_async` would reuse the transaction's connection, which belongs to
  # `run_in_transaction` (here `with_tx_context`), not to this call — so a refusal must not release it.
  p = MockPG960(2)
  empty!(SENT960)
  tx = CP.acquire_connection(p)
  try
    e = PormG.Configuration.with_tx_context(p, tx) do
      refused960(() -> CP.fetch(p, "SELECT \$1::text"; params = [NUL960]))
    end
    @test e isa PormG.InvalidValueError
    @test CP.pool_stats(p).in_use == 1
    @test isempty(SENT960)
  finally
    CP.release_connection(p, tx)
  end
  @test CP.pool_stats(p).in_use == 0
end

# ─────────────────────────────────────────────────────────────────────────────
# A real SQLite pool
# Both refusals: a NUL (`_refuse_nul`) and a value SQLite cannot bind (`sqlite_bind_value`, #721) —
# `typemax(UInt64)` does not fit the 64-bit integer SQLite stores.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#960/#970: SQLite — a refusal leaves an explicit conn with the caller" begin
  mktempdir() do dir
    pool = CP.SQLiteConnectionPool(joinpath(dir, "explicit960.sqlite"); pool_size = 1)
    try
      for params in ([NUL960], [typemax(UInt64)]),
          call in ((c, ps) -> CP.fetch(pool, "SELECT ? AS t;"; params = ps, conn = c),
                   (c, ps) -> CP.with_transaction_async(pool, "SELECT ? AS t;"; params = ps, conn = c))
        c = CP.acquire_connection(pool)
        @test CP.pool_stats(pool).in_use == 1
        e = @test_logs min_level = Logging.Warn refused960(() -> call(c, params))
        @test e isa PormG.InvalidValueError
        # Still the caller's (#970), released once by the caller.
        @test CP.pool_stats(pool).in_use == 1
        @test CP.release_connection(pool, c) === true
        @test CP.pool_stats(pool).in_use == 0
      end

      # The connection still works after the caller releases it: the pool hands it out again.
      @test only(CP.fetch(pool, "SELECT 1 AS n;")).n == 1
      @test CP.pool_stats(pool).in_use == 0
    finally
      CP.close_pool!(pool)   # release the handle so mktempdir can clean up (Windows)
    end
  end
end
