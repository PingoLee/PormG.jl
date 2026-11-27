# The juliac --trim entry of the fixture's MySQL variant (#1599, #1614): `../main.jl`'s app with MySQL.jl
# in place of SQLite — boot, one typed read, the comparison filters, order_by, lookups and expression comparisons (`../tools/reads.jl`), the single-row
# write (`../tools/writes.jl`: create, read back, update, delete), a `bulk_insert` of two rows and one statement
# the server refuses (`../tools/failing.jl`).
#   JIT:  julia --project=test/trim/mysql test/trim/mysql/main.jl
#   exe:  <build dir>/main                   (see ../README.md, "The MySQL variant")
#
# The boot is in this file, not in a package: `juliac` builds a package from a copy of its directory, so a
# package here could not include `../db/models.jl`, the models the SQLite app uses. It registers a
# `mysql://` URL (#1769), so no YAML is read. The server comes from the `PORMG_TRIM_*` environment
# variables (`../tools/server.jl`); unset, it is 127.0.0.1:1, where nothing listens: nothing is contacted
# at boot, and the read raises `PoolConnectError` under the JIT. Against a server seeded by `prep.jl`, the
# read returns the Monaco race. Each step prints one line to `Core.stdout`, as in ../main.jl.
using PormG, MySQL, Dates
# The roots a trimmed build needs (the render's run-time re-entries, upstream's), a no-op under the JIT (#1599).
PormG.trim_entrypoints(PormG.ConnectionPool.MySQLConnectionPool)

include(joinpath(@__DIR__, "..", "db", "models.jl"))
import .models as M
include(joinpath(@__DIR__, "..", "tools", "server.jl"))
include(joinpath(@__DIR__, "..", "tools", "failing.jl"))

const KEY = "f1"

"Register the MySQL connection under `KEY` and bind the models to it (#1606, #1769)."
function boot!(server::TrimServer)
    PormG.Configuration.register_connection(KEY, trim_url(server, "mysql");
        adapter = "MySQL", env = "prod", pool_size = 1, change_db = true, change_data = true)
    PormG.Models.set_models(models.MODEL_SET; key = KEY)
    return nothing
end

"""Register `key` on the same server with writes off (`change_data = false`, the default): a second, read-only
connection beside `KEY` (`keys_step`, `../tools/connections.jl`, #1599 layer 1)."""
function register_readonly!(server::TrimServer, key::String)
    PormG.Configuration.register_connection(key, trim_url(server, "mysql"); adapter = "MySQL", env = "prod", pool_size = 1)
    return nothing
end

# The struct of ../main.jl: `list(show_query = :struct)` writes the same fields on MySQL (#1632).
struct RaceRow
    raceid::Int64     # IDField
    year::Int64       # IntegerField
    round::Int64      # IntegerField
    circuitid::Int64  # ForeignKey
    name::String      # CharField
    date::Date        # DateField
end

say(step::String, detail::String) = (println(Core.stdout, "step\t", step, "\t", detail); nothing)

@noinline function failed(step::String, @nospecialize(e))
    say(step, string("threw ", nameof(typeof(e))))
    # A call the image has no code for: the method instance it missed, printed by the runtime's own static printer.
    e isa Core.MissingCodeError && Core.println("  missing: ", (e::Core.MissingCodeError).mi)
    e isa TypeError && Core.println("  typeerror: ", (e::TypeError).func, " ", (e::TypeError).context)
    e isa MethodError && Core.println("  missed: ", typeof(e.f))
    e isa MethodError && Core.println("  args: ", typeof(e.args))
    e isa PormG.ModelDefinitionError && Core.println("  msg: ", (e::PormG.ModelDefinitionError).msg)
    e isa PormG.InvalidConfigurationError &&
        Core.println("  msg: ", (e::PormG.InvalidConfigurationError).msg)
    # The pool wraps whatever the driver's connect raised: a refused port and a call the trimmed image has
    # no code for both arrive as `PoolConnectError`, told apart by the cause's type. Its text is not
    # printed: a server's refusal can name the user.
    if e isa PormG.PoolConnectError
        c = (e::PormG.PoolConnectError).cause
        Core.println("  cause: ", string(nameof(typeof(c))))
        c isa MethodError && Core.println("  cause missed: ", typeof(c.f))
        c isa MethodError && Core.println("  cause args: ", typeof(c.args))
    end
    # A statement's failure, likewise by the cause's type and the SQLSTATE; the server's message is not
    # printed, since it can quote a bound value.
    if e isa PormG.StatementError
        se = e::PormG.StatementError
        c = se.cause
        Core.println("  cause: ", string(nameof(typeof(c))))
        c isa MethodError && Core.println("  cause missed: ", typeof(c.f))
        c isa MethodError && Core.println("  cause args: ", typeof(c.args))
        se.sqlstate isa String && Core.println("  sqlstate: ", se.sqlstate)
    end
    try   # the frames, when the trimmed image can symbolize them
        for fr in stacktrace(catch_backtrace())
            f = string(fr.file)
            (occursin("PormG", f) || occursin("trim", f)) &&
                Core.println("  at ", string(fr.func), " ", basename(f), ":", string(fr.line))
        end
    catch err
        # swallows a failed symbolization: the frames are a diagnostic, the step already reported.
        err isa Exception || rethrow()
        Core.println("  (no stacktrace)")
    end
    return nothing
