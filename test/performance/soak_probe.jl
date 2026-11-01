## Soak probe per PostgreSQL driver — reaping, leak detection, a restart and network blips (#1072)
##
## Usage (from the repo root), against the `db_2` PostgreSQL database:
##
##   julia --project=test/integration test/performance/soak_probe.jl [minutes] [drivers...]
##
## `minutes` is the soak length per driver (default 10, at least 3); `drivers` defaults to
## `LibPQ Postgres`, run one after the other. It is not in any suite. The parent includes
## `common_setup.jl` and holds the integration suite's lock for the whole run (`minutes` plus about a
## minute per driver), so a suite reseeding `db_2` meanwhile queues instead of failing an operation
## for a reason that is not the driver's. Linux and macOS.
##
## What it soaks. For each driver the parent starts a TCP proxy on `127.0.0.1` in front of db_2 and a
## `julia -t 4` child whose only route to the server is that proxy. The child's `connection.yml` is
## the committed one with the host and port pointing at the proxy, `postgres_driver` set, and the
## pool features #1072 asks for switched on: `idle_timeout` and `max_lifetime` (#125),
## `leak_detection_threshold` (#127), plus an `application_name` of its own, `pormg-soak-<uuid>`,
## which is how the server-side checks find its sessions and nobody else's. `2 × pool_size` tasks then
## run F1 reads and writes through the ORM for the whole soak — `list()`, `count()`, `DataFrame(q)`,
## and a `create` + `delete` on `Bulk_copy_fidelity_scratch` — so the pool grows past its base size,
## which is the only part the reaper may retire.
##
## The parent injects the faults on a schedule that scales with `minutes` (`plan` below):
##
##   cut       — the proxy closes every connection: each driver sees its socket end.
##   blip      — the proxy stops forwarding in both directions for a few seconds, sockets open, then
##               resumes: a network blip that heals.
##   restart   — `cut`, then the proxy refuses new connections for a few seconds: a server restart as
##               the client sees it.
##   terminate — `pg_terminate_backend` on the child's own sessions (by `application_name`, from the
##               parent's direct connection): SQLSTATE 57P01, the #1042 retry-safe path.
##   idle      — the child stops its workload; the reaper must retire the overflow connections.
##   half-open — the proxy stops forwarding for longer, then `cut`: a blip that never heals.
##
## What the proxy cannot do: drop packets below TCP. It stops copying bytes, but the kernel on each
## side still acknowledges them, so TCP keepalives (which LibPQ honours and Postgres.jl ignores) are
## never exercised here. The blip and half-open rows measure how long each driver waits for an answer
## that is not coming, not how fast keepalives notice a dead peer; that needs real packet loss
## (`iptables -j DROP`), the app soak's job. Every fault touches only the child's connections: the
## proxy carries nothing else, and `terminate` filters by the child's own `application_name`.
##
## Pass rules, per driver (the run exits 1 when any driver fails one):
##
##   steady     — no operation fails outside a fault window (+ 10 s);
##   types      — inside one, only `OperationalError`, `PoolTimeoutError` or `PoolConnectError`;
##   recovery   — after each fault ends, an operation succeeds within 10 s;
##   stranded   — no caller waits for a connection while none is leased, outside the restart window:
##                nothing would ever be released to wake it, so it waits out `pool_timeout`;
##   reaper     — the pool grew past `pool_size` before the idle window and retired a connection in it;
##   leaks      — leak warnings only inside a fault window (+ the threshold + 10 s);
##   final      — every connection returned (`in_use == 0`), the server holds no more of the child's
##                sessions than the pool has open, and every one of them is `idle` (not running a
##                statement, not left in a transaction);
##   control    — each fault reached at least one of the child's connections, and the server showed
##                the child's sessions at least once: a fault that reached nothing proves nothing.
##
## Two of them fail on `main` when the probe lands, each with its issue. `types` fails on every LibPQ
## run: LibPQ reports a closed socket as `StatementError` (#1519). `stranded` fails on some runs of
## either driver, more often at the default 10 minutes, whose restart refuses connects for 15 s
## (#1518, in core): whether every caller ends up parked depends on how the failed connects interleave.
##
## Reported, not gated: the longest operation in each window (how long a driver waits on a dead
## socket), throughput, and the child's live Julia heap after a full GC against the end of the warm-up.
##
## Raw SQL here is the feature under test: the server's own view of the child's sessions, and the
## `pg_terminate_backend` fault. The child never learns the real server's host or port, only the
## proxy's. Its config file, which holds the password, is written mode 0600 inside a temporary
## directory removed before the child is stopped. The run prints exception type names only. The kept
## log directory also holds `errors-<driver>.txt`, the first stack trace of each kind with the driver's
## cause passed through `redact_secret`, and `<driver>.err`, PormG's own warnings, which redact the
## connection string themselves.
## Every scratch row carries a `name` starting with `soak1072`, and the parent deletes only those rows,
## before and after each driver.
using Sockets, UUIDs, Dates, Printf, Logging

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const INTEGRATION = joinpath(ROOT, "test", "integration")
const IS_CHILD = "--child" in ARGS
const SELF = abspath(@__FILE__)   # `common_setup.jl` changes the directory
const PREFIX = "soak1072"
const WHEN = DateTime(2021, 9, 12, 13, 0, 0)   # the 2021 Italian Grand Prix start, UTC
const POOL_SIZE = 3
const POOL_TIMEOUT = 10.0
const GRACE = 10.0                               # seconds after a fault before "steady" applies again
const ALLOWED = ("OperationalError", "PoolTimeoutError", "PoolConnectError")

