# The write steps every fixture binary runs (#1694, #1614): a create, then (after a typed read) an update and a
# delete, each checked by a typed read, and a `bulk_insert` of two rows read back. Included by the SQLite steps
# (`../steps.jl`) and by each server variant's `main.jl`, after each defines `M`, `RaceRow`, `say` and `failed`, so
# every binary prints the same lines for the same step.

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

# `bulk_insert` (#1694, #1614), after the delete: two Monaco races from a `Vector` of `NamedTuple`s, the input a
# trimmed program holds at a concrete type, leaving the three auto-filled fields to the write's own fill. The SQLite
# entry passes the Monaco circuit's id, 1; a server entry the one `monaco_circuitid_step` read, as for `write_step`.
# A typed read then sees both, and the step deletes them again (a `year__@gte` filter), so it leaves the database as it
# found it: a server job runs its binary right after its JIT control, on the same database (#1614). Exit code 9 when
# the call raises, its count is not 2, the read does not return the two rows, or the delete does not remove them.
# `bulk_insert` returns `(count, rows)` with `rows = nothing` without `returning=`, asserted at that type so the step
# prints the count without a call on an untyped value.
function bulk_step(circuitid::Int)::Bool
    try
        rows = [(year = 2010, round = 6, circuitid = circuitid, name = "Monaco Grand Prix", date = Date(2010, 5, 16)),
                (year = 2011, round = 6, circuitid = circuitid, name = "Monaco Grand Prix", date = Date(2011, 5, 29))]
        r = PormG.bulk_insert(M.Race.objects, rows)::NamedTuple{(:count, :rows), Tuple{Int, Nothing}}
        # The read every binary of the fixture runs (`query_step`'s), with the new rows picked out here, so this
        # step checks the write alone; the comparison filters are `tools/reads.jl`'s steps (#1599 layer 5).
        monaco = M.Race.objects.filter("circuitid__country" => "Monaco").list(RaceRow)
        back = sort!([x.year for x in monaco if x.year >= 2010])
        say("bulk", string(r.count, " rows; ", length(back), " read back"))
        removed = first(M.Race.objects.filter("year__@gte" => 2010).delete()::Tuple{Int, Dict{String, Integer}})
        removed == 2 || say("bulk", string("removed ", removed, " rows, expected 2"))
        return r.count == 2 && back == [2010, 2011] && length(monaco) == 3 && removed == 2
    catch e
        failed("bulk", e); return false
    end
end

# The upsert-shaped writes (#1694, #1599 layer 7), after `bulk_step`. Each leaves the database as it found it (a server
# job runs its binary right after its JIT control, on the same database, #1614) and is checked by a typed read.
# `update_or_create` looks its row up by `raceid`, the primary key: it needs a unique constraint behind the lookup, and
# the fixture's only ones are primary keys. The explicit id is far above any id a sequence gives in the fixture, and the
# step deletes its row again (a row-level write does not resync the sequence). `get_or_create` has its own step below
# (`get_or_create_step`): on a hit it reads its row through the untyped `first()` (the untyped read, layer 6).
const UPSERT_UOC_ID = 9_000_002

# `bulk_update` (exit code 15): two Monaco races written by `bulk_insert`, their ids read typed, their `round` set from a
# `Vector` of `NamedTuple`s matched on `raceid`, read back typed, then deleted. `bulk_update` returns `(count, rows)`
# with `rows = nothing`, asserted at that type.
function bulk_update_step(circuitid::Int)::Bool
    try
        PormG.bulk_insert(M.Race.objects,
            [(year = 2010, round = 6, circuitid = circuitid, name = "Monaco Grand Prix", date = Date(2010, 5, 16)),
             (year = 2011, round = 6, circuitid = circuitid, name = "Monaco Grand Prix", date = Date(2011, 5, 29))])
        written = M.Race.objects.filter("year__@gte" => 2010).order_by("year").list(RaceRow)
        length(written) == 2 || (say("bulk_update", string(length(written), " rows to update")); return false)
        r = PormG.bulk_update(M.Race.objects, [(raceid = written[1].raceid, round = 7), (raceid = written[2].raceid, round = 8)];
                              columns = ["round"], match_on = ["raceid"])::NamedTuple{(:count, :rows), Tuple{Int, Nothing}}
        back = M.Race.objects.filter("year__@gte" => 2010).order_by("year").list(RaceRow)
        rounds = [x.round for x in back]
        say("bulk_update", string(r.count, " rows; rounds ", join(rounds, ", ")))
        removed = first(M.Race.objects.filter("year__@gte" => 2010).delete()::Tuple{Int, Dict{String, Integer}})
        return r.count == 2 && rounds == [7, 8] && removed == 2
    catch e
        failed("bulk_update", e); return false
    end
