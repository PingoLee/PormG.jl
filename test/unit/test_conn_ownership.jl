"""
One ownership rule for a connection the caller passes as `conn = c` (#970).

A passed connection is **borrowed**: no funnel releases it — not on success, not when a check
refuses the statement before the driver call, not when the driver throws at dispatch, and not when
the statement fails asynchronously. The one exception is the explicit hand-over,
`with_transaction(…; release_conn = true)`. A connection the funnel acquired itself (`conn =
nothing`) is the funnel's: `fetch` releases it, `with_transaction*` returns it to the caller and
releases it only when the call throws before returning it.

Before #970 the four funnels disagreed: `fetch`/`fetch_async` released a passed `conn` on every
outcome, and `with_transaction_async` released it on a dispatch throw — with the caller's `BEGIN`
possibly still open on it — while its docstring said it never did.

The table below is the whole contract, funnel × outcome × {caller's conn, no conn}, measured on a
mock PostgreSQL pool whose slot bookkeeping is the real one. Releases are COUNTED, because a second
release of the same handle is silent: `_handoff_or_free!` just marks the slot available again, so
`in_use` alone cannot tell "released once" from "released by the funnel, then again by the caller".

julia --project=test/integration test/unit/test_conn_ownership.jl
"""

using Test
using Logging
using PormG
const CP = PormG.ConnectionPool

const NUL970 = "SEN\0hidden"

mutable struct FakeConn970
  id::Int
  closed::Bool
end
Base.close(c::FakeConn970) = (c.closed = true; nothing)

# The outcome knob: `:ok` returns a row, `:dispatch` throws from `backend_execute_async` itself (the
# synchronous failure LibPQ's `async_execute` can raise), `:async` returns a task that fails when
# awaited. `:refuse` sends a NUL, which `_refuse_nul` rejects before the driver is reached.
mutable struct MockPG970 <: PormG.PormGPostgres
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
  nid::Int
  outcome::Symbol
  releases::Int
  cancels::Int
  sent::Vector{String}
end
MockPG970(outcome::Symbol) =
  MockPG970(Any[nothing, nothing], [true, true], "mock://pg", 2, ReentrantLock(), 0, outcome, 0, 0, String[])

PormG.backend_connect(p::MockPG970; kwargs...) = FakeConn970(p.nid += 1, false)
PormG.backend_is_alive(::MockPG970, c) = c isa FakeConn970 && !c.closed
PormG.backend_is_connection_error(::MockPG970, e) = false   # never a retryable drop
# The abandoned-await recovery's driver calls (#315): counted, so the test sees whether it ran.
PormG.backend_cancel_query!(p::MockPG970, c) = (p.cancels += 1; nothing)
PormG.backend_drain_connection!(::MockPG970, c) = true
function PormG.backend_execute_async(p::MockPG970, conn, sql::String, params)
  push!(p.sent, sql)
  p.outcome === :dispatch && error("mock: dispatch refused")
  p.outcome === :interrupt && return @async throw(InterruptException())   # a Ctrl-C mid-await
  return @async begin
    p.outcome === :async && error("mock: statement failed")
    [(n = 1,)]
  end
end
# Count every release the funnels make, then do the real bookkeeping.
function CP.release_connection(p::MockPG970, conn)
  p.releases += 1
  return invoke(CP.release_connection, Tuple{PormG.PormGPostgres, Any}, p, conn)
end

# Carries the connection `with_transaction_async` handed back when its task fails afterwards.
struct HeldConn970 <: Exception
  conn::Any
  cause::Any
end

params970(outcome) = outcome === :refuse ? Any[NUL970] : Any[1]

# Each funnel, driven to completion the way a caller drives it. Returns the connection the caller
# holds afterwards when the funnel handed one back (`nothing` otherwise), so the test can release it.
const FUNNELS970 = (
  fetch       = (p, c, ps) -> (CP.fetch(p, "SELECT \$1::int AS n"; params = ps, conn = c); nothing),
  fetch_async = (p, c, ps) -> (CP.await_result(CP.fetch_async(p, "SELECT \$1::int AS n"; params = ps, conn = c)); nothing),
  tx_async    = (p, c, ps) -> begin
    task, held = CP.with_transaction_async(p, "SELECT \$1::int AS n"; params = ps, conn = c)
    try
      Base.fetch(task)
    catch e
      # An asynchronous failure surfaces here, after the funnel already returned the connection.
      throw(HeldConn970(held, e))
    end
    held
  end,
  tx_keep     = (p, c, ps) -> last(CP.with_transaction(p, "SELECT \$1::int AS n"; params = ps, conn = c, release_conn = false)),
  tx_release  = (p, c, ps) -> (CP.with_transaction(p, "SELECT \$1::int AS n"; params = ps, conn = c, release_conn = true); nothing),
)

