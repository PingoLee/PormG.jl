# The steps both SQLite entries of the fixture app run (#1599): `main.jl` (boot, two refused writes, a
# write, read, update, delete) and `read.jl` (boot, read). Included by each entry after its `using`
# line, so the two binaries print the same lines for the same step and exit with the same code when it
# fails.
#
# Each step prints one line to `Core.stdout` (a trimmed binary's `Base.stdout` is stale and it prints
# no `@error` records). A caught exception prints its type; for a `MethodError`, the function it
# missed and the argument types; for a PormG refusal, its message.
const M = TrimF1.M

# Pasted from `M.Race.objects.list(show_query = :struct)` on SQLite (#1632), without the three columns the
# write fills itself (`created_at`, `updated_on`, `token`): the typed read projects the struct's fields, so
# the read is the one it was before they were added.
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
    e isa PormG.InvalidValueError && Core.println("  msg: ", (e::PormG.InvalidValueError).msg)
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

# Two creates PormG refuses before any SQL (#1599 layer 7, #1694): a date the date validator refuses,
# and a `Bool` for a text column, which passes validation and is refused by the format step. Each prints
# the refusal's type and message, so the run shows the write's error paths work in a trimmed image: a
# path that cannot run there raises a `MethodError` in place of the refusal. Exit code 6 when either
# create is not refused with an `InvalidValueError`.
function refused_step()::Bool
    a = try
        M.Race.objects.create("year" => 2009, "round" => 6, "circuitid" => 1,
                              "name" => "Monaco Grand Prix", "date" => "2009-02-30")
        say("refused", "the create with an invalid date was not refused"); false
    catch e
        refusal("refused", e)
    end
    b = try
        M.Race.objects.create("year" => 2009, "round" => 6, "circuitid" => 1,
                              "name" => true, "date" => Date(2009, 5, 24))
        say("refused", "the create with a Bool name was not refused"); false
    catch e
        refusal("refused", e)
    end
    return a && b
end

# One refusal's line: its type and message for an `InvalidValueError`, `failed`'s lines for anything else.
@noinline function refusal(step::String, @nospecialize(e))::Bool
    if e isa PormG.InvalidValueError
        say(step, string("InvalidValueError: ", (e::PormG.InvalidValueError).msg))
        return true
    end
    failed(step, e)
    return false
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

# The write's other two verbs (#1694), after the read: `update` the row the write made (2009's), read it
# back typed and check the new `round`, then `delete` it and check that only the prepped row is left. Exit
# codes 7 (update) and 8 (delete) when the call raises or the read after it does not show the change.
# `update` returns the row count and `delete` the count and the rows per table, both asserted at the types
# the JIT returns, so a step prints them without a call on an untyped value.
function update_step()::Bool
    try
        n = M.Race.objects.filter("year" => 2009).update("round" => 7)::Int
        rows = M.Race.objects.filter("year" => 2009).list(RaceRow)
        say("update", string(n, " rows; round ", isempty(rows) ? "-" : string(rows[1].round)))
        return n == 1 && length(rows) == 1 && rows[1].round == 7
    catch e
        failed("update", e); return false
    end
end

function delete_step()::Bool
    try
        n = first(M.Race.objects.filter("year" => 2009).delete()::Tuple{Int, Dict{String, Integer}})
        rows = M.Race.objects.filter("circuitid__country" => "Monaco").list(RaceRow)
        say("delete", string(n, " rows; ", length(rows), " left"))
        return n == 1 && length(rows) == 1 && rows[1].year == 2008
    catch e
        failed("delete", e); return false
    end
end

# The `tasks` run's steps, the pool's long-lived tasks in a trimmed image (#1599 layer 2).
#
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
        opened = open_connections(pool)    # while both are leased, so no sweep can take one first
        CP.release_connection(pool, c1)
        CP.release_connection(pool, c2)
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

# A SQLite handle closed while the worker still has a statement for it is closed later, by a task that
# waits for the statement to end (#327): start a slow statement with `fetch_async`, close the pool at
# once (`drain_seconds = 0`), and wait for that task to close the handle. Fails, exit code 5, when the
# close was not deferred or the handle is still open after 60 s. The statement is raw SQL because the
# step needs one that is still running when the pool closes.
function close_step()::Bool
    try
        CP = PormG.ConnectionPool
        pool = PormG.Configuration.get_settings(TrimF1.KEY).connections::CP.SQLiteConnectionPool
        ft = CP.fetch_async(pool, "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c " *
                                  "WHERE x < 5000000) SELECT count(*) AS n FROM c")
        db = ft.conn::SQLite.DB
        CP.close_pool!(pool; drain_seconds = 0)
        if !isopen(db)
            say("close", "the handle closed at once: the statement had already ended")
            return false
        end
        t0 = time_ns()
        while isopen(db) && time_ns() - t0 < 60_000_000_000
            sleep(0.1)
        end
        ms = string(div(time_ns() - t0, 1_000_000))
        if isopen(db)
            say("close", string("the deferred close did not close the handle in ", ms, " ms"))
            return false
        end
        say("close", string("deferred, the handle closed ", ms, " ms after the pool"))
        return true
    catch e
        failed("close", e); return false
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
