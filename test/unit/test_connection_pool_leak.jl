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

# ─────────────────────────────────────────────────────────────────────────────
# The warning names what the held slot is doing (#1637).
#
# What: a leased slot past the threshold is worded by its state at the scan. With no statement
#   running: today's "likely acquired without release" text. With a statement still running (the
#   slot stamped by `_note_statement_start!`): "while its statement is still running: a slow
#   statement or an unresponsive server, not a leak", with `running_s`. Leased and empty (a slot
#   reserved for a connect, #1540): "while connecting to the server". Every wording keeps the prefix
#   "Pool connection held past leak_detection_threshold", and each still warns once per lease.
# SQL: none; `_leak_check!` is driven directly on the mock pool.
# Why: all three used to print "likely acquired without release", which sent a reader whose server
#   was paused or slow looking for a missing `await_result` that did not exist.
# ─────────────────────────────────────────────────────────────────────────────

const _LEAK_PREFIX_1637 = "Pool connection held past leak_detection_threshold"

# The Warn records one `_leak_check!` emits.
function _leak_logs_1637(p)
  logs, _ = Test.collect_test_logs(min_level = Logging.Warn) do
    CP._leak_check!(p)
  end
  return logs
end

@testset "leak (#1637): a lease with no statement running keeps today's wording" begin
  p = MockPGLeak(1)
  CP.enable_leak_detection!(p; threshold = 1.0)
  c, i = _lease_one(p)
  CP._POOL_MONITOR[p].last_used[i] -= 100.0
  logs = _leak_logs_1637(p)
  @test length(logs) == 1
  @test logs[1].message == "$(_LEAK_PREFIX_1637) — likely acquired without release; await the FetchTask or release the connection"
  @test !haskey(Dict(logs[1].kwargs), :running_s)
  @test isempty(_leak_logs_1637(p))                      # once per lease
  CP.release_connection(p, c)
end

@testset "leak (#1637): a lease whose statement is still running says so, with running_s" begin
  p = MockPGLeak(1)
  CP.enable_leak_detection!(p; threshold = 1.0)
  c, i = _lease_one(p)
  st = CP._POOL_MONITOR[p]
  mark = CP._note_statement_start!(p, c)
  @test mark.slot == i && st.statement_started[i] == mark.started
  st.last_used[i] -= 100.0
  st.statement_started[i] -= 40.0                        # the statement started 40 s ago
  logs = _leak_logs_1637(p)
  @test length(logs) == 1
  @test logs[1].message == "$(_LEAK_PREFIX_1637) while its statement is still running: a slow statement or an unresponsive server, not a leak"
  kw = Dict(logs[1].kwargs)
  @test 39.0 <= kw[:running_s] <= 41.0
  @test kw[:held_s] >= 99.0 && kw[:slot] == i
  @test isempty(_leak_logs_1637(p))                      # still once per lease
  CP.release_connection(p, c)
  @test st.statement_started[i] == 0.0                   # a returned lease has no statement
end

@testset "leak (#1637): a slot reserved for a connect says it is connecting" begin
  p = MockPGLeak(2)
  CP.enable_leak_detection!(p; threshold = 1.0)
  st = CP._POOL_MONITOR[p]
  # Reserve slot 2 the way an acquire does before it connects (#1540): leased, and still empty.
  Base.lock(p.lock) do
    p.available[2] = false
    CP._monitor_note_touch!(p, 2)
  end
  st.last_used[2] -= 100.0
  logs = _leak_logs_1637(p)
  @test length(logs) == 1
  @test logs[1].message == "$(_LEAK_PREFIX_1637) while connecting to the server"
  @test Dict(logs[1].kwargs)[:slot] == 2
  @test isempty(_leak_logs_1637(p))                      # once per lease
end

