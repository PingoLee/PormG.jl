## Write-path cost per PostgreSQL driver — create, update, bulk_insert, bulk_copy (#1072)
##
## Usage (from the repo root), against the `db_2` PostgreSQL database, once per driver:
##
##   PORMG_DB=db_2 julia -t auto --project=test/integration test/performance/write_path.jl [rounds]
##   PORMG_DB=db_2 PORMG_POSTGRES_DRIVER=Postgres julia -t auto --project=test/integration test/performance/write_path.jl
##
## The write half of `read_path_list.jl`: the same F1 fixture database, measured once through LibPQ
## and once through Postgres.jl. The steps are the ones #1072 lists — one `create`, one `update` by
## primary key, the `create` + `update` round trip, and a 1 000-row `bulk_insert` and `bulk_copy` —
## all on `Bulk_copy_fidelity_scratch` (id, name, amount, active, event_time). PostgreSQL only:
## `bulk_copy` is a PostgreSQL feature, so another `PORMG_DB` stops at the top.
##
## Unlike the read-only scripts it WRITES, so it includes `common_setup.jl` and holds the
## integration suite's lock for the whole run: a suite run started meanwhile queues instead of
## reading the scratch table mid-benchmark (`PORMG_TEST_LOCK_WAIT` bounds the wait; a timeout is a
## result to report, not a reason to set `PORMG_TEST_LOCK=0`). Every row it writes has a `name`
## starting with `perf1072`, and only those rows are ever deleted — `test_bulk_copy.jl` and
## `test_nul_string_values.jl` use the same table — before each visit (outside the timing) and at
## the end, so the table is left as it was found.
##
## Each step is called twice to compile it, then `rounds` interleaved rounds (default 30): every round
## visits every step, starting one step later than the round before, so a slow stretch of the machine
## or the network lands on all of them rather than one. A visit clears the `perf1072` rows, runs the
## step's setup (the row an `update` targets), then times one call with `@timed`. After the call the
## step's check reads back what it wrote — the row count for an insert, the updated values for an
## `update` — so a step that silently wrote nothing cannot report a fast time. The report is the
## median with its min and max. Only a same-machine comparison means anything: run the two drivers
## one after the other, ideally A B B A. The allocation and KiB columns count the Julia heap only:
## libpq allocates in C, where `@timed` cannot see it, so compare those columns within one driver,
## and compare drivers by time.
if !isdefined(Main, :PormG)
  include(joinpath(@__DIR__, "..", "integration", "common_setup.jl"))
end

PORMG_DB_FOLDER == "db_2" || error("write_path.jl measures the PostgreSQL drivers and needs PORMG_DB=db_2 " *
                                   "(bulk_copy is PostgreSQL-only); this run has PORMG_DB=$(PORMG_DB_FOLDER)")

const ROUNDS = isempty(ARGS) ? 30 : parse(Int, ARGS[1])
const ROOT = pkgdir(PormG)
const BULK_ROWS = 1_000
const PREFIX = "perf1072"
const WHEN = DateTime(2021, 9, 12, 13, 0, 0)   # the 2021 Italian Grand Prix start, UTC

scratch() = M.Bulk_copy_fidelity_scratch.objects
ours() = scratch().filter("name__@startswith" => PREFIX)
clear_ours!() = (q = ours(); q.exists() && q.delete(); nothing)

const BULK_DF = DataFrame(
  name       = ["$(PREFIX) bulk $(i)" for i in 1:BULK_ROWS],
  amount     = [Float64(i) / 4 for i in 1:BULK_ROWS],
  active     = [isodd(i) for i in 1:BULK_ROWS],
  event_time = [WHEN + Second(i) for i in 1:BULK_ROWS],
)

_create_one() = scratch().create("name" => "$(PREFIX) one", "amount" => 1.5, "active" => true,
                                 "event_time" => WHEN)
_update_one(id) = scratch().filter("id" => id).update("amount" => 2.5, "active" => false)

