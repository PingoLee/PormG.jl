# =============================================================================
# A read terminal copies the caller's handler once, not once per layer (#1589)
#
# The copy exists so a terminal never writes into the caller's handler (#43, #199): `get()`
# applies its inline filters and `limit(2)`, `last()` flips the ordering, and the build writes its
# parameters and CTE state back into the handler it runs on. Before #1589 every layer below the
# terminal copied again: `get()` copied the handler twice, `get(T)` three times, though every copy
# after the first was a private copy nothing else held. `deepcopy(handler)` is ~27 µs of a ~200 µs
# primary-key read on Postgres.jl (#41 phase 1), so the redundant copies were the largest single
# item in the build.
#
# The tests below are RELATIVE, so they hold across Julia versions: each terminal against the same
# work done with one copy, with the margin set to one `deepcopy` of the same handler. Before #1589 every
# one of them was one or two whole copies over.
#
# Hermetic: an in-memory SQLite database with an inline model module. No live database.
# =============================================================================
# julia --project=test/integration test/unit/test_read_path_one_copy_1589.jl

using Test
using PormG
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Dialect, Models, DoesNotExist
import PormG.ConnectionPool: fetch, SQLiteConnectionPool
import PormG.QueryBuilder: Count

const _OC_KEY = normpath(joinpath(@__DIR__, "pormg1589_one_copy"))
const _OC_POOL = SQLiteConnectionPool(":memory:"; pool_size = 1)
PormG.config[_OC_KEY] = Configuration.Settings(
    connections = _OC_POOL, change_data = true, db_def_folder = _OC_KEY)

PormG.@models_module OneCopy1589 "pormg1589_one_copy" begin
    Constructor = Models.Model("oc1589_constructor",
        constructorid = Models.IDField(),
        name          = Models.CharField(max_length = 40))
    Driver = Models.Model("oc1589_driver",
        driverid      = Models.IDField(),
        surname       = Models.CharField(max_length = 40),
        constructorid = Models.ForeignKey(Constructor, on_delete = "CASCADE"))
end
import .OneCopy1589 as OC

fetch(_OC_POOL, Dialect.create_table(_OC_POOL, OC.Constructor))
fetch(_OC_POOL, Dialect.create_table(_OC_POOL, OC.Driver))
OC.Constructor.objects.create("constructorid" => 1, "name" => "McLaren")
OC.Constructor.objects.create("constructorid" => 2, "name" => "Williams")
OC.Driver.objects.create("driverid" => 1, "surname" => "Senna", "constructorid" => 1)
OC.Driver.objects.create("driverid" => 2, "surname" => "Prost", "constructorid" => 1)
OC.Driver.objects.create("driverid" => 3, "surname" => "Mansell", "constructorid" => 2)

struct OcDriverRow
    driverid::Int64
    surname::String
end

# The fewest allocations of three warm calls: a count, not a time, so it repeats.
function _oc_allocs(f::F) where {F}
    f(); f()
    return minimum(Base.gc_alloc_count(@timed(f()).gcstats) for _ in 1:3)
end

# Assert `terminal` costs what `one_copy` costs plus less than one copy of `q`. Before #1589 the extra
# was at least one whole copy (86 allocations for these handlers, two for `get(T)`); since, it is the
# terminal's own fixed work (its limit, ordering, projection, message text, result shaping): 1–53
# allocations when measured (#1599 round 10, Julia 1.13.3: `aggregate()` 53, `count(col)` 41). The margin
# is a copy of the handler rather than a heavier handler, because a heavier handler grows the terminal
# side too (`_get` renders every filter into its message text, `last` inverts every order term).
#
# One whole copy, not the three quarters it was: #1599 round 10 typed `deepcopy(::OperObject)`, so a copy
# of these handlers fell from 73 allocations to 70 while `aggregate()`'s extra stayed 53, which put the
# three-quarter margin (52.5) below a terminal that had not changed. A second copy per layer, the defect
# #1589 removed, costs at least one copy, so this margin still catches it.
function _oc_one_copy(terminal::F, one_copy::G, q) where {F,G}
    copy_allocs = _oc_allocs(() -> deepcopy(q))
    extra = _oc_allocs(terminal) - _oc_allocs(one_copy)
    return (; extra, copy_allocs, ok = extra < copy_allocs)
