# The read-only juliac --trim entry of the fixture app (#1599): boot and one typed read, no write.
# `main.jl` without its write step, which still stops at layer 7; this binary returns rows (#1788),
# and the `Trim (juliac)` workflow builds and runs it (README.md).
#   JIT:  julia --project=test/trim test/trim/read.jl <run dir>
#   exe:  <build dir>/read <run dir>
# The steps and their output are in `steps.jl`, shared with `main.jl`.
using TrimF1, PormG, SQLite, Dates
include("steps.jl")

function (@main)(args::Vector{String})::Cint
    t0 = time_ns()
    dir = start_step(args)
    boot_step(dir) || return Cint(1)
    query_step() || return Cint(3)
    elapsed_step(t0)
    return Cint(0)
end