# What the funnel itself releases (the counter), and whether the caller still holds a lease after it.
#   caller's conn → borrowed: 0 releases and still leased, except the explicit hand-over.
#   no conn       → `fetch` releases what it acquired; `with_transaction*` returns it on success and
#                   releases it only when it throws before handing it back. A refusal before the
#                   acquire (`fetch_async`, `with_transaction_async`) leases nothing at all.
function expected970(funnel::Symbol, outcome::Symbol, passed::Bool)
  if passed
    return funnel === :tx_release ? (releases = 1, held = false) : (releases = 0, held = true)
  end
  funnel in (:fetch, :fetch_async) && return (releases = outcome === :refuse ? 0 : 1, held = false)
  funnel === :tx_release && return (releases = 1, held = false)
  if funnel === :tx_async
    outcome === :refuse   && return (releases = 0, held = false)   # refused before the acquire
    outcome === :dispatch && return (releases = 1, held = false)   # acquired here, never handed back
    return (releases = 0, held = true)                             # :ok/:async — handed back to the caller
  end
  # :tx_keep acquires before its checks, so a refusal releases what it leased.
  return outcome === :ok ? (releases = 0, held = true) : (releases = 1, held = false)
end

@testset "#970: funnel × outcome — a passed conn is borrowed" begin
  for funnel in keys(FUNNELS970), outcome in (:ok, :refuse, :dispatch, :async), passed in (true, false)
    @testset "$funnel / $outcome / $(passed ? "caller's conn" : "no conn")" begin
      p = MockPG970(outcome)
      c = passed ? CP.acquire_connection(p) : nothing
      held = nothing
      err = nothing
      Logging.with_logger(Logging.NullLogger()) do   # `with_transaction` logs its failures
        try
          held = FUNNELS970[funnel](p, c, params970(outcome))
        catch e
          err = e
          e isa HeldConn970 && (held = e.conn)
        end
      end

      @test (err === nothing) == (outcome === :ok)
      outcome === :refuse && @test err isa PormG.InvalidValueError
      outcome === :refuse && @test isempty(p.sent)
      want = expected970(funnel, outcome, passed)
      @test p.releases == want.releases
      @test CP.pool_stats(p).in_use == (want.held ? 1 : 0)
      # When a funnel hands a connection back, a caller's conn comes back as the very same handle.
      handed_back = err === nothing || err isa HeldConn970
      passed && handed_back && funnel in (:tx_async, :tx_keep) && @test held === c

      # The caller's single release finds the lease — never a second release of a freed slot.
      owner = passed ? c : held
      if want.held
        @test owner !== nothing
        @test CP.release_connection(p, owner) === true
      end
      @test CP.pool_stats(p).in_use == 0
    end
  end
end

@testset "#970: the issue's repro — with_transaction_async keeps a caller's conn on a driver throw" begin
  p = MockPG970(:dispatch)
  c = CP.acquire_connection(p)                                       # caller drives a transaction on c
  err = try
    CP.with_transaction_async(p, "INSERT INTO results (points) VALUES (25)"; conn = c)
    nothing
  catch e
    e
  end
  @test err isa PormG.DatabaseError
  @test CP.pool_stats(p).in_use == 1                                 # still the caller's
  other = CP.acquire_connection(p)                                   # another borrower
  @test other !== c                                                  # is not handed c
  CP.release_connection(p, other)
  @test CP.release_connection(p, c) === true
  @test CP.pool_stats(p).in_use == 0
end

# A cancelled await (`Ctrl+C`) leaves the driver possibly still on the connection, so an ACQUIRED one
# goes to the detached recovery — cancel, settle, then release or renew (#315). A BORROWED one is the
# caller's: the recovery would hand its slot back under the caller's lease, so it is left alone and
# the caller settles it (`finalize_transaction_connection!(…; renew = true)`), as `with_transaction`
# already leaves a caller's connection after an interrupt.
@testset "#970: a cancelled await leaves a borrowed conn with the caller" begin
  for passed in (true, false), via_async in (true, false)
    @testset "$(via_async ? "fetch_async" : "fetch") / $(passed ? "caller's conn" : "no conn")" begin
      p = MockPG970(:interrupt)
      c = passed ? CP.acquire_connection(p) : nothing
      err = Logging.with_logger(Logging.NullLogger()) do
        try
          via_async ? CP.await_result(CP.fetch_async(p, "SELECT 1"; conn = c)) :
                      CP.fetch(p, "SELECT 1"; conn = c)
          nothing
        catch e
          e
        end
      end
      @test err !== nothing
      if passed
        sleep(0.5)                                   # room for a recovery that must not run
        @test p.cancels == 0 && p.releases == 0
        @test CP.pool_stats(p).in_use == 1
        @test CP.release_connection(p, c) === true
      else
        # The recovery is detached; it cancels, then hands the slot back.
        @test timedwait(() -> p.cancels == 1 && CP.pool_stats(p).in_use == 0, 10.0) === :ok
      end
    end
  end
end
