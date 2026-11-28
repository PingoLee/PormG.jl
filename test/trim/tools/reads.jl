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

using PormG.QueryBuilder: Subquery, Exists, OuterRef
using PormG.Functions: Max

# The typed row of `subquery_step`'s correlated projection: the race's name and its circuit's, read by a `Subquery`.
const CircuitNameRow = NamedTuple{(:name, :cn), Tuple{String, String}}

# Subqueries (#1599 layer 5): a membership in a query (`__@in`), an `Exists` correlated with `OuterRef`, a `Subquery`
# correlated with `OuterRef` as a column, and a `Subquery` on the right of a filter, uncorrelated and correlated (each
# scalar subquery an aggregate, so it is one row whatever it matches). Each
# reads into its typed row and is checked against the two seeded races and their circuits. Exit code 20 when a read
# raises or returns other rows.
function subquery_step()::Bool
    try
        ok = true
        ok &= sub_line("circuitid__@in query",
                        M.Race.objects.filter("circuitid__@in" =>
                            M.Circuit.objects.filter("country" => "Monaco").values("circuitid")).list(RaceRow),
                        "Monaco Grand Prix")
        ok &= sub_line("Exists OuterRef",
                        M.Race.objects.filter(Exists(M.Circuit.objects.filter("circuitid" => OuterRef("circuitid"),
                                                                              "country" => "Brazil"))).list(RaceRow),
                        "Brazilian Grand Prix")
        c = M.Race.objects.values("name", "cn" => Subquery(M.Circuit.objects.filter("circuitid" => OuterRef("circuitid")).
                                                           values("n" => Max("name")))).order_by("date").list(CircuitNameRow)
        lc = join([string(x.name, " at ", x.cn) for x in c], ", ")
        say("subquery", string("Subquery OuterRef column ", length(c), " rows: ", lc))
        ok &= lc == "Monaco Grand Prix at Circuit de Monaco, Brazilian Grand Prix at Autódromo José Carlos Pace"
        ok &= sub_line("circuitid == Subquery",
                        M.Race.objects.filter("circuitid" =>
                            Subquery(M.Circuit.objects.filter("country" => "Brazil").values("m" => Max("circuitid")))).list(RaceRow),
                        "Brazilian Grand Prix")
        ok &= sub_line("round == Subquery OuterRef",
                        M.Race.objects.filter("round" =>
                            Subquery(M.Race.objects.filter("raceid" => OuterRef("raceid"), "year" => 2008).values("m" => Max("round")))).
                            order_by("date").list(RaceRow),
                        "Monaco Grand Prix, Brazilian Grand Prix")
        return ok
    catch e
        failed("subquery", e); return false
    end
end

# One subquery read's line, `<label> <n> rows: <names>`, and whether its rows are the `expected` names.
function sub_line(label::String, rows::Vector{RaceRow}, expected::String)::Bool
    names = race_names(rows)
    say("subquery", string(label, " ", length(rows), " rows: ", isempty(names) ? "none" : names))
    return names == expected
end

using PormG.Functions: Rank, RowNumber, WindowOver

# The typed rows of `join_step`'s CTE and window reads: the race's name and a count or a rank.
const CountRow = NamedTuple{(:name, :n), Tuple{String, Int64}}
const RankRow = NamedTuple{(:name, :rk), Tuple{String, Int64}}

