# The read-only juliac --trim entry of the fixture app (#1599): boot and one typed read, no write.
# `main.jl` without its write step, which still stops at layer 7; this binary returns rows (#1788),
# and the `Trim (juliac)` workflow builds and runs it (README.md).
#   JIT:  julia --project=test/trim test/trim/read.jl <run dir>
#   exe:  <build dir>/read <run dir>
#   tasks: <build dir>/read <run dir> tasks  adds the pool's long-lived tasks: the reaper and the
#          deferred close (about 20 s; see steps.jl)
# The steps and their output are in `steps.jl`, shared with `main.jl`.
using TrimF1, PormG, SQLite, Dates
include("steps.jl")

function (@main)(args::Vector{String})::Cint
    t0 = time_ns()
    dir = start_step(args)
    tasks = length(args) >= 2 && args[2] == "tasks"
    boot_step(dir, tasks ? 1 : 0) || return Cint(1)
    query_step() || return Cint(3)
    tasks && (reap_step() || return Cint(4))
    tasks && (close_step() || return Cint(5))
    elapsed_step(t0)
    return Cint(0)
end
