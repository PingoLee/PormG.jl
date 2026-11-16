# The read steps every fixture binary runs after its first typed read (#1599 layer 5): comparison filters on a date
# and on an integer, and an `order_by` each way, each checked by its typed result. Included by the SQLite steps
# (`../steps.jl`) and by each server variant's `main.jl`, after each defines `M`, `RaceRow`, `say` and `failed`, so
# every binary prints the same lines for the same step. They run before any write, on the two races every `prep.jl`
# seeds: the 2008 Monaco Grand Prix (round 6, 2008-05-25) and the 2008 Brazilian Grand Prix (round 18, 2008-11-02).

# The race names of `rows`, in order, as one line.
race_names(rows::Vector{RaceRow})::String = join([r.name for r in rows], ", ")

# One comparison lookup on a date and one on an integer (`__@gte`, `__@lt`). On SQLite and MySQL an ordering takes
# the render's unnamed-temporal check (#1310), which a trimmed image could not run (#1814, wall 21). Exit code 10
# when a read raises or does not return the one race it picks out.
function compare_step()::Bool
    try
        later = M.Race.objects.filter("date__@gte" => Date(2008, 6, 1)).list(RaceRow)
        say("compare", string("date__@gte ", length(later), " rows: ", race_names(later)))
        early = M.Race.objects.filter("round__@lt" => 10).list(RaceRow)
        say("compare", string("round__@lt ", length(early), " rows: ", race_names(early)))
        return length(later) == 1 && later[1].name == "Brazilian Grand Prix" &&
               length(early) == 1 && early[1].name == "Monaco Grand Prix"
    catch e
        failed("compare", e); return false
    end
end

# `order_by` ascending and descending on the date. Exit code 11 when a read raises or the order is not the dates'.
function order_step()::Bool
    try
        asc = M.Race.objects.order_by("date").list(RaceRow)
        say("order", string("date: ", race_names(asc)))
        desc = M.Race.objects.order_by("-date").list(RaceRow)
        say("order", string("-date: ", race_names(desc)))
        return race_names(asc) == "Monaco Grand Prix, Brazilian Grand Prix" &&
               race_names(desc) == "Brazilian Grand Prix, Monaco Grand Prix"
    catch e
        failed("order", e); return false
    end
end
