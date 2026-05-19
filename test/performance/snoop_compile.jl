## SnoopCompile profiling script for PormG
##
## Usage on Ubuntu / bash (from the repo root):
##
##   export PORMG_DB=db_sl
##   export PORMG_SNOOP_MODE=light   # optional: faster representative subset
##   export PORMG_PROFILEVIEW=1      # optional: open flamegraph after profiling
##   julia -t auto --project=. test/performance/snoop_compile.jl
##    
## Output
##   snoop_out/PormG.jl  — raw precompile directives inferred from the workload
##
## Workflow
##   1. Load SnoopCompile before the workload so @snoop_inference is available.
##   2. Run a heavy workload that exercises every major ORM codepath.
##   3. Parcel and write directives, then print a top-10 inference-time summary.
##   4. Optionally open a flamegraph with ProfileView.
##
## NOTE: SnoopCompile and related tooling are dev-only profiling deps kept in
##       [extras]. Install them with `Pkg.instantiate()` from the repo root.

# ── Step 1: load the profiling packages BEFORE any workload ───────────────────
using SnoopCompile
using SnoopCompileCore
using PormG

import PormG.QueryBuilder: Sum, Avg, Count, Max, Min, Qor, F, Q, Case, When, Value, Round

const PORMG_DB_FOLDER = get(ENV, "PORMG_DB", "db_sl")
const INTEGRATION_DIR = joinpath(@__DIR__, "..", "integration")
const SNOOP_MODE = get(ENV, "PORMG_SNOOP_MODE", "full")
const SHOW_PROGRESS = get(ENV, "PORMG_SNOOP_PROGRESS", "1") == "1"

function progress(message)
    if SHOW_PROGRESS
        println("[snoop] ", message)
    end
    nothing
end

# ── Step 2: profile the full ORM workload ─────────────────────────────────────
#
# @snoop_inference captures every method inference triggered inside the block.
# We mirror the integration test suite so the directives reflect real usage.

ENV["PORMG_ENV"] = "dev"
cd(INTEGRATION_DIR)
PormG.Configuration.load(PORMG_DB_FOLDER)

if PORMG_DB_FOLDER == "db_sl"
    PormG.@import_models "../integration/db_sl/models.jl" models
elseif PORMG_DB_FOLDER == "db_2"
    PormG.@import_models "../integration/db_2/models.jl" models
else
    error("Unsupported PORMG_DB folder for snoop workload: $PORMG_DB_FOLDER")
end

const M = models

@info "Starting inference profiling workload..." folder = PORMG_DB_FOLDER mode = SNOOP_MODE

# ── Warm up ALL execution paths BEFORE @snoop_inference ────────────────────────
# SnoopCompile's @snoop_inference hooks into the C-level type inference engine
# (jl_set_newly_inferred) and captures inference events from ALL tasks globally —
# including the persistent SQLite async worker (Threads.@spawn while-true loop).
#
# When .list() runs inside @snoop_inference, the worker's sqlite_execute() call
# triggers new method inference that gets recorded. After the block ends,
# timingtree/addchildren! hangs processing those records because the worker's
# inference graph is deeply entangled with Channel/Dict internals.
#
# Fix: run every query that will appear in the snoop block ONCE beforehand.
# This compiles all execution-path methods so .list() inside the block triggers
# zero new inference in the worker. Query-building inference IS still captured.
progress("warm-up: pre-compiling execution paths")
M.Circuit.objects.filter("country" => "Italy").values("name", "location").list()