end

# `update_or_create` (exit code 16): `UPSERT_UOC_ID` is a miss, so the first call inserts it (`created` true); the same
# call with `round => 7` updates it (`created` false); read back typed and deleted.
function update_or_create_step(circuitid::Int)::Bool
    try
        first_call = M.Race.objects.update_or_create("raceid" => UPSERT_UOC_ID;
            defaults = ["year" => 2013, "round" => 6, "circuitid" => circuitid, "name" => "Monaco Grand Prix",
                        "date" => Date(2013, 5, 26)])::Tuple{PormGRow, Bool}
        second_call = M.Race.objects.update_or_create("raceid" => UPSERT_UOC_ID;
            defaults = ["year" => 2013, "round" => 7, "circuitid" => circuitid, "name" => "Monaco Grand Prix",
                        "date" => Date(2013, 5, 26)])::Tuple{PormGRow, Bool}
        back = M.Race.objects.filter("raceid" => UPSERT_UOC_ID).list(RaceRow)
        say("update_or_create", string("first created ", first_call[2], "; second created ", second_call[2], "; round ",
                                       isempty(back) ? "-" : string(back[1].round)))
        removed = first(M.Race.objects.filter("raceid" => UPSERT_UOC_ID).delete()::Tuple{Int, Dict{String, Integer}})
        return first_call[2] && !second_call[2] && length(back) == 1 && back[1].round == 7 && removed == 1
    catch e
        failed("update_or_create", e); return false
    end
end

const UPSERT_GOC_ID = 9_000_003

# `get_or_create` (exit code 18): `UPSERT_GOC_ID` is a miss, so the first call inserts it (`created` true); the second
# finds it (`created` false) through the untyped `first()` (#1599 layer 6) and returns the row it found, whose `round`
# is the one the first call wrote; then deleted, so the database is left as it was.
function get_or_create_step(circuitid::Int)::Bool
    try
        defaults = ["year" => 2014, "round" => 6, "circuitid" => circuitid, "name" => "Monaco Grand Prix",
                    "date" => Date(2014, 5, 25)]
        miss = M.Race.objects.get_or_create("raceid" => UPSERT_GOC_ID; defaults = defaults)::Tuple{PormGRow, Bool}
        hit = M.Race.objects.get_or_create("raceid" => UPSERT_GOC_ID; defaults = defaults)::Tuple{PormGRow, Bool}
        say("get_or_create", string("first created ", miss[2], "; second created ", hit[2], "; round ",
                                    cell_text(hit[1][:round]), "; ", row_types(hit[1])))
        removed = first(M.Race.objects.filter("raceid" => UPSERT_GOC_ID).delete()::Tuple{Int, Dict{String, Integer}})
        return miss[2] && !hit[2] && cell_text(hit[1][:round]) == "6" && removed == 1
    catch e
        failed("get_or_create", e); return false
    end
end

# The cascading delete (#1694, #1599 layer 7; exit code 22), after the upserts. A race of the step's own (2015) with two
# pit stops and a driver who debuted in it; deleting the race runs the ORM's collector: the pit stops go with it
# (`CASCADE`), the driver stays with no debut race (`SET_NULL`), and on PostgreSQL and MySQL the race's and its pit
# stops' rows are locked first (`FOR UPDATE`, #1815). Typed reads check each, and that the pit stop and driver
# `prep.jl` seeded on the Monaco race are left as they were; then the driver is deleted, so the step leaves the
# database as it found it. `delete` returns the total and the rows per model, read at the type the JIT returns.
struct PitStopRow
    pitstopid::Int64  # IDField
    raceid::Int64     # ForeignKey
    stop::Int64       # IntegerField
    lap::Int64        # IntegerField
end

struct DriverRow
    driverid::Int64                     # IDField
    surname::String                     # CharField
    debut_raceid::Union{Nothing, Int64}  # ForeignKey, null = true
end

# The rows per model `delete` reports for the step's race: its two pit stops and itself, by model name.
const CASCADE_COUNTS = "pitstop 2, race 1"

