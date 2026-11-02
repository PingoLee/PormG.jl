## Async path under concurrency: is the thread free while a fetch waits, and the SQLite ceiling (#1280)
##
## A measurement, not a test: it prints tables and exits 0, except when the Q1 positive control fails
## (then the probe cannot see a held thread, and its flat line would prove nothing; exit 1). It is
## not in any suite. Each invocation measures one configuration, because `-t` is fixed per process:
##
##   # Q1, Postgres.jl (db_2): does a task awaiting `fetch` free its thread?
##   PORMG_POSTGRES_DRIVER=Postgres PORMG_TEST_POOL_SIZE=40 julia -t 8,1 --project=test/integration test/performance/async_concurrency_probe.jl q1
##
##   # Interactive caller: one `:interactive` task's lookups while every `:default` thread computes
##   PORMG_POSTGRES_DRIVER=Postgres julia -t 4,1 --project=test/integration test/performance/async_concurrency_probe.jl interactive
##   julia -t 4,1 --project=test/integration test/performance/async_concurrency_probe.jl interactive
##   PORMG_DB=db_sl julia -t 4,1 --project=test/integration test/performance/async_concurrency_probe.jl interactive
##
##   # Q4, the SQLite single-worker ceiling, once per thread count
##   PORMG_DB=db_sl julia -t 1 --project=test/integration test/performance/async_concurrency_probe.jl q4
##   PORMG_DB=db_sl julia -t 4 --project=test/integration test/performance/async_concurrency_probe.jl q4
##   PORMG_DB=db_sl julia -t 8 --project=test/integration test/performance/async_concurrency_probe.jl q4
##
## SQLite at `-t 4` and `-t 8` is deliberate: Q4 asks how SQLite behaves under threads. The suite's
## `-t 1` rule is for the test suite, and this probe only reads. `PORMG_PROBE_SECONDS` sets the
## length of each measured window (default 6).
##
## It includes `common_setup.jl`, so on `db_2` it waits on the integration suite's advisory lock and
## no suite run overlaps it. It writes nothing. Raw SQL is the stimulus here, not the subject:
## `pg_sleep` is the statement that waits, and a recursive CTE is a CPU-bound SQLite statement of a
## chosen length. The lookups the numbers are about go through the ORM, plus a raw-SQL arm in Q4 that
## separates the query build from the worker.
##
## What each mode measures:
##
##   q1          K = 4, 8, 16, 32 tasks on `:default`, each looping `fetch(pool, "SELECT pg_sleep(0.2)")`,
##               beside a heartbeat task looping `sleep(0.01)` and recording how late each wake is.
##               If the waits hold threads, the heartbeat is late once K reaches `nthreads(:default)`,
##               and the waits complete at no more than nthreads / 0.2 s. The positive control runs the
##               same K tasks computing 0.2 s at a time without yielding, back to back: from
##               K = nthreads the heartbeat cannot run until the window ends, so its p99 must be
##               over 100 ms. Also records whether a task's thread or `sticky` flag changes across
##               its first fetch.
##   interactive One `:interactive` task runs a primary-key lookup every 100 ms, while S tasks on
##               `:default` compute without yielding, S = 0, nthreads(:default) − 1, nthreads(:default).
##               The question is whether an interactive caller's statement needs a free `:default`
##               thread. It does on Postgres.jl, which spawns each statement on `:default` (#1577),
##               and on SQLite, whose single worker task lives there.
##   q4          The primary-key lookup on `drivers`, through the ORM and as raw SQL, by 1, 8 and 64
##               concurrent tasks: statements per second. Then the head-of-line case: 8 tasks of
##               lookups while one ~200 ms statement is always in flight, against the same 8 without
##               it: the lookups' p50 and p99. At 64 tasks the default SQLite pool (3, growing to 30)
##               reaches its ceiling and warns, and the extra tasks wait for a connection. On Julia
##               1.13, `-t 4` is `-t 4,1`: it adds one interactive thread.
if !isdefined(Main, :PormG)
    include(joinpath(@__DIR__, "..", "integration", "common_setup.jl"))
end

using Printf, Statistics

const MODE = isempty(ARGS) ? "" : ARGS[1]
MODE in ("q1", "interactive", "q4") ||
    error("usage: async_concurrency_probe.jl q1|interactive|q4 (see the header)")
const POOL = PormG.config[PORMG_DB_FOLDER].connections
const WINDOW = parse(Float64, get(ENV, "PORMG_PROBE_SECONDS", "6"))
const NDEF = Threads.nthreads(:default)
const NINT = Threads.nthreads(:interactive)

# ── Shared pieces ─────────────────────────────────────────────────────────────────────────────

pct(v::Vector{Float64}, p::Real) = isempty(v) ? NaN : quantile(v, p)

# Computes for `seconds` without yielding to the scheduler. The safepoint lets a GC stop the world
# (a spin with none would stall every other thread's allocation), and it is not a yield.
function spin(seconds::Float64)
    lim = round(UInt64, seconds * 1e9)
    t0 = time_ns()
    while time_ns() - t0 < lim
        GC.safepoint()
    end
    return nothing
