## Statement split — where one primary-key read spends its CPU on Postgres.jl (#41 phase 1)
##
## A measurement, not a test: it prints Markdown tables and exits 0. It is not in any suite. One
## mode per invocation, because `-t` is fixed per process:
##
##   PORMG_DB=db_2 PORMG_POSTGRES_DRIVER=Postgres julia -t 1 --project=test/integration test/performance/statement_split.jl single
##   PORMG_DB=db_2 PORMG_POSTGRES_DRIVER=Postgres PORMG_TEST_POOL_SIZE=32 julia -t 8,1 --project=test/integration test/performance/statement_split.jl concurrent
##
## `single [rounds] [batch]` (default 10 × 500 calls); `concurrent` runs each part for
## `PORMG_PROBE_SECONDS` (default 5) with `PORMG_SPLIT_TASKS` tasks (default 50, Nitro's c=50).
##
## Why it exists. Nitro's socket bench measured ~290 µs of THREAD CPU per statement on `/queries?n=20`
## (#41). `alloc_baseline.jl` and `read_path_list.jl` report WALL time, which also counts the wait on the
## database socket, so their numbers cannot be summed and compared with that figure. This script
## measures process CPU time per call, part by part, so the sum can be.
##
## The statement is the shape of Nitro's `/queries`: `get` by a random primary key, one row. `Status`
## (two columns) is the closest F1 match to TechEmpower's `world(id, randomnumber)`; `Driver` (nine
## columns) is the wider row. Each is read as `get()` (a `PormGRow`) and as `get(T)` (a typed read).
##
## The parts, each a closure over pieces built once, so each runs on its own:
##
##   build          `get(…; show_query = :sql)`: the copies, `get_settings` and the render the execute
##                  path does, no database
##   PormG execute  `fetch(settings, sql, params)` on SQL built once: lease, the spawned driver task,
##                  `FetchTask`, await, release
##   bare driver    `backend_execute(pool, conn, sql, params)` on a connection leased once, on the
##                  calling task: the driver alone, no pool and no spawn
##   driver decode  `Tables.columntable(result)` over a held result: Postgres.jl's per-row decode (#1597)
##   parse          `_rows_from_result` + a `PormGRow`, or `_typed_rows` for `get(T)`, over a held result
##                  (the decode included: both start with `Tables.columntable`)
##   end to end     `get(…)` / `get(T, …)`
##
## Derived: Σ = build + PormG execute + parse; residual = end to end − Σ; pool + spawn = PormG execute −
## bare driver.
##
## The residual is not missing work. A part in a warm loop of its own is flattered: nothing evicts its
## caches, and the core never idles between calls. Inside `get`, the build's ~30 KiB of allocation
## evicts what the fetch had warm, and the socket wait lets the core drop its clock. On a Ryzen 7 5825U
## (`powersave` governor, boost on), a build with a 60 µs idle sleep between calls costs ~15% more CPU
## than back to back, and a build alternating with a fetch costs ~25% more than the two apart. So the
## isolated table is a floor for each part, and the split that adds up is the IN-SITU one: `get`'s own
## body (`get_in_situ`, copied step by step from `_get` → `list` → `_execute_select`), with the THREAD
## CPU clock read between steps. Build and parse never yield, so the thread clock times them exactly,
## under concurrency too (a GC pause that lands in a step counts in it); execute, which yields, is the
## remainder of the process CPU. The report checks the body's total against the real `get`: a gap of
## more than a few percent means the copy has drifted from src/, and the split is void.
##
## Metrics, per call:
##   CPU      process CPU time (`CLOCK_PROCESS_CPUTIME_ID`), every thread: the spawned driver task runs
##            on another thread, which a thread clock would miss. "net" subtracts the CPU the process
##            burns idle over the same wall time (measured first, no tasks); Nitro's figure contains
##            its idle spin too, so both are shown
##   wall     for continuity with the `alloc_baseline.jl` tables
##   allocs   `Base.gc_num` count and bytes
##   GC       the stop-the-world pause per call, and its share: pause × nthreads(:default) ÷ CPU. That
##            approximates the share of thread samples in GC Nitro's profile reported; it is not it
##
## It includes `common_setup.jl`, so it waits on the integration suite's advisory lock on `db_2`: no
## suite run reseeds the database under it. It only reads. The database server's own CPU is outside
## every number here, whether it is local or remote. Only a same-machine comparison means anything.
if !isdefined(Main, :PormG)
  include(joinpath(@__DIR__, "..", "integration", "common_setup.jl"))
