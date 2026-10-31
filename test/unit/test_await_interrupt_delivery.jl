# ============================================================
# test/unit/test_await_interrupt_delivery.jl
#
# A Ctrl-C reaches a task awaiting a driver handle while the statement runs (#1512).
#
# CONTRACT being tested:
#   Julia throws a SIGINT into thread 1 at once only while thread 1 is parked in libuv's I/O wait.
#   Otherwise the interrupt stays pending until thread 1 next runs Julia code. LibPQ waits on its
#   socket through an `FDWatcher`, so it meets that condition. Postgres.jl polls on Reseau's own
#   thread, and the SQLite handle waits on a `Channel` for the global worker, so an idle
#   thread 1 slept through the signal and Ctrl-C arrived only when the statement finished: 30.5 s
#   for a `pg_sleep(30)` under Postgres.jl, where LibPQ took 1.3 s. The #315 recovery that cancels
#   the statement never ran while it was in flight.
#
#   `ConnectionPool._fetch_interruptible` holds a `Timer` across the wait, which keeps libuv's loop
#   alive. Every await on a driver handle goes through it.
#
# Hermetic: no database. The driver is stood in for by a task that blocks outside libuv (a GC-safe
# `usleep` on another thread), which is the property that matters. The live check is
# `test/performance/sigint_query_probe.jl` against `db_2`.
#
# Reverting the fix (a bare `Base.fetch` in `_fetch_interruptible`) fails the first testset: the
# patched child then takes as long as the control.
# ============================================================

using Test
using PormG

const CP = PormG.ConnectionPool

# The child awaits a task that blocks for `_BLOCK_SECONDS` outside libuv, on a thread other than 1,
# and reports what the await raised and how long after `READY` it raised it. `ARGS[1]` picks the
# await: `patched` is `_fetch_interruptible`, `control` is a bare `Base.fetch`.
const _BLOCK_SECONDS = 8
const _CHILD_SCRIPT = """
using PormG
Base.exit_on_sigint(false)
started = Threads.Atomic{Bool}(false)
blocker = Threads.@spawn :default begin
  started[] = true
  for _ in 1:$(_BLOCK_SECONDS * 5)
    @ccall gc_safe = true usleep(200_000::Cuint)::Cint
  end
  Threads.threadid()
end
while !started[]
  yield()
end
println("READY"); flush(stdout)
t0 = time()
raised = try
  ARGS[1] == "patched" ? PormG.ConnectionPool._fetch_interruptible(blocker) : Base.fetch(blocker)
  "none"
catch e
  string(nameof(typeof(e)))
end
println("RESULT ", raised, " ", round(time() - t0; digits = 2)); flush(stdout)
"""

function _run_interrupted_child(mode::String)
  # `-t 2,1`: the main task on interactive thread 1, the blocker on a default thread. Were the
  # blocker on thread 1, the interrupt would land on it between two sleeps and prove nothing.
  cmd = `$(Base.julia_cmd()) -t 2,1 --project=$(Base.active_project()) -e $(_CHILD_SCRIPT) $(mode)`
  out = Pipe()
  errlog = tempname()
  proc = run(pipeline(ignorestatus(cmd); stdout = out, stderr = errlog); wait = false)
  close(out.in)
  lines = String[]
  reader = @async for line in eachline(out)
    push!(lines, line)
  end
  ready = Base.timedwait(() -> "READY" in lines || !process_running(proc), 300.0; pollint = 0.05)
  if ready === :ok && "READY" in lines
    sleep(1.0)   # the await is parked by now
    kill(proc, Base.SIGINT)
  end
  Base.timedwait(() -> !process_running(proc), 120.0; pollint = 0.1) === :timed_out && kill(proc, Base.SIGKILL)
  wait(proc); wait(reader)
  i = findfirst(l -> startswith(l, "RESULT "), lines)
  if i === nothing
    # The only diagnostic a CI failure has: show what the child said.
    @info "Interrupt-delivery child ($(mode)) printed no RESULT" stdout = join(lines, '\n') stderr = read(errlog, String)
    return (raised = "no RESULT", seconds = Inf)
  end
  _, raised, seconds = split(lines[i])
  return (raised = String(raised), seconds = parse(Float64, seconds))
end

