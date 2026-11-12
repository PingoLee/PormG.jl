# ============================================================
# test/unit/test_unit_files_load_drivers.jl
#
# Every unit file loads the SQL drivers itself (#1658).
#
# `CONTRIBUTING.md` → *Verification* documents one way to run a single test file:
#
#   julia --project=test/integration test/unit/<file>.jl
#
# That environment *carries* LibPQ, Postgres, SQLite and MySQL, but carrying a driver is not
# loading it. They are `[weakdeps]`, so each extension activates only when something runs `using` on
# its driver. Under `Pkg.test()`, `test/runtests.jl` includes `test/load_drivers.jl` before any unit
# file, so a file that never loads a driver is green there and red on its own:
# `MissingConfigurationError: … the SQLite backend requires SQLite`. Eight files did exactly that.
# One cost a review cycle, because a false red looks like a regression.
#
# Deciding from the source which file needs a driver is the heuristic that missed those eight, so the
# rule covers every file: each `test/unit/test_*.jl` carries the guard
#
#   isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
#
# Under `Pkg.test()` the `isdefined` short-circuits, so it costs nothing. A file run on its own pays
# the driver load, a few seconds. The unconditional `include(joinpath(@__DIR__, "..", "load_drivers.jl"))`
# also counts (`load_drivers.jl` is idempotent). `helper_*.jl` files are included by unit files and
# are not run on their own, so they are out of scope.
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

# ─────────────────────────────────────────────────────────────────────────────
# Every unit file includes test/load_drivers.jl (#1658)
# What it tests: each `test/unit/test_*.jl` has a non-comment line that includes
#   `joinpath(@__DIR__, "..", "load_drivers.jl")`. A file without one is named in the failure. No SQL;
#   it reads the files' source.
# Why it matters: the documented single-file command does not load the drivers, so a file without the
#   guard can be green under `Pkg.test()` and red on its own, and nothing else would catch it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "every unit file includes test/load_drivers.jl (#1658)" begin
    needle = """include(joinpath(@__DIR__, "..", "load_drivers.jl"))"""
    unit_dir = @__DIR__
    files = sort!(filter(f -> startswith(f, "test_") && endswith(f, ".jl"), readdir(unit_dir)))
    # A floor, so a wrong directory cannot pass by finding nothing to check.
    @test length(files) > 300

    loads_drivers(path) = open(path) do io
        any(eachline(io)) do line
            stripped = lstrip(line)
            !startswith(stripped, "#") && occursin(needle, stripped)
        end
    end
    @test filter(f -> !loads_drivers(joinpath(unit_dir, f)), files) == String[]
end