# The fault schedule, in seconds from the child's READY, for a soak of `D` seconds. The child reads it
# too: its idle window and its pool settings come from here.
function plan(D::Float64)
  blip = clamp(D / 30, 5.0, 20.0)
  (; D,
     cut_at = 0.10D,
     blip_at = 0.20D, blip_s = blip,
     restart_at = 0.32D, refuse_s = clamp(D / 40, 5.0, 15.0),
     terminate_at = 0.45D,
     idle_from = 0.55D, idle_to = 0.75D,
     halfopen_at = 0.80D, halfopen_s = clamp(0.075D, 10.0, 45.0),
     idle_timeout = max(5.0, D / 20),
     max_lifetime = max(30.0, D / 4),
     leak_s = 5.0)
end

using PormG
if IS_CHILD
  include(joinpath(ROOT, "test", "load_drivers.jl"))
  import DataFrames   # the integration env lists it; PormG does not depend on it (#1344)
  const _i = findfirst(==("--child"), ARGS)
  const CONF_ROOT, DRIVER, LOGDIR = ARGS[_i + 1], ARGS[_i + 3], ARGS[_i + 4]
  const SOAK_S = parse(Float64, ARGS[_i + 2])
  const KEY = PormG.Configuration.load("db_2"; root = CONF_ROOT, env = "dev")
  const M = PormG.import_models(joinpath(CONF_ROOT, "db_2", "models.jl"); into = Module(:Soak))
else
  ENV["PORMG_DB"] = "db_2"
  include(joinpath(INTEGRATION, "common_setup.jl"))   # takes the suite lock, held until exit
end

# ── Child: the workload ──────────────────────────────────────────────────────────────────────────────

# Records each leak-detection warning (#127) with its time, then hands every record to the console.
# The logging macros already asked `shouldlog` of this logger, so the record is forwarded as it is:
# a logger that throws here throws out of PormG's own `@warn`, mid-cleanup.
struct LeakCounter <: AbstractLogger
  inner::AbstractLogger
  times::Vector{Float64}
  lock::ReentrantLock
end
Logging.min_enabled_level(l::LeakCounter) = Logging.min_enabled_level(l.inner)
Logging.shouldlog(l::LeakCounter, args...) = true
Logging.catch_exceptions(::LeakCounter) = true
function Logging.handle_message(l::LeakCounter, level, message, args...; kwargs...)
  if level == Logging.Warn && message isa AbstractString && startswith(message, "Pool connection held past leak_detection_threshold")
    Base.lock(() -> push!(l.times, time()), l.lock)
  end
  Logging.handle_message(l.inner, level, message, args...; kwargs...)
end