# ─────────────────────────────────────────────────────────────────────────────
# Interrupt delivery: a SIGINT reaches a task awaiting a handle that waits outside libuv
# Two children await the same 8 s blocker and get a SIGINT 1 s in. Through `_fetch_interruptible`
# the await raises `InterruptException` at once. With a bare `Base.fetch` (the positive control) it
# raises only when the blocker finishes. Without the control, the first assertion would also pass
# on a Julia that delivers the signal anyway, and would prove nothing. No SQL: no database.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Ctrl-C reaches an await on a handle that waits outside libuv (#1512)" begin
  if Sys.iswindows()
    @test_skip "SIGINT to a child process is POSIX-only"
  else
    # Concurrently, so the file costs one child's run time rather than two.
    patched_task = @async _run_interrupted_child("patched")
    control_task = @async _run_interrupted_child("control")
    patched, control = fetch(patched_task), fetch(control_task)

    # The control reproduces the defect: the interrupt arrived, but only once the blocker finished.
    @test control.raised == "InterruptException"
    @test isfinite(control.seconds)
    @test control.seconds >= _BLOCK_SECONDS - 2
    # The fix: the interrupt arrived about one second in, as an InterruptException.
    @test patched.raised == "InterruptException"
    @test patched.seconds < 4
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# _fetch_interruptible: returns and throws exactly what Base.fetch does
# `await_result`, `_await_tx_statement` and `AdvisoryLock` read the result and classify the failure
# (`_await_abandoned`, `_as_database_error`), so the helper must not change either. Checked on
# thread 1, which arms the timer, and off it, which does not.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_fetch_interruptible returns and throws what Base.fetch does (#1512)" begin
  @test Threads.threadid() == 1   # the timer-arming branch
  @test CP._fetch_interruptible(Threads.@spawn 41 + 1) == 42
  failed = Threads.@spawn error("driver failure")
  err = try
    CP._fetch_interruptible(failed)
    nothing
  catch e
    e
  end
  @test err isa TaskFailedException
  @test err.task === failed
  # Off thread 1 the helper fetches without the timer; same result. Under `-t 1` every task runs on
  # thread 1, so there is no other thread to check from.
  if fetch(Threads.@spawn :default Threads.threadid()) != 1
    @test fetch(Threads.@spawn :default CP._fetch_interruptible(Threads.@spawn "off thread 1")) == "off thread 1"
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Await sites: no new bare Base.fetch on a driver handle
# A driver-handle await written as a bare `Base.fetch` brings #1512 back on every engine whose
# driver waits outside libuv. Counted per file, as `test_type_ratchet.jl` counts its patterns; each
# remaining call is listed with its reason. A rise fails, and so does a fall until the count is
# lowered here. No SQL.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Driver-handle awaits go through _fetch_interruptible (#1512)" begin
  # Calls, not method definitions (`function Base.fetch(handle::T)`, `Base.wait(handle::T) = …`).
  # Qualified or bare: `ConnectionPool` imports `Base.fetch`, so a bare one-argument `fetch(task)` is
  # the same call. Every ORM `fetch` takes a pool and a statement, so the one-argument form is Base's.
  # Any `Base.`-qualified call, nested arguments included (`Base.fetch(backend_execute_async(…))`),
  # plus a bare call with one simple argument.
  pattern = r"Base\.(fetch|wait)\(|(?<![\w.])(fetch|wait)\(\s*[^,()]+\)"
  definition = r"^\s*(function\s+)?(Base\.)?(fetch|wait)\([^)]*::"
  reviewed = Dict(
    # `_fetch_interruptible` itself (2); `_settle_probe`'s `Base.wait`, on a detached task, which
    # SIGINT never targets (1); prose in docstrings (3): `_as_database_error`'s example, its
    # `fetch(Threads.@spawn …)`, and `_settle_probe`'s `wait(result_task)`.
    "src/ConnectionPool.jl" => 6,
    # The LibPQ handle's `Base.fetch` forwarding to LibPQ's `AsyncResult`: the driver side of the
    # await, which `_fetch_interruptible` calls.
    "ext/PormGLibPQExt.jl" => 1,
  )
  root = pkgdir(PormG)
  found = Dict{String, Int}()
  for dir in ("src", "ext"), (path, _, files) in walkdir(joinpath(root, dir)), f in files
    endswith(f, ".jl") || continue
    file = joinpath(path, f)
    n = count(eachline(file)) do line
      !startswith(lstrip(line), "#") && occursin(pattern, line) && !occursin(definition, line)
    end
    n > 0 && (found[replace(relpath(file, root), '\\' => '/')] = n)
  end
  @test found == reviewed
end