end

# The typed read, one line per row (`../steps.jl`'s `query_step`). Exit code 3 when it fails.
function query_step()::Bool
    try
        # Ordered by year, so the two rows print in one order on every driver (Postgres.jl returned them in heap order).
        rows = M.Race.objects.filter("circuitid__country" => "Monaco").order_by("year").list(RaceRow)
        say("query", string(length(rows), " rows"))
        for r in rows
            say("row", string(r.raceid, " ", r.year, " ", r.name, " ", r.date))
        end
        return true
    catch e
        failed("query", e); return false
    end
end

include(joinpath(@__DIR__, "..", "tools", "writes.jl"))
include(joinpath(@__DIR__, "..", "tools", "reads.jl"))
include(joinpath(@__DIR__, "..", "tools", "connections.jl"))
raw_marker(i::Int)::String = "?"   # the backend's bind marker, for the raw `fetch` of `../tools/terminals.jl`
include(joinpath(@__DIR__, "..", "tools", "terminals.jl"))

function (@main)(args::Vector{String})::Cint
    t0 = time_ns()
    say("main", "entered")
    say("ext", string(Base.get_extension(PormG, :PormGMySQLExt) !== nothing))
    server = trim_server()
    say("server", trim_where(server))
    try
        boot!(server)
        say("boot", "ok")
    catch e
        failed("boot", e); return Cint(1)
    end
    query_step() || return Cint(3)
    # A second, read-only key beside the entry's own, registered in code (#1599 layer 1, `../tools/connections.jl`).
    keys_step(key -> register_readonly!(server, key)) || return Cint(33)
    # The comparison filters, `order_by`, the other lookups and the expression comparisons (#1599 layer 5, `../tools/reads.jl`), on the two seeded races.
    compare_step() || return Cint(10)
    order_step() || return Cint(11)
    lookup_step() || return Cint(13)
    expr_step() || return Cint(14)
    untyped_step() || return Cint(17)
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
    lock_step(KEY) || return Cint(44)
    raw_fetch_step(KEY) || return Cint(45)
    tables_step() || return Cint(46)
    # The single-row write (#1614, `../tools/writes.jl`): create with the auto-filled fields, read back, update,
    # delete, each checked by a typed read. Monaco's id is read first: the server's sequence is not reset.
    circuitid = monaco_circuitid_step()
    circuitid === nothing && return Cint(2)
    write_step(circuitid) || return Cint(2)
    query_step() || return Cint(3)
    update_step() || return Cint(7)
    delete_step() || return Cint(8)
    # `bulk_insert` of two Monaco races, read back (#1694, #1614, `../tools/writes.jl`).
    bulk_step(circuitid) || return Cint(9)
    # The upsert-shaped writes, each read back typed and undone (#1694, `../tools/writes.jl`).
    bulk_update_step(circuitid) || return Cint(15)
    update_or_create_step(circuitid) || return Cint(16)
    get_or_create_step(circuitid) || return Cint(18)
    copy_write_step(circuitid) || return Cint(55)   # a filled handler copied and written through (`tools/writes.jl`, #1684)
    cascade_step(circuitid) || return Cint(22)  # the cascading delete (`tools/writes.jl`, #1694)
    # The write residue of layer 7 (`tools/writes.jl`, #1694): bulk_update with filters= and two keys, SET_DEFAULT, a
    # self-referential CASCADE, and the bulk writers' refusals.
    bulk_update_more_step(circuitid) || return Cint(27)
    set_default_step() || return Cint(28)
    self_cascade_step() || return Cint(29)
    bulk_refusals_step(circuitid) || return Cint(30)
    bulk_conflict_step(circuitid) || return Cint(31)        # bulk_insert's on_conflict= (`../tools/writes.jl`, #1694)
    # The writes applications use most (`tools/writes.jl`, #1694, #1599 layer 7): bulk writes from a column table, and the
    # delete rules beyond CASCADE.
    bulk_table_step(circuitid) || return Cint(47)
    delete_rules_step() || return Cint(49)
    preallocated_keys_refusal_step(circuitid) || return Cint(32)  # MySQL cannot reserve an AUTO_INCREMENT id: the refusal
    transaction_step(circuitid, KEY) || return Cint(24)  # a user transaction (`../tools/connections.jl`, #1599 layer 2)
    nested_transaction_step(circuitid, KEY) || return Cint(35)  # a transaction inside one (`../tools/connections.jl`)
    spawned_read_step(2008) || return Cint(36)  # a read on spawned tasks (`../tools/connections.jl`, #1599 layer 2)
    say("elapsed_ms", string(div(time_ns() - t0, 1_000_000)))
    # A statement the server refuses reaches the caller as its own error, after the read, the write and their timing (#1599, ../tools/failing.jl).
    pool = PormG.Configuration.get_settings(KEY).connections::PormG.ConnectionPool.MySQLConnectionPool
    fail_step(pool) || return Cint(6)
    close_all_step(pool) || return Cint(25)  # last: a trimmed binary runs no atexit hook
    return Cint(0)
end