end

using Printf

const MODE = isempty(ARGS) ? "" : ARGS[1]
MODE in ("single", "concurrent") || error("usage: statement_split.jl single [rounds] [batch] | concurrent (see the header)")
Sys.islinux() || error("statement_split.jl reads CLOCK_PROCESS_CPUTIME_ID through clock_gettime: Linux only")
PORMG_DB_FOLDER == "db_2" || error("statement_split.jl measures PostgreSQL (#41): set PORMG_DB=db_2")
get(ENV, "PORMG_POSTGRES_DRIVER", "") == "Postgres" ||
  error("statement_split.jl measures Postgres.jl (#41, #1072): set PORMG_POSTGRES_DRIVER=Postgres")

const QB = PormG.QueryBuilder
const POOL = PormG.config[PORMG_DB_FOLDER].connections
const SETTINGS = PormG.config[PORMG_DB_FOLDER]
const NDEF = Threads.nthreads(:default)
const ROUNDS = MODE == "single" && length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 10
const BATCH = MODE == "single" && length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 500
const WINDOW = parse(Float64, get(ENV, "PORMG_PROBE_SECONDS", "5"))
const TASKS = parse(Int, get(ENV, "PORMG_SPLIT_TASKS", "50"))
MODE == "concurrent" && NDEF == 1 && error("concurrent mode needs more than one :default thread (-t 8,1)")

# ── Clocks ────────────────────────────────────────────────────────────────────────────────────────

struct _Timespec
  sec::Clong
  nsec::Clong
end
const _CLOCK_PROCESS_CPUTIME_ID = Cint(2)   # Linux <time.h>
function cpu_ns()::Int64
  ts = Ref(_Timespec(0, 0))
  ccall(:clock_gettime, Cint, (Cint, Ref{_Timespec}), _CLOCK_PROCESS_CPUTIME_ID, ts) == 0 ||
    error("clock_gettime(CLOCK_PROCESS_CPUTIME_ID) failed")
  return Int64(ts[].sec) * 1_000_000_000 + Int64(ts[].nsec)
end

# One measured span: process CPU, wall, and the GC counters across it.
struct Span
  calls::Int
  cpu::Int64
  wall::Int64
  allocs::Int64
  bytes::Int64
  gc_pause::Int64
end
function span(calls::Int, f_run::F) where {F}
  gc0 = Base.gc_num(); c0 = cpu_ns(); w0 = time_ns()
  f_run()
  w1 = time_ns(); c1 = cpu_ns(); gcd = Base.GC_Diff(Base.gc_num(), gc0)
  return Span(calls, c1 - c0, Int64(w1 - w0), Int64(Base.gc_alloc_count(gcd)), Int64(gcd.allocd),
              Int64(gcd.total_time))
end

# ── The statements ────────────────────────────────────────────────────────────────────────────────

struct StatusRow
  statusid::Int64
  status::String
end
struct DriverRow
  driverid::Int64
  driverref::String
  number::Union{Nothing,Int64}
  code::Union{Nothing,String}
  forename::String
  surname::String
  dob::Date
  nationality::String
  url::String
end