# Joins, CTEs and windows (#1599 layer 5): a join projected with `values()` and ordered by the joined path and by its
# alias, a read through a CTE joined back to the race (its column projected, and filtered on), and two window functions
# (`RowNumber` over a partition, `Rank` over an order). Each reads into its typed row and is checked against the two
# seeded races and their circuits. Exit code 21 when a read raises or returns other rows.
function join_step()::Bool
    try
        ok = true
        races = M.Race.objects.filter("circuitid__country__@in" => ["Monaco", "Brazil"])
        ok &= named_line("join", "order_by path",
                         races.values("name", "cn" => "circuitid__name").order_by("circuitid__name").list(CircuitNameRow),
                         r -> string(r.name, " at ", r.cn),
                         "Brazilian Grand Prix at Autódromo José Carlos Pace, Monaco Grand Prix at Circuit de Monaco")
        races = M.Race.objects.filter("circuitid__country__@in" => ["Monaco", "Brazil"])
        ok &= named_line("join", "order_by -alias",
                         races.values("name", "cn" => "circuitid__name").order_by("-cn").list(CircuitNameRow),
                         r -> string(r.name, " at ", r.cn),
                         "Monaco Grand Prix at Circuit de Monaco, Brazilian Grand Prix at Autódromo José Carlos Pace")
        stats = M.Race.objects.values("circuitid", "n" => Count("raceid"))
        q = M.Race.objects
        q.with("st" => stats, join_field = "circuitid" => "circuitid")
        ok &= named_line("join", "CTE column", q.values("name", "n" => "st__n").order_by("date").list(CountRow),
                         r -> string(r.name, " ", r.n), "Monaco Grand Prix 1, Brazilian Grand Prix 1")
        stats = M.Race.objects.filter("year" => 2008).values("circuitid", "n" => Count("raceid"))
        q = M.Race.objects
        q.with("st" => stats, join_field = "circuitid" => "circuitid")
        ok &= named_line("join", "CTE filter", q.filter("st__n__@gte" => 1, "round__@gt" => 10).values("name", "n" => "st__n").list(CountRow),
                         r -> string(r.name, " ", r.n), "Brazilian Grand Prix 1")
        ok &= named_line("join", "RowNumber partition",
                         M.Race.objects.values("name", "rk" => RowNumber(over = WindowOver(partition_by = ["year"], order_by = ["date"]))).
                             order_by("date").list(RankRow),
                         r -> string(r.name, " ", r.rk), "Monaco Grand Prix 1, Brazilian Grand Prix 2")
        ok &= named_line("join", "Rank order",
                         M.Race.objects.values("name", "rk" => Rank(over = WindowOver(order_by = ["-round"]))).order_by("-round").list(RankRow),
                         r -> string(r.name, " ", r.rk), "Brazilian Grand Prix 1, Monaco Grand Prix 2")
        return ok
    catch e
        failed("join", e); return false
    end
end

using PormG.Functions: Cast

# The typed rows of `cte_step`: the race's name and the CTE column, at the type its expression means.
const FlagRow = NamedTuple{(:name, :b), Tuple{String, Bool}}
const TextRow = NamedTuple{(:name, :s), Tuple{String, String}}