end

# How late each `sleep(0.01)` wakes, in ms, until `stop` is set.
function heartbeat(stop::Threads.Atomic{Bool}, out::Vector{Float64})
    while !stop[]
        t0 = time_ns()
        sleep(0.01)
        push!(out, (time_ns() - t0) / 1e6 - 10.0)
    end
    return nothing
end

const DRIVER_IDS = Int[r[:driverid] for r in M.Driver.objects.values("driverid").list()]
isempty(DRIVER_IDS) && error("the F1 `drivers` table is empty on $(PORMG_DB_FOLDER); reseed it first")
const TABLE = safe_table_identifier(PormG.Models.model_table_name(M.Driver), POOL)
const RAW_LOOKUP = "SELECT driverid, surname FROM $(TABLE) WHERE driverid = $(placeholder(1))"

lookup_orm(id::Int) = M.Driver.objects.filter("driverid" => id).list()
lookup_raw(id::Int) = fetch(POOL, RAW_LOOKUP; params = Any[id])

driver_label(::PormG.ConnectionPool.PostgresConnectionPool{D}) where {D} = string(D)
driver_label(pool) = string(engine_key())

function print_setup()
    host = get(PormG.config[PORMG_DB_FOLDER].db_config_settings, "host", "")
    where_ = engine_key() === :sqlite ? "file" :
             host in ("localhost", "127.0.0.1", "::1", "") ? "local" : "remote"
    # The load average says how quiet the machine was: other processes share its cores.
    @printf("Julia %s | -t %d,%d | %s | driver %s | server version %d (%s) | pool %d | window %.0f s | load %.1f on %d cores\n",
            VERSION, NDEF, NINT, PORMG_DB_FOLDER, driver_label(POOL),
            PormG.Kernel._server_version(POOL), where_, POOL.pool_size, WINDOW,
            Sys.loadavg()[1], Sys.CPU_THREADS)
end

# ── Q1 ────────────────────────────────────────────────────────────────────────────────────────

function q1_window(arm::Symbol, K::Int)
    stop = Threads.Atomic{Bool}(false)
    late = Float64[]
    hb = Threads.@spawn :default heartbeat(stop, late)
    sleep(0.05)
    done = Threads.Atomic{Int}(0)
    deadline = time() + WINDOW
    t0 = time()
    workers = [Threads.@spawn :default begin
                   while time() < deadline
                       arm === :fetch ? fetch(POOL, "SELECT pg_sleep(0.2)") : spin(0.2)
                       Threads.atomic_add!(done, 1)
                   end
               end for _ in 1:K]
    K == 0 && sleep(WINDOW)   # the idle baseline: the heartbeat alone, for a full window
    foreach(wait, workers)
    elapsed = time() - t0
    stop[] = true
    wait(hb)
    return (; arm, K, rate = done[] / elapsed, p50 = pct(late, 0.5), p99 = pct(late, 0.99),
              max = isempty(late) ? NaN : maximum(late), beats = length(late))
end

# Each of 8 fresh tasks: its thread and `sticky` flag before and after one fetch.
function q1_sticky()
    rows = map(1:8) do _
        fetch(Threads.@spawn :default begin
            t1, s1 = Threads.threadid(), current_task().sticky
            fetch(POOL, "SELECT 1")
            sleep(0.01)
            (t1, s1, Threads.threadid(), current_task().sticky)
        end)
    end
    sticky_after = count(r -> r[4], rows)
    moved = count(r -> r[1] != r[3], rows)
    return (; sticky_before = count(r -> r[2], rows), sticky_after, moved)
end

function run_q1()
    engine_key() === :postgres || error("q1 runs on PostgreSQL (PORMG_DB=db_2)")
    POOL.pool_size > 32 || error("q1 needs a pool above 32: PORMG_TEST_POOL_SIZE=40")
    for _ in 1:3; fetch(POOL, "SELECT pg_sleep(0.01)"); end   # compile and open connections
    rtt = map(1:50) do _
        t = time_ns(); fetch(POOL, "SELECT 1"); (time_ns() - t) / 1e6
    end
    @printf("SELECT 1 round trip through fetch: p50 %.2f ms\n\n", median(rtt))
    rows = Any[q1_window(:fetch, 0)]
    for arm in (:fetch, :spin), K in (4, 8, 16, 32)
        push!(rows, q1_window(arm, K))
    end
    println("| arm | K | completed per s | if waits held threads, at most | heartbeat late p50 / p99 / max (ms) |")
    println("|---|---:|---:|---:|---|")
    for r in rows
        cap = r.arm === :fetch && r.K > 0 ? @sprintf("%.0f", NDEF / 0.2) : "–"
        @printf("| %s | %d | %.1f | %s | %.2f / %.2f / %.1f |\n",
                r.K == 0 ? "idle" : string(r.arm), r.K, r.K == 0 ? 0.0 : r.rate, cap, r.p50, r.p99, r.max)
    end
    s = q1_sticky()
    @printf("\nfresh tasks, one fetch each (of 8): sticky before %d, sticky after %d, moved thread %d\n",
            s.sticky_before, s.sticky_after, s.moved)
    control = filter(r -> r.arm === :spin && r.K >= NDEF, rows)
    if any(r -> r.p99 < 100.0, control)
        println("\nPOSITIVE CONTROL FAILED: the heartbeat was not late with every :default thread computing.")
        exit(1)
    end
