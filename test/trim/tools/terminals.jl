# The terminals applications use most (#1599 layer 6): `count()`, `exists()`, a user read under
# `select_for_update(of = ("self",))` in a transaction, a raw `fetch` (outside and inside a transaction), and typed rows
# handed to a table sink (`Tables.columntable`, as a `DataFrame` reads them). Included by the SQLite steps
# (`../steps.jl`) and by each server variant's `main.jl`, after each defines `M`, `RaceRow`, `say`, `failed` and
# `raw_marker(i)` (the backend's own bind marker for the `i`th value: `?` on SQLite and MySQL, `$i` on PostgreSQL). They
# run before any write, on the two races every `prep.jl` seeds.

import Tables

# `count()` (#1599 layer 6): over a filter, across a join, and over no row. `count()` returns the integer the driver
# read, untyped; a trimmed program states its type (`::Int`), as it declares a typed read's row type. Exit code 42 when
# one raises or counts other rows.
function count_step()::Bool
    try
        all_rounds = M.Race.objects.filter("round__@gt" => 0).count()::Int
        monaco = M.Race.objects.filter("circuitid__country" => "Monaco").count()::Int
        none = M.Race.objects.filter("year" => 1900).count()::Int
        say("count", string("round__@gt ", all_rounds, "; circuitid__country ", monaco, "; year 1900 ", none))
        return all_rounds == 2 && monaco == 1 && none == 0
    catch e
        failed("count", e); return false
    end
end

# `exists()` as a read terminal (#1599 layer 6), for a filter that matches and one that does not. Exit code 43 when one
# raises or answers the other way.
function exists_step()::Bool
    try
        yes = M.Race.objects.filter("year" => 2008).exists()::Bool   # untyped, as `count()`'s integer: state it
        no = M.Race.objects.filter("year" => 1900).exists()::Bool
        say("exists", string("year 2008 ", yes, "; year 1900 ", no))
        return yes && !no
    catch e
        failed("exists", e); return false
    end
end

# A user read under `select_for_update(of = ("self",))`, inside `run_in_transaction` (#1599 layer 6): the rows it locks,
# typed. SQLite renders no lock clause (its transaction holds the write lock), MySQL and PostgreSQL `FOR UPDATE OF`.
# Exit code 44 when the block raises or the rows differ.
function lock_step(key::String)::Bool
    try
        rows = PormG.run_in_transaction(key) do
            M.Race.objects.filter("year" => 2008).select_for_update(of = ("self",)).order_by("round").list(RaceRow)
        end::Vector{RaceRow}
        say("lock", string("select_for_update(of = self) ", length(rows), " rows: ", race_names(rows)))
        return race_names(rows) == "Monaco Grand Prix, Brazilian Grand Prix"
    catch e
        failed("lock", e); return false
    end
end

# A raw `fetch` (#1599 layer 6), the hatch for a statement PormG does not build, bound with the backend's own markers
# (`raw_marker`): an `UPDATE` that moves the 2008 Monaco race's round by +100, then, inside a transaction, the one that
# moves it back, each checked by a typed read. The hatch returns the driver's own result, untyped and of a different
# type on each engine, so the step reads its effect through the ORM rather than the result itself
# (`docs/src/static_compilation.md`). Exit code 45 when a statement raises or a read does not show the change; the
# round is moved back on any path.
function raw_fetch_step(key::String)::Bool
    settings = PormG.Configuration.get_settings(key)
    sql(delta::Int) = string("UPDATE race SET round = round ", delta > 0 ? "+ " : "- ", abs(delta), " WHERE year = ",
                             raw_marker(1), " AND name = ", raw_marker(2))
    ok = false
    try
        fetch(settings, sql(100), [2008, "Monaco Grand Prix"])
        up = M.Race.objects.filter("year" => 2008).order_by("round").list(RaceRow)
        back = PormG.run_in_transaction(key) do
            fetch(settings, sql(-100), [2008, "Monaco Grand Prix"])
            M.Race.objects.filter("year" => 2008).order_by("round").list(RaceRow)
        end::Vector{RaceRow}
        rounds(rows) = join([string(r.round) for r in rows], ", ")
        say("raw_fetch", string("update +100: rounds ", rounds(up), "; in a transaction -100: rounds ", rounds(back)))
        ok = rounds(up) == "18, 106" && rounds(back) == "6, 18"
    catch e
        failed("raw_fetch", e)
    finally
        # When the step did not pass, the race is put back at its round if a +100 stuck (an UPDATE can commit before its
        # call raises), read through the ORM so it is never moved twice: the step leaves the database as it found it.
        if !ok
            try
                monaco = M.Race.objects.filter("year" => 2008, "name" => "Monaco Grand Prix").list(RaceRow)
                if !isempty(monaco) && monaco[1].round > 100
                    fetch(settings, sql(-100), [2008, "Monaco Grand Prix"])
                end
            catch e
                failed("raw_fetch", e)
            end
        end
    end
    return ok
end

# The rows a table sink reads in a trimmed binary (#1599 layer 6): the typed read `list(T)`, whose rows' type the
# program declares, handed to `Tables.columntable`, a `NamedTuple` of typed vectors, as `DataFrame(rows)` reads them. A
# query handed to the sink itself (`Tables.columntable(query)`, `query |> DataFrame`) does not run trimmed: its
# columns' types are the result's, decided when the statement runs, and a trimmed image has no code for a type it did
# not know when it was built (`docs/src/static_compilation.md`). Exit code 46 when it raises or the columns hold other
# values.
const NameRoundRow = NamedTuple{(:name, :round), Tuple{String, Int64}}

function tables_step()::Bool
    try
        rows = M.Race.objects.filter("year" => 2008).values("name", "round").order_by("round").list(NameRoundRow)
        ct = Tables.columntable(rows)
        say("tables", string("columntable of list(T) ", join(string.(Tables.columnnames(ct)), ", "), ": ",
                             join(ct.name, ", "), "; rounds ", join(string.(ct.round), ", ")))
        return join(ct.name, ", ") == "Monaco Grand Prix, Brazilian Grand Prix" && ct.round == [6, 18]
    catch e
        failed("tables", e); return false
    end
end
