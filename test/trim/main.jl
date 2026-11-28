# The juliac --trim entry of the fixture app (#1616, #1599): boot, models loaded with @import_models, a read-only second
# key, two refused writes, two comparison filters,
# an order_by each way, the other common lookups and comparisons against an expression, one write, one typed read, one update, one delete, one bulk_insert of two rows and
# one bulk_insert validation refuses.
#   JIT:  julia --project=test/trim test/trim/main.jl <run dir>
#   exe:  <build dir>/main <run dir>         (see README.md)
# The steps and their output are in `steps.jl`, shared with the read-only entry `read.jl`.
using TrimF1, PormG, SQLite, Dates
include("steps.jl")
# The roots a trimmed build needs (the render's run-time re-entries, upstream's), a no-op under the JIT (#1599).
PormG.trim_entrypoints(PormG.ConnectionPool.SQLiteConnectionPool)

function (@main)(args::Vector{String})::Cint
    t0 = time_ns()
    dir = start_step(args)
    boot_step(dir) || return Cint(1)
    # How an application starts (#1599 layers 1-3): models loaded with `@import_models` and read through the key they
    # recorded, registered in code (`steps.jl`), and a second, read-only key beside the entry's own (`tools/connections.jl`).
    imported_step(dir) || return Cint(34)
    keys_step(key -> TrimF1.register_readonly!(dir, key)) || return Cint(33)
    refused_step() || return Cint(6)
    compare_step() || return Cint(10)  # before the write: the two seeded races (`tools/reads.jl`)
    order_step() || return Cint(11)
    lookup_step() || return Cint(13)
    expr_step() || return Cint(14)
    untyped_step() || return Cint(17)   # the untyped read, before the write (#1599 layer 6)
    func_step() || return Cint(19)
    subquery_step() || return Cint(20)
    join_step() || return Cint(21)
    cte_step() || return Cint(26)  # a CTE body copied and typed at its types (`tools/reads.jl`, #1599 layer 5)
    # The read shapes applications use most (`tools/reads.jl`, #1599 layer 5): relation hops, the remaining lookups and
    # Q/Qor, paging, aggregates, and the shapes each engine answers its own way.
    hops_step() || return Cint(37)
    m2m_step() || return Cint(56)        # a many-to-many hop each way (`tools/reads.jl`, #1689)
    lookup_more_step() || return Cint(38)
    qor_many_step() || return Cint(51)   # Q/Qor from 32 arguments (`tools/reads.jl`)
    copy_step() || return Cint(54)       # `.copy()`, the copy changed and both read (`tools/reads.jl`, #1684)
    page_step() || return Cint(39)
    aggregate_step() || return Cint(40)
    engine_read_step() || return Cint(41)
    lookup_refusals_step() || return Cint(50)   # the JSON and network lookups (`tools/reads.jl`)
    array_lookup_step() || return Cint(53)      # the array lookups (`tools/reads.jl`, #1844)
    filter_refusal_step() || return Cint(52)    # filter values refused and located (`tools/reads.jl`, #1844)
    # The terminals applications use most (`tools/terminals.jl`, #1599 layer 6): count(), exists(), a locking read in a
    # transaction, a raw fetch, and the Tables.jl interface a table sink reads.
    count_step() || return Cint(42)
    exists_step() || return Cint(43)
    lock_step(TrimF1.KEY) || return Cint(44)
    raw_fetch_step(TrimF1.KEY) || return Cint(45)
    tables_step() || return Cint(46)
    write_step(1) || return Cint(2)   # the Monaco circuit `prep.jl` seeds first
    query_step() || return Cint(3)
    update_step() || return Cint(7)
    delete_step() || return Cint(8)
    bulk_step(1) || return Cint(9)   # the Monaco circuit `prep.jl` seeds first
    bulk_refused_step() || return Cint(12)
    bulk_update_step(1) || return Cint(15)        # the upsert-shaped writes (`tools/writes.jl`, #1694)
    update_or_create_step(1) || return Cint(16)
    get_or_create_step(1) || return Cint(18)
    copy_write_step(1) || return Cint(55)   # a filled handler copied and written through (`tools/writes.jl`, #1684)
    cascade_step(1) || return Cint(22)  # the cascading delete (`tools/writes.jl`, #1694)
    # The write residue of layer 7 (`tools/writes.jl`, #1694): bulk_update with filters= and two keys, SET_DEFAULT, a
    # self-referential CASCADE, and the bulk writers' refusals.
    bulk_update_more_step(1) || return Cint(27)
    set_default_step() || return Cint(28)
    self_cascade_step() || return Cint(29)
    bulk_refusals_step(1) || return Cint(30)
    bulk_conflict_step(1) || return Cint(31)        # bulk_insert's on_conflict= (`tools/writes.jl`, #1694)
    # The writes applications use most (`tools/writes.jl`, #1694, #1599 layer 7): bulk writes from a column table, and the
    # delete rules beyond CASCADE.
    bulk_table_step(1) || return Cint(47)
    delete_rules_step() || return Cint(49)
    transaction_step(1, TrimF1.KEY) || return Cint(24)  # a user transaction (`tools/connections.jl`, #1599 layer 2)
    nested_transaction_step(1, TrimF1.KEY) || return Cint(35)  # a transaction inside one (`tools/connections.jl`)
    spawned_read_step(2008) || return Cint(36)  # a read on spawned tasks (`tools/connections.jl`, #1599 layer 2)
    elapsed_step(t0)
    # Last: a trimmed binary runs no atexit hook, so the app closes its pools itself.
    close_all_step(PormG.Configuration.get_settings(TrimF1.KEY).connections::PormG.ConnectionPool.SQLiteConnectionPool) || return Cint(25)
    return Cint(0)
end
