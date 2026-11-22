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
        # On any path, neither race is left behind: a server job runs its binary right after its JIT control, on the
        # same database (#1614), and a leftover row would fail an earlier step there.
        try
            M.Race.objects.filter("year__@in" => [2016, 2017]).delete()
        catch e
            failed("transaction", e)   # the cleanup's own failure, reported; the step has already answered
        end
    end
    return ok
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
        say("close_all", string(before, " open before, ", after, " after; the handle ", closed ? "closed" : "still open"))
        return before >= 1 && after == 0 && closed
    catch e
        failed("close_all", e); return false
    end
end