# The exception's type name and, for a PormG error carrying one, its cause's. Never the message.
function _err_names(e)::Tuple{String, String}
  e isa TaskFailedException && return _err_names(e.task.exception)
  e isa CompositeException && !isempty(e.exceptions) && return _err_names(first(e.exceptions))
  cause = hasfield(typeof(e), :cause) ? getfield(e, :cause) : nothing
  return (string(nameof(typeof(e))), cause isa Exception ? string(nameof(typeof(cause))) : "")
end

_op_list() = M.Result.objects.filter("driverid__surname" => "Senna").values("points", "raceid__year").list()
_op_count() = M.Driver.objects.filter("surname" => "Senna").count()
_op_frame() = DataFrames.DataFrame(M.Race.objects.filter("year" => 1991).values("raceid", "name"))
function _op_write(task::Int)
  row = M.Bulk_copy_fidelity_scratch.objects.create("name" => "$(PREFIX) $(task)", "amount" => 1.5,
                                                     "active" => true, "event_time" => WHEN)
  M.Bulk_copy_fidelity_scratch.objects.filter("id" => row[:id]).delete()
end

function _run_op(op::Symbol, task::Int)
  op === :list  && return _op_list()
  op === :count && return _op_count()
  op === :frame && return _op_frame()
  return _op_write(task)
end

const OPS = (:list, :count, :frame, :write)

function child()
  p = plan(SOAK_S)
  pool = PormG.config[KEY].connections
  leaks = LeakCounter(global_logger(), Float64[], ReentrantLock())
  global_logger(leaks)

  # Compile every operation and open the base slots before READY.
  for op in OPS
    _run_op(op, 0)
  end
  foreach(wait, [Threads.@spawn _op_count() for _ in 1:POOL_SIZE])
  println("POOL $(typeof(pool)) size=$(pool.pool_size)")

  events = open(joinpath(LOGDIR, "events-$(DRIVER).csv"), "w")
  samples = open(joinpath(LOGDIR, "samples-$(DRIVER).csv"), "w")
  println(events, "t_start,t_end,task,op,ok,err,cause")
  println(samples, "t,size,in_use,materialized,waiting,live_mb")
  ev_lock = ReentrantLock()
  traces = open(joinpath(LOGDIR, "errors-$(DRIVER).txt"), "w")
  traced = Set{Tuple{String, String, Symbol}}()

  GC.gc(true)
  println("WARM live_mb=$(round(Base.gc_live_bytes() / 2^20; digits = 1))")
  t0 = time()
  println("READY $(t0)"); flush(stdout)
  t_end = t0 + p.D
  idle(t) = t0 + p.idle_from <= t < t0 + p.idle_to

  sampler = Threads.@spawn while time() < t_end
    s = PormG.ConnectionPool.pool_stats(pool)
    materialized = Base.lock(() -> count(!isnothing, pool.connections), pool.lock)
    @printf(samples, "%.3f,%d,%d,%d,%d,%.1f\n", time(), s.size, s.in_use, materialized, s.waiting,
            Base.gc_live_bytes() / 2^20)
    flush(samples)
    sleep(1.0)
  end

  tasks = map(1:2POOL_SIZE) do task
    Threads.@spawn begin
      k = task
      while time() < t_end
        if idle(time())
          sleep(0.5)
          continue
        end
        op = OPS[mod1(k, length(OPS))]
        k += 1
        ts = time()
        ok, err, cause = try
          _run_op(op, task)
          (true, "", "")
        catch e
          names = _err_names(e)
          Base.lock(ev_lock) do
            if (names..., op) ∉ traced   # the first of each kind, for a human reading the logs
              push!(traced, (names..., op))
              println(traces, "── $(op) at $(round(time() - t0; digits = 1)) s: $(names[1]) $(names[2])")
              showerror(traces, e, catch_backtrace())
              inner = hasfield(typeof(e), :cause) ? getfield(e, :cause) : nothing
              inner isa Exception &&   # a driver error can quote the connection string
                print(traces, "\ncause: ", PormG.ConnectionPool._redacted_cause(inner))
              println(traces, "\n"); flush(traces)
            end
          end
          (false, names...)
        end
        te = time()
        Base.lock(ev_lock) do
          @printf(events, "%.3f,%.3f,%d,%s,%d,%s,%s\n", ts, te, task, op, ok, err, cause)
        end
        ok || sleep(0.2)   # a failing operation does not spin
      end
    end
  end
  foreach(wait, tasks)
  wait(sampler)

  # Every lease must come back on its own; give a stuck one 30 s before reporting it.
  deadline = time() + 30
  while PormG.ConnectionPool.pool_stats(pool).in_use > 0 && time() < deadline
    sleep(0.2)
  end
  Base.lock(ev_lock) do
    foreach(t -> @printf(events, "%.3f,%.3f,0,leakwarn,1,,\n", t, t), leaks.times)
  end
  close(events); close(samples); close(traces)
  GC.gc(true)
  s = PormG.ConnectionPool.pool_stats(pool)
  materialized = Base.lock(() -> count(!isnothing, pool.connections), pool.lock)
  println("FINAL in_use=$(s.in_use) size=$(s.size) materialized=$(materialized) ",
          "live_mb=$(round(Base.gc_live_bytes() / 2^20; digits = 1))")
  flush(stdout)
  readline(stdin)   # the parent counts the server's sessions while the pool is still open