end

_oc_query() = OC.Driver.objects.filter("constructorid" => 1)

# ─────────────────────────────────────────────────────────────────────────────
# One copy per terminal, inspection arm: first / last / get / get(T) / earliest / list(T)
# Each terminal's `show_query = :sql` arm, against `show_query` (one copy) of a handler that already
# carries what the terminal adds (its limit, its ordering, its typed projection), so both render the
# same SQL. Before #1589 the terminal arm copied the handler once more in `query_list` (and once more
# in `_typed_query` for a typed read), and the extra was a whole copy or two.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1589: a terminal's show_query arm copies the handler once" begin
    q = _oc_query()
    prepped(f) = (h = deepcopy(q); f(h); h)
    cases = (
        ("first()",    () -> q.first(show_query = :sql),
                       prepped(h -> h.limit(1))),
        ("last()",     () -> q.last(show_query = :sql),
                       prepped(h -> (h.order_by("-driverid"); h.limit(1)))),
        ("get()",      () -> q.get(show_query = :sql),
                       prepped(h -> h.limit(2))),
        ("get(T)",     () -> q.get(OcDriverRow; show_query = :sql),
                       prepped(h -> (h.values("driverid", "surname"); h.limit(2)))),
        ("earliest()", () -> q.earliest("surname"; show_query = :sql),
                       prepped(h -> (h.order_by("surname"); h.limit(1)))),
        ("list(T)",    () -> q.list(OcDriverRow; show_query = :sql),
                       prepped(h -> h.values("driverid", "surname"))),
    )
    for (name, terminal, prepared) in cases
        @test terminal() == PormG.QueryBuilder.show_query(prepared, :sql)   # the same SQL, so the same render
        r = _oc_one_copy(terminal, () -> PormG.QueryBuilder.show_query(prepared, :sql), q)
        r.ok || @info "#1589 copy margin" terminal = name extra = r.extra copy = r.copy_allocs
        @test r.ok
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# One copy per terminal, execute arm: get / get(T) / first / count("col") / aggregate against list
# Each terminal executed against `list` (which copies once) of a handler already carrying what the
# terminal adds, on the same rows. Before #1589 `get()`/`first()`/`count("col")`/`aggregate()`
# copied once in the terminal and again in `_execute_select`, and `get(T)` once more in
# `_typed_query`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1589: an executing terminal copies the handler once" begin
    q = _oc_query()
    pk1 = OC.Driver.objects.filter("driverid" => 1)
    # A copy of `base` carrying what the terminal adds, and the `list` read of it (which copies once).
    listing(base, prep, fmt) = (h = deepcopy(base); prep(h); () -> PormG.QueryBuilder.list(h, fmt))
    cases = (
        ("get()",       () -> pk1.get(),            listing(pk1, h -> h.limit(2), :row), pk1),
        ("get(T)",      () -> pk1.get(OcDriverRow), listing(pk1, h -> h.limit(2), OcDriverRow), pk1),
        ("first()",     () -> q.first(),            listing(q, h -> h.limit(1), :row), q),
        ("count(col)",  () -> q.count("driverid"),
                        listing(q, h -> h.values("pormg_count" => Count("driverid")), :dict), q),
        ("aggregate()", () -> q.aggregate("n" => Count("driverid")),
                        listing(q, h -> h.values("n" => Count("driverid")), :dict), q),
    )
    for (name, terminal, one_copy, handler) in cases
        r = _oc_one_copy(terminal, one_copy, handler)
        r.ok || @info "#1589 copy margin" terminal = name extra = r.extra copy = r.copy_allocs
        @test r.ok
    end
    # The results are the ones the one-copy reads give: the hand-off changed the copying, not the rows.
    @test pk1.get().driverid == 1
    @test pk1.get(OcDriverRow) == OcDriverRow(1, "Senna")
    @test q.count("driverid") == 2
    @test q.aggregate("n" => Count("driverid")) == (n = 2,)
end