@testset "leak (#1637): a statement's end clears only its own stamp" begin
  p = MockPGLeak(1)
  CP.enable_leak_detection!(p; threshold = 1.0)
  c, i = _lease_one(p)
  st = CP._POOL_MONITOR[p]
  first_mark = CP._note_statement_start!(p, c)
  st.statement_started[i] = first_mark.started + 1.0     # a later statement stamped the slot since
  CP._note_statement_end!(p, first_mark)
  @test st.statement_started[i] == first_mark.started + 1.0   # the older end leaves it alone
  CP._note_statement_end!(p, CP._StatementMark(i, first_mark.started + 1.0))
  @test st.statement_started[i] == 0.0
  # After the stamp is cleared, the same lease reads as one nobody returned.
  st.last_used[i] -= 100.0
  @test occursin("likely acquired without release", only(_leak_logs_1637(p)).message)
  CP.release_connection(p, c)
end

@testset "leak (#1637): a renewal that swaps the slot's handle clears its stamp" begin
  # A statement stuck on the old handle no longer stands for the slot once a renewal installs a new one
  # (`_swap_slot!`, still leased). If the holder then never returns the lease, the scan must call it
  # what it is, not a running statement.
  p = MockPGLeak(1)
  CP.enable_leak_detection!(p; threshold = 1.0)
  c, i = _lease_one(p)
  st = CP._POOL_MONITOR[p]
  mark = CP._note_statement_start!(p, c)
  @test st.statement_started[i] == mark.started
  renewed = FakeLeakConn(99)
  @test CP._swap_slot!(p, i, c, renewed)
  @test st.statement_started[i] == 0.0
  CP._note_statement_end!(p, mark)                       # the old statement's late end: no effect
  @test st.statement_started[i] == 0.0
  st.last_used[i] -= 100.0
  @test occursin("likely acquired without release", only(_leak_logs_1637(p)).message)
  CP.release_connection(p, renewed)
end

@testset "leak (#1637): a pool without leak detection records no statement" begin
  plain = MockPGLeak(1)                                  # no monitor state at all
  c, _ = _lease_one(plain)
  @test CP._note_statement_start!(plain, c) === CP._NO_STATEMENT_MARK
  CP.release_connection(plain, c)
  reaping = MockPGLeak(1)                                # monitored, but leak detection off
  CP.enable_reaping!(reaping; idle_timeout = 60.0)
  c2, i2 = _lease_one(reaping)
  @test CP._note_statement_start!(reaping, c2) === CP._NO_STATEMENT_MARK
  @test CP._POOL_MONITOR[reaping].statement_started[i2] == 0.0
  CP.release_connection(reaping, c2)
end

# ── Each statement path clears its stamp when the statement ends, on success and on a throw ──

PormG.backend_is_connection_error(::MockPGLeak, e) = false

# COPY (#1637): `fetch_copy` stamps the slot around `backend_copy_in!`. The mock reads the stamp while
# it "runs" and fails when asked to.
const _COPY_SAW_1637 = Ref(0.0)
function PormG.backend_copy_in!(p::MockPGLeak, conn, sql::String, data_itr)::Int
  i = findfirst(c -> c === conn, p.connections)
  _COPY_SAW_1637[] = CP._POOL_MONITOR[p].statement_started[i]
  data_itr == ["fail"] && error("mock: copy refused")
  return 1
end

@testset "leak (#1637): fetch_copy stamps the slot while COPY runs and clears it after" begin
  p = MockPGLeak(1)
  CP.enable_leak_detection!(p; threshold = 1.0)
  st = CP._POOL_MONITOR[p]
  _COPY_SAW_1637[] = 0.0
  @test CP.fetch_copy(p, "COPY status FROM STDIN", ["1,Finished\n"]) == 1
  @test _COPY_SAW_1637[] > 0.0                           # stamped while it ran
  @test st.statement_started[1] == 0.0                   # cleared after
  _COPY_SAW_1637[] = 0.0
  @test_throws PormG.DatabaseError CP.fetch_copy(p, "COPY status FROM STDIN", ["fail"])
  @test _COPY_SAW_1637[] > 0.0
  @test st.statement_started[1] == 0.0                   # cleared on a throw too
  # Inside a transaction the connection stays leased after the COPY, so only the COPY's own clear
  # can empty the stamp (a return's reset never comes).
  c, i = _lease_one(p)
  PormG.Configuration.with_tx_context(p, c) do
    _COPY_SAW_1637[] = 0.0
    @test CP.fetch_copy(p, "COPY status FROM STDIN", ["1,Finished\n"]) == 1
    @test _COPY_SAW_1637[] > 0.0
    @test st.statement_started[i] == 0.0
    @test_throws PormG.DatabaseError CP.fetch_copy(p, "COPY status FROM STDIN", ["fail"])
    @test st.statement_started[i] == 0.0
  end
  CP.release_connection(p, c)