# A CTE read over each body `.with()` copies through the typed tree copy, and whose column the CTE typing names through
# the walk (#1599 layer 5): a body projecting a correlated scalar `Subquery`, an `Exists`, a window, a `Case`, a `Cast`,
# `F` arithmetic and a `Case` over a mutable literal (a list), each joined back to the race on `circuitid`, its column
# projected and read into its typed row. Exit code 26 when a read raises or returns other rows.
function cte_step()::Bool
    try
        ok = true
        latest = M.Race.objects.filter("circuitid" => OuterRef("circuitid")).values("year").order_by("-year")
        ok &= cte_line("Subquery", M.Race.objects.values("circuitid", "v" => Subquery(latest)), CountRow,
                       r -> string(r.name, " ", r.n), "Monaco Grand Prix 2008, Brazilian Grand Prix 2008", "n")
        late = M.Race.objects.filter("circuitid" => OuterRef("circuitid"), "round__@gt" => 10)
        ok &= cte_line("Exists", M.Race.objects.values("circuitid", "v" => Exists(late)), FlagRow,
                       r -> string(r.name, " ", r.b), "Monaco Grand Prix false, Brazilian Grand Prix true", "b")
        ok &= cte_line("RowNumber", M.Race.objects.values("circuitid", "v" => RowNumber(over = WindowOver(order_by = ["date"]))),
                       CountRow, r -> string(r.name, " ", r.n), "Monaco Grand Prix 1, Brazilian Grand Prix 2", "n")
        ok &= cte_line("Case", M.Race.objects.values("circuitid", "v" => Case(When("round__@gt" => 10, then = 1), default = 0)),
                       CountRow, r -> string(r.name, " ", r.n), "Monaco Grand Prix 0, Brazilian Grand Prix 1", "n")
        ok &= cte_line("Cast", M.Race.objects.values("circuitid", "v" => Cast("round", "text")), TextRow,
                       r -> string(r.name, " ", r.s), "Monaco Grand Prix 6, Brazilian Grand Prix 18", "s")
        ok &= cte_line("F arithmetic", M.Race.objects.values("circuitid", "v" => F("round") + 1), CountRow,
                       r -> string(r.name, " ", r.n), "Monaco Grand Prix 7, Brazilian Grand Prix 19", "n")
        # The mutable literal (a `Vector` the caller still holds) sits in a condition, so the column reads as one type
        # everywhere.
        names = ["Brazilian Grand Prix"]
        ok &= cte_line("Case over a list", M.Race.objects.values("circuitid", "v" => Case(When("name__@in" => names, then = 1), default = 0)),
                       CountRow, r -> string(r.name, " ", r.n), "Monaco Grand Prix 0, Brazilian Grand Prix 1", "n")
        return ok
    catch e
        failed("cte", e); return false
    end
end

# One CTE read: `body` as the CTE `st`, joined back on `circuitid`, its column `v` projected as `col` into `R`, ordered by
# date; the line `<label> <n> rows: <rows>`, and whether the rows are `expected`.
function cte_line(label::String, body, ::Type{R}, show_row::F, expected::String, col::String)::Bool where {R, F}
    q = M.Race.objects.filter("circuitid__country__@in" => ["Monaco", "Brazil"])
    q.with("st" => body, join_field = "circuitid" => "circuitid")
    return named_line("cte", label, q.values("name", col => "st__v").order_by("date").list(R), show_row, expected)
end

# One read's line, `<label> <n> rows: <rows>`, each row through `show_row`, and whether the rows are `expected`.
function named_line(step::String, label::String, rows::Vector{T}, show_row::F, expected::String)::Bool where {T,F}
    text = join([show_row(r) for r in rows], ", ")
    say(step, string(label, " ", length(rows), " rows: ", isempty(text) ? "none" : text))
    return text == expected
end

# ── The read shapes applications use most (#1599 layer 5): relation hops, the remaining lookups, `Q`/`Qor`, paging,
# aggregates, `Case` in an aggregate, `distinct()`, `ToChar` ordered by its alias and an INNER CTE join. Each is
# checked by its typed rows, over the rows every `prep.jl` seeds (two races, one pit stop, a chain of three
# constructors), before any write.

using PormG.Functions: Avg, Min, ToChar
using PormG: Q, Qor

const HopRow = NamedTuple{(:stop, :country), Tuple{Int64, String}}
const HomeRow = NamedTuple{(:name, :home), Tuple{String, Union{Nothing, String}}}
const RaceYearRow = NamedTuple{(:name, :yr), Tuple{String, Int64}}
const RaceNameRow = NamedTuple{(:name,), Tuple{String}}
const AggRow = NamedTuple{(:year, :c, :mx, :av, :mn),
                          Tuple{Int64, Int64, Union{Nothing, Int64}, Union{Nothing, Float64}, Union{Nothing, Int64}}}
const LateRow = NamedTuple{(:year, :late), Tuple{Int64, Union{Nothing, Int64}}}
const YearRow = NamedTuple{(:year,), Tuple{Int64}}
const MonthRow = NamedTuple{(:name, :ym), Tuple{String, Union{Nothing, String}}}
const CteCountRow = NamedTuple{(:name, :n), Tuple{String, Union{Nothing, Int64}}}