# ─────────────────────────────────────────────────────────────────────────────
# DoesNotExist names a CTE-path filter as the caller wrote it, not as the build resolved it
# `get()` / `get(T)` / `earliest()` on a query filtered by `"agg__total"` (a column of a `.with()`
# CTE), with no matching row. The build rewrites that filter's column into a `CTEReference` in the
# handler it runs on; since #1589 that is the terminal's own copy, so the message is rendered before
# the build. Expected text: `agg__total = 99`, as before #1589.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1589: DoesNotExist names a CTE-path filter as written" begin
    function cte_query()
        agg = OC.Driver.objects.values("constructorid", "total" => Count("driverid"))
        q = OC.Constructor.objects
        q.with("agg" => agg, join_field = "constructorid" => "constructorid")
        q.filter("agg__total" => 99)
        q.values("constructorid", "name")
        return q
    end
    struct_row = NamedTuple{(:constructorid, :name), Tuple{Int64, String}}
    for (name, call, expected) in (
            ("get()",      q -> q.get(),               "No record found matching filters: agg__total = 99"),
            ("get(T)",     q -> q.get(struct_row),      "No record found matching filters: agg__total = 99"),
            ("get(inline)", q -> q.get("name" => "X"),  "No record found matching filters: agg__total = 99, name = X"),
            ("earliest()", q -> q.earliest("name"),     "No record found matching filters: earliest: agg__total = 99"))
        err = try
            call(cte_query())
            nothing
        catch e
            e
        end
        @test err isa DoesNotExist
        msg = sprint(showerror, err)
        occursin(expected, msg) || @info "#1589 DoesNotExist text" terminal = name msg
        @test occursin(expected, msg)
        @test !occursin("CTEReference", msg)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# The one copy still keeps the caller's handler clean, on a CTE-path query, for every terminal
# Each terminal runs on a `.with("agg" => …)` query filtered by `"agg__total" => 2` (McLaren, two
# drivers), then the CALLER's handler is checked: its filter still names `agg__total` (the build
# rewrites it into a `CTEReference` only in the copy), no `parameters` were written into it, and its
# CTE entry has no `"model"`. Before #1589 the second copy in `_execute_select` absorbed these writes;
# now the terminal's own copy is the only thing between the build and the caller (#43, #199).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1589: the caller's handler stays clean after every terminal on a CTE query" begin
    # `aggregate()` refuses a projected queryset, so it runs on the unprojected form.
    function cte_query(; projected::Bool = true)
        agg = OC.Driver.objects.values("constructorid", "total" => Count("driverid"))
        q = OC.Constructor.objects
        q.with("agg" => agg, join_field = "constructorid" => "constructorid")
        q.filter("agg__total" => 2)
        projected && q.values("constructorid", "name")
        return q
    end
    row_t = NamedTuple{(:constructorid, :name), Tuple{Int64, String}}
    terminals = (
        ("get()",       q -> q.get()),
        ("get(T)",      q -> q.get(row_t)),
        ("first()",     q -> q.first()),
        ("first(T)",    q -> q.first(row_t)),
        ("last()",      q -> q.last()),
        ("earliest()",  q -> q.earliest("name")),
        ("latest(T)",   q -> q.latest(row_t, "name")),
        ("list()",      q -> q.list()),
        ("list(T)",     q -> q.list(row_t)),
        ("count(col)",  q -> q.count("constructorid")),
        ("aggregate()", q -> q.aggregate("n" => Count("constructorid"))),
    )
    for (name, call) in terminals
        q = cte_query(projected = name != "aggregate()")
        call(q)
        clean = PormG.QueryBuilder._filters_repr(q) == "agg__total = 2" &&
                q.object.parameters === nothing &&
                !haskey(q.object.ctes["agg"], "model")
        clean || @info "#1589 caller handler changed" terminal = name filters = PormG.QueryBuilder._filters_repr(q)
        @test clean
    end
    # And the reads return what the query means: McLaren is the one constructor with two drivers.
    @test cte_query().get().name == "McLaren"
    @test cte_query().get(row_t) == (constructorid = 1, name = "McLaren")
    @test cte_query().count("constructorid") == 1
    @test cte_query(projected = false).aggregate("n" => Count("constructorid")) == (n = 1,)
end
