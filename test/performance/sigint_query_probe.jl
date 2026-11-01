## Ctrl-C probe (#315) per PostgreSQL driver — does an interrupted query leave the pool usable?
##
## Usage (from the repo root), against the `db_2` PostgreSQL database:
##
##   julia --project=test/integration test/performance/sigint_query_probe.jl [rounds] [drivers...]
##
## `drivers` defaults to `LibPQ Postgres`, `rounds` to 5. It is not in any suite. No table is written,
## every child holds at most its pool (3 connections with the committed `connection.yml`), and the
## only statement it cancels is its own `pg_sleep`; still, the parent includes `common_setup.jl` and
## holds the integration suite's lock for the whole run, so a suite reseeding `db_2` meanwhile cannot
## turn a follow-up query red for a reason that is not the driver's. The children run under it
## without taking it. Linux and macOS only (it sends SIGINT to a child process).
##
## #315 was a Ctrl-C during a long query that left the pooled connection with an unread result, so
## every later query on that slot failed with "another command is already in progress". The unit
## tests in `test/unit/test_await_result_interrupt.jl` cover the pool's recovery with mocks; this is
## the same thing through a real driver and a real signal, on each driver.
##
## For each driver and round, the parent spawns a `julia -t 4` child with `PORMG_POSTGRES_DRIVER` set
## to the driver. The child turns SIGINT into an `InterruptException` (`Base.exit_on_sigint(false)`),
## loads `db_2`, runs one query on every pool slot to warm them, prints `READY` and starts a
## `pg_sleep(30)` through `ConnectionPool.fetch`. The parent waits one second, so the statement is
## on the server, and sends SIGINT. The child then reports:
##
##   interrupted — the exception `fetch` raised (`none` if the sleep ran to the end);
##   fetch s     — how long `fetch` took to raise it. About 1 s is a cancel; about 30 s is a driver
##                 that waited for the sleep to finish, which `server` alone cannot tell apart;
##   after       — `ok/n` for `pool_size + 1` concurrent ORM counts, then 3 sequential ones. The
##                 pool hands out the lowest free slot first, so the first of them takes the slot the
##                 interrupted `fetch` held; a poisoned slot fails it;
##   seen        — how many of its `pg_sleep` statements `pg_stat_activity` shows half a second
##                 before the interrupt: 1, or the `server` column proves nothing;
##   server      — how many of its `pg_sleep` statements `pg_stat_activity` still shows running one
##                 second later: 0 means the cancel reached the server.
##
## Raw SQL here is the feature under test: a statement still in flight, and the server's own view of
## it. The child prints no connection string. Its output goes to `<tmp>/<driver>-<round>.log` and
## `.err`. A round passes (`ok`) when `seen` is 1, `fetch s` is under 5, every follow-up query
## succeeds, `server` is 0 and the child exits 0; the run exits 1 when any round fails. Before #1512
## every Postgres.jl round failed on `fetch s` (about 30.5 s): the interrupt waited for the
## statement, because Reseau's wait leaves Julia's main thread outside libuv. 10/10 rounds pass since.
using UUIDs

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const INTEGRATION = joinpath(ROOT, "test", "integration")

const IS_CHILD = "--child" in ARGS
const SELF = abspath(@__FILE__)   # `common_setup.jl` changes the directory

# The child's setup is top level, so `M` and the drivers exist before `child()` is compiled.
# `using PormG` stays outside the `if`: the block's macros (`@import_models`) expand before it runs.
using PormG
if IS_CHILD
  include(joinpath(ROOT, "test", "load_drivers.jl"))
  import DataFrames   # the integration env lists it; PormG does not depend on it (#1344)
  Base.exit_on_sigint(false)
  cd(INTEGRATION)
  const KEY = PormG.Configuration.load("db_2"; env = "dev")
  PormG.@import_models "../integration/db_2/models.jl" models   # relative to this file
  import .models as M
else
  ENV["PORMG_DB"] = "db_2"
  include(joinpath(INTEGRATION, "common_setup.jl"))   # takes the suite lock, held until exit
end

