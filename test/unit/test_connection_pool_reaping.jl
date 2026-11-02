using Test
using PormG
const CP = PormG.ConnectionPool   # match the sibling pool tests' idiom

# ─────────────────────────────────────────────────────────────────────────────
# Idle-connection reaping + max-lifetime (#125)
#
# DB-free: mock pools (own struct, no reaping fields → exercises the module-level registry).
# `_reap_pool!` is driven DIRECTLY (deterministic, no waiting on the background Timer), and
# timestamps in CP._POOL_MONITOR[pool] are backdated to force expiry without sleeping. Covers:
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
  st = CP._POOL_MONITOR[p]
  for i in 1:length(st.last_used); st.last_used[i] -= secs; st.created_at[i] -= secs; end
end
_open_count(p) = count(c -> c !== nothing, p.connections)

@testset "reaping OFF by default → no-op, pool unregistered" begin
  p = MockPGReap(2)
  held = _expand_and_idle(p, 5)          # 5 open (2 base + 3 overflow)
  @test !haskey(CP._POOL_MONITOR, p)        # never opted in
  @test CP._monitor_state(p) === nothing
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
  st = CP._POOL_MONITOR[p]
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

# ─────────────────────────────────────────────────────────────────────────────
# #1562: the sweeper is a task that never ends, and a precompile worker waits for every open task
# before it writes the cache. A package whose module body loads a configuration with idle_timeout or
# max_lifetime therefore never finished precompiling.
# ─────────────────────────────────────────────────────────────────────────────

@testset "#1562: _ensure_reaper! starts and latches nothing while precompiling" begin
  # What: with `generating = true` (the precompile branch), `_ensure_reaper!` returns without
  #   spawning the sweeper and without setting `_reaper_started`, so the run-time call that follows
  #   (a package's `__init__` loading its configuration again) still starts it.
  # Why: latching the flag in the precompile worker would be harmless there, but spawning is the hang.
  #   The flag is the observable proxy for the spawn: the old code set it right after spawning.
  was = CP._reaper_started[]
  try
    CP._reaper_started[] = false
    @test CP._ensure_reaper!(; generating = true) === nothing
    @test !CP._reaper_started[]
  finally
    CP._reaper_started[] = was
  end
end

@testset "#1562: the first acquire starts the sweeper a reaping pool lacks; leak-only starts none" begin
  # What: with `_reaper_started` unset (a sysimage or `juliac` build saves it unset, and its run-time
  #   `load` returns early without reaching `enable_reaping!`), acquiring from a pool that reaps
  #   starts the sweeper; acquiring from a pool with leak detection only does not.
  # Why: without the lazy start such a build never reaps its overflow connections, and says nothing.
  # The test process may already run a sweeper (earlier testsets enabled reaping), so a second one can
  # start here; two sweepers take the same locks and reap the same overflow, which is harmless.
  was = CP._reaper_started[]
  try
    leaky = MockPGReap(2)
    CP.enable_leak_detection!(leaky; threshold = 30.0)
    CP._reaper_started[] = false
    CP.release_connection(leaky, CP.acquire_connection(leaky))
    @test !CP._reaper_started[]

    reaping = MockPGReap(2)
    CP.enable_reaping!(reaping; idle_timeout = 60.0)
    CP._reaper_started[] = false
    CP.release_connection(reaping, CP.acquire_connection(reaping))
    @test CP._reaper_started[]

    sqlite = MockSQLiteReap(2)             # the SQLite acquire path calls the same hook
    CP.enable_reaping!(sqlite; max_lifetime = 60.0)
    CP._reaper_started[] = false
    CP.release_connection(sqlite, CP.acquire_connection(sqlite))
    @test CP._reaper_started[]
  finally
    CP._reaper_started[] = was || CP._reaper_started[]
  end
end