function cascade_step(circuitid::Int)::Bool
    try
        M.Race.objects.create("year" => 2015, "round" => 6, "circuitid" => circuitid,
                              "name" => "Monaco Grand Prix", "date" => Date(2015, 5, 24))
        race = M.Race.objects.filter("year" => 2015).list(RaceRow)
        length(race) == 1 || (say("cascade", string(length(race), " races of 2015")); return false)
        raceid = race[1].raceid
        M.PitStop.objects.create("raceid" => raceid, "stop" => 1, "lap" => 30)
        M.PitStop.objects.create("raceid" => raceid, "stop" => 2, "lap" => 52)
        M.Driver.objects.create("surname" => "Verstappen", "debut_raceid" => raceid)
        n, per = M.Race.objects.filter("raceid" => raceid).delete()::Tuple{Int, Dict{String, Integer}}
        counts = join([string(k, " ", per[k]::Int) for k in sort!(collect(keys(per)))], ", ")
        say("cascade", string(n, " rows; ", counts))
        left = M.PitStop.objects.filter("raceid" => raceid).list(PitStopRow)
        driver = M.Driver.objects.filter("surname" => "Verstappen").list(DriverRow)
        debut = length(driver) == 1 ? driver[1].debut_raceid : nothing
        say("cascade", string(length(left), " pit stops left; ", length(driver), " driver, debut ",
                              debut === nothing ? "none" : string(debut)))
        seeded_stops = M.PitStop.objects.filter("raceid__year" => 2008).list(PitStopRow)
        seeded = M.Driver.objects.filter("surname" => "Piquet").list(DriverRow)
        seeded_debut = length(seeded) == 1 ? seeded[1].debut_raceid : nothing
        kept = length(seeded_stops) == 1 && seeded_debut !== nothing && seeded_debut == seeded_stops[1].raceid
        say("cascade", string("seeded ", length(seeded_stops), " pit stop, ", length(seeded), " driver; ",
                              kept ? "kept" : "changed"))
        removed = first(M.Driver.objects.filter("surname" => "Verstappen").delete()::Tuple{Int, Dict{String, Integer}})
        return n == 3 && counts == CASCADE_COUNTS && isempty(left) && length(driver) == 1 && debut === nothing &&
               kept && removed == 1
    catch e
        failed("cascade", e); return false
    end
end

# ── The write residue of layer 7 (#1694, #1599 layer 7) ─────────────────────────────────────────────────────────────

# `bulk_update` with a constant `filters=` and with a two-column key (exit code 27): two Monaco races written by
# `bulk_insert`, their `round` set from `NamedTuple` rows matched on `raceid` under `filters = ["year" => 2010]` (the
# 2011 row's update is filtered out), then their `name` set matched on `year` and `round` together; each read back typed,
# then both races deleted.
function bulk_update_more_step(circuitid::Int)::Bool
    try
        PormG.bulk_insert(M.Race.objects,
            [(year = 2010, round = 6, circuitid = circuitid, name = "Monaco Grand Prix", date = Date(2010, 5, 16)),
             (year = 2011, round = 6, circuitid = circuitid, name = "Monaco Grand Prix", date = Date(2011, 5, 29))])
        written = M.Race.objects.filter("year__@gte" => 2010).order_by("year").list(RaceRow)
        length(written) == 2 || (say("bulk_update_more", string(length(written), " rows to update")); return false)
        r1 = PormG.bulk_update(M.Race.objects, [(raceid = written[1].raceid, round = 7), (raceid = written[2].raceid, round = 8)];
                               columns = ["round"], match_on = ["raceid"],
                               filters = ["year" => 2010])::NamedTuple{(:count, :rows), Tuple{Int, Nothing}}
        rounds = [x.round for x in M.Race.objects.filter("year__@gte" => 2010).order_by("year").list(RaceRow)]
        say("bulk_update_more", string("filters: ", r1.count, " rows; rounds ", join(rounds, ", ")))
        r2 = PormG.bulk_update(M.Race.objects, [(year = 2010, round = 7, name = "Monaco 2010"), (year = 2011, round = 6, name = "Monaco 2011")];
                               columns = ["name"], match_on = ["year", "round"])::NamedTuple{(:count, :rows), Tuple{Int, Nothing}}
        names = [x.name for x in M.Race.objects.filter("year__@gte" => 2010).order_by("year").list(RaceRow)]
        say("bulk_update_more", string("two keys: ", r2.count, " rows; ", join(names, ", ")))
        removed = first(M.Race.objects.filter("year__@gte" => 2010).delete()::Tuple{Int, Dict{String, Integer}})
        return r1.count == 1 && rounds == [7, 6] && r2.count == 2 && names == ["Monaco 2010", "Monaco 2011"] && removed == 2
    catch e
        failed("bulk_update_more", e); return false
    end
end

# The typed row of a constructor (`list(show_query = :struct)`'s fields).
struct ConstructorRow
    constructorid::Int64                 # IDField
    name::String                         # CharField
    parentid::Union{Nothing, Int64}      # ForeignKey, null = true
    home_circuitid::Int64                # ForeignKey, SET_DEFAULT
end

