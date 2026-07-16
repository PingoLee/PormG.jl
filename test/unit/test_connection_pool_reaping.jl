using Test
using PormG
const CP = PormG.ConnectionPool   # match the sibling pool tests' idiom

# ─────────────────────────────────────────────────────────────────────────────
# Idle-connection reaping + max-lifetime (#125)
#
# DB-free: mock pools (own struct, no reaping fields → exercises the module-level registry).
# `_reap_pool!` is driven DIRECTLY (deterministic, no waiting on the background Timer), and
# timestamps in CP._POOL_REAP[pool] are backdated to force expiry without sleeping. Covers:
# idle overflow reaped to base (append-only, base kept, conns closed), leased never reaped,
# max-lifetime (sweeper + retire-on-return), reaping OFF default (no-op), SQLite split no-op.
# ─────────────────────────────────────────────────────────────────────────────

mutable struct FakeReapConn
  id::Int
  closed::Bool
end
FakeReapConn(id::Int) = FakeReapConn(id, false)
Base.close(c::FakeReapConn) = (c.closed = true; nothing)

mutable struct MockPGReap <: PormG.PormGPostgres
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
  nid::Int
end
MockPGReap(n::Int) = MockPGReap(Any[nothing for _ in 1:n], fill(true, n), "mock://pg", n, ReentrantLock(), 0)
PormG.backend_connect(p::MockPGReap; kwargs...) = FakeReapConn(p.nid += 1)
PormG.backend_is_alive(::MockPGReap, c) = c isa FakeReapConn && !c.closed

mutable struct MockSQLiteReap <: PormG.PormGSQLite
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
MockSQLiteReap(n::Int; split::Bool = false) =
  MockSQLiteReap(Any[nothing for _ in 1:n], fill(true, n), "mock://sqlite", n, split && n > 1, 1, 0,
                 ReentrantLock(), ReentrantLock(), 0)
PormG.backend_connect(p::MockSQLiteReap; kwargs...) = FakeReapConn(p.nid += 1)
PormG.backend_is_alive(::MockSQLiteReap, c) = c isa FakeReapConn && !c.closed

# Expand the pool to `total` open connections, then release them all (idle in the pool).
function _expand_and_idle(p, total)
  held = [CP.acquire_connection(p) for _ in 1:total]
  for c in held; CP.release_connection(p, c); end
  return held
end
# Backdate every slot's last_used AND created_at by `secs` so it looks idle/old.
function _backdate!(p, secs)
  st = CP._POOL_REAP[p]
  for i in 1:length(st.last_used); st.last_used[i] -= secs; st.created_at[i] -= secs; end
end
_open_count(p) = count(c -> c !== nothing, p.connections)

@testset "reaping OFF by default → no-op, pool unregistered" begin
  p = MockPGReap(2)
  held = _expand_and_idle(p, 5)          # 5 open (2 base + 3 overflow)
  @test !haskey(CP._POOL_REAP, p)        # never opted in
  @test CP._reap_state(p) === nothing
  CP._reap_pool!(p)                       # must do nothing
  @test _open_count(p) == 5
  @test length(p.connections) == 5
  @test all(c -> !c.closed, held)         # nothing closed
end

@testset "idle overflow reaped down to base (append-only, base kept)" begin
  p = MockPGReap(2)                        # base 2
  held = _expand_and_idle(p, 5)           # 5 open (slots 1-2 base, 3-5 overflow), all idle
  CP.enable_reaping!(p; idle_timeout = 1.0)
  _backdate!(p, 100.0)                     # 100s idle → past the 1s threshold
  len_before = length(p.connections)

  CP._reap_pool!(p)

  @test _open_count(p) == 2               # trimmed back to base
  @test p.connections[1] !== nothing && p.connections[2] !== nothing   # base kept warm
  @test all(i -> p.connections[i] === nothing, 3:5)                    # overflow niled
  @test length(p.connections) == len_before                           # append-only: length unchanged
  @test all(p.available)                                              # reaped slots stay available
  @test all(c -> c.closed, held[3:5])     # reaped conns were closed
  @test !held[1].closed && !held[2].closed  # base conns not closed
end

@testset "leased (in-use) connections are never reaped" begin
  p = MockPGReap(2)
  _expand_and_idle(p, 5)
  CP.enable_reaping!(p; idle_timeout = 1.0)
  held = [CP.acquire_connection(p) for _ in 1:5]   # lease all 5 again
  _backdate!(p, 100.0)
  CP._reap_pool!(p)
  @test _open_count(p) == 5               # nothing reaped — all leased
  @test all(c -> !c.closed, held)
  @test count(!, p.available) == 5        # still all leased
end

@testset "max-lifetime: sweeper retires over-age idle overflow" begin
  p = MockPGReap(2)
  held = _expand_and_idle(p, 5)
  CP.enable_reaping!(p; max_lifetime = 1.0)   # only lifetime, no idle
  _backdate!(p, 100.0)                          # created 100s ago → past 1s lifetime
  CP._reap_pool!(p)
  @test _open_count(p) == 2                     # over-age overflow retired
  @test all(c -> c.closed, held[3:5])
end

@testset "max-lifetime: retire-on-return closes an over-age overflow conn" begin
  p = MockPGReap(2)
  _expand_and_idle(p, 5)
  CP.enable_reaping!(p; max_lifetime = 1.0)
  # Lease an OVERFLOW slot, backdate its created_at, then release → retired on return.
  conns = [CP.acquire_connection(p) for _ in 1:5]     # slots 1..5 leased
  st = CP._POOL_REAP[p]
  st.created_at[5] -= 100.0                            # overflow slot 5 is now over-age
  overflow_conn = conns[5]
  CP.release_connection(p, overflow_conn)
  @test overflow_conn.closed                          # retired + closed on return
  @test p.connections[5] === nothing                  # slot niled
  @test p.available[5] == true                         # available again
  # A base slot over-age is NOT retired on return (base floor).
  st.created_at[1] -= 100.0
  base_conn = conns[1]
  CP.release_connection(p, base_conn)
  @test !base_conn.closed
  @test p.connections[1] === base_conn
  for c in conns[2:4]; CP.release_connection(p, c); end
end

@testset "SQLite split pool: no overflow → reaping is a no-op" begin
  p = MockSQLiteReap(2; split = true)     # writer=slot1, reader=slot2; never expands
  wconn = CP.acquire_connection(p; mode = :write)
  rconn = CP.acquire_connection(p; mode = :read)
  CP.release_connection(p, wconn); CP.release_connection(p, rconn)
  CP.enable_reaping!(p; idle_timeout = 1.0, max_lifetime = 1.0)
  _backdate!(p, 100.0)
  CP._reap_pool!(p)                        # overflow range (3:2) is empty
  @test length(p.connections) == 2
  @test _open_count(p) == 2               # reader + writer both kept
  @test !wconn.closed && !rconn.closed
end
