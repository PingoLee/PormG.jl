## SIGTERM-at-exit repro (#1429) — does a process with statements in flight exit on SIGTERM?
##
## Usage (from the repo root), against the `db_2` PostgreSQL database:
##
##   julia --project=test/integration test/performance/sigterm_exit_repro.jl <out_dir> [n] [cells...]
##
## It is not in any suite and takes no suite lock: it holds up to `pool_size * 10` connections of
## `db_2` (30 with the committed `connection.yml`), so run it while no other session uses `db_2`.
## No table is read or written — every statement is `SELECT pg_sleep(0.05)`.
##
## For each of `n` rounds (default 20) it visits every cell, starting one cell later than the round
## before, so a slow stretch of the machine lands on all cells rather than one. A visit spawns a fresh
## `julia -t 8,1` child, waits for it to report `READY`, waits a random 0–500 ms, sends SIGTERM and
## gives the child 30 s to exit. A child still alive then is a hang: the parent saves each thread's
## `/proc/<pid>/task/*/wchan`, SIGKILLs it, and records it. (A SIGQUIT at that point prints nothing:
## once the SIGTERM exit has started, Julia's signal thread no longer handles it.) One TSV row per
## visit goes to `<out_dir>/results.tsv`, the child's output to `<out_dir>/<cell>-<round>.log`, and
## a tally is printed at the end. Linux only (`/proc`, `pipe(2)`).
##
## Every atexit hook in a child is wrapped in `MARK hook_begin <i> <name>` / `MARK hook_end <i>`
## lines written straight to fd 2 (`MARK hook_threw <i>` if it throws), and a last hook writes
## `MARK hooks_done`. The child refuses to report `READY` if a hook was registered after the wrapping;
## the compile cell, which reports `READY` before its first query, writes `MARK late_hook` if that
## query registers one. The TSV's `last_mark=` is the last mark a child wrote: a hang names the
## hook it stopped in, or, with no mark at all, shows that the exit never reached the hooks.
## `abnormal` counts children that exited with anything but code 0 or SIGTERM — a crash is not a
## clean exit.
##
## Cells (all by default):
##   libpq:on, postgres:on      16 tasks loop the statement, half inside `run_in_transaction`;
##                              PormG's exit hook is registered as shipped
##   libpq:off, postgres:off    the same with PormG's exit hook removed from `Base.atexit_hooks`
##                              — the issue's "separate the PormG part" check
##   libpq:compile              SIGTERM while the process compiles and runs its first query, with
##                              nothing else in flight — the issue's third shape
##   nodb                       no database and no PormG: 16 tasks parked in `FDWatcher` waits on
##                              pipes a writer task feeds every 50 ms — "separate the Julia part"

const DB2 = normpath(joinpath(@__DIR__, "..", "integration", "db_2"))
const ALL_CELLS = ["libpq:on", "libpq:off", "postgres:on", "postgres:off", "libpq:compile", "nodb"]
const N_TASKS = 16
const EXIT_GRACE_SECONDS = 30.0
const READY_TIMEOUT_SECONDS = 180.0

# ── child ────────────────────────────────────────────────────────────────────

# Loaded at top level, before any function below runs: the driver decides which extension loads.
const CHILD = length(ARGS) >= 2 && ARGS[1] == "--child"
if CHILD && ARGS[2] == "postgres"
  using PormG, Postgres
elseif CHILD && ARGS[2] == "libpq"
  using PormG, LibPQ
elseif CHILD
  using FileWatching
end

# A marker written straight to fd 2: the child's stderr is buffered, and a hung process never
# flushes it, so a `println` would not say how far the exit got.
mark(s::String) = (m = "MARK " * s * "\n"; ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), 2, m, sizeof(m)); nothing)

# Wraps every registered atexit hook in begin/end markers, and appends one that marks the end of
# the list, so a hung exit says which hook it stopped in. `_atexit` pops hooks from the front, so
# the order printed is the order they run.
function mark_exit_hooks!()
  hooks = Base.atexit_hooks
  for i in eachindex(hooks)
    f = hooks[i]
    name = string(parentmodule(f), ".", nameof(f))
    hooks[i] = function (code::Cint)
      mark("hook_begin $i $name")
      try
        hasmethod(f, (Cint,)) ? f(code) : f()
      catch
        mark("hook_threw $i")
        rethrow()
      end
      mark("hook_end $i")
    end
  end
  push!(hooks, () -> mark("hooks_done"))
  return length(hooks)
end

# `atexit` pushes to the front, so a hook registered after the wrapping would run first, unmarked,
# and a hang in it would read as "never reached the hooks". Checked before `READY`, not assumed.
function ready(n_hooks::Int)
  length(Base.atexit_hooks) == n_hooks || error("an atexit hook was registered after the wrapping")
  println("READY"); flush(stdout)
end

function child_db(mode::String)
  key = PormG.Configuration.load(DB2; env = "dev")
  pool = PormG.config[key].connections
  if mode == "off"
    n = length(Base.atexit_hooks)
    filter!(f -> f !== PormG.Configuration.__cleanup__, Base.atexit_hooks)
    length(Base.atexit_hooks) == n - 1 || error("PormG's exit hook was not found in Base.atexit_hooks")
  end
  n_hooks = mark_exit_hooks!()
  sql = "SELECT pg_sleep(0.05)"
  query() = PormG.ConnectionPool.fetch(pool, sql)
  mode == "compile" && ready(n_hooks)
  query()
  length(Base.atexit_hooks) == n_hooks || mark("late_hook")
  done = Threads.Atomic{Int}(0)
  for i in 1:N_TASKS
    Threads.@spawn while true
      try
        if isodd(i)
          PormG.ConnectionPool.run_in_transaction(() -> query(), pool)
        else
          query()
        end
        Threads.atomic_add!(done, 1)
      catch
        sleep(0.01)
      end
    end
  end
  mode == "compile" || (while done[] < 2 * N_TASKS; sleep(0.05); end; ready(n_hooks))
  sleep(300)   # bounded, so a child the parent failed to kill does not hold connections for long
