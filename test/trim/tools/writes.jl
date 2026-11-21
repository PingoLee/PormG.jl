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
# step deletes its row again (a row-level write does not resync the sequence). `get_or_create` has no step: on a hit it
# reads its row through the untyped `first()`, whose rows a trimmed image cannot read (the untyped read, layer 6).
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
