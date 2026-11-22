# The read-only juliac --trim entry of the fixture app (#1599): boot, one typed read, two comparison filters,
# an order_by each way, the other common lookups and comparisons against an expression (`tools/reads.jl`), no write.
# `main.jl` without its write steps (the refused creates, the write, the update and the delete); this
# binary returns rows (#1788), and the `Trim (juliac)` workflow builds and runs it (README.md).
#   JIT:  julia --project=test/trim test/trim/read.jl <run dir>
#   exe:  <build dir>/read <run dir>
#   tasks: <build dir>/read <run dir> tasks  adds the pool's long-lived tasks: the reaper and the
#          deferred close (about 20 s; see steps.jl)
# The steps and their output are in `steps.jl`, shared with `main.jl`.
using TrimF1, PormG, SQLite, Dates
include("steps.jl")
# The roots a trimmed build needs (the render's run-time re-entries, upstream's), a no-op under the JIT (#1599).
PormG.trim_entrypoints(PormG.ConnectionPool.SQLiteConnectionPool)

function (@main)(args::Vector{String})::Cint
    t0 = time_ns()
    dir = start_step(args)
    tasks = length(args) >= 2 && args[2] == "tasks"
    boot_step(dir, tasks ? 1 : 0) || return Cint(1)
    query_step() || return Cint(3)
    compare_step() || return Cint(10)
    order_step() || return Cint(11)
    lookup_step() || return Cint(13)
    expr_step() || return Cint(14)
    untyped_step() || return Cint(17)
    func_step() || return Cint(19)
    subquery_step() || return Cint(20)
    join_step() || return Cint(21)
    tasks && (reap_step() || return Cint(4))
    tasks && (close_step() || return Cint(5))
    elapsed_step(t0)
    return Cint(0)
end
