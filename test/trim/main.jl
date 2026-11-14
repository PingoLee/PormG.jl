# The juliac --trim entry of the fixture app (#1616, #1599): boot, one write, one typed read.
#   JIT:  julia --project=test/trim test/trim/main.jl <run dir>
#   exe:  <build dir>/main <run dir>         (see README.md)
# The steps and their output are in `steps.jl`, shared with the read-only entry `read.jl`.
using TrimF1, PormG, SQLite, Dates
include("steps.jl")

function (@main)(args::Vector{String})::Cint
    t0 = time_ns()
    dir = start_step(args)
    boot_step(dir) || return Cint(1)
    try
        M.Race.objects.create("year" => 2009, "round" => 6, "circuitid" => 1,
                              "name" => "Monaco Grand Prix", "date" => Date(2009, 5, 24))
        say("write", "ok")
    catch e
        failed("write", e); return Cint(2)
    end
    query_step() || return Cint(3)
    elapsed_step(t0)
    return Cint(0)
end