# `SET_DEFAULT` (exit code 28): a circuit of the step's own, a constructor whose home it is; deleting the circuit puts the
# constructor back on the default circuit (`models.DEFAULT_CIRCUIT_ID`), checked by a typed read, and the step deletes the
# constructor again. `delete` reports the circuit alone: a `SET_DEFAULT` child is updated, not deleted.
function set_default_step()::Bool
    try
        M.Circuit.objects.create("circuitref" => "hockenheim", "name" => "Hockenheimring", "country" => "Germany")
        circuit = M.Circuit.objects.filter("circuitref" => "hockenheim").list(CircuitId)
        length(circuit) == 1 || (say("set_default", string(length(circuit), " circuits named hockenheim")); return false)
        M.Constructor.objects.create("name" => "Mercedes", "home_circuitid" => circuit[1].circuitid)
        n, per = M.Circuit.objects.filter("circuitref" => "hockenheim").delete()::Tuple{Int, Dict{String, Integer}}
        counts = join([string(k, " ", per[k]::Int) for k in sort!(collect(keys(per)))], ", ")
        back = M.Constructor.objects.filter("name" => "Mercedes").list(ConstructorRow)
        home = length(back) == 1 ? back[1].home_circuitid : 0
        say("set_default", string(n, " rows; ", counts, "; home ", home == models_default_circuit() ? "default" : string(home)))
        removed = first(M.Constructor.objects.filter("name" => "Mercedes").delete()::Tuple{Int, Dict{String, Integer}})
        return n == 1 && length(back) == 1 && home == models_default_circuit() && removed == 1
    catch e
        failed("set_default", e); return false
    end
end

# A self-referential `CASCADE` (exit code 29, #1377): a chain of four constructors of the step's own (Tyrrell became BAR,
# then Honda, then Brawn); deleting Tyrrell deletes the three after it, level by level, through the collector's walk of
# the constructor's own table. Typed reads check that none of the four is left and that the seeded chain (Toleman,
# Benetton, Renault) is as it was.
function self_cascade_step()::Bool
    try
        parent = nothing
        for name in ("Tyrrell", "BAR", "Honda", "Brawn")
            if parent === nothing
                M.Constructor.objects.create("name" => name, "home_circuitid" => models_default_circuit())
            else
                M.Constructor.objects.create("name" => name, "parentid" => parent, "home_circuitid" => models_default_circuit())
            end
            row = M.Constructor.objects.filter("name" => name).list(ConstructorRow)
            length(row) == 1 || (say("self_cascade", string(length(row), " constructors named ", name)); return false)
            parent = row[1].constructorid
        end
        n, per = M.Constructor.objects.filter("name" => "Tyrrell").delete()::Tuple{Int, Dict{String, Integer}}
        counts = join([string(k, " ", per[k]::Int) for k in sort!(collect(keys(per)))], ", ")
        left = M.Constructor.objects.filter("name__@in" => ["Tyrrell", "BAR", "Honda", "Brawn"]).list(ConstructorRow)
        seeded = M.Constructor.objects.filter("name__@in" => ["Toleman", "Benetton", "Renault"]).order_by("constructorid").list(ConstructorRow)
        chain = length(seeded) == 3 && seeded[1].parentid === nothing && seeded[2].parentid == seeded[1].constructorid &&
                seeded[3].parentid == seeded[2].constructorid
        say("self_cascade", string(n, " rows; ", counts, "; ", length(left), " left; seeded chain ", chain ? "kept" : "changed"))
        return n == 4 && isempty(left) && chain
    catch e
        failed("self_cascade", e); return false
    end
end

# One refusal case: `call` must raise a PormG refusal; its line is `<label>: <type>: <message>`. A refusal that does not
# come, or another error, fails the case. Each case's closure is its own type, so the call into it is static.
function refusal_case(label::String, call::F)::Bool where {F}
    try
        call()
        say("bulk_refusal", string(label, ": not refused"))
        return false
    catch e
        text = refusal_text(e)
        text === nothing && (failed("bulk_refusal", e); return false)
        # One line per refusal, so `same_lines.sh` compares a multi-line message whole.
        say("bulk_refusal", string(label, ": ", replace(text, '\n' => " ⏎ ")))
        return true
    end
end

# A refusal's type and message, each error type read at its own type (its `msg` field), or `nothing` for any other
# error: `error_message` over the abstract `PormGError` would be a run-time call in a trimmed image.
function refusal_text(@nospecialize(e))::Union{Nothing, String}
    e isa PormG.QueryBuildError && return string("QueryBuildError: ", (e::PormG.QueryBuildError).msg)
    e isa PormG.UnknownFieldError && return string("UnknownFieldError: ", (e::PormG.UnknownFieldError).msg)
    e isa PormG.InvalidValueError && return string("InvalidValueError: ", (e::PormG.InvalidValueError).msg)
    e isa PormG.UnsafeMutationError && return string("UnsafeMutationError: ", (e::PormG.UnsafeMutationError).msg)
    e isa PormG.FilterError && return string("FilterError: ", (e::PormG.FilterError).msg)
    e isa PormG.BackendCapabilityError && return string("BackendCapabilityError: ", (e::PormG.BackendCapabilityError).msg)
    return nothing