race_name(r)::String = r.name

# `values()` across relations (#1599 layer 5): two hops forward (a pit stop's race's circuit), three hops forward
# (a constructor's parent's parent's home circuit, through the self-referential key twice) and one reverse hop (a
# circuit's races). Exit code 37 when a read raises or returns other rows.
function hops_step()::Bool
    try
        ok = true
        ok &= named_line("hops", "2 hops", M.PitStop.objects.values("stop", "country" => "raceid__circuitid__country").list(HopRow),
                         r -> string("stop ", r.stop, " in ", r.country), "stop 1 in Monaco")
        ok &= named_line("hops", "3 hops",
                         M.Constructor.objects.filter("name" => "Renault").
                             values("name", "home" => "parentid__parentid__home_circuitid__country").list(HomeRow),
                         r -> string(r.name, " from ", something(r.home, "NULL")), "Renault from None")
        ok &= named_line("hops", "reverse",
                         M.Circuit.objects.filter("circuitref__@in" => ["monaco", "interlagos"]).
                             values("name", "yr" => "race__year").order_by("name").list(RaceYearRow),
                         r -> string(r.name, " ", r.yr), "Autódromo José Carlos Pace 2008, Circuit de Monaco 2008")
        return ok
    catch e
        failed("hops", e); return false
    end
end

# The lookups `lookup_step` leaves out that every engine has (#1599 layer 5): a year and month (`__@yyyy_mm`), not
# equal (`__@ne`), not in a list (`__@nin`), and `Qor` over a lookup and a nested `Q`. Exit code 38 when a read raises
# or returns other rows.
function lookup_more_step()::Bool
    try
        ok = true
        ok &= named_line("lookup_more", "date__@yyyy_mm",
                         M.Race.objects.filter("date__@yyyy_mm" => "2008-05").values("name").list(RaceNameRow), race_name,
                         "Monaco Grand Prix")
        ok &= named_line("lookup_more", "round__@ne",
                         M.Race.objects.filter("round__@ne" => 6).values("name").list(RaceNameRow), race_name,
                         "Brazilian Grand Prix")
        ok &= named_line("lookup_more", "round__@nin",
                         M.Race.objects.filter("round__@nin" => [6, 7]).values("name").list(RaceNameRow), race_name,
                         "Brazilian Grand Prix")
        ok &= named_line("lookup_more", "Qor(Q)",
                         M.Race.objects.filter(Qor("round__@lt" => 3, Q("name__@icontains" => "monaco", "year" => 2008))).
                             values("name").list(RaceNameRow), race_name, "Monaco Grand Prix")
        return ok
    catch e
        failed("lookup_more", e); return false
    end
end

# `Q`/`Qor` from 32 arguments on (#1599 layer 5, #1838 residue): a `Qor` of 40 literal arguments of mixed types, and a
# `Qor` built from a list the way an application builds one at run time, by `push!` over a `Vector{Pair{String,Int64}}`.
# `Qor(v...)` over a `Vector` is not one of them: a splat whose length is known only at run time is a call a trimmed
# image has no target for (`juliac --trim` refuses `_apply_iterate` into a function, whatever the vector's type), so
# the step uses the spelling that runs. Each is checked by its typed rows. Exit code 51 when a read raises or returns
# other rows.
function qor_many_step()::Bool
    try
        ok = true
        many = Qor("round" => 6, "name__@icontains" => "brazil", "year__@gte" => 2100.0, "date" => Date(1990, 1, 1),
                   "round" => 101, "round" => 102, "round" => 103, "round" => 104, "round" => 105, "round" => 106,
                   "round" => 107, "round" => 108, "round" => 109, "round" => 110, "round" => 111, "round" => 112,
                   "round" => 113, "round" => 114, "round" => 115, "round" => 116, "round" => 117, "round" => 118,
                   "round" => 119, "round" => 120, "round" => 121, "round" => 122, "round" => 123, "round" => 124,
                   "round" => 125, "round" => 126, "round" => 127, "round" => 128, "round" => 129, "round" => 130,
                   "round" => 131, "round" => 132, "round" => 133, "round" => 134, "round" => 135, Q("year" => 1950))
        ok &= named_line("qor_many", "Qor of 40 literal arguments",
                         M.Race.objects.filter(many).order_by("round").values("name").list(RaceNameRow), race_name,
                         "Monaco Grand Prix, Brazilian Grand Prix")
        rounds = Pair{String, Int64}[("round" => r) for r in vcat(6, 200:240)]
        built = Qor()
        for p in rounds
            push!(built, p)
        end
        ok &= named_line("qor_many", "Qor by push! over $(length(rounds)) pairs",
                         M.Race.objects.filter(built).values("name").list(RaceNameRow), race_name, "Monaco Grand Prix")
        return ok
    catch e
        failed("qor_many", e); return false
    end