# Everything a part closes over, built once per case.
function prepare(label::String, model_handler::Function, pk::String, ::Type{T}) where T
  ids = Int[r[Symbol(pk)] for r in model_handler().values(pk).list()]
  isempty(ids) && error("the F1 table behind $(label) is empty on $(PORMG_DB_FOLDER); reseed it first")
  id = first(ids)
  # The statement `get` runs: its filter plus the `limit(2)` probe (`_get` in execution_read.jl).
  q = model_handler().filter(pk => id).limit(2)
  settings, connection, _ = QB.get_settings(q)
  # #1624: the build writes nothing into `q`; its SQL and parameters are the render's.
  rendered = QB._render_select(q; connection = connection, show_query = :execute)
  sql = rendered.sql
  params = rendered.instruction.parameters
  result, built, conn = QB._execute_select(q)
  parsers = QB._projection_parsers(built, conn)
  model = q.object.model
  site = QB._TypedReadSite("statement_split", model.name)
  return (; label, model_handler, pk, T, ids, settings, connection, sql, params, result, parsers, model, site)
end

const CASES = [
  prepare("Status (2 columns)", () -> M.Status.objects, "statusid", StatusRow),
  prepare("Driver (9 columns)", () -> M.Driver.objects, "driverid", DriverRow),
]

# The parts of one case. `conn_ref` holds the connection the bare-driver part runs on: one per task.
function parts(c)
  T = c.T
  rid() = rand(c.ids)
  return [
    (:build_row,   () -> c.model_handler().get(c.pk => rid(); show_query = :sql)),
    (:build_typed, () -> c.model_handler().get(T, c.pk => rid(); show_query = :sql)),
    (:execute,     () -> PormG.ConnectionPool.fetch(c.settings, c.sql, c.params)),
    (:bare_driver, :bare),   # needs a leased connection; built per task in `bare_closure`
    (:decode,      () -> QB.Tables.columntable(c.result)),
    (:parse_row,   () -> [QB.PormGRow(r, c.model) for r in QB._rows_from_result(c.result, c.parsers)]),
    (:parse_typed, () -> QB._typed_rows(T, c.result, c.parsers, c.site)),
    (:e2e_row,     () -> c.model_handler().get(c.pk => rid())),
    (:e2e_typed,   () -> c.model_handler().get(T, c.pk => rid())),
  ]
end
bare_closure(c, conn) = () -> PormG.backend_execute(c.connection, conn, c.sql, c.params)

# ── In situ: `get`'s own body, with the thread CPU clock read between its steps (see the header) ──
#
# `_get` → `_list_owned` → `_execute_select` (execution_read.jl) and `_list_owned(q, T)`
# (typed_read.jl), step by step: since #1589 the handler is copied once, in `_get`, and the typed
# projection and the build run on that copy; since #1624 that copy is shallow (`_terminal_copy`), the
# build writes nothing (`_render_select` returns the SQL and the instruction), and the messages are
# rendered only when thrown. When any of them changes, change this copy with it: the report's gap
# column is what notices.
const _CLOCK_THREAD_CPUTIME_ID = Cint(3)   # Linux <time.h>
function thread_cpu_ns()::Int64
  ts = Ref(_Timespec(0, 0))
  ccall(:clock_gettime, Cint, (Cint, Ref{_Timespec}), _CLOCK_THREAD_CPUTIME_ID, ts) == 0 ||
    error("clock_gettime(CLOCK_THREAD_CPUTIME_ID) failed")
  return Int64(ts[].sec) * 1_000_000_000 + Int64(ts[].nsec)
end

# Accumulated thread CPU of the build and parse steps, in ns, over the calls of one span.
mutable struct InSitu
  build::Int64
  parse::Int64
  execute_thread::Int64   # the caller's thread across `fetch`: exact at -t 1 only
end
InSitu() = InSitu(0, 0, 0)

_finish(::Val{:row}, result, q, instruction, connection) =
  [QB.PormGRow(r, q.object.model) for r in QB._rows_from_result(result, QB._projection_parsers(instruction, connection))]