end

# The default circuit's id, read where the entry's models are (`M` is the models module in every entry).
models_default_circuit() = M.DEFAULT_CIRCUIT_ID::Int

# The bulk writers' refusals (exit code 30): one input per kind PormG refuses before any SQL, each printing its typed
# error's type and text, the line the JIT control prints, so the job compares them (`same_lines.sh`). No row is written:
# the step checks that no 2012 race exists afterwards. A refusal that does not come is a failure; so is another error type.
function bulk_refusals_step(circuitid::Int)::Bool
    ok = true
    race(year) = (year = year, round = 6, circuitid = circuitid, name = "Monaco Grand Prix", date = Date(year, 5, 20))
    ok &= refusal_case("a query as the table", () -> PormG.bulk_insert(M.Race.objects, M.Race.objects.filter("year" => 2012)))
    ok &= refusal_case("not a table", () -> PormG.bulk_insert(M.Race.objects, [1, 2]))
    ok &= refusal_case("columns of different lengths", () -> PormG.bulk_insert(M.Race.objects, (year = [2012, 2012], round = [6])))
    ok &= refusal_case("rows with no columns", () -> PormG.bulk_insert(M.Race.objects, [NamedTuple(), NamedTuple()]))
    ok &= refusal_case("a columns= of the wrong type", () -> PormG.bulk_insert(M.Race.objects, [race(2012)]; columns = 5))
    ok &= refusal_case("a field mapped twice", () -> PormG.bulk_insert(M.Race.objects,
        [(a = 2012, b = 2012, round = 6, circuitid = circuitid, name = "Monaco Grand Prix", date = Date(2012, 5, 20))];
        columns = ["a" => "year", "b" => "year", "round", "circuitid", "name", "date"]))
    # #1694: a columns= name the model has no field for, bare and as a pair's target: `UnknownFieldError`, where it was a raw
    # `KeyError` (upgrading/2026-11-23-1694-bulk-insert-unknown-column-unknownfielderror.md).
    ok &= refusal_case("a columns= field the model lacks", () -> PormG.bulk_insert(M.Race.objects,
        [(year = 2012, round = 6, circuitid = circuitid, name = "Monaco Grand Prix", date = Date(2012, 5, 20), lap = 1)];
        columns = ["year", "round", "circuitid", "name", "date", "lap"]))
    ok &= refusal_case("a columns= pair to a field the model lacks", () -> PormG.bulk_insert(M.Race.objects,
        [(year = 2012, round = 6, circuitid = circuitid, name = "Monaco Grand Prix", date = Date(2012, 5, 20), lap = 1)];
        columns = ["year", "round", "circuitid", "name", "date", "lap" => "laps"]))
    ok &= refusal_case("a column in another case", () -> PormG.bulk_insert(M.Race.objects,
        [(Year = 2012, round = 6, circuitid = circuitid, name = "Monaco Grand Prix", date = Date(2012, 5, 20))]))
    ok &= refusal_case("a primary key set", () -> PormG.bulk_update(M.Race.objects, [(raceid = 1, round = 6)];
        columns = ["raceid", "round"], match_on = ["round"]))
    ok &= refusal_case("a match_on pair", () -> PormG.bulk_update(M.Race.objects, [(raceid = 1, round = 6)];
        columns = ["round"], match_on = ["raceid" => "raceid"]))
    ok &= refusal_case("a match_on the model does not have", () -> PormG.bulk_update(M.Race.objects, [(lap = 1, round = 6)];
        columns = ["round"], match_on = ["lap"]))
    ok &= refusal_case("a per-row key in filters=", () -> PormG.bulk_update(M.Race.objects, [(raceid = 1, round = 6)];
        columns = ["round"], filters = ["raceid"]))
    ok &= refusal_case("a filters= entry that is no predicate", () -> PormG.bulk_update(M.Race.objects, [(raceid = 1, round = 6)];
        columns = ["round"], match_on = ["raceid"], filters = [5]))
    ok &= refusal_case("a filters= column name beside match_on", () -> PormG.bulk_update(M.Race.objects, [(raceid = 1, round = 6)];
        columns = ["round"], match_on = ["raceid"], filters = ["raceid"]))
    ok &= refusal_case("a key given twice", () -> PormG.bulk_update(M.Race.objects, [(raceid = 1, round = 6), (raceid = 1, round = 7)];
        columns = ["round"], match_on = ["raceid"]))
    # #1841: every field the rows bring is a key, so nothing is left for SET. On `Season`, which fills no field itself:
    # `Race`'s `auto_now` field, which these rows would not bring, would be set, so the same call on a race has a SET.
    ok &= refusal_case("every field a key", () -> PormG.bulk_update(M.Season.objects, [(seasonid = 1, year = 2012)];
        columns = ["year"], match_on = ["seasonid"], filters = ["year" => 2012]))
    ok &= refusal_case("a joined path", () -> PormG.bulk_update(M.Race.objects, [(raceid = 1, cn = "x")];
        columns = ["cn" => "circuitid__name"], match_on = ["raceid"]))
    ok &= refusal_case("an ordered handler", () -> PormG.bulk_update(M.Race.objects.order_by("year"), [(raceid = 1, round = 6)];
        columns = ["round"], match_on = ["raceid"]))
    ok &= refusal_case("a handler with a CTE", () -> PormG.bulk_update(
        M.Race.objects.with("st" => M.Race.objects.values("circuitid"), join_field = "circuitid" => "circuitid"),
        [(raceid = 1, round = 6)]; columns = ["round"], match_on = ["raceid"]))
    ok &= refusal_case("a returning= of the wrong type", () -> PormG.bulk_insert(M.Race.objects, [race(2012)]; returning = 5))
    ok &= refusal_case("an empty returning=", () -> PormG.bulk_insert(M.Race.objects, [race(2012)]; returning = String[]))
    ok &= refusal_case("a returning= field the model does not have", () -> PormG.bulk_insert(M.Race.objects, [race(2012)];
        returning = ["laps"]))
    ok &= refusal_case("an on_conflict= of the wrong kind", () -> PormG.bulk_insert(M.Race.objects, [race(2012)];
        on_conflict = :replace))
    ok &= refusal_case("an on_conflict= update with no target", () -> PormG.bulk_insert(M.Race.objects, [race(2012)];
        on_conflict = (action = :update, set = ["round"])))
    ok &= refusal_case("an on_conflict= with an unknown key", () -> PormG.bulk_insert(M.Race.objects, [race(2012)];
        on_conflict = (action = :nothing, bogus = 1)))
    try
        left = M.Race.objects.filter("year" => 2012).list(RaceRow)
        say("bulk_refusal", string(length(left), " races written"))
        ok &= isempty(left)
    catch e
        failed("bulk_refusal", e); ok = false
    end
    return ok
