# Run a command against a local server with the trim fixture's `PORMG_TRIM_*` variables set (#1599, #1614).
#
#   julia --project=test/integration test/trim/tools/runner.jl <folder> [--env=<env>] [--database=<name>] -- <command...>
#
# `<folder>` is an integration configuration folder, `test/integration/db_my` (MySQL) or `test/integration/db_2`
# (PostgreSQL), or the short name `db_my`/`db_2` for the one in this checkout. The runner loads it in place with
# `PormG.Configuration.load`, so the `connection.yml` is read by PormG and never by this script, and takes the
# server's host, port, user and password from the loaded settings. It runs `<command...>` in a child process whose
# environment adds `PORMG_TRIM_HOST`, `PORMG_TRIM_PORT`, `PORMG_TRIM_USER`, `PORMG_TRIM_PASSWORD` and
# `PORMG_TRIM_DATABASE` (`tools/server.jl`); this process's own environment is left as it was.
#
# The database is `pormg_trim` unless `--database=` names another, and the name must contain `trim`, as each
# `prep.jl` requires: the fixture empties its tables, so it never runs against the integration suite's database.
# The runner prints one line, `runner	<host>:<port>/<database>`, and the child's exit code; never the user or the
# password, in output or in an error. It exits with the child's code, `128 + n` when signal `n` killed it (a trimmed
# binary that aborts), and 127 when the command could not be started.
#
# It reaches the server over TCP, as the fixture's URL does, so the folder must set `host:` (a name or an IPv4
# address, not a socket directory or `hostaddr:`) and `password:`; `tools/server.jl` reads an empty password as its
# default. Loading the folder may connect to the folder's own database once, when it lists `extensions:` (the load
# checks they are installed); the runner itself runs nothing there.

using PormG
using LibPQ, Postgres, MySQL   # the pool the load builds needs its driver (`postgres_driver:` may name Postgres.jl)

const USAGE = "usage: runner.jl <db_my|db_2|<folder>> [--env=<env>] [--database=<name>] -- <command...>"

# A runner error: its message names what is missing, never a value read from the configuration.
runner_fail(msg::AbstractString) = (println(stderr, "runner: ", msg); exit(2))

function parse_args(args::Vector{String})
    sep = findfirst(==("--"), args)
    sep === nothing && runner_fail("no command after `--`. " * USAGE)
    head, cmd = args[1:sep-1], args[sep+1:end]
    isempty(cmd) && runner_fail("no command after `--`. " * USAGE)
    folder = nothing; env = "dev"; database = "pormg_trim"
    for a in head
        if startswith(a, "--env=")
            env = a[7:end]
        elseif startswith(a, "--database=")
            database = a[12:end]
        elseif startswith(a, "--")
            runner_fail("unknown option `$(a)`. " * USAGE)
        elseif folder === nothing
            folder = a
        else
            runner_fail("more than one folder given. " * USAGE)
        end
    end
    folder === nothing && runner_fail("no configuration folder given. " * USAGE)
    occursin("trim", database) ||
        runner_fail("the database `$(database)` does not contain `trim`; the fixture's prep.jl empties its tables, " *
                    "so it runs only against a database of its own (pormg_trim)")
    return folder, env, database, cmd
end

# A short name resolves to this checkout's integration folder; anything else is a path.
resolve_folder(f::String) = f in ("db_my", "db_2") ?
    normpath(joinpath(@__DIR__, "..", "..", "integration", f)) : abspath(f)

# One setting of the loaded configuration as text, or `nothing` when it is unset. The value is returned, never
# printed; an error names the key only.
function setting(cfg::AbstractDict, key::String)
    v = get(cfg, key, nothing)
    (v === nothing || v == "") && return nothing
    return string(v)
end

function main(args::Vector{String})
    folder, env, database, cmd = parse_args(args)
    path = resolve_folder(folder)
    isfile(joinpath(path, "connection.yml")) ||
        runner_fail("no connection.yml in $(path) (it is gitignored: in a worktree, pass the main checkout's folder)")
    key = PormG.Configuration.load(path; env = env)
    cfg = PormG.Configuration.config[key].db_config_settings
    adapter = something(setting(cfg, "adapter"), "")
    adapter in ("MySQL", "PostgreSQL") ||
        runner_fail("the folder's adapter is `$(adapter)`; the runner serves the MySQL and PostgreSQL variants")
    setting(cfg, "url") === nothing ||
        runner_fail("the folder sets `url:`; the runner reads `host:`, `port:`, `username:` and `password:`")
    setting(cfg, "hostaddr") === nothing ||
        runner_fail("the folder sets `hostaddr:`; the runner reads `host:`, a name or an IPv4 address")
    host = setting(cfg, "host")
    host === nothing && runner_fail("the folder sets no `host:`; the runner connects over TCP, as the fixture does")
    startswith(host, "/") && runner_fail("the folder's `host:` is a socket directory; the runner connects over TCP")
    port = something(setting(cfg, "port"), adapter == "MySQL" ? "3306" : "5432")
    user = setting(cfg, "username")
    user === nothing && runner_fail("the folder sets no `username:`")
    password = setting(cfg, "password")
    password === nothing && runner_fail("the folder sets no `password:` (tools/server.jl reads an empty one as its default)")

    env_vars = copy(ENV)
    env_vars["PORMG_TRIM_HOST"] = host
    env_vars["PORMG_TRIM_PORT"] = port
    env_vars["PORMG_TRIM_USER"] = user
    env_vars["PORMG_TRIM_PASSWORD"] = password
    env_vars["PORMG_TRIM_DATABASE"] = database
    PormG.Configuration.close_pool!(key)

    println("runner\t", host, ":", port, "/", database)
    flush(stdout)
    # Nothing that shows the process is ever printed: `show(::Cmd)` of a `setenv` command lists its environment, the
    # password included. `ignorestatus` keeps a failing command from throwing `ProcessFailedException`, and a command
    # that cannot be started (`IOError: could not spawn …`, which shows it) is caught and named by its first word only.
    proc = try
        run(ignorestatus(setenv(Cmd(cmd), env_vars)))
    catch e
        e isa InterruptException && rethrow()
        println(stderr, "runner: could not start `", cmd[1], "` (", nameof(typeof(e)), ")")
        return 127
    end
    if proc.termsignal != 0
        println("runner\tkilled by signal ", proc.termsignal)
        return 128 + proc.termsignal
    end
    println("runner\texit ", proc.exitcode)
    return proc.exitcode
end

exit(main(ARGS))
