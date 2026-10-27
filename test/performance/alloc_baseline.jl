## Allocation baseline — what a typical query costs once compiled (#1346)
##
## Usage (from the repo root), against the F1 fixture database:
##
##   PORMG_DB=db_sl julia -t 1 --project=test/integration test/performance/alloc_baseline.jl [rounds]
##
## A PR that touches the query build or the row read runs it before and after, on the same machine
## and Julia version, and compares. It is not in the unit suite and not a CI gate: the numbers move
## between Julia versions and machines, so only a same-machine before/after comparison means anything.
##
## For each query below, two phases:
##   build — the chain from `M.Model.objects` to its terminal with `show_query = :sql`: the queryset,
##           the build and the render, no database;
##   read  — the same chain run: build, execute, and every row parsed.
## Each closure is called twice to compile it, then the timed section runs `rounds` interleaved
## rounds (default 30): every round visits every query and phase, starting one case later than the
## round before, so a slow stretch of the machine lands on all of them rather than on one. Each visit
## records `@allocated` and the wall time from two separate calls, behind a function barrier. The
## report is the median with its min and max, and the GC counters across the timed section.
##
## Read-only: it never writes, so it runs on a seeded database as is (`runtests.jl` seeds it). It does
## not take the integration suite's lock, so a suite reseeding the same database during the run
## invalidates the numbers; each query's row count (a count's value) is read again after the timed
## section, and a net change there stops the report. db_sl runs with `-t 1`, as the suite does.
using PormG
using Dates
include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG.QueryBuilder: Sum

const ROUNDS = isempty(ARGS) ? 30 : parse(Int, ARGS[1])
const ROOT = pkgdir(PormG)

cd(joinpath(@__DIR__, "..", "integration"))
const DB_FOLDER = get(ENV, "PORMG_DB", "db_sl")
PormG.Configuration.load(DB_FOLDER; env = "dev")   # common_setup.jl sets PORMG_ENV = "dev"
# `@import_models` takes a literal path, so each folder is named (as in common_setup.jl).
if DB_FOLDER == "db_sl"
  PormG.@import_models "../integration/db_sl/models.jl" models
elseif DB_FOLDER == "db_2"
  PormG.@import_models "../integration/db_2/models.jl" models
elseif DB_FOLDER == "db_my"
  PormG.@import_models "../integration/db_my/models.jl" models
else
  error("no models file for PORMG_DB=$(DB_FOLDER)")
end
import .models as M

# Typical F1 reads: a filtered list, a primary-key get, a two-hop join, a grouped aggregate, a count,
# and a read of ~1000 rows whose cost is mostly row parsing.
const CASES = (
  (name = "filter + values + order_by",
   run = sql -> M.Race.objects.filter("year" => 2021).values("raceid", "name", "date").order_by("date").
     list(; show_query = sql)),
  (name = "get by primary key",
   run = sql -> M.Driver.objects.get("driverid" => 1; show_query = sql)),
  (name = "two-hop join",
   run = sql -> M.Result.objects.filter("raceid__year" => 2021, "raceid__circuitid__country" => "Italy").
     values("driverid__surname", "constructorid__name", "points", "positionorder").order_by("positionorder").
     list(; show_query = sql)),
  (name = "grouped Sum aggregate",
   run = sql -> M.Result.objects.filter("raceid__year" => 2021).values("driverid__surname", "pts" => Sum("points")).
     order_by("-pts").list(; show_query = sql)),
  (name = "count",
   run = sql -> M.Result.objects.filter("raceid__year__@gte" => 2010, "statusid" => 1).count(; show_query = sql)),
  (name = "lap times (~1000 rows)",
   run = sql -> M.Lap_times.objects.filter("raceid__year" => 2021, "raceid__round" => 1).
     values("driverid__code", "lap", "position", "milliseconds").order_by("driverid__code", "lap").
     list(; show_query = sql)),
)

# Function barriers: each closure is its own type, so these compile once per closure and measure the
# call, not the dispatch to it.
_alloc(f::F) where {F} = @allocated f()
function _time_ns(f::F) where {F}
  t0 = time_ns()
  f()
  return time_ns() - t0