_finish(::Type{T}, result, q, instruction, connection) where T =
  QB._typed_rows(T, result, QB._projection_parsers(instruction, connection), QB._TypedReadSite("a typed read into $(T)", q.object.model.name))
_shape(q, ::Val{:row}) = q
_shape(q, ::Type{T}) where T = (QB._check_typed_read_target(T); QB._typed_projection!(q, T))

function get_in_situ(c, format, acc::InSitu)
  t0 = thread_cpu_ns()
  # _get: the one (shallow) copy, its filter and probe
  q = QB._terminal_copy(c.model_handler())
  QB._filter!(q.object, (c.pk => rand(c.ids),))
  q = q.limit(QB._probe_limit(q.object.limit, 2))
  # _list_owned → (the typed projection, on the same copy) → _execute_select
  q = _shape(q, format)
  settings, connection, _ = QB.get_settings(q)
  rendered = QB._render_select(q; connection = connection, show_query = :execute)
  QB._refuse_lock_outside_transaction(q, rendered.instruction)
  t1 = thread_cpu_ns()
  result = PormG.ConnectionPool.fetch(settings, rendered.sql, rendered.instruction.parameters)
  t2 = thread_cpu_ns()
  rows = _finish(format, result, q, rendered.instruction, connection)
  # _get's checks after the read; the messages are rendered only when one is thrown
  length(rows) == 1 || throw(isempty(rows) ? QB.DoesNotExist(q.object.model.name, QB._filters_repr(q)) :
                                             QB.MultipleObjectsReturned(q.object.model.name, length(rows), QB._filters_repr(q)))
  t3 = thread_cpu_ns()
  acc.build += t1 - t0
  acc.execute_thread += t2 - t1
  acc.parse += t3 - t2
  return rows[1]
end

const IN_SITU_FORMS = (("get()", Val(:row)), ("get(T)", nothing))   # `nothing`: the case's T
_form(c, f) = f === nothing ? c.T : f

const PART_LABEL = Dict(
  :build_row => "build — get()", :build_typed => "build — get(T)", :execute => "PormG execute",
  :bare_driver => "bare driver", :decode => "driver decode", :parse_row => "parse — get()",
  :parse_typed => "parse — get(T)", :e2e_row => "end to end — get()", :e2e_typed => "end to end — get(T)")

# ── Single: one task, interleaved batches ─────────────────────────────────────────────────────────

function loop!(f::F, n::Int) where {F}
  for _ in 1:n
    f()
  end
  return nothing
end

function idle_rate(seconds::Float64)
  GC.gc()
  s = span(0, () -> sleep(seconds))
  return s.cpu / s.wall   # CPU ns per wall ns with nothing to do
end

function measure_single()
  results = Dict{Tuple{String,Symbol},Vector{Span}}()
  conns = Dict{String,Any}()
  thunks = Tuple{String,Symbol,Any}[]
  for c in CASES
    conn = PormG.ConnectionPool.acquire_connection(POOL)
    conns[c.label] = conn
    for (name, f) in parts(c)
      push!(thunks, (c.label, name, f === :bare ? bare_closure(c, conn) : f))
    end
  end
  try
    for (_, _, f) in thunks
      loop!(f, 50)   # compile and warm
    end
    idle = idle_rate(2.0)
    GC.gc()
    for r in 1:ROUNDS, i in 0:length(thunks)-1
      label, name, f = thunks[mod1(r + i, length(thunks))]
      push!(get!(results, (label, name), Span[]), span(BATCH, () -> loop!(f, BATCH)))
    end
    in_situ = measure_in_situ_single()
    return (; results, idle, in_situ)
  finally
    for conn in values(conns)
      PormG.ConnectionPool.release_connection(POOL, conn)
    end
  end
end