end

# ── bulk_insert's on_conflict= executing (#1694, #1599 layer 7) ─────────────────────────────────────────────────────────
#
# The step writes races with explicit ids far above any id a sequence gives in the fixture (as `update_or_create_step`
# does), so the `on_conflict` target is the primary key, the one unique key the race table has (MySQL's `ON DUPLICATE KEY
# UPDATE` names no target, so it runs only when the target is that key). Explicit keys also make the write resync the
# table's sequence afterwards (SQLite's `sqlite_sequence`, PostgreSQL's `setval`; MySQL moves `AUTO_INCREMENT` past them
# itself), so the next generated id is above them, which no step reads. The step deletes every race it wrote.
const BULK_CONFLICT_IDS = (9_000_010, 9_000_011, 9_000_012)

# The rounds of the races with these ids, in id order, by a typed read.
function rounds_of(ids::Vector{Int})::Vector{Int}
    return Int[Int(x.round) for x in M.Race.objects.filter("raceid__@in" => ids).order_by("raceid").list(RaceRow)]
end

# `on_conflict=` (exit code 31): a race written first; then an upsert over it and a new one (`action = :update`, target
# `raceid`, `set` `round`), which updates the first race's round and inserts the second; then a skip over the second and
# a third (`action = :nothing`, target `raceid`), which leaves the second as it was and inserts the third. Each is read
# back typed; `bulk_insert` returns `(count, rows)` with `rows = nothing` without `returning=`, asserted at that type.
function bulk_conflict_step(circuitid::Int)::Bool
    try
        a, b, c = BULK_CONFLICT_IDS
        race(id, year, round) = (raceid = id, year = year, round = round, circuitid = circuitid,
                                 name = "Monaco Grand Prix", date = Date(year, 5, 20))
        PormG.bulk_insert(M.Race.objects, [race(a, 2018, 6)])
        up = PormG.bulk_insert(M.Race.objects, [race(a, 2018, 7), race(b, 2019, 6)];
            on_conflict = (action = :update, target = ["raceid"], set = ["round"]))::NamedTuple{(:count, :rows), Tuple{Int, Nothing}}
        after_up = rounds_of([a, b])
        skip = PormG.bulk_insert(M.Race.objects, [race(b, 2019, 9), race(c, 2020, 6)];
            on_conflict = (action = :nothing, target = ["raceid"]))::NamedTuple{(:count, :rows), Tuple{Int, Nothing}}
        after_skip = rounds_of([a, b, c])
        say("bulk_conflict", string("update ", up.count, " rows; rounds ", join(after_up, ", ")))
        say("bulk_conflict", string("nothing ", skip.count, " rows; rounds ", join(after_skip, ", ")))
        removed = first(M.Race.objects.filter("raceid__@in" => [a, b, c]).delete()::Tuple{Int, Dict{String, Integer}})
        return up.count == 2 && after_up == [7, 6] && skip.count == 1 && after_skip == [7, 6, 6] && removed == 3
    catch e
        failed("bulk_conflict", e); return false
    end
