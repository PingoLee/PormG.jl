# The juliac --trim entry of the fixture app (#1616, #1599): boot, two refused writes, two comparison filters
# and an order_by each way, one write, one typed read, one update, one delete and one bulk_insert of two rows.
#   JIT:  julia --project=test/trim test/trim/main.jl <run dir>
#   exe:  <build dir>/main <run dir>         (see README.md)
# The steps and their output are in `steps.jl`, shared with the read-only entry `read.jl`.
using TrimF1, PormG, SQLite, Dates
include("steps.jl")

function (@main)(args::Vector{String})::Cint
    t0 = time_ns()
    dir = start_step(args)
    boot_step(dir) || return Cint(1)
    refused_step() || return Cint(6)
    compare_step() || return Cint(10)  # before the write: the two seeded races (`tools/reads.jl`)
    order_step() || return Cint(11)
    write_step(1) || return Cint(2)   # the Monaco circuit `prep.jl` seeds first
    query_step() || return Cint(3)
    update_step() || return Cint(7)
    delete_step() || return Cint(8)
    bulk_step() || return Cint(9)
    elapsed_step(t0)
    return Cint(0)
end
