# How much of the unit suite is JIT compilation, per file? (#819)
#
# Runs test/runtests.jl's unit file set the way runtests.jl does (one process, every file `include`d
# into Main, same preamble), reading Julia's cumulative compile counters around each file.
#
#     julia -O0 --project=test/integration test/performance/compile_profile.jl out.csv [test_x.jl ...]
#
# Optional file names restrict the run to those files, in runtests.jl order (a quick check).
# Aqua is not included. `Pkg.test` adds --check-bounds=yes and other flags (and CI adds coverage),
# which this does not, so its totals are not CI's. `-O0` matches how the suite and CI run (#819);
# drop it to measure at Julia's default -O2.
#
# `compile_s` is inference + codegen, which is what a PrecompileTools workload can move into the
# package image. What it cannot move is compile of the test files' own code, and of specializations
# on types the tests define themselves (mocks), so read a file's compile share as an upper bound on
# what the workload can save there, not a forecast.
isempty(ARGS) && error("usage: julia -O0 --project=test/integration test/performance/compile_profile.jl out.csv [test_x.jl ...]")
Base.cumulative_compile_timing(true)
const T_START = time_ns()
using Test
using PormG
include(joinpath(@__DIR__, "..", "load_drivers.jl"))
haskey(ENV, "PORMG_ENV") || (ENV["PORMG_ENV"] = "test")
delete!(ENV, "PORMG_POSTGRES_DRIVER")

const UNIT_DIR = joinpath(@__DIR__, "..", "unit")
const OUT = ARGS[1]
const ONLY = Set(ARGS[2:end])

# The files runtests.jl runs, in its order; the commented-out planner file stays out.
function unit_files()
    files = String[]
    open(joinpath(@__DIR__, "..", "runtests.jl")) do io
        for line in eachline(io)
            m = match(r"^\s*@testset\s.*\binclude\(\"unit/([^\"]+)\"\)", line)
            m === nothing || push!(files, m[1])
        end
    end
    # An empty list would profile nothing and report a zero total, which reads as a measurement.
    # It means the regex above stopped matching runtests.jl's shape.
    isempty(files) && error("compile_profile: no unit files matched in test/runtests.jl")
    missing_only = setdiff(ONLY, files)
    isempty(missing_only) || throw(ArgumentError("compile_profile: not in runtests.jl: $(join(sort!(collect(missing_only)), ", "))"))
    return isempty(ONLY) ? files : filter(in(ONLY), files)
end

compile_s() = Base.cumulative_compile_time_ns() ./ 1e9   # (compile, recompile)

# Resolved before the `try` below, whose `finally` writes the CSV: a bad file list must fail with no
# output file at all, not with a load-row-only CSV.
const FILES = unit_files()

const ROWS = Tuple{String,Float64,Float64,Float64}[]
let (c, r) = compile_s()
    push!(ROWS, ("<load: PormG + drivers>", (time_ns() - T_START) / 1e9, c, r))
end

try
    @testset "PormG Unit Tests (compile profile)" begin
        for f in FILES
            (c0, r0) = compile_s(); t0 = time_ns()
            try
                @testset "$f" begin include(joinpath(UNIT_DIR, f)) end
            finally
                (c1, r1) = compile_s()
                push!(ROWS, (f, (time_ns() - t0) / 1e9, c1 - c0, r1 - r0))
            end
        end
    end
finally
    # Written even when a testset fails, so a red file still leaves its row.
    open(OUT, "w") do io
        println(io, "file,wall_s,compile_s,recompile_s")
        for (n, w, c, r) in ROWS
            println(io, join((n, round(w; digits = 3), round(c; digits = 3), round(r; digits = 3)), ","))
        end
    end
    # Files only: the load row is a one-time cost, and on a fresh env it includes package precompilation.
    files = ROWS[2:end]
    w = sum((r[2] for r in files); init = 0.0); c = sum((r[3] for r in files); init = 0.0)
    println("TOTAL (files) wall=$(round(w; digits = 1))s compile=$(round(c; digits = 1))s ($(round(Int, 100c / max(w, eps())))%)")
end