end

# `returning=` (exit code 32), MySQL only: a race with no id and `returning = ["raceid"]` needs its key drawn before the
# INSERT, which MySQL's `AUTO_INCREMENT` cannot do, so PormG refuses it before any SQL with a `BackendCapabilityError`,
# the line the JIT control prints. A `returning=` that executes does not run trimmed on any engine yet: its rows are a
# table whose type follows the requested names, the values and the caller's table kind (`_returning_table`), which a
# trimmed image has no code for (#1599 residue). No row is written.
function preallocated_keys_refusal_step(circuitid::Int)::Bool
    ok = refusal_case("an allocated key", () -> PormG.bulk_insert(M.Race.objects,
        [(year = 2022, round = 6, circuitid = circuitid, name = "Monaco Grand Prix", date = Date(2022, 5, 29))];
        returning = ["raceid"]))
    try
        left = M.Race.objects.filter("year" => 2022).list(RaceRow)
        say("bulk_refusal", string(length(left), " races written"))
        return ok && isempty(left)
    catch e
        failed("bulk_refusal", e); return false
    end
end

# ── The writes applications use most (#1694, #1599 layer 7) ──────────────────────────────────────────────────────────

# The column table a `DataFrame` hands a bulk writer, as a `NamedTuple` of vectors.
const RaceRoundRow = NamedTuple{(:year, :round, :name), Tuple{Int64, Int64, String}}

# Bulk writes from a column table (#1694, #1599 layer 7): `bulk_insert` of two races whose columns are named otherwise
# than the fields (`columns = ["yr" => "year", "rnd" => "round", …]`), then `bulk_update` of their rounds matched on
# `year` under two `filters=` pairs (`"circuitid" => …` and `"name" => …`), each checked by a typed read; the step deletes
# the two races. Exit code 47 when a write raises, a read does not show it, or the delete does not remove the rows.
function bulk_table_step(circuitid::Int)::Bool
    ok = false
    try
        table = (yr = [2040, 2041], rnd = [6, 7], cid = [circuitid, circuitid], nm = ["Monaco Grand Prix", "Monaco Grand Prix"],
                 dt = [Date(2040, 5, 27), Date(2041, 5, 26)])
        PormG.bulk_insert(M.Race.objects, table;
                          columns = ["yr" => "year", "rnd" => "round", "cid" => "circuitid", "nm" => "name", "dt" => "date"])
        inserted = M.Race.objects.filter("year__@in" => [2040, 2041]).order_by("year").values("year", "round", "name").list(RaceRoundRow)
        updates = (year = [2040, 2041], round = [16, 17])
        r = PormG.bulk_update(M.Race.objects, updates; columns = ["round"], match_on = ["year"],
                              filters = ["circuitid" => circuitid, "name" => "Monaco Grand Prix"])::NamedTuple{(:count, :rows), Tuple{Int, Nothing}}
        updated = M.Race.objects.filter("year__@in" => [2040, 2041]).order_by("year").values("year", "round", "name").list(RaceRoundRow)
        removed = first(M.Race.objects.filter("year__@in" => [2040, 2041]).delete()::Tuple{Int, Dict{String, Integer}})
        shown(rows) = join([string(x.year, " round ", x.round) for x in rows], ", ")
        say("bulk_table", string("columns= pairs: ", length(inserted), " rows: ", shown(inserted), "; two filters= pairs: ",
                                 r.count, " rows: ", shown(updated), "; removed ", removed))
        ok = shown(inserted) == "2040 round 6, 2041 round 7" && r.count == 2 && shown(updated) == "2040 round 16, 2041 round 17" &&
             removed == 2
    catch e
        failed("bulk_table", e)
    finally
        if !ok   # neither race is left behind (`transaction_step`'s reason)
            try
                M.Race.objects.filter("year__@in" => [2040, 2041]).delete()
            catch e
                failed("bulk_table", e)
            end
        end
    end
    return ok
end

