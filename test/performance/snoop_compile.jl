## SnoopCompile profiling script for PormG
##
## Usage (from the repo root):
##
##   $env:PORMG_DB = "db_sl"
##   $env:PORMG_PROFILEVIEW = "1"  # (optional) open flamegraph after profiling
##   julia --project=. test/performance/snoop_compile.jl
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
## NOTE: SnoopCompile and SnoopCompileCore are dev-only profiling deps.
##       This script can add them to the active environment on first run.

using Pkg

# ── install snoop deps into the active project layer if not present ────────────
for pkg in ("SnoopCompile", "SnoopCompileCore", "ProfileView")
    if !haskey(Pkg.project().dependencies, pkg)
        @info "Adding $pkg to current environment (dev-only)"
        Pkg.add(pkg)
    end
end

# ── Step 1: load the profiling packages BEFORE any workload ───────────────────
using SnoopCompile
using SnoopCompileCore
using PormG
using DataFrames

import PormG.QueryBuilder: Sum, Avg, Count, Max, Min, Qor, F, Q, Case, When, Value, Round

# ── Step 2: profile the full ORM workload ─────────────────────────────────────
#
# @snoop_inference captures every method inference triggered inside the block.
# We mirror the integration test suite so the directives reflect real usage.

const PORMG_DB_FOLDER = get(ENV, "PORMG_DB", "db_sl")
@info "Starting inference profiling workload..." folder = PORMG_DB_FOLDER

tinf = @snoop_inference begin

    ENV["PORMG_ENV"] = "dev"
    db_folder = PORMG_DB_FOLDER

    cd(joinpath(@__DIR__, "..", "integration"))

    PormG.Configuration.load(db_folder)

    PormG.@import_models "C:/Sistemas/PormG-new-features/test/integration/db_sl/models.jl" models
    import .models as M

    # ── simple filters & ordering ──────────────────────────────────────────────
    M.Driver.objects.filter("nationality" => "British").order_by("-driverid").limit(10).list()
    M.Driver.objects.filter("surname__@startswith" => "Sc").list()
    M.Circuit.objects.filter("country" => "Italy").values("name", "location").list()

    # ── FK join traversal (double-underscore) ──────────────────────────────────
    M.Race.objects.filter("circuitid__country" => "Monaco").order_by("-year").values("*").limit(5).list()
    M.Driver_standings.objects.filter("raceid__year__@gte" => 2020
      ).filter("points__@gt" => 0.0
      ).order_by("-points"
      ).limit(20).values("*").list()

    # ── aggregates + values ────────────────────────────────────────────────────
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

    # ── Qor logic ─────────────────────────────────────────────────────────────
    M.Race.objects.filter(
        Qor("year" => 2021, "year" => 2022)
    ).order_by("year", "round"
    ).values("year", "round", "name"
    ).list()

    # ── count / exists ─────────────────────────────────────────────────────────
    M.Lap_times.objects.filter("raceid__year" => 2021).count()
    M.Pit_stops.objects.filter("stop__@ne" => 1).exists()

    # ── list_json ──────────────────────────────────────────────────────────────
    M.Qualifying.objects.filter("raceid__year" => 2022
        ).filter("position__@lte" => 3
        ).values("driverid__code", "raceid__name", "position"
        ).order_by("raceid__round", "position"
        ).list_json()

    # ── F() field references ───────────────────────────────────────────────────
    M.Result.objects.filter("points__@gte" => 0.0
        ).values(
            "driverid__surname",
            "points",
            "adjusted" => F("points") * 1.1
        ).limit(10).list()

    # ── offset / pagination ────────────────────────────────────────────────────
    M.Driver.objects.order_by("surname").limit(25).offset(50).list()

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
triggers = inference_triggers(tinf)

if !isempty(triggers)
    sorted = sort(triggers; by = x -> SnoopCompileCore.inclusive(x), rev = true)
    for (i, t) in enumerate(first(sorted, 10))
        println("$i. ", t)
    end
else
    println("(no triggers recorded — workload may have already been fully precompiled)")
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