end

# ── Interactive caller ────────────────────────────────────────────────────────────────────────

function interactive_window(nspin::Int)
    deadline = time() + WINDOW
    spinners = [Threads.@spawn :default begin
                    while time() < deadline
                        spin(0.05)
                    end
                end for _ in 1:nspin]
    lat = Float64[]
    probe = Threads.@spawn :interactive begin
        while time() < deadline
            t = time_ns()
            lookup_orm(rand(DRIVER_IDS))
            push!(lat, (time_ns() - t) / 1e6)
            sleep(0.1)
        end
    end
    wait(probe)
    foreach(wait, spinners)
    return (; nspin, n = length(lat), p50 = pct(lat, 0.5), max = isempty(lat) ? NaN : maximum(lat))
end

function run_interactive()
    NINT >= 1 || error("interactive needs an interactive thread: julia -t N,1")
    for _ in 1:5; lookup_orm(rand(DRIVER_IDS)); end
    for _ in 1:5; fetch(Threads.@spawn :interactive lookup_orm(rand(DRIVER_IDS))); end
    println("| :default threads computing | lookups in $(Int(WINDOW)) s (expected ≈ $(Int(WINDOW * 10))) | p50 latency (ms) | max latency (ms) |")
    println("|---:|---:|---:|---:|")
    for s in (0, NDEF - 1, NDEF)
        r = interactive_window(s)
        @printf("| %d of %d | %d | %.1f | %.0f |\n", r.nspin, NDEF, r.n, r.p50, r.max)
    end
end

# ── Q4 ────────────────────────────────────────────────────────────────────────────────────────

function throughput(f, ntasks::Int)
    done = Threads.Atomic{Int}(0)
    deadline = time() + WINDOW
    t0 = time()
    ts = [Threads.@spawn begin
              while time() < deadline
                  f(rand(DRIVER_IDS))
                  Threads.atomic_add!(done, 1)
              end
          end for _ in 1:ntasks]
    foreach(wait, ts)
    return done[] / (time() - t0)
end

slow_sql(n::Int) = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < $n) SELECT sum(x) FROM c"

# The CTE length that takes about 200 ms on this machine.
function calibrate_slow()
    n = 100_000
    while true
        fetch(POOL, slow_sql(n))
        t = @elapsed fetch(POOL, slow_sql(n))
        t >= 0.2 && return (n, t)
        n = round(Int, n * max(1.2, 0.2 / max(t, 1e-3)))
    end
end

function lookups_beside(slow::Union{Nothing, String}, ntasks::Int)
    deadline = time() + WINDOW
    stop = Threads.Atomic{Bool}(false)
    bg = slow === nothing ? nothing : Threads.@spawn begin
        while !stop[]
            fetch(POOL, slow)
        end
    end
    lat = [Float64[] for _ in 1:ntasks]
    ts = [Threads.@spawn begin
              while time() < deadline
                  t = time_ns()
                  lookup_orm(rand(DRIVER_IDS))
                  push!(lat[i], (time_ns() - t) / 1e6)
              end
          end for i in 1:ntasks]
    foreach(wait, ts)
    stop[] = true
    bg === nothing || wait(bg)
    all = reduce(vcat, lat)
    return (; n = length(all), p50 = pct(all, 0.5), p99 = pct(all, 0.99))
end

function run_q4()
    engine_key() === :sqlite || error("q4 runs on SQLite (PORMG_DB=db_sl)")
    for _ in 1:20; lookup_orm(rand(DRIVER_IDS)); lookup_raw(rand(DRIVER_IDS)); end
    println("| tasks | ORM lookups per s | raw lookups per s |")
    println("|---:|---:|---:|")
    for n in (1, 8, 64)
        @printf("| %d | %.0f | %.0f |\n", n, throughput(lookup_orm, n), throughput(lookup_raw, n))
    end
    n, t = calibrate_slow()
    @printf("\nhead-of-line: a recursive CTE of %d rows, %.0f ms alone, always in flight beside 8 tasks of ORM lookups\n\n", n, 1000t)
    println("| | lookups | p50 (ms) | p99 (ms) |")
    println("|---|---:|---:|---:|")
    for (label, slow) in (("alone", nothing), ("beside the 200 ms statement", slow_sql(n)))
        r = lookups_beside(slow, 8)
        @printf("| %s | %d | %.2f | %.1f |\n", label, r.n, r.p50, r.p99)
    end
end

# ── Main ──────────────────────────────────────────────────────────────────────────────────────

print_setup()
println()
MODE == "q1" ? run_q1() : MODE == "interactive" ? run_interactive() : run_q4()