end

@testset "leak (#1637): a driver-owned statement task clears the stamp once it settles" begin
  # LibPQ's shape: the statement runs in a task the driver owns, so a waiting task clears the stamp.
  for fails in (false, true)
    p = MockPGLeak(1)
    CP.enable_leak_detection!(p; threshold = 1.0)
    c, i = _lease_one(p)
    st = CP._POOL_MONITOR[p]
    gate = Channel{Nothing}(1)
    mark = CP._note_statement_start!(p, c)
    handle = Threads.@spawn (take!(gate); fails && error("mock: statement failed"); 1)
    CP._note_statement_end_when_settled!(p, mark, handle)
    sleep(0.05)
    @test st.statement_started[i] == mark.started         # still running
    put!(gate, nothing)
    @test timedwait(() -> st.statement_started[i] == 0.0, 5.0) === :ok
    CP.release_connection(p, c)
  end
  # No mark (leak detection off): nothing is spawned, and the call returns at once.
  @test CP._note_statement_end_when_settled!(MockPGLeak(1), CP._NO_STATEMENT_MARK, Threads.@spawn(1)) === nothing
end

# SQLite: the worker stamps a statement when it is queued and clears it in its own `finally`.
mutable struct MockSQLiteLeak <: PormG.PormGSQLite
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
  gate::Channel{Nothing}
end
MockSQLiteLeak() = MockSQLiteLeak(Any[FakeLeakConn(1)], [false], "mock://sqlite", 1, ReentrantLock(), Channel{Nothing}(1))
function PormG.backend_execute(p::MockSQLiteLeak, conn, sql::String, params)
  take!(p.gate)
  sql == "fail" && error("mock: statement failed")
  return NamedTuple[]
end

@testset "leak (#1637): SQLite's worker stamps a queued statement and clears it when it ends" begin
  for sql in ("SELECT 1", "fail")
    p = MockSQLiteLeak()
    CP.enable_leak_detection!(p; threshold = 1.0)
    st = CP._POOL_MONITOR[p]
    t = CP.sqlite_execute_async(p, p.connections[1], sql, nothing)
    @test st.statement_started[1] > 0.0                   # stamped before the worker runs it
    put!(p.gate, nothing)
    try
      fetch(t)
    catch
    end
    @test st.statement_started[1] == 0.0                  # cleared on success and on a throw
  end
end

@testset "leak (#1637): the PostgreSQL and MySQL extensions stamp every statement" begin
  # A `Postgres.Connection`, a `LibPQ.Connection` or a `MySQL.Connection` needs a server, so the
  # extension methods are pinned by source: the stamp is taken before the statement, and cleared in the
  # task's `finally` (Postgres.jl, MySQL) or once the driver's handle settles (LibPQ).
  # `test_connection_pool.jl` checks the real drivers end to end.
  ext_dir = joinpath(pkgdir(PormG), "ext")
  for file in ("PormGPostgresExt.jl", "PormGMySQLExt.jl", "PormGLibPQExt.jl")
    src = read(joinpath(ext_dir, file), String)
    @test (file, occursin("PormG.ConnectionPool._note_statement_start!(pool, conn)", src)) == (file, true)
  end
  for file in ("PormGPostgresExt.jl", "PormGMySQLExt.jl")
    src = read(joinpath(ext_dir, file), String)
    @test (file, occursin(r"finally\s+PormG\.ConnectionPool\._note_statement_end!\(pool, mark\)", src)) == (file, true)
  end
  src = read(joinpath(ext_dir, "PormGLibPQExt.jl"), String)
  @test occursin("PormG.ConnectionPool._note_statement_end_when_settled!(pool, mark, handle)", src)
end