end

# ── Parent: the proxy ────────────────────────────────────────────────────────────────────────────────

# A byte-copying TCP proxy. `stalled` holds every byte read until it clears; `cut!` closes every
# connection; `restart!` closes the listener, cuts, and listens again after a while, so a connect is
# refused as during a server restart.
mutable struct Proxy
  const host::String          # the real server; never printed
  const port::Int
  const listen_port::Int
  server::Sockets.TCPServer
  const pairs::Vector{Tuple{TCPSocket, TCPSocket}}
  const lock::ReentrantLock
  const stalled::Threads.Atomic{Bool}
  const cuts::Threads.Atomic{Int}   # bumped by every `cut!`: a bridge still connecting upstream
end                                 # when one happens closes itself rather than survive it

# `reuseaddr`: the proxy closes the connections it accepted, which leaves them in TIME_WAIT on its own
# port, and Linux refuses to bind that port again without it.
function _listen(port::Integer)
  server = Sockets.TCPServer()
  bind(server, ip"127.0.0.1", port; reuseaddr = true) || error("soak_probe: the proxy could not bind 127.0.0.1")
  listen(server)
  return server
end

function Proxy(host::String, port::Int)
  server = _listen(0)
  _, listen_port = getsockname(server)
  p = Proxy(host, port, Int(listen_port), server, Tuple{TCPSocket, TCPSocket}[], ReentrantLock(),
            Threads.Atomic{Bool}(false), Threads.Atomic{Int}(0))
  _serve!(p, server)
  return p
end

function _serve!(p::Proxy, server::Sockets.TCPServer)
  errormonitor(@async while true
    client = try
      accept(server)
    catch
      return   # the listener was closed (`restart!`, or the end of the run)
    end
    errormonitor(@async _bridge!(p, client))
  end)
  return nothing
end

function _bridge!(p::Proxy, client::TCPSocket)
  generation = p.cuts[]
  upstream = try
    connect(p.host, p.port)
  catch
    close(client)
    return
  end
  pair = (client, upstream)
  cut_meanwhile = Base.lock(p.lock) do
    p.cuts[] == generation || return true
    push!(p.pairs, pair)
    return false
  end
  cut_meanwhile && (close(client); close(upstream); return)
  a = @async _pump(p, client, upstream)
  b = @async _pump(p, upstream, client)
  wait(a); wait(b)
  Base.lock(() -> filter!(x -> x !== pair, p.pairs), p.lock)
  return nothing
end

function _pump(p::Proxy, src::TCPSocket, dst::TCPSocket)
  try
    while !eof(src)
      data = readavailable(src)
      while p.stalled[] && isopen(dst)
        sleep(0.05)
      end
      write(dst, data)
    end
  catch
    # a closed socket on either side ends the pair
  finally
    close(src); close(dst)
  end
  return nothing
end

function cut!(p::Proxy)
  pairs = Base.lock(p.lock) do
    Threads.atomic_add!(p.cuts, 1)
    copy(p.pairs)
  end
  foreach(((a, b),) -> (close(a); close(b)), pairs)
  return length(pairs)
end