function child()
  pool = PormG.config[KEY].connections
  count_query() = M.Driver.objects.filter("surname" => "Senna").count()

  marker = "probe315-$(uuid4())"
  sleep_sql = "SELECT pg_sleep(30) AS slept -- $(marker)"   # the marker is ours, never user input
  running_sql = "SELECT count(*) AS c FROM pg_stat_activity " *
                "WHERE query LIKE \$1 AND state = 'active' AND pid <> pg_backend_pid()"
  running() = Int(DataFrames.DataFrame(PormG.ConnectionPool.fetch(pool, running_sql;
                                                                 params = ["%$(marker)%"]))[1, :c])

  # Warm every slot (and compile the paths) before the interrupt.
  foreach(wait, [Threads.@spawn count_query() for _ in 1:pool.pool_size])
  running()
  println("POOL $(typeof(pool)) size=$(pool.pool_size)")
  println("READY"); flush(stdout)
  # The positive control: half a second in, the server must show the sleep running, or a 0 in
  # `server` afterwards would prove nothing.
  Threads.@spawn (sleep(0.5); println("SEEN $(running())"); flush(stdout))

  t_fetch = time()
  interrupted = try
    PormG.ConnectionPool.fetch(pool, sleep_sql)
    "none"
  catch e
    cause = e isa PormG.PormGError && hasproperty(e, :cause) ? " cause=$(nameof(typeof(e.cause)))" : ""
    "$(nameof(typeof(e)))$(cause)"
  end
  println("FETCH_S $(round(time() - t_fetch; digits = 2))")
  println("INTERRUPTED $(interrupted)"); flush(stdout)

  errors = String[]
  tasks = [Threads.@spawn count_query() for _ in 1:pool.pool_size + 1]
  results = Any[]
  for t in tasks
    try
      push!(results, fetch(t))
    catch e
      err = e isa TaskFailedException ? e.task.exception : e
      push!(errors, string(nameof(typeof(err))))
    end
  end
  for _ in 1:3
    try
      push!(results, count_query())
    catch e
      push!(errors, string(nameof(typeof(e))))
    end
  end
  n = pool.pool_size + 4
  println("AFTER $(n - length(errors))/$(n) errors=$(isempty(errors) ? "none" : join(unique(errors), ","))")
  sleep(1.0)
  println("SERVER $(running())"); flush(stdout)
end

function run_one(driver::String, round::Int, logdir::String)
  env = copy(ENV)
  env["PORMG_POSTGRES_DRIVER"] = driver
  env["PORMG_DB"] = "db_2"
  cmd = setenv(`$(Base.julia_cmd()) -t 4 --project=$(INTEGRATION) $(SELF) --child`, env)
  log = joinpath(logdir, "$(driver)-$(round).log")
  out = Pipe()
  proc = run(pipeline(cmd; stdout = out, stderr = joinpath(logdir, "$(driver)-$(round).err")); wait = false)
  close(out.in)
  lines = String[]
  reader = @async for line in eachline(out)
    push!(lines, line)
    open(io -> println(io, line), log, "a")
  end
  deadline = time() + 600
  while !any(==("READY"), lines) && process_running(proc) && time() < deadline
    sleep(0.1)
  end
  any(==("READY"), lines) || (kill(proc); wait(reader);
                              return (; driver, round, pool = "-", seen = "-", fetch_s = "-",
                                      interrupted = "no READY", after = "-", server = "-",
                                      exit = "see $(log)", ok = false))
  sleep(1.0)
  kill(proc, Base.SIGINT)
  t0 = time()
  while process_running(proc) && time() - t0 < 120
    sleep(0.1)
  end
  process_running(proc) && kill(proc, Base.SIGKILL)
  wait(proc); wait(reader)
  field(prefix) = (i = findfirst(l -> startswith(l, prefix * " "), lines);
                   i === nothing ? "missing" : lines[i][length(prefix)+2:end])
  seen, fetch_s, after, server = field("SEEN"), field("FETCH_S"), field("AFTER"), field("SERVER")
  ok = seen == "1" && something(tryparse(Float64, fetch_s), Inf) < 5 &&
       endswith(after, "errors=none") && server == "0" && proc.exitcode == 0
  return (; driver, round, pool = field("POOL"), seen, fetch_s, interrupted = field("INTERRUPTED"), after,
          server, exit = string(proc.exitcode), ok)
end

function parent(args)
  rounds = isempty(args) ? 5 : parse(Int, args[1])
  drivers = length(args) > 1 ? args[2:end] : ["LibPQ", "Postgres"]
  logdir = mktempdir(; cleanup = false)
  println("logs: $(logdir)")
  println()
  println("| driver | round | seen | fetch s | interrupted | after | server | exit | result |")
  println("|---|---:|---:|---:|---|---|---:|---:|---|")
  pools = Set{String}()
  passed = 0
  for r in 1:rounds, d in (isodd(r) ? drivers : reverse(drivers))
    row = run_one(d, r, logdir)
    passed += row.ok
    push!(pools, "$(d): $(row.pool)")
    println("| $(row.driver) | $(row.round) | $(row.seen) | $(row.fetch_s) | $(row.interrupted) | $(row.after) | ",
            "$(row.server) | $(row.exit) | $(row.ok ? "ok" : "FAIL") |")
    flush(stdout)
  end
  println()
  foreach(p -> println("pool — ", p), sort!(collect(pools)))
  println("ok $(passed)/$(rounds * length(drivers))")
  return passed == rounds * length(drivers)
end

if IS_CHILD
  child()
else
  parent(ARGS) || exit(1)   # a FAIL round fails the run, so a fix to #1512 can be checked by `$?`
end