end

_rows(x) = x isa AbstractVector ? length(x) : 1
# What the re-check after the timed section compares: the rows a list returns, the value a count does.
_fingerprint(x) = x isa Integer ? x : _rows(x)

const PHASES = (:build, :read)
_thunk(c, phase::Symbol) = phase === :build ? (() -> c.run(:sql)) : (() -> c.run(:execute))

function measure(rounds::Int)
  thunks = [(c.name, p, _thunk(c, p)) for c in CASES for p in PHASES]
  first_read = Dict(c.name => c.run(:execute) for c in CASES)
  rows = Dict(n => _rows(x) for (n, x) in first_read)
  before = Dict(n => _fingerprint(x) for (n, x) in first_read)
  for (_, _, f) in thunks, _ in 1:2   # compile every closure and both barriers
    _alloc(f); _time_ns(f)
  end
  allocs = Dict(k => Int[] for k in [(n, p) for (n, p, _) in thunks])
  times = Dict(k => UInt64[] for k in keys(allocs))
  GC.gc()
  live0 = Base.gc_live_bytes()
  gc0 = Base.gc_num()
  for r in 1:rounds, i in 0:length(thunks)-1
    n, p, f = thunks[mod1(r + i, length(thunks))]
    push!(allocs[(n, p)], _alloc(f))
    push!(times[(n, p)], _time_ns(f))
  end
  gcd = Base.GC_Diff(Base.gc_num(), gc0)
  live1 = Base.gc_live_bytes()
  after = Dict(c.name => _fingerprint(c.run(:execute)) for c in CASES)
  after == before || error("the results changed during the run ($(before) → $(after)): something wrote " *
                         "to $(DB_FOLDER) meanwhile, so these numbers measure a different database")
  return (; thunks, rows, allocs, times, gcd, live0, live1)
end

_median(v) = (s = sort(v); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
_fmt(x::Real; digits = 1) = string(round(x; digits = digits))
_spread(v, scale; digits = 1) =
  "$(_fmt(_median(v) / scale; digits)) ($(_fmt(minimum(v) / scale; digits))–$(_fmt(maximum(v) / scale; digits)))"

function report(io::IO, m)
  # `--dirty`: a before/after pair over an uncommitted change would otherwise carry one label.
  commit = try readchomp(`git -C $(ROOT) describe --always --dirty`) catch; "unknown" end
  cpu = Sys.cpu_info()
  println(io, "**Machine:** $(first(cpu).model), $(length(cpu)) logical CPUs, ",
          "$(round(Sys.total_memory() / 2^30; digits = 1)) GiB, $(Sys.KERNEL) $(Sys.ARCH)")
  println(io, "**Julia:** $(VERSION), -O$(Base.JLOptions().opt_level), $(Threads.nthreads()) thread(s) · ",
          "**PormG:** $(commit) · **database:** $(DB_FOLDER)")
  println(io, "**Method:** test/performance/alloc_baseline.jl, $(ROUNDS) interleaved rounds after 2 warm-up ",
          "calls per closure; median (min–max).")
  println(io)
  println(io, "| query | phase | rows | allocated KiB | time µs |")
  println(io, "|---|---|---:|---:|---:|")
  for (n, p, _) in m.thunks
    rows = p === :build ? "—" : string(m.rows[n])
    println(io, "| $(n) | $(p) | $(rows) | $(_spread(m.allocs[(n, p)], 1024)) | $(_spread(m.times[(n, p)], 1000)) |")
  end
  g = m.gcd
  println(io)
  println(io, "**GC across the timed section:** $(g.pause) collections ($(g.full_sweep) full), ",
          "$(_fmt(g.total_time / 1e6)) ms paused, $(_fmt(g.allocd / 2^20)) MiB allocated; live heap ",
          "$(_fmt(m.live0 / 2^20)) → $(_fmt(m.live1 / 2^20)) MiB.")
end

report(stdout, measure(ROUNDS))
