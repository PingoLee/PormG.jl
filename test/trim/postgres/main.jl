# The juliac --trim entry of the fixture's Postgres.jl variant (#1599, #1614): `../main.jl`'s app with
# Postgres.jl in place of SQLite — boot, one typed read, the comparison filters, order_by, lookups and expression comparisons (`../tools/reads.jl`), the single-row
# write (`../tools/writes.jl`: create, read back, update, delete), a `bulk_insert` of two rows and one statement
# the server refuses (`../tools/failing.jl`).
#   JIT:  julia --project=test/trim/postgres test/trim/postgres/main.jl
#   exe:  <build dir>/main                   (see ../README.md, "The Postgres.jl variant")
#
# The boot is in this file, not in a package: `juliac` builds a package from a copy of its directory, so a
# package here could not include `../db/models.jl`, the models the SQLite app uses. It registers a
# `postgresql://` URL with `postgres_driver = "Postgres"`: Postgres.jl, not LibPQ, whose dependencies
# abort a trimmed binary before `main` (README). No YAML is read. The server comes from the `PORMG_TRIM_*`
# environment variables (`../tools/server.jl`); unset, it is 127.0.0.1:1, where nothing listens: nothing
# is contacted at boot, and the read raises `PoolConnectError` under the JIT. Against a server seeded by
# `prep.jl`, the read returns the Monaco race. Each step prints one line to `Core.stdout`, as in ../main.jl.
using PormG, Postgres, Dates
# The roots a trimmed build needs (the render's run-time re-entries, upstream's, and SCRAM authentication's Base64
# methods, which the Postgres.jl extension names), a no-op under the JIT (#1599).
PormG.trim_entrypoints(PormG.ConnectionPool.PostgresConnectionPool{:postgres})

include(joinpath(@__DIR__, "..", "db", "models.jl"))
import .models as M
include(joinpath(@__DIR__, "..", "tools", "server.jl"))
include(joinpath(@__DIR__, "..", "tools", "failing.jl"))

const KEY = "f1"

"Register the PostgreSQL connection (Postgres.jl) under `KEY` and bind the models to it (#1606, #1776)."
function boot!(server::TrimServer)
    PormG.Configuration.register_connection(KEY, trim_url(server, "postgresql");
        adapter = "PostgreSQL", postgres_driver = "Postgres", env = "prod", pool_size = 1,
        change_db = true, change_data = true)
    PormG.Models.set_models(models.MODEL_SET; key = KEY)
    return nothing
end

# The struct of ../main.jl: `list(show_query = :struct)` writes the same fields on PostgreSQL (#1632).
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
        rows = M.Race.objects.filter("circuitid__country" => "Monaco").list(RaceRow)
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

# The URL of one connection shape: `user` with `password` or none (`nothing`), and an `sslmode` or none. It holds the
# password when there is one: never print it.
function shape_url(s::TrimServer, user::String, password::Union{Nothing, String}, sslmode::Union{Nothing, String})::String
    auth = password === nothing ? trim_urlencode(user) : string(trim_urlencode(user), ":", trim_urlencode(password))
    query = sslmode === nothing ? "" : string("?sslmode=", sslmode)
    return string("postgresql://", auth, "@", s.host, ":", s.port, "/", trim_urlencode(s.database), query)
end

# The three Postgres.jl connection shapes beyond the fixture's own (a password, no `sslmode`), each a connection of its
# own, registered under its own key, read through it (`db(key)`), and closed (#1599 layer 2, #1614): `_dial`'s typed
# arms for a password with an `sslmode`, and no password with an `sslmode` or none. `sslmode = disable` needs no TLS on
# the server. The two shapes without a password log in as the role `PORMG_TRIM_TRUST_USER` names, which the server
# trusts on this database, with `SELECT` on its tables (the CI job grants it after `prep.jl`); unset, the step says so
# and skips them, never passing them silently. Postgres.jl fills a URL's missing password and `sslmode` from
# `PGPASSWORD` and `PGSSLMODE`, which would take another arm than the one named, so the step refuses to run with
# either set. Exit code 23 when a shape's read raises or does not return the Monaco race, or either variable is set.
function shapes_step(server::TrimServer)::Bool
    try
        if !isempty(trim_env("PGPASSWORD", "")) || !isempty(trim_env("PGSSLMODE", ""))
            say("shape", "PGPASSWORD or PGSSLMODE is set: the shapes would not be the ones named")
            return false
        end
        trust = trim_env("PORMG_TRIM_TRUST_USER", "")
        names = String["password, sslmode"]
        urls = String[shape_url(server, server.user, server.password, "disable")]
        if !isempty(trust)
            push!(names, "no password"); push!(urls, shape_url(server, trust, nothing, nothing))
            push!(names, "no password, sslmode"); push!(urls, shape_url(server, trust, nothing, "disable"))
        end
        ok = true
        for i in eachindex(urls)
            key = string(KEY, "_shape", i)
            PormG.Configuration.register_connection(key, urls[i]; adapter = "PostgreSQL", postgres_driver = "Postgres",
                                                     env = "prod", pool_size = 1)
            rows = try
                M.Race.objects.filter("circuitid__country" => "Monaco").db(key).list(RaceRow)
            finally
                PormG.Configuration.close_pool!(key)   # on every path, so a failed shape leaves no pool open
            end
            say("shape", string(names[i], ": ", length(rows), " rows"))
            ok &= length(rows) == 1 && rows[1].year == 2008
        end
        isempty(trust) && say("shape", "no password: skipped (PORMG_TRIM_TRUST_USER unset)")
        return ok
    catch e
        failed("shape", e); return false
    end
end

function (@main)(args::Vector{String})::Cint
    t0 = time_ns()
    say("main", "entered")
    say("ext", string(Base.get_extension(PormG, :PormGPostgresExt) !== nothing))
    server = trim_server()
    say("server", trim_where(server))
    try
        boot!(server)
        say("boot", "ok")
    catch e
        failed("boot", e); return Cint(1)
    end
    query_step() || return Cint(3)
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
    cascade_step(circuitid) || return Cint(22)  # the cascading delete (`tools/writes.jl`, #1694)
    transaction_step(circuitid, KEY) || return Cint(24)  # a user transaction (`../tools/connections.jl`, #1599 layer 2)
    shapes_step(server) || return Cint(23)
    say("elapsed_ms", string(div(time_ns() - t0, 1_000_000)))
    # A statement the server refuses reaches the caller as its own error, after the read, the write and their timing (#1599, ../tools/failing.jl).
    pool = PormG.Configuration.get_settings(KEY).connections::PormG.ConnectionPool.PostgresConnectionPool{:postgres}
    fail_step(pool) || return Cint(6)
    close_all_step(pool) || return Cint(25)  # last: a trimmed binary runs no atexit hook
    return Cint(0)
end