# The scratch package, and the script that loads it, in `dir`. `dir` is also an explicit
# environment whose manifest lists the package and names its two dependencies by UUID: Julia then
# locates them in the test environment further down the stack, with no Pkg operation and no registry.
function _write_paddock1562(dir::String)
  pkg = joinpath(dir, "Paddock1562")
  mkpath(joinpath(pkg, "src")); mkpath(joinpath(pkg, "db"))
  sqlite = Base.identify_package("SQLite")
  sqlite === nothing && error("the test environment has no SQLite")
  uuid, pormg = "6a1f5c2e-8d4b-4e7a-9c3f-1562b0d5e7a9", Base.PkgId(PormG).uuid
  write(joinpath(pkg, "Project.toml"), """
    name = "Paddock1562"
    uuid = "$(uuid)"
    version = "0.1.0"

    [deps]
    PormG = "$(pormg)"
    SQLite = "$(sqlite.uuid)"
    """)
  write(joinpath(dir, "Project.toml"), """
    [deps]
    Paddock1562 = "$(uuid)"
    """)
  write(joinpath(dir, "Manifest.toml"), """
    manifest_format = "2.0"

    [[deps.Paddock1562]]
    path = "Paddock1562"
    uuid = "$(uuid)"
    version = "0.1.0"

        [deps.Paddock1562.deps]
        PormG = "$(pormg)"
        SQLite = "$(sqlite.uuid)"
    """)
  write(joinpath(pkg, "db", "connection.yml"), """
    dev:
      adapter: SQLite
      database: f1.sqlite
      idle_timeout: 300
      max_lifetime: 3600
    """)
  write(joinpath(pkg, "src", "Paddock1562.jl"), """
    module Paddock1562
    using PormG, SQLite
    const ROOT = dirname(@__DIR__)
    # The documented module-body shape: load here (so `@import_models` could bind at precompile
    # time) and again at run time in `__init__`.
    PormG.Configuration.load("db"; root = ROOT, env = "dev")
    # Lets the test fail in seconds instead of at its deadline: the worker's own output reaches the
    # parent only once the worker exits, so the hang cannot be read from the child's stderr.
    ccall(:jl_generating_output, Cint, ()) == 1 && PormG.ConnectionPool._reaper_started[] &&
      touch(joinpath(ROOT, "sweeper_started_while_precompiling"))
    __init__() = (PormG.Configuration.load("db"; root = ROOT, env = "dev", force = true); nothing)
    end
    """)
  script = joinpath(dir, "load1562.jl")
  write(script, """
    using Paddock1562
    import PormG
    print(PormG.ConnectionPool._reaper_started[] ? "REAPER_RUNNING" : "REAPER_OFF")
    """)
  return script
end

@testset "#1562: a package whose module-body load sets idle_timeout precompiles" begin
  # What: a scratch package (SQLite, `idle_timeout`/`max_lifetime` set) that calls
  #   `Configuration.load` in its module body and again in `__init__` precompiles in a child process,
  #   and once loaded the sweeper is running: the run-time `load` started it.
  # Why: before the fix the precompile worker waited forever ("Waiting for background task / IO /
  #   timer to finish"), because `load` → `enable_reaping!` spawned a task that never ends.
  # The child gets its own first depot, so the scratch package's cache never lands in the user's
  # depot; PormG's and SQLite's caches are found in the depots after it, built with the same flags
  # (`Base.julia_cmd()` carries the parent's). The child runs detached, in its own process group, so
  # a hang is cleaned up with the precompile worker it spawned: killing the child alone orphans it.
  # The other shape of the bug, a package depending on one whose `__init__` loads the configuration,
  # takes the same branch: the dependent's worker runs that `__init__` while generating output.
  mktempdir() do dir
    script = _write_paddock1562(dir)
    sep = Sys.iswindows() ? ";" : ":"
    depot = joinpath(dir, "depot"); mkpath(depot)
    env = copy(ENV)
    env["JULIA_DEPOT_PATH"] = join([depot; DEPOT_PATH], sep)
    env["JULIA_LOAD_PATH"] = join(["@", dir, "@stdlib"], sep)
    env["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
    out, err = joinpath(dir, "child.out"), joinpath(dir, "child.err")
    marker = joinpath(dir, "Paddock1562", "sweeper_started_while_precompiling")
    cmd = setenv(`$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) $(script)`, env)
    proc = run(pipeline(Cmd(cmd; detach = true); stdout = out, stderr = err); wait = false)
    deadline = time() + 300           # a healthy run takes seconds
    while process_running(proc) && !isfile(marker) && time() < deadline
      sleep(0.5)
    end
    timed_out = process_running(proc) && !isfile(marker)
    if process_running(proc)
      if Sys.iswindows()
        run(ignorestatus(`taskkill /T /F /PID $(getpid(proc))`))   # the tree, worker included
      else
        ccall(:kill, Cint, (Cint, Cint), -getpid(proc), Base.SIGKILL)   # the whole group
      end
      wait(proc)
    end
    # Plain Bools: a failed `@test success(proc)` would print the command, and its environment with it.
    ok = success(proc)
    compiled = joinpath(depot, "compiled", "v$(VERSION.major).$(VERSION.minor)", "Paddock1562")
    precompiled = isdir(compiled) && !isempty(readdir(compiled))
    @test !isfile(marker)
    @test !timed_out
    @test ok
    @test precompiled                 # not loaded uncompiled (`--compiled-modules=no`), which proves nothing
    @test read(out, String) == "REAPER_RUNNING"
    ok || @info "child stderr (#1562)" errtext = (isfile(err) ? read(err, String) : "")
  end
end
