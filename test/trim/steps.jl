# The steps both SQLite entries of the fixture app run (#1599): `main.jl` (boot, write, read) and
# `read.jl` (boot, read). Included by each entry after its `using` line, so the two binaries print
# the same lines for the same step and exit with the same code when it fails.
#
# Each step prints one line to `Core.stdout` (a trimmed binary's `Base.stdout` is stale and it prints
# no `@error` records). A caught exception prints its type; for a `MethodError`, the function it
# missed and the argument types; for a PormG refusal, its message.
const M = TrimF1.M

# Pasted unedited from `M.Race.objects.list(show_query = :struct)` on SQLite (#1632).
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
    e isa MethodError && Core.println("  missed: ", typeof(e.f))
    e isa MethodError && Core.println("  args: ", typeof(e.args))
    e isa PormG.ModelDefinitionError && Core.println("  msg: ", (e::PormG.ModelDefinitionError).msg)
    e isa PormG.InvalidConfigurationError &&
        Core.println("  msg: ", (e::PormG.InvalidConfigurationError).msg)
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

# The first lines of every run: the entry was entered, and whether the SQLite extension is loaded.
function start_step(args::Vector{String})::String
    say("main", "entered")
    dir = abspath(args[1])
    say("ext", string(Base.get_extension(PormG, :PormGSQLiteExt) !== nothing))
    return dir
end

# Register the connection in code and bind the models (`TrimF1.boot!`). Exit code 1 when it fails.
function boot_step(dir::String, idle_timeout::Int = 0)::Bool
    try
        TrimF1.boot!(dir, idle_timeout)
        say("boot", "ok")
        return true
    catch e
        failed("boot", e); return false
    end
end

# The typed read into the struct `show_query = :struct` wrote, one line per row. Exit code 3 when it
# fails.
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

# The pool's background reaper (#125) closes an idle overflow connection: lease two connections so the
# pool (`pool_size = 1`) opens an overflow slot, the only kind it reaps, give both back, and wait for the
# next sweep. The reaper sweeps every `_REAP_INTERVAL` (15 s), so this step takes about that long; it
# fails, exit code 4, when no sweep closes the connection within 40 s. Needs a boot with a positive
# `idle_timeout`. A trimmed image never compiled the reaper's task body before #1599's layer-2 fix, so
# the task died at its first call and nothing was ever reaped.
function reap_step()::Bool
    try
        CP = PormG.ConnectionPool
        pool = PormG.Configuration.get_settings(TrimF1.KEY).connections::CP.SQLiteConnectionPool
        c1 = CP.acquire_connection(pool)
        c2 = CP.acquire_connection(pool)
        CP.release_connection(pool, c1)
        CP.release_connection(pool, c2)
        opened = open_connections(pool)
        t0 = time_ns()
        while open_connections(pool) >= opened && time_ns() - t0 < 40_000_000_000
            sleep(0.25)
        end
        ms = string(div(time_ns() - t0, 1_000_000))
        left = open_connections(pool)
        if left < opened
            say("reap", string("closed ", opened - left, " idle overflow connection after ", ms, " ms"))
            return true
        end
        say("reap", string("no connection closed in ", ms, " ms (", opened, " open)"))
        return false
    catch e
        failed("reap", e); return false
    end
end

# How many of the pool's slots hold a connection, read under the pool's lock.
function open_connections(pool::PormG.ConnectionPool.SQLiteConnectionPool)::Int
    Base.lock(pool.lock) do
        n = 0
        for c in pool.connections
            c === nothing || (n += 1)
        end
        n
    end
end

elapsed_step(t0::UInt64) = say("elapsed_ms", string(div(time_ns() - t0, 1_000_000)))
