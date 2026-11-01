## Read-path breakdown — where a `list()` call spends its time (#1073, #1072)
##
## Usage (from the repo root), against the F1 fixture database:
##
##   PORMG_DB=db_2 julia -t auto --project=test/integration test/performance/read_path_list.jl [rounds]
##   PORMG_DB=db_2 PORMG_POSTGRES_DRIVER=Postgres julia -t auto --project=test/integration test/performance/read_path_list.jl
##   PORMG_DB=db_sl julia -t 1 --project=test/integration test/performance/read_path_list.jl
##
## One query, the one #1073 and #1072 profiled: `Result` filtered by `driverid__surname`, projecting
## `points` and `raceid__year` across two joins (208 rows on the F1 fixture). It is split into steps:
##
##   execute   — build, render and `fetch` through the pool, up to the driver's result;
##   rowtable  — `Tables.rowtable` over that result plus a `Dict` per row: the row walk `_list_raw`
##               did before #1073, kept here so one run compares both walks over the same result;
##   columns   — `_rows_from_result` over that result: the column-wise read `_list_raw` does now;
##   list()    — the terminal end to end, then `list(:dict)` and `DataFrame(q)` beside it.
##
## Each step is called twice to compile it, then `rounds` interleaved rounds (default 50) record
## `@allocated` and the wall time from separate calls; the report is the median with its min and max.
## Read-only, and like `alloc_baseline.jl` it does not take the integration suite's lock: a suite
## reseeding the database during the run invalidates the numbers, so the row count is checked again
## after the timed section. Only a same-machine comparison means anything.
using PormG
include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import DataFrames   # the integration env lists it; PormG does not depend on it (#1344)
const Tables = PormG.QueryBuilder.Tables

const ROUNDS = isempty(ARGS) ? 50 : parse(Int, ARGS[1])
const ROOT = pkgdir(PormG)
const QB = PormG.QueryBuilder

cd(joinpath(@__DIR__, "..", "integration"))
const DB_FOLDER = get(ENV, "PORMG_DB", "db_sl")
PormG.Configuration.load(DB_FOLDER; env = "dev")   # common_setup.jl sets PORMG_ENV = "dev"
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

query() = M.Result.objects.filter("driverid__surname" => "Hamilton").values("points", "raceid__year")

# The row walk `_list_raw` did before #1073, over a result already in hand.
_rowwise(result) = [Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs(row)) for row in Tables.rowtable(result)]

const HELD = let (result, built, connection) = QB._execute_select(query())
  (; result, parsers = QB._projection_parsers(built, connection))
end
# A PormG from before #1073 has no `_rows_from_result`; its step is left out, so the same script
# measures that build's `list()` for the before column of a before/after pair.
const STEPS = Tuple(filter(!isnothing, [
  ("execute (build + fetch)", () -> QB._execute_select(query())),
  ("rowtable + Dict per row (before #1073)", () -> _rowwise(HELD.result)),
  isdefined(QB, :_rows_from_result) ?
    ("_rows_from_result (after #1073)", () -> QB._rows_from_result(HELD.result, HELD.parsers)) : nothing,
  ("list()", () -> query().list()),
  ("list(:dict)", () -> query().list(:dict)),
  ("DataFrame(q)", () -> DataFrames.DataFrame(query())),
]))

_alloc(f::F) where {F} = @allocated f()
function _time_ns(f::F) where {F}
  t0 = time_ns()
  f()
  return time_ns() - t0
end

function measure(rounds::Int)
  rows = length(query().list())
  for (_, f) in STEPS, _ in 1:2
    _alloc(f); _time_ns(f)
  end
  allocs = Dict(n => Int[] for (n, _) in STEPS)
  times = Dict(n => UInt64[] for (n, _) in STEPS)
  for r in 1:rounds, i in 0:length(STEPS)-1
    n, f = STEPS[mod1(r + i, length(STEPS))]
    push!(allocs[n], _alloc(f))
    push!(times[n], _time_ns(f))
  end
  after = length(query().list())
  after == rows || error("the row count changed during the run ($(rows) → $(after)): something wrote " *
                         "to $(DB_FOLDER) meanwhile, so these numbers measure a different database")
  return (; rows, allocs, times)
end