# What a step must leave behind, read back after the timing: `rows` rows of ours, and for an
# `update`, that one row carrying the updated values.
_wrote(rows::Int) = () -> ours().count() == rows
_updated() = () -> ours().count() == 1 && ours().filter("amount" => 2.5, "active" => false).count() == 1

# (name, setup, run, check): `setup()` runs before the timing and its value is handed to `run`;
# `check()` runs after it.
const STEPS = (
  (name = "create (1 row)", setup = () -> nothing, run = _ -> _create_one(), check = _wrote(1)),
  (name = "update by pk (1 row)", setup = () -> _create_one()[:id], run = id -> _update_one(id),
   check = _updated()),
  (name = "create + update round trip", setup = () -> nothing,
   run = _ -> _update_one(_create_one()[:id]), check = _updated()),
  (name = "bulk_insert ($(BULK_ROWS) rows)", setup = () -> nothing,
   run = _ -> bulk_insert(scratch(), BULK_DF), check = _wrote(BULK_ROWS)),
  (name = "bulk_copy ($(BULK_ROWS) rows)", setup = () -> nothing,
   run = _ -> bulk_copy(scratch(), BULK_DF), check = _wrote(BULK_ROWS)),
)

# Function barrier: `@timed` over a closure of a known type.
_timed(run::F, state) where {F} = @timed run(state)

function visit(step)
  clear_ours!()
  state = step.setup()
  t = _timed(step.run, state)
  step.check() || error("$(step.name): reading back its $(PREFIX) rows did not find what it wrote")
  return (; time = t.time, bytes = t.bytes, allocs = Base.gc_alloc_count(t.gcstats))
end

function measure(rounds::Int)
  for step in STEPS, _ in 1:2
    visit(step)
  end
  samples = Dict(s.name => NamedTuple{(:time, :bytes, :allocs), Tuple{Float64, Int, Int}}[] for s in STEPS)
  for r in 1:rounds, i in 0:length(STEPS)-1
    step = STEPS[mod1(r + i, length(STEPS))]
    push!(samples[step.name], visit(step))
  end
  return samples
end

_median(v) = (s = sort(v); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
_fmt(x::Real; digits = 2) = string(round(x; digits = digits))
_spread(v, scale; digits = 2) =
  "$(_fmt(_median(v) / scale; digits)) ($(_fmt(minimum(v) / scale; digits))–$(_fmt(maximum(v) / scale; digits)))"

function _driver_version(name::Symbol)
  for m in values(Base.loaded_modules)
    nameof(m) === name && return string(pkgversion(m))
  end
  return "not loaded"
end

function report(io::IO, samples)
  commit = try readchomp(`git -C $(ROOT) describe --always --dirty`) catch; "unknown" end
  pool = PormG.config[PORMG_DB_FOLDER].connections
  cpu = Sys.cpu_info()
  println(io, "**Machine:** $(Base.first(cpu).model), $(length(cpu)) logical CPUs · **Julia:** $(VERSION), ",
          "-O$(Base.JLOptions().opt_level), $(Threads.nthreads()) thread(s)")
  println(io, "**PormG:** $(commit) · **database:** $(PORMG_DB_FOLDER) · **pool:** `$(typeof(pool))` · ",
          "**LibPQ:** $(_driver_version(:LibPQ)) · **Postgres.jl:** $(_driver_version(:Postgres))")
  println(io, "**Method:** test/performance/write_path.jl, $(ROUNDS) interleaved rounds after 2 warm-up ",
          "calls per step; median (min–max).")
  println(io)
  println(io, "| step | allocations | KiB | time ms |")
  println(io, "|---|---:|---:|---:|")
  for s in STEPS
    v = samples[s.name]
    println(io, "| $(s.name) | $(round(Int, _median([x.allocs for x in v]))) | ",
            "$(_spread([x.bytes for x in v], 1024; digits = 1)) | $(_spread([x.time for x in v], 1e-3)) |")
  end
end

try
  report(stdout, measure(ROUNDS))
finally
  clear_ours!()
end