end

# Paging (#1599 layer 5): `order_by("-date")` with `page(limit)`, with `page(limit, offset)`, and with `limit` and
# `offset`. Exit code 39 when a read raises or returns other rows.
function page_step()::Bool
    try
        ok = true
        ok &= named_line("page", "page(1)", M.Race.objects.order_by("-date").page(1).values("name").list(RaceNameRow),
                         race_name, "Brazilian Grand Prix")
        ok &= named_line("page", "page(1, 1)", M.Race.objects.order_by("-date").page(1, 1).values("name").list(RaceNameRow),
                         race_name, "Monaco Grand Prix")
        ok &= named_line("page", "limit offset",
                         M.Race.objects.order_by("-date").limit(1).offset(1).values("name").list(RaceNameRow), race_name,
                         "Monaco Grand Prix")
        return ok
    catch e
        failed("page", e); return false
    end
end

# Aggregates and the grouped shapes around them (#1599 layer 5): `Count(distinct = true)`, `Max`, `Avg` and `Min`
# grouped by year; `Sum(Case(When(...), default = ...))`; `distinct()`; `ToChar` ordered by its alias; and a CTE
# joined with `join_type = "INNER"`. Exit code 40 when a read raises or returns other rows.
function aggregate_step()::Bool
    try
        ok = true
        ok &= named_line("aggregate", "Count distinct/Max/Avg/Min",
                         M.Race.objects.values("year", "c" => Count("circuitid", distinct = true), "mx" => Max("round"),
                                               "av" => Avg("round"), "mn" => Min("round")).list(AggRow),
                         r -> string(r.year, " ", r.c, " ", something(r.mx, -1), " ", something(r.av, -1.0), " ",
                                     something(r.mn, -1)),
                         "2008 2 18 12.0 6")
        ok &= named_line("aggregate", "Sum(Case)",
                         M.Race.objects.values("year", "late" => Sum(Case(When("round__@gt" => 10, then = 1), default = 0))).
                             list(LateRow),
                         r -> string(r.year, " ", something(r.late, -1)), "2008 1")
        ok &= named_line("aggregate", "distinct", M.Race.objects.values("year").distinct().list(YearRow),
                         r -> string(r.year), "2008")
        ok &= named_line("aggregate", "ToChar -alias",
                         M.Race.objects.values("name", "ym" => ToChar("date", "YYYY-MM")).order_by("-ym").list(MonthRow),
                         r -> string(r.name, " ", something(r.ym, "NULL")),
                         "Brazilian Grand Prix 2008-11, Monaco Grand Prix 2008-05")
        late = M.Race.objects.filter("round__@gt" => 10).values("circuitid", "n" => Count("raceid"))
        q = M.Race.objects
        q.with("st" => late, join_field = "circuitid" => "circuitid", join_type = "INNER")
        ok &= named_line("aggregate", "CTE INNER", q.values("name", "n" => "st__n").list(CteCountRow),
                         r -> string(r.name, " ", something(r.n, -1)), "Brazilian Grand Prix 1")
        return ok
    catch e
        failed("aggregate", e); return false
    end