# Close the listener before cutting, so no driver reconnects in between.
function restart!(p::Proxy, seconds::Float64)
  close(p.server)
  n = cut!(p)
  sleep(seconds)
  for attempt in 1:50
    try
      p.server = _listen(p.listen_port)
      _serve!(p, p.server)
      return n
    catch
      sleep(0.1)
    end
  end
  error("soak_probe: the proxy could not listen again on its own port")
end

function stall!(p::Proxy, seconds::Float64)
  p.stalled[] = true
  sleep(seconds)
  p.stalled[] = false
  return nothing
end

function close_proxy!(p::Proxy)
  close(p.server)
  p.stalled[] = false
  cut!(p)
  return nothing
end

# ── Parent: one driver ───────────────────────────────────────────────────────────────────────────────

const PG = PormG.config["db_2"]

_db_setting(k) = get(PG.db_config_settings, k, nothing)

# The child's connection.yml: the committed settings, through the proxy, with the pool features on.
function write_child_config(conf_root::String, driver::String, proxy::Proxy, app::String, p)
  for k in ("database", "username")
    _db_setting(k) === nothing && error("soak_probe: db_2/connection.yml must name `$(k)`")
  end
  PormG.Configuration._is_unset(_db_setting("url")) ||
    error("soak_probe: db_2/connection.yml must use `host:`/`port:` keys, not `url:` (the probe rewrites the host)")
  _db_setting("hostaddr") === nothing ||
    error("soak_probe: db_2/connection.yml sets `hostaddr`, which would bypass the proxy")
  parts = ["host=127.0.0.1", "port=$(proxy.listen_port)", "application_name=$(app)"]
  # Every other key the PostgreSQL builder reads (`_build_connection_pool!`), so the child connects
  # as the suite does.
  for (k, as) in (("database", "dbname"), ("username", "user"), ("password", "password"),
                  ("passfile", "passfile"), ("connect_timeout", "connect_timeout"),
                  ("client_encoding", "client_encoding"), ("sslmode", "sslmode"),
                  ("sslrootcert", "sslrootcert"), ("sslcert", "sslcert"), ("sslkey", "sslkey"))
    v = _db_setting(k)
    v === nothing || push!(parts, "$(as)=$(PormG.Configuration._conninfo_value(k, v))")
  end
  sslmode = _db_setting("sslmode")
  sslmode in ("verify-full",) &&
    error("soak_probe: db_2 uses sslmode=verify-full, which cannot verify the server through a proxy on 127.0.0.1")
  url = replace(join(parts, " "), "'" => "''")   # YAML single-quoted scalar
  dir = joinpath(conf_root, "db_2")
  mkpath(dir)
  cp(joinpath(INTEGRATION, "db_2", "models.jl"), joinpath(dir, "models.jl"))
  file = joinpath(dir, "connection.yml")
  touch(file); chmod(file, 0o600)
  open(file, "w") do io
    println(io, "env: dev")
    println(io, "dev:")
    println(io, "  adapter: PostgreSQL")
    println(io, "  url: '", url, "'")
    println(io, "  postgres_driver: ", driver)
    println(io, "  pool_size: ", POOL_SIZE)
    println(io, "  pool_timeout: ", POOL_TIMEOUT)
    println(io, "  idle_timeout: ", p.idle_timeout)
    println(io, "  max_lifetime: ", p.max_lifetime)
    println(io, "  leak_detection_threshold: ", p.leak_s)
    println(io, "  config:")
    println(io, "    change_db: false")
    println(io, "    change_data: true")
    println(io, "    time_zone: 'America/Sao_Paulo'")
  end
  return nothing
end

# `busy` is every state but `idle`: a session left `idle in transaction` is as wrong at the end as one
# still running a statement.
const SESSIONS_SQL = "SELECT count(*) AS total, count(*) FILTER (WHERE state <> 'idle') AS active " *
                     "FROM pg_stat_activity WHERE application_name = \$1"
const TERMINATE_SQL = "SELECT count(pg_terminate_backend(pid)) AS n FROM pg_stat_activity " *
                      "WHERE application_name = \$1"