_median(v) = (s = sort(v); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
_fmt(x::Real; digits = 1) = string(round(x; digits = digits))
_spread(v, scale; digits = 1) =
  "$(_fmt(_median(v) / scale; digits)) ($(_fmt(minimum(v) / scale; digits))–$(_fmt(maximum(v) / scale; digits)))"

function report(io::IO, m)
  commit = try readchomp(`git -C $(ROOT) describe --always --dirty`) catch; "unknown" end
  driver = DB_FOLDER == "db_2" ? " · **driver:** $(get(ENV, "PORMG_POSTGRES_DRIVER", "LibPQ"))" : ""
  cpu = Sys.cpu_info()
  println(io, "**Machine:** $(Base.first(cpu).model), $(length(cpu)) logical CPUs · **Julia:** $(VERSION), ",
          "-O$(Base.JLOptions().opt_level), $(Threads.nthreads()) thread(s)")
  println(io, "**PormG:** $(commit) · **database:** $(DB_FOLDER)$(driver) · **rows:** $(m.rows) · ",
          "**result type:** `$(nameof(typeof(HELD.result)))`")
  println(io, "**Method:** test/performance/read_path_list.jl, $(ROUNDS) interleaved rounds after 2 warm-up ",
          "calls per step; median (min–max).")
  println(io)
  println(io, "| step | allocations | KiB | time µs |")
  println(io, "|---|---:|---:|---:|")
  for (n, f) in STEPS
    println(io, "| $(n) | $(_count_allocs(f)) | $(_spread(m.allocs[n], 1024)) | $(_spread(m.times[n], 1000)) |")
  end
end

# The allocation COUNT (the issues' unit) from one extra warm call, beside the bytes the rounds recorded.
_count_allocs(f::F) where {F} = (f(); Base.gc_alloc_count(@timed(f()).gcstats))

report(stdout, measure(ROUNDS))

## ── The typed read (#1352) at 1k and 100k rows ───────────────────────────────────────────────────
##
## `list(T)` is step 1 of #1352: the `Dict{Symbol,Any}` rows `list(:dict)` builds, then one `T` per
## row. Step 2 — decoding the driver's columns straight into `T` — would save the Dict per row and
## nothing else, so the steps below split a `list(T)` call into the parts that decision needs:
##
##   execute        — build + fetch, as above;
##   Dict rows      — `_rows_from_result` over that result: what step 2 would remove;
##   T rows         — `_typed_rows` over those Dicts: the conversion `list(T)` adds to `list(:dict)`;
##   list(:dict), list(T), list() — the terminals end to end.
##
## A `Lap_times` read ordered by its natural key, five integer columns, at `limit(n)`. Rounds are
## capped at 10 for 100k rows, which still interleaves every step.
struct LapRow1352
  raceid::Int64
  driverid::Int64
  lap::Int64
  position::Union{Nothing,Int64}
  milliseconds::Union{Nothing,Int64}
end

function typed_report(io::IO, n::Int, rounds::Int)
  q() = M.Lap_times.objects.values("raceid", "driverid", "lap", "position", "milliseconds").
    order_by("raceid", "driverid", "lap").limit(n)
  held = let (result, built, connection) = QB._execute_select(q())
    (; result, parsers = QB._projection_parsers(built, connection))
  end
  dicts = QB._rows_from_result(held.result, held.parsers)
  site = QB._TypedReadSite("list(LapRow1352)", "Lap_times")
  steps = (
    ("execute (build + fetch)", () -> QB._execute_select(q())),
    ("Dict rows (_rows_from_result)", () -> QB._rows_from_result(held.result, held.parsers)),
    ("T rows (_typed_rows over the Dicts)", () -> QB._typed_rows(LapRow1352, dicts, site)),
    ("list(:dict)", () -> q().list(:dict)),
    ("list(T)", () -> q().list(LapRow1352)),
    ("list()", () -> q().list()),
  )
  for (_, f) in steps, _ in 1:2
    _alloc(f); _time_ns(f)
  end
  allocs = Dict(s => Int[] for (s, _) in steps)
  times = Dict(s => UInt64[] for (s, _) in steps)
  for r in 1:rounds, i in 0:length(steps)-1
    s, f = steps[mod1(r + i, length(steps))]
    push!(allocs[s], _alloc(f))
    push!(times[s], _time_ns(f))
  end
  println(io)
  println(io, "**Typed read (#1352):** `Lap_times`, $(length(dicts)) rows, $(rounds) interleaved rounds; median (min–max).")
  println(io)
  println(io, "| step | allocations | KiB | time µs |")
  println(io, "|---|---:|---:|---:|")
  for (s, f) in steps
    println(io, "| $(s) | $(_count_allocs(f)) | $(_spread(allocs[s], 1024)) | $(_spread(times[s], 1000)) |")
  end
end

typed_report(stdout, 1_000, ROUNDS)
typed_report(stdout, 100_000, min(ROUNDS, 10))