const SeasonRow = NamedTuple{(:year, :previousid), Tuple{Int64, Union{Nothing, Int64}}}
const SeasonIdRow = NamedTuple{(:seasonid,), Tuple{Int64}}

# Whether `e` is the `ProtectedError` a delete raises for `field` under `rule`, read at its type.
protected_by(@nospecialize(e), field::String, rule::String)::Bool =
    e isa PormG.ProtectedError && occursin(field, (e::PormG.ProtectedError).msg) && occursin(rule, (e::PormG.ProtectedError).msg)

# The delete rules a schema's keys declare most beyond `CASCADE` (#1694, #1599 layer 7): deleting the seeded Monaco race,
# which has a result (`PROTECT`), and the result's driver (`RESTRICT`) is refused with `ProtectedError` before any row
# is deleted, and both stay; deleting a season clears the next season's reference to it (`SET_NULL` on its own table).
# The step deletes the seasons it made. Exit code 49 when a delete is not refused, a seeded row is gone, or the reference
# is not cleared.
function delete_rules_step()::Bool
    ok = false
    try
        protect = try
            M.Race.objects.filter("year" => 2008, "round" => 6).delete()
            "not refused"
        catch e
            protected_by(e, "result.raceid", "PROTECT") || rethrow()
            "refused with ProtectedError (result.raceid)"
        end
        restrict = try
            M.Driver.objects.filter("surname" => "Piquet").delete()
            "not refused"
        catch e
            protected_by(e, "result.driverid", "RESTRICT") || rethrow()
            "refused with ProtectedError (result.driverid)"
        end
        kept = string(M.Race.objects.filter("year" => 2008, "round" => 6).count()::Int, " race, ",
                      M.Driver.objects.filter("surname" => "Piquet").count()::Int, " driver, ",
                      M.Result.objects.count()::Int, " result")
        M.Season.objects.create("year" => 2030)
        first_season = M.Season.objects.filter("year" => 2030).values("seasonid").list(SeasonIdRow)[1].seasonid
        M.Season.objects.create("year" => 2031, "previousid" => first_season)
        deleted = first(M.Season.objects.filter("year" => 2030).delete()::Tuple{Int, Dict{String, Integer}})
        after = M.Season.objects.filter("year" => 2031).values("year", "previousid").list(SeasonRow)
        previous = isempty(after) ? "missing" : after[1].previousid === nothing ? "none" : string(after[1].previousid)
        say("delete_rules", string("PROTECT: ", protect, "; RESTRICT: ", restrict, "; kept ", kept))
        say("delete_rules", string("SET_NULL: deleted ", deleted, ", 2031 previous ", previous))
        ok = startswith(protect, "refused") && startswith(restrict, "refused") && kept == "1 race, 1 driver, 1 result" &&
             deleted == 1 && previous == "none"
    catch e
        failed("delete_rules", e)
    finally
        try   # the seasons the step made, on every path (the 2031 season no longer references 2030 once it is deleted)
            M.Season.objects.filter("year__@in" => [2030, 2031], "previousid__@isnull" => false).update("previousid" => nothing)
            M.Season.objects.filter("year__@in" => [2030, 2031]).delete()
        catch e
            failed("delete_rules", e); ok = false
        end
    end
    return ok
end

# A handler `create` wrote through, copied, and a second create through the copy (#1684, #1599 layer 7): `create` leaves
# its values in the handler's insert map, so the copy copies a filled map, which went through `deepcopy`'s generic walk
# before #1684. (The second `create` sets the copy's map anew: the step shows the filled map's copy runs, and the unit
# test `test_typed_copy_1684.jl` checks what it holds.) Both rows are read back typed, then deleted, so the step leaves the database as it found it. Exit code 55
# when a call raises or the read does not return the two rows.
function copy_write_step(circuitid::Int)::Bool
    try
        q = M.Race.objects
        q.create("year" => 2012, "round" => 6, "circuitid" => circuitid, "name" => "Monaco Grand Prix",
                 "date" => Date(2012, 5, 27))
        c = q.copy()
        c.create("year" => 2013, "round" => 6, "circuitid" => circuitid, "name" => "Monaco Grand Prix",
                 "date" => Date(2013, 5, 26))
        rows = M.Race.objects.filter("year__@in" => [2012, 2013]).order_by("year").list(RaceRow)
        say("copy_write", string(length(rows), " rows: ", join([string(r.year) for r in rows], ", ")))
        removed = first(M.Race.objects.filter("year__@in" => [2012, 2013]).delete()::Tuple{Int, Dict{String, Integer}})
        removed == 2 || say("copy_write", string("removed ", removed, " rows, expected 2"))
        return [r.year for r in rows] == [2012, 2013] && removed == 2
    catch e
        failed("copy_write", e); return false
    end
end