# The in-situ body and the real `get` in alternating batches, so both see the same machine.
function measure_in_situ_single()
  out = Dict{Tuple{String,String},Vector{Tuple{Span,InSitu,Span}}}()
  for c in CASES, (fname, f) in IN_SITU_FORMS
    fmt = _form(c, f)
    real = fmt isa Val ? (() -> c.model_handler().get(c.pk => rand(c.ids))) :
                         (() -> c.model_handler().get(fmt, c.pk => rand(c.ids)))
    loop!(() -> get_in_situ(c, fmt, InSitu()), 50)
    for _ in 1:ROUNDS
      acc = InSitu()
      s = span(BATCH, () -> loop!(() -> get_in_situ(c, fmt, acc), BATCH))
      r = span(BATCH, () -> loop!(real, BATCH))
      push!(get!(out, (c.label, fname), Tuple{Span,InSitu,Span}[]), (s, acc, r))
    end
  end
  return out
end

# ── Concurrent: K tasks per part for a window ─────────────────────────────────────────────────────

function window(make_f::Function, K::Int, seconds::Float64)
  done = Threads.Atomic{Int}(0)
  ready = Threads.Atomic{Int}(0)
  go = Threads.Atomic{Bool}(false)
  stop = Threads.Atomic{Bool}(false)
  local s
  workers = [Threads.@spawn :default begin
               f, cleanup = make_f()
               try
                 Threads.atomic_add!(ready, 1)
                 while !go[]
                   yield()
                 end
                 n = 0
                 while !stop[]
                   f(); n += 1
                 end
                 Threads.atomic_add!(done, n)
               finally
                 cleanup()
               end
             end for _ in 1:K]
  while ready[] < K
    sleep(0.01)
  end
  # The span opens after every task holds what it needs (a bare-driver connection) and closes when
  # the last one has stopped, so set-up and tear-down stay outside it. Calls in flight at `stop` finish
  # inside it and are counted.
  s = span(0, () -> begin
    go[] = true
    sleep(seconds)
    stop[] = true
    foreach(wait, workers)
  end)
  return Span(done[], s.cpu, s.wall, s.allocs, s.bytes, s.gc_pause)
end

function measure_concurrent()
  results = Dict{Tuple{String,Symbol},Vector{Span}}()
  # Warm every part on one task first, so compilation stays out of the windows.
  for c in CASES
    conn = PormG.ConnectionPool.acquire_connection(POOL)
    try
      for (_, f) in parts(c)
        loop!(f === :bare ? bare_closure(c, conn) : f, 50)
      end
    finally
      PormG.ConnectionPool.release_connection(POOL, conn)
    end
  end
  GC.gc()
  idle = let s = span(0, () -> sleep(WINDOW)); s.cpu / s.wall end
  for c in CASES, (name, f) in parts(c)
    make_f = if f === :bare
      () -> begin
        conn = PormG.ConnectionPool.acquire_connection(POOL)
        (bare_closure(c, conn), () -> PormG.ConnectionPool.release_connection(POOL, conn))
      end
    else
      () -> (f, () -> nothing)
    end
    GC.gc()
    results[(c.label, name)] = [window(make_f, TASKS, WINDOW)]
  end
  in_situ = Dict{Tuple{String,String},Vector{Tuple{Span,InSitu,Span}}}()
  for c in CASES, (fname, f) in IN_SITU_FORMS
    fmt = _form(c, f)
    accs = InSitu[]
    lk = ReentrantLock()
    make_in_situ = () -> begin
      acc = InSitu()
      lock(() -> push!(accs, acc), lk)
      (() -> get_in_situ(c, fmt, acc), () -> nothing)
    end
    real = fmt isa Val ? (() -> c.model_handler().get(c.pk => rand(c.ids))) :
                         (() -> c.model_handler().get(fmt, c.pk => rand(c.ids)))
    GC.gc()
    s = window(make_in_situ, TASKS, WINDOW)
    total = InSitu(sum(a.build for a in accs), sum(a.parse for a in accs), sum(a.execute_thread for a in accs))
    GC.gc()
    r = window(() -> (real, () -> nothing), TASKS, WINDOW)
    in_situ[(c.label, fname)] = [(s, total, r)]
  end
  return (; results, idle, in_situ)