end

function child_nodb()
  n_hooks = mark_exit_hooks!()
  for _ in 1:N_TASKS
    fds = Vector{Cint}(undef, 2)
    ccall(:pipe, Cint, (Ptr{Cint},), fds) == 0 || error("pipe failed")
    rd, wr = fds
    byte = Ref{UInt8}(0x01)
    Threads.@spawn while true
      w = FileWatching.FDWatcher(RawFD(rd), true, false)
      try
        wait(w)
      finally
        close(w)
      end
      ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), rd, byte, 1)
    end
    Threads.@spawn while true
      sleep(0.05)
      ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), wr, byte, 1)
    end
  end
  sleep(0.5)
  ready(n_hooks)
  sleep(300)
end

# ── parent ───────────────────────────────────────────────────────────────────

function child_cmd(cell::String)
  driver, mode = cell == "nodb" ? ("none", "nodb") : split(cell, ":")
  cmd = `$(Base.julia_cmd()) --startup-file=no -t 8,1 --project=$(Base.active_project()) $(@__FILE__) --child $driver $mode`
  return driver == "postgres" ? addenv(cmd, "PORMG_POSTGRES_DRIVER" => "Postgres") :
                                addenv(cmd, "PORMG_POSTGRES_DRIVER" => "LibPQ")
end

function wchan_dump(pid::Int32)
  io = IOBuffer()
  for tid in readdir("/proc/$pid/task"; join = false)
    comm = strip(read("/proc/$pid/task/$tid/comm", String))
    wchan = read("/proc/$pid/task/$tid/wchan", String)
    println(io, tid, "\t", comm, "\t", wchan)
  end
  return String(take!(io))
end

function visit(cell::String, rnd::Int, out::String)
  log = joinpath(out, "$(replace(cell, ':' => '-'))-$rnd.log")
  outcome, seconds, code, sig = "exited", NaN, -1, -1
  open(log, "w") do io
    p = run(pipeline(child_cmd(cell); stdout = io, stderr = io); wait = false)
    try
      is_ready = timedwait(() -> process_exited(p) || occursin("READY", read(log, String)),
                           READY_TIMEOUT_SECONDS; pollint = 0.1)
      if is_ready === :timed_out || process_exited(p)
        outcome = process_exited(p) ? "died_before_ready" : "not_ready"
      else
        sleep(rand() * 0.5)
        if process_exited(p)
          outcome = "died_before_term"
        else
          t0 = time()
          kill(p, Base.SIGTERM)
          exited = timedwait(() -> process_exited(p), EXIT_GRACE_SECONDS; pollint = 0.05)
          seconds = time() - t0
          if exited === :timed_out
            outcome = "HANG"
            try
              write(log * ".wchan", wchan_dump(getpid(p)))
            catch e
              write(log * ".wchan", sprint(showerror, e))
            end
          end
        end
      end
    finally
      # Also on an error or a Ctrl-C in the parent: an orphaned child keeps 16 tasks on `db_2`.
      process_exited(p) || kill(p, 9)
      wait(p)
    end
    code, sig = p.exitcode, p.termsignal
  end
  text = read(log, String)
  marks = join(filter(!isempty, [
    occursin("val already in a list", text) ? "val_in_list" : "",
    occursin("closed connections that were still checked out", text) ? "closed_leased" : "",
    let m = collect(eachmatch(r"MARK ([^\n]*)", text)); isempty(m) ? "" : "last_mark=" * m[end][1] end,
  ]), ",")
  return (; cell, round = rnd, outcome, seconds = round(seconds; digits = 2), code, sig, marks, log)
end

function main(args)
  out = args[1]
  n = length(args) >= 2 ? parse(Int, args[2]) : 20
  cells = length(args) >= 3 ? args[3:end] : ALL_CELLS
  mkpath(out)
  tsv = joinpath(out, "results.tsv")
  isfile(tsv) || write(tsv, "cell\tround\toutcome\tseconds\texitcode\ttermsignal\tmarks\tlog\n")
  rows = []
  for r in 1:n, k in 0:length(cells)-1
    cell = cells[mod1(r + k, length(cells))]
    row = visit(cell, r, out)
    push!(rows, row)
    open(tsv, "a") do io
      println(io, join((row.cell, row.round, row.outcome, row.seconds, row.code, row.sig, row.marks, row.log), '\t'))
    end
    println(row.cell, " round ", row.round, ": ", row.outcome, " (", row.seconds, " s) ", row.marks)
    flush(stdout)
  end
  println("\ncell\tvisits\thangs\tnot_ready\tabnormal")
  for cell in cells
    rs = filter(r -> r.cell == cell, rows)
    println(cell, '\t', length(rs), '\t', count(r -> r.outcome == "HANG", rs), '\t',
            count(r -> r.outcome in ("not_ready", "died_before_ready", "died_before_term"), rs), '\t',
            count(r -> r.outcome == "exited" && !(r.code == 0 && r.sig in (0, Base.SIGTERM)), rs))
  end
end

if CHILD
  ARGS[2] == "none" ? child_nodb() : child_db(ARGS[3])
else
  main(ARGS)
end
