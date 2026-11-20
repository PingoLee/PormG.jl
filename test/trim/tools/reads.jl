# The read steps every fixture binary runs after its first typed read (#1599 layer 5): comparison filters on a date
# and on an integer, an `order_by` each way, the other common lookups and comparisons against an expression, each checked by its typed
# result. Included by the SQLite steps
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

# The other common filter lookups (#1599 layer 5): the two comparisons `compare_step` leaves out (`__@gt`, `__@lte`),
# a range of dates, a membership over integers and over text, a NULL test each way and a text match each way. Each
# picks out its own rows from the two seeded races, and its typed result is checked against them. Exit code 13 when
# a read raises or returns other rows.
function lookup_step()::Bool
    try
        ok = true
        ok &= lookup_line("round__@gt", M.Race.objects.filter("round__@gt" => 10).list(RaceRow),
                          "Brazilian Grand Prix")
        ok &= lookup_line("round__@lte", M.Race.objects.filter("round__@lte" => 6).list(RaceRow),
                          "Monaco Grand Prix")
        ok &= lookup_line("date__@range",
                          M.Race.objects.filter("date__@range" => [Date(2008, 5, 1), Date(2008, 6, 30)]).list(RaceRow),
                          "Monaco Grand Prix")
        ok &= lookup_line("round__@in", M.Race.objects.filter("round__@in" => [6, 7]).list(RaceRow),
                          "Monaco Grand Prix")
        ok &= lookup_line("name__@in",
                          M.Race.objects.filter("name__@in" => ["Brazilian Grand Prix"]).list(RaceRow),
                          "Brazilian Grand Prix")
        ok &= lookup_line("date__@isnull false",
                          M.Race.objects.filter("date__@isnull" => false).order_by("date").list(RaceRow),
                          "Monaco Grand Prix, Brazilian Grand Prix")
        ok &= lookup_line("date__@isnull true", M.Race.objects.filter("date__@isnull" => true).list(RaceRow), "")
        ok &= lookup_line("name__@icontains", M.Race.objects.filter("name__@icontains" => "brazil").list(RaceRow),
                          "Brazilian Grand Prix")
        ok &= lookup_line("name__@contains", M.Race.objects.filter("name__@contains" => "Monaco").list(RaceRow),
                          "Monaco Grand Prix")
        return ok
    catch e
        failed("lookup", e); return false
    end
end

# One lookup's line, `<lookup> <n> rows: <names>` (`none` for no rows, so no line ends in a space), and whether its
# rows are the `expected` names.
function lookup_line(lookup::String, rows::Vector{RaceRow}, expected::String)::Bool
    names = race_names(rows)
    say("lookup", string(lookup, " ", length(rows), " rows: ", isempty(names) ? "none" : names))
    return names == expected
end

using PormG.Functions: Case, When, Extract

# Comparisons against expressions (#1599 layer 5): an `F` with arithmetic on the right side of a lookup and on the
# left side of a comparison, a function over a column (`Extract` of the date's month, and the `@year` transform, which
# the render rewrites into a range on the column), and a `Case`/`When` on each side. Each picks out its own rows from
# the two seeded races, and its typed result is checked against them. Exit code 14 when a read raises or returns
# other rows.
function expr_step()::Bool
    try
        ok = true
        ok &= expr_line("year__@gt F(round) + 2000",
                        M.Race.objects.filter("year__@gt" => F("round") + 2000).list(RaceRow), "Monaco Grand Prix")
        ok &= expr_line("F(round) + 1 == 19", M.Race.objects.filter(F("round") + 1 == 19).list(RaceRow),
                        "Brazilian Grand Prix")
        ok &= expr_line("Extract(date, month) == 11",
                        M.Race.objects.filter(Extract("date", "month") == 11).list(RaceRow), "Brazilian Grand Prix")
        ok &= expr_line("date__@year", M.Race.objects.filter("date__@year" => 2008).order_by("date").list(RaceRow),
                        "Monaco Grand Prix, Brazilian Grand Prix")
        ok &= expr_line("round__@gte Case",
                        M.Race.objects.filter("round__@gte" =>
                            Case(When("name" => "Monaco Grand Prix", then = 6), default = 100)).list(RaceRow),
                        "Monaco Grand Prix")
        ok &= expr_line("Case == 1",
                        M.Race.objects.filter(Case(When("round__@lt" => 10, then = 1), default = 0) == 1).list(RaceRow),
                        "Monaco Grand Prix")
        return ok
    catch e
        failed("expr", e); return false
    end
end

# One expression comparison's line, `<label> <n> rows: <names>`, and whether its rows are the `expected` names.
function expr_line(label::String, rows::Vector{RaceRow}, expected::String)::Bool
    names = race_names(rows)
    say("expr", string(label, " ", length(rows), " rows: ", isempty(names) ? "none" : names))
    return names == expected
end