end

# ── Report ────────────────────────────────────────────────────────────────────────────────────────

_median(v) = (s = sort(v); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
per_call(s::Span, field::Symbol) = getfield(s, field) / s.calls
net_cpu(s::Span, idle::Float64) = (s.cpu - idle * s.wall) / s.calls
gc_share(s::Span) = s.cpu == 0 ? 0.0 : min(1.0, s.gc_pause * NDEF / s.cpu)

struct Row
  cpu::Float64      # µs per call
  net::Float64
  cpu_lo::Float64
  cpu_hi::Float64
  wall::Float64
  allocs::Float64
  kib::Float64
  gc_us::Float64
  gc_share::Float64
  rate::Float64     # calls per second (concurrent)
end
function summarize(spans::Vector{Span}, idle::Float64)
  cpus = [per_call(s, :cpu) / 1e3 for s in spans]
  m(f) = _median([f(s) for s in spans])
  return Row(_median(cpus), m(s -> net_cpu(s, idle)) / 1e3, minimum(cpus), maximum(cpus),
             m(s -> per_call(s, :wall)) / 1e3, m(s -> per_call(s, :allocs)), m(s -> per_call(s, :bytes)) / 1024,
             m(s -> per_call(s, :gc_pause)) / 1e3, m(gc_share), m(s -> s.calls / (s.wall / 1e9)))
end

where_db() = begin
  host = get(SETTINGS.db_config_settings, "host", "")
  host in ("localhost", "127.0.0.1", "::1", "") ? "local" : "remote"
end

postgres_version() = something(pkgversion(only(m for (k, m) in Base.loaded_modules if k.name == "Postgres")), "unknown")

function report(io::IO, m)
  commit = try readchomp(`git -C $(pkgdir(PormG)) describe --always --dirty`) catch; "unknown" end
  cpu = Sys.cpu_info()
  println(io, "**Machine:** $(Base.first(cpu).model), $(length(cpu)) logical CPUs, load $(round(Sys.loadavg()[1]; digits = 1)) · ",
          "**Julia:** $(VERSION), -O$(Base.JLOptions().opt_level), -t $(NDEF),$(Threads.nthreads(:interactive)) · ",
          "**PormG:** $(commit)")
  println(io, "**Database:** $(PORMG_DB_FOLDER) ($(where_db())), PostgreSQL $(PormG.Kernel._server_version(POOL)), driver Postgres.jl ",
          "$(postgres_version()) · pool $(POOL.pool_size)")
  if MODE == "single"
    println(io, "**Method:** test/performance/statement_split.jl single, one task, $(ROUNDS) interleaved rounds × $(BATCH) calls ",
            "after 50 warm-up calls per part; median per call (CPU min–max over rounds).")
  else
    println(io, "**Method:** test/performance/statement_split.jl concurrent, $(TASKS) tasks on :default per part, ",
            "$(WINDOW) s window per part after 50 warm-up calls; per call over the window.")
  end
  println(io, "**Idle CPU:** $(round(m.idle * 100; digits = 2))% of one core over the wall time (subtracted in \"net\").")
  for c in CASES
    rows = Dict(name => summarize(m.results[(c.label, name)], m.idle) for (name, _) in parts(c))
    println(io)
    println(io, "**$(c.label)**")
    println(io)
    if MODE == "single"
      println(io, "| part | CPU µs | net CPU µs | wall µs | allocs | KiB | GC pause µs | GC share |")
      println(io, "|---|---:|---:|---:|---:|---:|---:|---:|")
    else
      println(io, "| part | calls/s | CPU µs | net CPU µs | allocs | KiB | GC pause µs | GC share |")
      println(io, "|---|---:|---:|---:|---:|---:|---:|---:|")
    end
    for (name, _) in parts(c)
      r = rows[name]
      cpu = @sprintf("%.1f (%.1f–%.1f)", r.cpu, r.cpu_lo, r.cpu_hi)
      if MODE == "single"
        @printf(io, "| %s | %s | %.1f | %.1f | %.0f | %.1f | %.1f | %.0f%% |\n", PART_LABEL[name], cpu, r.net, r.wall,
                r.allocs, r.kib, r.gc_us, 100r.gc_share)
      else
        @printf(io, "| %s | %.0f | %.1f | %.1f | %.0f | %.1f | %.1f | %.0f%% |\n", PART_LABEL[name], r.rate, r.cpu, r.net,
                r.allocs, r.kib, r.gc_us, 100r.gc_share)
      end
    end
    for (kind, b, p, e) in (("get()", :build_row, :parse_row, :e2e_row), ("get(T)", :build_typed, :parse_typed, :e2e_typed))
      Σ = rows[b].cpu + rows[:execute].cpu + rows[p].cpu
      Σn = rows[b].net + rows[:execute].net + rows[p].net
      @printf(io, "\n%s: Σ build + execute + parse = %.1f µs CPU (%.1f net) · end to end %.1f (%.1f net) · residual %+.1f µs (%+.0f%%) · vs Nitro's ~290 µs: %.0f%%",
              kind, Σ, Σn, rows[e].cpu, rows[e].net, rows[e].cpu - Σ, 100 * (rows[e].cpu - Σ) / rows[e].cpu, 100 * rows[e].cpu / 290)
    end
    @printf(io, "\npool + spawn = PormG execute − bare driver = %.1f µs CPU (%.1f net)\n",
            rows[:execute].cpu - rows[:bare_driver].cpu, rows[:execute].net - rows[:bare_driver].net)
  end
  report_in_situ(io, m)
end

function report_in_situ(io::IO, m)
  println(io)
  println(io, "**In situ** — `get`'s own body with the thread CPU clock between steps (execute = process CPU − build − parse):")
  println(io)
  println(io, "| statement | build µs | execute µs | parse + checks µs | total µs | real `get` µs | gap | GC share | build / execute / parse |")
  println(io, "|---|---:|---:|---:|---:|---:|---:|---:|---|")
  for c in CASES, (fname, _) in IN_SITU_FORMS
    v = m.in_situ[(c.label, fname)]
    b = _median([a.build / s.calls for (s, a, _) in v]) / 1e3
    p = _median([a.parse / s.calls for (s, a, _) in v]) / 1e3
    tot = _median([per_call(s, :cpu) for (s, _, _) in v]) / 1e3
    real = _median([per_call(r, :cpu) for (_, _, r) in v]) / 1e3
    gcs = _median([gc_share(s) for (s, _, _) in v])
    e = tot - b - p
    @printf(io, "| %s %s | %.1f | %.1f | %.1f | %.1f | %.1f | %+.0f%% | %.0f%% | %.0f%% / %.0f%% / %.0f%% |\n",
            c.label, fname, b, e, p, tot, real, 100 * (tot - real) / real, 100gcs, 100b / tot, 100e / tot, 100p / tot)
  end
  if MODE == "single"
    v = [(s, a) for c in CASES, (fname, _) in IN_SITU_FORMS for (s, a, _) in m.in_situ[(c.label, fname)]]
    @printf(io, "\nAt -t 1 the caller's thread clock across `fetch` sees the driver task too: %.1f µs per call on average, against the remainder above.\n",
            sum(a.execute_thread for (_, a) in v) / sum(s.calls for (s, _) in v) / 1e3)
  end
  t0 = thread_cpu_ns(); for _ in 1:10_000; thread_cpu_ns(); end
  @printf(io, "Each clock read costs %.2f µs; the in-situ body makes four.\n", (thread_cpu_ns() - t0) / 10_000 / 1e3)
end

report(stdout, MODE == "single" ? measure_single() : measure_concurrent())