tinf = @snoop_inference begin
    if SNOOP_MODE == "light"
        progress("phase 1/3: simple filters and ordering")
    else
        progress("phase 1/8: simple filters and ordering")
    end

    # ── simple filters & ordering ──────────────────────────────────────────────
    M.Driver.objects.filter("nationality" => "British").order_by("-driverid").limit(10).list()
    M.Driver.objects.filter("surname__@startswith" => "Sc").list()
    M.Circuit.objects.filter("country" => "Italy").values("name", "location").list()

    if SNOOP_MODE == "full"
        progress("phase 2/8: foreign key joins")

        # ── FK join traversal (double-underscore) ──────────────────────────────
        M.Race.objects.filter("circuitid__country" => "Monaco").order_by("-year").values("*").limit(5).list()
        M.Driver_standings.objects.filter("raceid__year__@gte" => 2020
          ).filter("points__@gt" => 0.0
          ).order_by("-points"
          ).limit(20).values("*").list()

        progress("phase 3/8: aggregates")

        # ── aggregates + values ────────────────────────────────────────────────
        M.Driver_standings.objects.filter("raceid__year" => 2021
          ).values(
                "driverid__forename",
                "driverid__surname",
                "total_points" => Sum("points"),
                "wins" => Sum("wins")
            ).order_by("-total_points"
            ).list()

        M.Constructor_standings.objects.filter("raceid__year__@gte" => 2019
          ).values(
                "constructorid__name",
                "seasons_top3" => Count("constructorstandingsid")
            ).filter("position__@lte" => 3
            ).order_by("-seasons_top3"
            ).list()

        progress("phase 4/8: Qor logic")

        # ── Qor logic ─────────────────────────────────────────────────────────
        M.Race.objects.filter(
            Qor("year" => 2021, "year" => 2022)
        ).order_by("year", "round"
        ).values("year", "round", "name"
        ).list()

        progress("phase 5/8: count and exists")
    else
        progress("phase 2/3: count and exists")
    end

    # # ── count / exists ─────────────────────────────────────────────────────────
    M.Lap_times.objects.filter("raceid__year" => 2021).count()
    M.Pit_stops.objects.filter("stop__@ne" => 1).exists()

    if SNOOP_MODE == "full"
        progress("phase 6/8: json output")

        # ── list(:json) ───────────────────────────────────────────────────────
        M.Qualifying.objects.filter("raceid__year" => 2022
            ).filter("position__@lte" => 3
            ).values("driverid__code", "raceid__name", "position"
            ).order_by("raceid__round", "position"
            ).list(:json)

        progress("phase 7/8: F expressions")
    else
        progress("phase 3/3: F expressions and deep joins")
    end

    # ── F() field references ───────────────────────────────────────────────────
    M.Result.objects.filter("points__@gte" => 0.0
        ).values(
            "driverid__surname",
            "points",
            "adjusted" => F("points") * 1.1
        ).limit(10).list()

    if SNOOP_MODE == "full"
        progress("phase 8/8: pagination and deep joins")

        # ── offset / pagination ────────────────────────────────────────────────
        M.Driver.objects.order_by("surname").limit(25).offset(50).list()
    end

    # ── deep join (3-level) ────────────────────────────────────────────────────
    M.Result.objects.filter("raceid__circuitid__country" => "Brazil"
        ).values("driverid__surname", "raceid__name", "raceid__year", "points"
        ).order_by("-points"
        ).limit(10).list()

end  # @snoop_inference

# ── Step 3: parcel and write directives ───────────────────────────────────────
@info "Parceling and writing precompile directives..."
outdir = joinpath(@__DIR__, "snoop_out")
mkpath(outdir)

ttot, pcs = SnoopCompile.parcel(tinf)
SnoopCompile.write(outdir, pcs)

@info "Precompile directives written to $outdir"
@info "Total inference time" seconds=round(ttot; digits=3)

# ── Step 4: top-10 inference hotspots ─────────────────────────────────────────
#
# These are the methods worth adding to src/precompile.jl @compile_workload.
println("\n── Top-10 inference hotspots (inclusive time) ────────────────────────────")
try
    triggers = inference_triggers(tinf)

    if !isempty(triggers)
        sorted = sort(triggers; by = x -> SnoopCompileCore.inclusive(x), rev = true)
        for (i, t) in enumerate(first(sorted, 10))
            println("$i. ", t)
        end
    else
        println("(no triggers recorded — workload may have already been fully precompiled)")
    end
catch e
    @warn "inference_triggers failed (common when warm-up pre-compiles execution paths)" exception=e
end

# ── Step 5: Visual Analysis (Optional) ────────────────────────────────────────
# ProfileView is useful for interactive inspection of inference hotspots, but it
# requires a GUI environment. Enable it only when needed.
if get(ENV, "PORMG_PROFILEVIEW", "0") == "1"
    @info "Opening ProfileView flamegraph..."
    using ProfileView
    fg = flamegraph(tinf)
    ProfileView.view(fg)
end

println("\nDone. Review $(joinpath(outdir, "PormG.jl")) and merge any new")
println("precompile() calls into src/precompile.jl @compile_workload block.")