function server_sessions(app::String)
  df = DataFrame(PormG.ConnectionPool.fetch(PG.connections, SESSIONS_SQL; params = [app]))
  return (total = Int(df[1, :total]), active = Int(df[1, :active]))
end

terminate_sessions!(app::String) =
  Int(DataFrame(PormG.ConnectionPool.fetch(PG.connections, TERMINATE_SQL; params = [app]))[1, :n])

clear_scratch!() = (q = M.Bulk_copy_fidelity_scratch.objects.filter("name__@startswith" => PREFIX);
                    q.exists() && q.delete(); nothing)

_sleep_until(t) = (d = t - time(); d > 0 && sleep(d); nothing)

function run_faults!(proxy::Proxy, app::String, t0::Float64, p)
  # `hits` is the positive control: how many of the child's connections the fault reached. A fault
  # that reached none proves nothing, so `analyze` fails it.
  windows = NamedTuple{(:name, :s, :e, :hits), Tuple{String, Float64, Float64, Int}}[]
  record(name, s, hits) = push!(windows, (name = name, s = s, e = time(), hits = hits))
  carried() = Base.lock(() -> length(proxy.pairs), proxy.lock)

  _sleep_until(t0 + p.cut_at)
  s = time(); record("cut", s, cut!(proxy))

  _sleep_until(t0 + p.blip_at)
  s = time(); n = carried(); stall!(proxy, p.blip_s); record("blip", s, n)

  _sleep_until(t0 + p.restart_at)
  s = time(); record("restart", s, restart!(proxy, p.refuse_s))

  _sleep_until(t0 + p.terminate_at)
  s = time(); record("terminate", s, terminate_sessions!(app))

  _sleep_until(t0 + p.halfopen_at)
  s = time(); proxy.stalled[] = true; sleep(p.halfopen_s); n = cut!(proxy); proxy.stalled[] = false
  record("half-open", s, n)
  return windows
end

function read_csv(file::String)
  lines = readlines(file)
  header = Symbol.(split(first(lines), ','))
  return [NamedTuple{Tuple(header)}(Tuple(split(l, ','; limit = length(header)))) for l in lines[2:end]]
end

_f(x) = parse(Float64, x)

