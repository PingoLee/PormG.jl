# Layer 2 steps (#1599, #1614): a user transaction that commits and one that rolls back, the Postgres.jl connection
# shapes beyond the fixture's own, and `close_all!()` before `main` returns. Included by the SQLite steps
# (`../steps.jl`) and by each server variant's `main.jl`, after each defines `M`, `RaceRow`, `say` and `failed`.

# The error the rollback block raises: the application's own, so the step checks that `atomic` hands the caller the
# error the block raised, after rolling the block back, as under the JIT.
struct TrimRollback <: Exception end

# A user transaction block that commits (`run_in_transaction`, on the connection key) and one that rolls back on a
# raised error (`atomic`), each proven by a typed read after the block: the committed 2016 race is there and the
# rolled-back 2017 race is not. The step deletes the 2016 race again, so it leaves the database as it found it. Exit
# code 24 when a block raises something else, a read does not show the outcome, or the delete does not remove the row.
function transaction_step(circuitid::Int, key::String)::Bool
    ok = false
    try
        inside = PormG.run_in_transaction(key) do
            M.Race.objects.create("year" => 2016, "round" => 6, "circuitid" => circuitid,
                                  "name" => "Monaco Grand Prix", "date" => Date(2016, 5, 29))
            length(M.Race.objects.filter("year" => 2016).list(RaceRow))
        end::Int
        committed = M.Race.objects.filter("year" => 2016).list(RaceRow)
        raised = false
        try
            PormG.atomic(key) do
                M.Race.objects.create("year" => 2017, "round" => 6, "circuitid" => circuitid,
                                      "name" => "Monaco Grand Prix", "date" => Date(2017, 5, 28))
                throw(TrimRollback())
            end
        catch e
            e isa TrimRollback || rethrow()
            raised = true
        end
        left = M.Race.objects.filter("year" => 2017).list(RaceRow)
        removed = first(M.Race.objects.filter("year" => 2016).delete()::Tuple{Int, Dict{String, Integer}})
        say("transaction", string("committed ", inside, " seen inside, ", length(committed), " after; rolled back ",
                                  raised ? "on TrimRollback" : "without the error", ", ", length(left), " left; removed ",
                                  removed))
        ok = inside == 1 && length(committed) == 1 && raised && isempty(left) && removed == 1
    catch e
        failed("transaction", e)
    finally
        # When the step did not pass, neither race is left behind: a server job runs its binary right after its JIT
        # control, on the same database (#1614), and a leftover row would fail an earlier step there. (When it passed,
        # its own delete removed the 2016 race and the rollback left no 2017 race.) A cleanup that raises fails the step.
        if !ok
            try
                M.Race.objects.filter("year__@in" => [2016, 2017]).delete()
            catch e
                failed("transaction", e)
            end
        end
    end
    return ok
end

# The key of the read-only connection `keys_step` registers beside the entry's own (`f1` on every entry).
const RO_KEY = "f1_ro"

# The Monaco races through `key` (the entry's own when `nothing`), ordered by year.
monaco_races(key::Union{Nothing, String})::Vector{RaceRow} = key === nothing ?
    M.Race.objects.filter("circuitid__country" => "Monaco").order_by("year").list(RaceRow) :
    M.Race.objects.filter("circuitid__country" => "Monaco").db(key).order_by("year").list(RaceRow)

# A second connection key on the same database, registered in code with writes off, beside the entry's own (#1599
# layer 1): an application that reads several keys from `connection.yml`, one of them read-only, registers each in code
# in a trimmed binary, which cannot read YAML. `register!(key)` registers `key` the entry's way (a path or a server
# URL), with `change_data` left off. The step reads the Monaco races through each key, checks that a create through the
# read-only key is refused with `WritesDisabledError` before any SQL, and closes that key's pool. Exit code 33 when a
# read raises or the two differ, or the create is not refused.
function keys_step(register!::F)::Bool where {F <: Function}
    ok = false
    try
        register!(RO_KEY)
        own = monaco_races(nothing)
        ro = monaco_races(RO_KEY)
        refused = try
            M.Race.objects.db(RO_KEY).create("year" => 2015, "round" => 6, "circuitid" => 1,
                                             "name" => "Monaco Grand Prix", "date" => Date(2015, 5, 24))
            false
        catch e
            e isa PormG.WritesDisabledError || rethrow()
            showerror_line("keys", e)
            true
        end
        say("keys", string(length(own), " rows on f1, ", length(ro), " on ", RO_KEY, "; a create on ", RO_KEY,
                           refused ? " refused with WritesDisabledError" : " was not refused"))
        ok = length(own) == length(ro) == 1 && own[1].raceid == ro[1].raceid && refused
    catch e
        failed("keys", e)
    finally
        try
            # On every path, so the step leaves no pool open; not when the registration itself failed.
            haskey(PormG.config, RO_KEY) && PormG.Configuration.close_pool!(RO_KEY)
        catch e
            failed("keys", e); ok = false
        end
    end
    return ok
end

# A race created inside a transaction that is itself inside one (`run_in_transaction` within `run_in_transaction`
# on the same key, which becomes a savepoint, #26): the shape of a helper that opens its own transaction and is
# called from inside another. `fail` raises `TrimRollback` after the create, inside the inner block.
function inner_transaction_race(key::String, circuitid::Int, year::Int, fail::Bool)::Nothing
    PormG.run_in_transaction(key) do
        M.Race.objects.create("year" => year, "round" => 6, "circuitid" => circuitid,
                              "name" => "Monaco Grand Prix", "date" => Date(year, 5, 24))
        fail && throw(TrimRollback())
        nothing
    end
    return nothing
