# The single-row write steps every fixture binary runs (#1694, #1614): a create, then (after a typed read) an
# update and a delete, each checked by a typed read. Included by the SQLite steps (`../steps.jl`) and by each
# server variant's `main.jl`, after each defines `M`, `RaceRow`, `say` and `failed`, so every binary prints the
# same lines for the same step.

# One create that leaves the three auto-filled fields (`created_at`, `updated_on`, `token`) to the write's own fill.
# Exit code 2 when it raises. The SQLite entry passes the Monaco circuit's id, 1; a server entry reads it first
# (`monaco_circuitid_step`), since `prep.jl` empties the tables without resetting the server's sequences.
function write_step(circuitid::Int)::Bool
    try
        M.Race.objects.create("year" => 2009, "round" => 6, "circuitid" => circuitid,
                              "name" => "Monaco Grand Prix", "date" => Date(2009, 5, 24))
        say("write", "ok")
        return true
    catch e
        failed("write", e); return false
    end
end

# The Monaco circuit's id, by a typed read into a one-field struct (`list(show_query = :struct)` writes the
# field). `nothing` (exit code 2) when the read raises or does not find exactly one circuit.
struct CircuitId
    circuitid::Int64  # IDField
end

function monaco_circuitid_step()::Union{Nothing, Int}
    try
        rows = M.Circuit.objects.filter("circuitref" => "monaco").list(CircuitId)
        length(rows) == 1 || (say("circuit", string(length(rows), " circuits named monaco")); return nothing)
        return Int(rows[1].circuitid)
    catch e
        failed("circuit", e); return nothing
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