function analyze(driver::String, logdir::String, windows, t0::Float64, p, final::Dict{String, Float64},
                 server, server_series, warm_mb::Float64)
  rows = read_csv(joinpath(logdir, "events-$(driver).csv"))
  samples = read_csv(joinpath(logdir, "samples-$(driver).csv"))
  ops = filter(r -> r.op != "leakwarn", rows)
  leakwarns = [_f(r.t_start) for r in rows if r.op == "leakwarn"]
  in_fault(ts, te; grace = GRACE) = any(w -> ts <= w.e + grace && te >= w.s, windows)

  failures = String[]
  steady_fail = [r for r in ops if r.ok == "0" && !in_fault(_f(r.t_start), _f(r.t_end))]
  isempty(steady_fail) || push!(failures, "steady: $(length(steady_fail)) failed outside a fault " *
                                "($(join(unique(r.err for r in steady_fail), ", ")))")
  odd = [r for r in ops if r.ok == "0" && in_fault(_f(r.t_start), _f(r.t_end)) && !(r.err in ALLOWED)]
  isempty(odd) || push!(failures, "types: $(join(unique("$(r.err)/$(r.cause)" for r in odd), ", "))")

  println()
  println("| window | start s | length s | reached | ops | failed | failed as | recovery s | longest op s |")
  println("|---|---:|---:|---:|---:|---:|---|---:|---:|")
  for w in windows
    w.hits > 0 || push!(failures, "control: the $(w.name) fault reached none of the child's connections")
    mine = [r for r in ops if _f(r.t_start) <= w.e && _f(r.t_end) >= w.s]
    failed = [r for r in mine if r.ok == "0"]
    after = [_f(r.t_end) for r in ops if r.ok == "1" && _f(r.t_start) >= w.e]
    recovery = isempty(after) ? Inf : minimum(after) - w.e
    recovery <= GRACE || push!(failures, "recovery: $(w.name) took $(round(recovery; digits = 1)) s")
    longest = isempty(mine) ? 0.0 : maximum(_f(r.t_end) - _f(r.t_start) for r in mine)
    kinds = isempty(failed) ? "-" : join(sort(unique("$(r.err)" * (isempty(r.cause) ? "" : "($(r.cause))")
                                                       for r in failed)), ", ")
    @printf("| %s | %.0f | %.1f | %d | %d | %d | %s | %.2f | %.2f |\n", w.name, w.s - t0, w.e - w.s,
            w.hits, length(mine), length(failed), kinds, recovery, longest)
  end
  steady = [r for r in ops if !in_fault(_f(r.t_start), _f(r.t_end))]
  steady_longest = isempty(steady) ? 0.0 : maximum(_f(r.t_end) - _f(r.t_start) for r in steady)
  @printf("| steady (the rest) | | | | %d | %d | %s | | %.2f |\n", length(steady), length(steady_fail),
          isempty(steady_fail) ? "-" : "see above", steady_longest)

  # The reaper (#125) retires only overflow slots, so the pool must have grown first.
  at(t) = samples[argmin([abs(_f(s.t) - t) for s in samples])]
  idle_start = parse(Int, at(t0 + p.idle_from).materialized)
  idle_min = minimum(parse(Int, s.materialized) for s in samples
                     if t0 + p.idle_from <= _f(s.t) < t0 + p.idle_to)
  if idle_start <= POOL_SIZE
    push!(failures, "reaper: the pool never grew past pool_size=$(POOL_SIZE) before the idle window")
  elseif idle_min >= idle_start
    push!(failures, "reaper: retired nothing in the idle window ($(idle_start) open)")
  end

  # Callers parked while no connection is leased: nothing will ever be released to wake them, so
  # they wait out `pool_timeout`. Expected only while the server is unreachable (the restart window);
  # one sample of slack for the sampler's own timing.
  restart = only(w for w in windows if w.name == "restart")
  stranded = [s for s in samples if parse(Int, s.waiting) > 0 && parse(Int, s.in_use) == 0 &&
                                   !(restart.s <= _f(s.t) <= restart.e)]
  length(stranded) <= 1 || push!(failures, "stranded: callers waited with no connection leased for " *
                                 "$(length(stranded)) s while the server was reachable")

  late = [t for t in leakwarns if !in_fault(t, t; grace = GRACE + p.leak_s)]
  isempty(late) || push!(failures, "leaks: $(length(late)) leak warning(s) outside a fault window")

  peak = maximum(x -> x.total, server_series; init = 0)
  peak > 0 || push!(failures, "control: the server never showed a session named $(repr(app))")
  final["in_use"] == 0 || push!(failures, "final: $(Int(final["in_use"])) connection(s) never returned")
  server.total <= final["materialized"] ||
    push!(failures, "final: the server holds $(server.total) session(s) for $(Int(final["materialized"])) open connection(s)")
  server.active == 0 || push!(failures, "final: $(server.active) session(s) not idle (running, or in a transaction)")

  ok_ops = count(r -> r.ok == "1", ops)
  println()
  @printf("ops %d (%d failed), %.0f ops/s overall; leak warnings %d; reaper %d → %d open in the idle window\n",
          length(ops), length(ops) - ok_ops, ok_ops / p.D, length(leakwarns), idle_start, idle_min)
  @printf("pool at the end: %d open, %d in use; server: %d session(s), %d not idle; most sessions seen: %d\n",
          Int(final["materialized"]), Int(final["in_use"]), server.total, server.active, peak)
  @printf("live heap after a full GC: %.1f MiB after the warm-up, %.1f MiB at the end\n",
          warm_mb, final["live_mb"])
  println(isempty(failures) ? "PASS" : "FAIL — " * join(failures, "; "))
  return isempty(failures)
end

function _wait_exit(proc, seconds::Float64)::Bool
  deadline = time() + seconds
  while process_running(proc) && time() < deadline
    sleep(0.1)
  end
  return !process_running(proc)
end