end

# `Extract("date", "EPOCH")` means a width-less decimal (#1121): the engines that compute it read it as a `Decimal`.
const EpochRow = NamedTuple{(:name, :ep), Tuple{String, Union{Nothing, PormG.Decimals.Decimal}}}

# The read shapes whose answer is each engine's own (#1599 layer 5): `__@regex`, `__@iregex` and
# `__@iunaccent_contains`, which only PostgreSQL has (`docs/src/backends.md`), and `Extract("date", "EPOCH")`. An engine
# without one refuses it with `BackendCapabilityError` before any SQL, and the line is the refusal's text; one that runs
# it prints its rows. A job checks these `engine_read` lines against its own JIT control (`same_lines.sh`). Exit code 41
# when a read raises anything else.
function engine_read_step()::Bool
    try
        engine_read_line("name__@regex",
                         () -> join(map(race_name, M.Race.objects.filter("name__@regex" => "^Monaco").values("name").list(RaceNameRow)), ", "))
        engine_read_line("name__@iregex",
                         () -> join(map(race_name, M.Race.objects.filter("name__@iregex" => "^brazil").values("name").list(RaceNameRow)), ", "))
        engine_read_line("name__@iunaccent_contains",
                         () -> join(map(race_name, M.Circuit.objects.filter("name__@iunaccent_contains" => "autodromo").values("name").list(RaceNameRow)), ", ");
                         needs_function = true)
        engine_read_line("Extract EPOCH",
                         () -> join([string(r.name, " ", r.ep === nothing ? "NULL" : string(r.ep::PormG.Decimals.Decimal)) for r in
                                     M.Race.objects.values("name", "ep" => Extract("date", "EPOCH")).order_by("date").list(EpochRow)], ", "))
        return true
    catch e
        failed("engine_read", e); return false
    end
end

# A telemetry row's key, the typed row of `lookup_refusals_step`.
const TelemetryIdRow = NamedTuple{(:telemetryid,), Tuple{Int64}}

# The JSON and network lookups (#1599, #1838 decision 2), which only PostgreSQL has: one read per lookup over
# `CarTelemetry`. PostgreSQL runs each, and the line is the rows it matches; SQLite and MySQL refuse each before any
# SQL through the renderer's barrier, and the line is the refusal's type and text. A job checks these `lookup_refusal`
# lines against its own JIT control (`same_lines.sh`). Exit code 50 when a read raises anything else.
# The array lookups are `array_lookup_step`'s (#1844).
function lookup_refusals_step()::Bool
    try
        q() = M.CarTelemetry.objects
        lookup_refusal_line("payload__@jcontains", () -> q().filter("payload__@jcontains" => Dict("drs" => true)).values("telemetryid").list(TelemetryIdRow))
        lookup_refusal_line("payload__@has_key", () -> q().filter("payload__@has_key" => "tyre").values("telemetryid").list(TelemetryIdRow))
        lookup_refusal_line("payload__@has_any_keys", () -> q().filter("payload__@has_any_keys" => ["ers", "tyre"]).values("telemetryid").list(TelemetryIdRow))
        lookup_refusal_line("payload__@has_keys", () -> q().filter("payload__@has_keys" => ["drs", "tyre"]).values("telemetryid").list(TelemetryIdRow))
        lookup_refusal_line("pit_ip__@net_contained", () -> q().filter("pit_ip__@net_contained" => "10.0.0.0/8").values("telemetryid").list(TelemetryIdRow))
        lookup_refusal_line("pit_ip__@net_contained_or_equal", () -> q().filter("pit_ip__@net_contained_or_equal" => "10.0.0.0/8").values("telemetryid").list(TelemetryIdRow))
        lookup_refusal_line("pit_ip__@net_contains", () -> q().filter("pit_ip__@net_contains" => "10.0.0.7").values("telemetryid").list(TelemetryIdRow))
        lookup_refusal_line("pit_ip__@net_contains_or_equals", () -> q().filter("pit_ip__@net_contains_or_equals" => "10.0.0.7").values("telemetryid").list(TelemetryIdRow))
        lookup_refusal_line("pit_ip__@net_overlaps", () -> q().filter("pit_ip__@net_overlaps" => "10.0.0.0/24").values("telemetryid").list(TelemetryIdRow))
        lookup_refusal_line("pit_ip__@family", () -> q().filter("pit_ip__@family" => 4).values("telemetryid").list(TelemetryIdRow))
        lookup_refusal_line("pit_ip__@prefixlen", () -> q().filter("pit_ip__@prefixlen" => 32).values("telemetryid").list(TelemetryIdRow))
        return true
    catch e
        failed("lookup_refusal", e); return false
    end