end

# A nested user transaction (#1599 layer 2): an outer block that creates the 2018 race and calls a helper whose own
# block creates the 2019 race (a savepoint), both committed with the outer block; then an outer block that creates the
# 2020 race and calls the helper for 2021, which raises inside its own block, so only the savepoint rolls back and the
# outer block, catching the error, commits 2020. Each is proven by a typed read; the step deletes the races it kept.
# Exit code 35 when a block raises something else, a read does not show the outcome, or the delete does not remove
# the rows.
function nested_transaction_step(circuitid::Int, key::String)::Bool
    ok = false
    try
        inside = PormG.run_in_transaction(key) do
            M.Race.objects.create("year" => 2018, "round" => 6, "circuitid" => circuitid,
                                  "name" => "Monaco Grand Prix", "date" => Date(2018, 5, 27))
            inner_transaction_race(key, circuitid, 2019, false)
            length(M.Race.objects.filter("year__@in" => [2018, 2019]).list(RaceRow))
        end::Int
        committed = M.Race.objects.filter("year__@in" => [2018, 2019]).list(RaceRow)
        raised = PormG.run_in_transaction(key) do
            M.Race.objects.create("year" => 2020, "round" => 6, "circuitid" => circuitid,
                                  "name" => "Monaco Grand Prix", "date" => Date(2020, 5, 24))
            try
                inner_transaction_race(key, circuitid, 2021, true)
                false
            catch e
                e isa TrimRollback || rethrow()
                true
            end
        end::Bool
        kept = M.Race.objects.filter("year__@in" => [2020, 2021]).order_by("year").list(RaceRow)
        removed = first(M.Race.objects.filter("year__@in" => [2018, 2019, 2020]).delete()::Tuple{Int, Dict{String, Integer}})
        say("nested_transaction", string("committed ", inside, " seen inside, ", length(committed), " after; inner ",
                                         raised ? "rolled back on TrimRollback" : "did not raise", ", kept ",
                                         join([string(r.year) for r in kept], ", "), "; removed ", removed))
        ok = inside == 2 && length(committed) == 2 && raised && length(kept) == 1 && kept[1].year == 2020 &&
             removed == 3
    catch e
        failed("nested_transaction", e)
    finally
        # When the step did not pass, none of its races is left behind (`transaction_step`'s reason).
        if !ok
            try
                M.Race.objects.filter("year__@in" => [2018, 2019, 2020, 2021]).delete()
            catch e
                failed("nested_transaction", e)
            end
        end
    end
    return ok
end

# The `year` races, read on a spawned task. `year` is an argument rather than a literal, so the task's closure captures
# a value (a captured constant is folded and the task body never compiled, #1794).
spawned_races(year::Int)::Vector{RaceRow} = M.Race.objects.filter("year" => year).order_by("round").list(RaceRow)

# A read on a spawned task (#1599 layer 2): the same typed read on a task `Threads.@spawn` starts (on another thread
# when the binary runs with more than one), then on one `@async` starts (on this thread), each fetched and checked
# against the two seeded races. An application's request handlers and background jobs read this way. One after the
# other, so the pool (`pool_size = 1`) opens no second connection and `close_all_step`'s count is the same as without
# this step; the pool's long-lived tasks are the `tasks` run's (`../steps.jl`). Exit code 36 when a task raises or a
# read returns other rows.
function spawned_read_step(year::Int)::Bool
    try
        a = fetch(Threads.@spawn spawned_races(year))::Vector{RaceRow}
        b = fetch(@async spawned_races(year))::Vector{RaceRow}
        say("spawned", string("@spawn ", length(a), " rows: ", race_names(a), "; @async ", length(b), " rows: ",
                              race_names(b)))
        expected = "Monaco Grand Prix, Brazilian Grand Prix"
        return race_names(a) == expected && race_names(b) == expected
    catch e
        # A task's error reaches `fetch` wrapped: report the one inside, a trim wall's `MissingCodeError` included.
        failed("spawned", e isa TaskFailedException ? (e::TaskFailedException).task.exception : e); return false
    end
end

# How many of a pool's slots hold a connection, read under the pool's lock, and the first one held (`nothing` when none).
function open_slots(pool::P)::Tuple{Int, Any} where {P <: PormG.PormGBackend}
    Base.lock(pool.lock) do
        n = 0
        first_handle = nothing
        for c in pool.connections
            c === nothing && continue
            n += 1
            first_handle === nothing && (first_handle = c)
        end
        (n, first_handle)
    end
end

# `close_all!()`, the call PormG's exit hook makes, which a trimmed binary must make itself (it runs no `atexit` hook),
# last before `main` returns. The key's pool held a connection before it and holds none after, and that connection's
# driver handle (at the concrete type the driver's extension names, `backend_handle_type`) is closed: the pool empties its
# slots before it closes each handle, and a close that raised would be swallowed, so the handle itself is the proof that
# the driver's close ran. Exit code 25 when it raises, a connection is still held or the handle is still open.
function close_all_step(pool::P)::Bool where {P <: PormG.PormGBackend}
    H = PormG.backend_handle_type(P)
    try
        before, handle = open_slots(pool)
        close_all!()
        after, _ = open_slots(pool)
        closed = handle isa H && !isopen(handle::H)
        state = handle === nothing ? "no handle held" : !(handle isa H) ? string("not a ", H) :
                closed ? "the handle closed" : "the handle still open"
        say("close_all", string(before, " open before, ", after, " after; ", state))
        return before >= 1 && after == 0 && closed
    catch e
        failed("close_all", e); return false
    end
end