# The untyped read (#1599 layer 6): `first()` and `list()` with no type, and a `values(...)` projection, return
# `PormGRow`s holding a `Dict{Symbol,Any}` whose cell types the statement decides. Each line shows the cells it checks
# and, for `first()` and the projection, every key in the row's own iteration order with its value's type, so a binary
# whose rows differ from the JIT control's in a key, its order or a type prints a different line. Exit code 17 when a
# read raises or returns other rows. The results are asserted at the types the untyped terminals return
# (`Union{Nothing,PormGRow}`, `Vector{PormGRow}`), as code in a trimmed image reads them: the terminals pick their
# return by `show_query`, so the caller does not infer it.
function untyped_step()::Bool
    try
        row = M.Race.objects.filter("name" => "Monaco Grand Prix").first()::Union{Nothing, PormGRow}
        row === nothing && (say("untyped", "first none"); return false)
        say("untyped", string("first ", cell_text(row[:name]), " round ", cell_text(row[:round]), " date ",
                              cell_text(row[:date])))
        say("untyped", string("first types ", row_types(row)))
        rows = M.Race.objects.order_by("date").list()::Vector{PormGRow}
        names = join([cell_text(r[:name]) for r in rows], ", ")
        say("untyped", string("list ", length(rows), " rows: ", names))
        vals = M.Race.objects.filter("round__@lt" => 10).values("name", "round").list()::Vector{PormGRow}
        say("untyped", string("values ", length(vals), " rows: ", isempty(vals) ? "none" : row_types(vals[1]),
                              isempty(vals) ? "" : string("; ", cell_text(vals[1][:name]), " ", cell_text(vals[1][:round]))))
        return cell_text(row[:name]) == "Monaco Grand Prix" && cell_text(row[:round]) == "6" &&
               names == "Monaco Grand Prix, Brazilian Grand Prix" &&
               length(vals) == 1 && cell_text(vals[1][:name]) == "Monaco Grand Prix"
    catch e
        failed("untyped", e); return false
    end
end

# A cell of an untyped row as text: its value for the types the steps check, its type's name otherwise. Every call is
# made at a concrete type, so the fixture's own code adds no dynamic call to the read it measures.
function cell_text(@nospecialize(v))::String
    v isa String && return v
    v isa Int64 && return string(v)
    v isa Int32 && return string(v)
    v isa Date && return string(v)
    v isa Missing && return "missing"
    return string("<", type_name(v), ">")
end

type_name(@nospecialize(v))::String = String((typeof(v)::DataType).name.name)

# A row's keys in its own iteration order, each with its value's type: `name::String, round::Int64`.
row_types(row::PormGRow)::String = join([string(k, "::", type_name(v)) for (k, v) in pairs(row)], ", ")

using PormG.Functions: Abs, Round, Upper, Lower, Count, Sum

# The typed rows of `func_step`'s projections: `values(...)` names exactly these fields, in this order (#1352).
const AbsRow = NamedTuple{(:name, :d, :r), Tuple{String, Int64, Int64}}
const GroupRow = NamedTuple{(:year, :n, :s), Tuple{Int64, Int64, Int64}}
const NameRow = NamedTuple{(:name, :u), Tuple{String, String}}
const CaseRow = NamedTuple{(:name, :c), Tuple{String, Int64}}

# The remaining function shapes (#1599 layer 5): a number function over a column in a projection (`Abs` over an `F`
# difference, `Round` over the integer column) and in a filter, two aggregates grouped by a column (`Count`, `Sum`), a
# nested function as a column (`Upper(Lower(...))`), and a `Case` whose `then` is an `F`. Each reads into its typed row
# and is checked against the two seeded races. Exit code 19 when a read raises or returns other rows.
function func_step()::Bool
    try
        ok = true
        a = M.Race.objects.values("name", "d" => Abs(F("round") - 10), "r" => Round(F("round"))).order_by("date").list(AbsRow)
        la = join([string(x.name, " ", x.d, " ", x.r) for x in a], ", ")
        say("func", string("Abs/Round ", length(a), " rows: ", la))
        ok &= la == "Monaco Grand Prix 4 6, Brazilian Grand Prix 8 18"
        f = M.Race.objects.filter(Abs(F("round") - 10) == 4).list(RaceRow)
        say("func", string("Abs == 4 ", length(f), " rows: ", race_names(f)))
        ok &= race_names(f) == "Monaco Grand Prix"
        g = M.Race.objects.values("year", "n" => Count("raceid"), "s" => Sum("round")).list(GroupRow)
        lg = join([string(x.year, " ", x.n, " ", x.s) for x in g], ", ")
        say("func", string("Count/Sum ", length(g), " rows: ", lg))
        ok &= lg == "2008 2 24"
        u = M.Race.objects.values("name", "u" => Upper(Lower("name"))).order_by("date").list(NameRow)
        lu = join([x.u for x in u], ", ")
        say("func", string("Upper(Lower) ", length(u), " rows: ", lu))
        ok &= lu == "MONACO GRAND PRIX, BRAZILIAN GRAND PRIX"
        c = M.Race.objects.values("name", "c" => Case(When("round__@lt" => 10, then = F("round")), default = 0)).
            order_by("date").list(CaseRow)
        lc = join([string(x.name, " ", x.c) for x in c], ", ")
        say("func", string("Case then F ", length(c), " rows: ", lc))
        ok &= lc == "Monaco Grand Prix 6, Brazilian Grand Prix 0"
        return ok
    catch e
        failed("func", e); return false
    end
end