end

# The array lookups (#1844): `__@acontains`, `__@contained_by` and `__@overlap` over `CarTelemetry.pit_laps`, an
# `ArrayField(IntegerField())`, which only PostgreSQL has. Their list goes through the column's `ArrayFormatter`, each
# element through the base field's formatter. PostgreSQL runs each, and the line is the rows it matches over the one seeded
# row (`pit_laps = [12, 31]`); SQLite and MySQL refuse each before any SQL, and the line is the refusal's type and text. A
# job checks these `array_lookup` lines against its own JIT control (`same_lines.sh`). Exit code 53 when a read raises
# anything else.
function array_lookup_step()::Bool
    try
        q() = M.CarTelemetry.objects
        lookup_refusal_line("pit_laps__@acontains", () -> q().filter("pit_laps__@acontains" => [12]).values("telemetryid").list(TelemetryIdRow);
                            step = "array_lookup")
        lookup_refusal_line("pit_laps__@contained_by", () -> q().filter("pit_laps__@contained_by" => [12, 31, 40]).values("telemetryid").list(TelemetryIdRow);
                            step = "array_lookup")
        lookup_refusal_line("pit_laps__@overlap", () -> q().filter("pit_laps__@overlap" => [31, 99]).values("telemetryid").list(TelemetryIdRow);
                            step = "array_lookup")
        lookup_refusal_line("pit_laps__@acontains none", () -> q().filter("pit_laps__@acontains" => [99]).values("telemetryid").list(TelemetryIdRow);
                            step = "array_lookup")
        return true
    catch e
        failed("array_lookup", e); return false
    end
end

# Filter values PormG refuses before any SQL, each located by `_locate_filter_refusal` (#1844): a field formatter's refusal
# on a plain field and on a date field, and a `@year` bucket's bound on a date field (the sargable rewrite's site). The line is the refusal's type and text, located with
# the field and its type label; a trimmed image that cannot build the location raises a `MethodError` in place of
# the `InvalidValueError` the JIT raises. The same on every engine; a job checks these `filter_refusal` lines against its
# own JIT control (`same_lines.sh`). Exit code 52 when a read is not refused with an `InvalidValueError`.
function filter_refusal_step()::Bool
    ok = filter_refusal_line("year", () -> M.Race.objects.filter("year" => "abc").values("name").list(RaceNameRow))
    ok &= filter_refusal_line("date", () -> M.Race.objects.filter("date" => "not a date").values("name").list(RaceNameRow))
    ok &= filter_refusal_line("date__@year", () -> M.Race.objects.filter("date__@year" => "abc").values("name").list(RaceNameRow))
    return ok
end

# One `filter_refusal` line: `<label>: InvalidValueError: <message>`. A read that is not refused, or is refused with anything
# else, prints `failed`'s lines and the step fails.
function filter_refusal_line(label::String, read::F)::Bool where {F <: Function}
    try
        read()
        say("filter_refusal", string(label, ": not refused")); return false
    catch e
        e isa PormG.InvalidValueError || (failed("filter_refusal", e); return false)
        say("filter_refusal", string(label, ": InvalidValueError: ", (e::PormG.InvalidValueError).msg))
        return true
    end
