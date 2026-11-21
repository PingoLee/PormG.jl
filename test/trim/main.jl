# The juliac --trim entry of the fixture app (#1616, #1599): boot, two refused writes, two comparison filters,
# an order_by each way, the other common lookups and comparisons against an expression, one write, one typed read, one update, one delete, one bulk_insert of two rows and
# one bulk_insert validation refuses.
#   JIT:  julia --project=test/trim test/trim/main.jl <run dir>
#   exe:  <build dir>/main <run dir>         (see README.md)
# The steps and their output are in `steps.jl`, shared with the read-only entry `read.jl`.
using TrimF1, PormG, SQLite, Dates
include("steps.jl")
include(joinpath(@__DIR__, "tools", "upstream_roots.jl"))
# The render's run-time re-entry into a nested node finds code only where the build rooted it (#1599 layer 5).
for (f, t) in PormG.QueryBuilder._trim_render_roots(PormG.ConnectionPool.SQLiteConnectionPool); Base.Experimental.entrypoint(f, t); end

function (@main)(args::Vector{String})::Cint
    t0 = time_ns()
    dir = start_step(args)
    boot_step(dir) || return Cint(1)
    refused_step() || return Cint(6)
    compare_step() || return Cint(10)  # before the write: the two seeded races (`tools/reads.jl`)
    order_step() || return Cint(11)
    lookup_step() || return Cint(13)
    expr_step() || return Cint(14)
    untyped_step() || return Cint(17)   # the untyped read, before the write (#1599 layer 6)
    func_step() || return Cint(19)
    subquery_step() || return Cint(20)
    join_step() || return Cint(21)
    write_step(1) || return Cint(2)   # the Monaco circuit `prep.jl` seeds first
    query_step() || return Cint(3)
    update_step() || return Cint(7)
    delete_step() || return Cint(8)
    bulk_step(1) || return Cint(9)   # the Monaco circuit `prep.jl` seeds first
    bulk_refused_step() || return Cint(12)
    bulk_update_step(1) || return Cint(15)        # the upsert-shaped writes (`tools/writes.jl`, #1694)
    update_or_create_step(1) || return Cint(16)
    get_or_create_step(1) || return Cint(18)
    elapsed_step(t0)
    return Cint(0)
end
