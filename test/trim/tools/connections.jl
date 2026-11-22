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
        return inside == 1 && length(committed) == 1 && raised && isempty(left) && removed == 1
    catch e
        failed("transaction", e); return false
    end
end

# How many of a pool's slots hold a connection, read under the pool's lock.
function open_slots(pool::P)::Int where {P <: PormG.PormGBackend}
    Base.lock(pool.lock) do
        n = 0
        for c in pool.connections
            c === nothing || (n += 1)
        end
        n
    end
end

# `close_all!()`, the call PormG's exit hook makes, which a trimmed binary must make itself (it runs no `atexit` hook),
# last before `main` returns: the key's pool held a connection before it and holds none after. Exit code 25 when it
# raises or a connection is still open.
function close_all_step(pool::P)::Bool where {P <: PormG.PormGBackend}
    try
        before = open_slots(pool)
        close_all!()
        after = open_slots(pool)
        say("close_all", string(before, " open before, ", after, " after"))
        return before >= 1 && after == 0
    catch e
        failed("close_all", e); return false
    end
end