end

# One `lookup_refusal` line (or `step`'s): `<label>: <n> rows`, or `<label>: BackendCapabilityError: <message>` when the
# engine refuses it. Anything else propagates to the step.
function lookup_refusal_line(label::String, read::F; step::String = "lookup_refusal")::Nothing where {F <: Function}
    text = try
        string(length(read()::Vector{TelemetryIdRow}), " rows")
    catch e
        e isa PormG.BackendCapabilityError || rethrow()
        string("BackendCapabilityError: ", (e::PormG.BackendCapabilityError).msg)
    end
    say(step, string(label, ": ", text))
    return nothing
end

# One `engine_read` line: `<label>: <rows>`, or `<label> refused: <message>` when the engine refuses it with
# `BackendCapabilityError`. With `needs_function`, a server that lacks the SQL function the lookup calls (SQLSTATE 42883,
# PostgreSQL's `unaccent` when the extension is not installed in the database) is recorded as such rather than failing:
# `migrate` installs the extension when `connection.yml` names it, and the fixture's `prep.jl` does not. Anything else
# propagates to the step.
function engine_read_line(label::String, read::F; needs_function::Bool = false)::Nothing where {F <: Function}
    text = try
        string(": ", read()::String)
    catch e
        if e isa PormG.BackendCapabilityError
            string(" refused: ", (e::PormG.BackendCapabilityError).msg)
        elseif needs_function && e isa PormG.StatementError && (e::PormG.StatementError).sqlstate == "42883"
            " not run: the database has no unaccent function (SQLSTATE 42883)"
        else
            rethrow()
        end
    end
    say("engine_read", string(label, text))
    return nothing
end

# `.copy()` (#1684, #1599 layer 4): a handler filtered and ordered, copied, the copy changed (a filter, an `order_by`, a
# `values` projection) and both read, checked by typed rows; then the original changed and the copy read again. The
# original reads the two seeded races in date order, the copy the one past round 10, and neither sees the other's
# calls. `.copy()` walked the query through `deepcopy`'s generic walk before #1684. Exit code 54 when a read raises or a
# handler returns other rows.
const CopyRow = NamedTuple{(:name, :round), Tuple{String, Int64}}
function copy_step()::Bool
    try
        q = M.Race.objects.filter("year" => 2008)
        q.order_by("date")
        c = q.copy()
        c.filter("round__@gt" => 10)
        c.order_by("-round")
        c.values("name", "round")
        branch = c.list(CopyRow)
        orig = q.list(RaceRow)
        say("copy", string("original: ", race_names(orig)))
        say("copy", string("copy: ", join([string(r.name, " (", r.round, ")") for r in branch], ", ")))
        q.filter("round__@lt" => 10)
        again = c.list(CopyRow)
        after = q.list(RaceRow)
        say("copy", string("original after its filter: ", race_names(after), "; copy: ",
                           join([r.name for r in again], ", ")))
        # A handler that already projects, copied: the projection's nodes are copied at their types too.
        p = M.Race.objects.filter("year" => 2008).values("name", "round").order_by("date")
        pc = p.copy()
        pc.filter("round__@lt" => 10)
        pr, pcr = p.list(CopyRow), pc.list(CopyRow)
        say("copy", string("projected original: ", join([r.name for r in pr], ", "), "; copy: ",
                           join([r.name for r in pcr], ", ")))
        return race_names(orig) == "Monaco Grand Prix, Brazilian Grand Prix" &&
               length(branch) == 1 && branch[1] == (name = "Brazilian Grand Prix", round = 18) &&
               race_names(after) == "Monaco Grand Prix" && again == branch &&
               [r.name for r in pr] == ["Monaco Grand Prix", "Brazilian Grand Prix"] &&
               [r.name for r in pcr] == ["Monaco Grand Prix"]
    catch e
        failed("copy", e); return false
    end
end