function run_driver(driver::String, minutes::Float64, logdir::String)
  p = plan(60minutes)
  app = "pormg-soak-$(string(uuid4())[1:8])"
  host = _db_setting("host")
  host === nothing && error("soak_probe: db_2/connection.yml must name `host`")
  port = something(tryparse(Int, string(something(_db_setting("port"), 5432))), 5432)
  proxy = Proxy(string(host), port)
  conf_root = mktempdir()
  write_child_config(conf_root, driver, proxy, app, p)
  clear_scratch!()

  println("\n## $(driver) — $(minutes) min, pool_size $(POOL_SIZE), $(2POOL_SIZE) tasks")
  env = copy(ENV)
  env["PORMG_POSTGRES_DRIVER"] = driver
  delete!(env, "PORMG_ENV")
  cmd = setenv(`$(Base.julia_cmd()) -t 4 --project=$(INTEGRATION) $(SELF) --child $(conf_root) $(60minutes) $(driver) $(logdir)`, env)
  out, inp = Pipe(), Pipe()
  proc = run(pipeline(cmd; stdin = inp, stdout = out, stderr = joinpath(logdir, "$(driver).err")); wait = false)
  close(out.in); close(inp.out)
  lines = Channel{String}(Inf)
  reader = @async for line in eachline(out)
    put!(lines, line)
    open(io -> println(io, line), joinpath(logdir, "$(driver).log"), "a")
  end
  warm_mb = NaN
  next_line(prefix, timeout) = begin
    deadline = time() + timeout
    while time() < deadline
      if isready(lines)
        l = take!(lines)
        startswith(l, prefix) && return l
        startswith(l, "POOL") && println("  ", l)
        startswith(l, "WARM live_mb=") && (warm_mb = parse(Float64, l[length("WARM live_mb=")+1:end]))
      elseif !process_running(proc)
        return nothing
      else
        sleep(0.1)
      end
    end
    return nothing
  end

  ok = false
  try
    ready = next_line("READY", 900)
    ready === nothing && (println("FAIL — the child never reported READY; see $(logdir)/$(driver).err"); return false)
    t0 = parse(Float64, split(ready)[2])

    server_series = NamedTuple{(:t, :total, :active), Tuple{Float64, Int, Int}}[]
    watcher = @async while process_running(proc) && time() < t0 + p.D
      s = try server_sessions(app) catch; nothing end
      s === nothing || push!(server_series, (t = time(), total = s.total, active = s.active))
      sleep(5.0)
    end
    windows = run_faults!(proxy, app, t0, p)

    fin = next_line("FINAL", p.D + 120)
    fin === nothing && (println("FAIL — the child never reported FINAL; see $(logdir)/$(driver).err"); return false)
    final = Dict(String(k) => parse(Float64, v) for (k, v) in (split(kv, '=') for kv in split(fin)[2:end]))
    sleep(1.0)
    server = server_sessions(app)
    println(inp, "done"); close(inp)
    wait(watcher)
    ok = analyze(driver, logdir, windows, t0, p, final, server, server_series, warm_mb)
  finally
    # The proxy and the config holding the password go first: a child that will not exit must not
    # keep either. Then SIGTERM, and SIGKILL if that hangs too (#1429 is a SIGTERM-at-exit hang).
    close_proxy!(proxy)
    rm(conf_root; recursive = true, force = true)
    _wait_exit(proc, 10.0) || (kill(proc); _wait_exit(proc, 10.0) || kill(proc, Base.SIGKILL))
    wait(proc); wait(reader)
    clear_scratch!()
  end
  proc.exitcode == 0 || println("child exit code $(proc.exitcode)")
  return ok && proc.exitcode == 0
end

function parent(args)
  minutes = isempty(args) ? 10.0 : parse(Float64, args[1])
  minutes >= 3 || error("soak_probe: a soak shorter than 3 minutes leaves no room for the idle window")
  drivers = length(args) > 1 ? args[2:end] : ["LibPQ", "Postgres"]
  logdir = mktempdir(; cleanup = false)
  commit = try readchomp(`git -C $(ROOT) describe --always --dirty`) catch; "unknown" end
  println("soak_probe — commit $(commit), Julia $(VERSION), logs: $(logdir)")
  results = [d => run_driver(d, minutes, logdir) for d in drivers]
  println()
  foreach(((d, ok),) -> println("$(d): $(ok ? "PASS" : "FAIL")"), results)
  return all(last, results)
end

if IS_CHILD
  child()
else
  parent(ARGS) || exit(1)
end
