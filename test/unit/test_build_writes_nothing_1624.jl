# =============================================================================
# The build writes nothing into the handler it renders, so a read needs no deep copy (#1624, #1625)
#
# `query()` used to write its parameters and projection kinds back into the handler, the CTE body
# builds wrote each CTE's model and column records into the handler's `ctes` dict, and the CTE path
# resolver rewrote the handler's own `SQLField`s in place. Every read deep-copied the caller's handler
# for that reason (#43, #199), and a membership subquery (`__@in`), which is not copied, was written
# into (#1625). Since #1624 the build keeps all of it on its instruction (`_render_select`,
# `CTEState`, a resolved view of the query), a terminal copies only the containers it changes itself
# (`_terminal_copy`), and `list()` / `show_query` copy nothing.
#
# Hermetic: an in-memory SQLite database with an inline model module. No live database.
# =============================================================================
# julia --project=test/integration test/unit/test_build_writes_nothing_1624.jl

using Test
using PormG
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Dialect, Models
import PormG.ConnectionPool: fetch, SQLiteConnectionPool
import PormG.QueryBuilder: Count

const _BW_QB = PormG.QueryBuilder
const _BW_KEY = normpath(joinpath(@__DIR__, "pormg1624_writes_nothing"))
const _BW_POOL = SQLiteConnectionPool(":memory:"; pool_size = 1)
PormG.config[_BW_KEY] = Configuration.Settings(
    connections = _BW_POOL, change_data = true, db_def_folder = _BW_KEY)

PormG.@models_module WritesNothing1624 "pormg1624_writes_nothing" begin
    Constructor = Models.Model("bw1624_constructor",
        constructorid = Models.IDField(),
        name          = Models.CharField(max_length = 40),
        updated       = Models.DateTimeField(auto_now = true, null = true))
    Driver = Models.Model("bw1624_driver",
        driverid      = Models.IDField(),
        surname       = Models.CharField(max_length = 40),
        constructorid = Models.ForeignKey(Constructor, on_delete = "CASCADE"))
end
import .WritesNothing1624 as BW

fetch(_BW_POOL, Dialect.create_table(_BW_POOL, BW.Constructor))
fetch(_BW_POOL, Dialect.create_table(_BW_POOL, BW.Driver))
BW.Constructor.objects.create("constructorid" => 1, "name" => "McLaren")
BW.Constructor.objects.create("constructorid" => 2, "name" => "Williams")
BW.Driver.objects.create("driverid" => 1, "surname" => "Senna", "constructorid" => 1)
BW.Driver.objects.create("driverid" => 2, "surname" => "Prost", "constructorid" => 1)
BW.Driver.objects.create("driverid" => 3, "surname" => "Mansell", "constructorid" => 2)

struct BwDriverRow
    driverid::Int64
    surname::String
end

# A query declaring the CTE `agg` (drivers per constructor), filtered, projected and ordered by its
# column through `"agg__total"` string paths — the paths the build resolves into `CTEReference`s.
function _bw_cte_query(; projected::Bool = true)
    agg = BW.Driver.objects.values("constructorid", "total" => Count("driverid"))
    q = BW.Constructor.objects
    q.with("agg" => agg, join_field = "constructorid" => "constructorid")
    q.filter("agg__total" => 2)
    projected && q.values("constructorid", "name", "t" => "agg__total")
    projected && q.order_by("agg__total")
    return q
end

# What a build could write into the caller's handler: every `SQLField` in its projection, filters and
# ordering (the object, its `.field`, its `.root`), its parameters, its kinds, and its CTE dicts' keys.
function _bw_snapshot(q)
    fields = Any[]
    for v in q.object.values
        v isa _BW_QB.SQLField && push!(fields, (v, v.field, v.root))
    end
    for f in q.object.filter
        f isa _BW_QB.OperObject && f.column isa _BW_QB.SQLField && push!(fields, (f.column, f.column.field, f.column.root))
    end
    for o in q.object.order
        o.field isa _BW_QB.SQLField && push!(fields, (o.field, o.field.field, o.field.root))
    end
    return (fields = fields,
            parameters = q.object.parameters,
            kinds = copy(q.object.projection_kinds),
            cte_keys = Dict(n => sort(collect(keys(d))) for (n, d) in q.object.ctes),
            filters = _BW_QB._filters_repr(q))
end
function _bw_unchanged(before, q)
    after = _bw_snapshot(q)
    length(after.fields) == length(before.fields) || return false
    for ((obj_b, field_b, root_b), (obj_a, field_a, root_a)) in zip(before.fields, after.fields)
        (obj_a === obj_b && field_a === field_b && obj_a.field === field_b && obj_a.root === root_b) || return false
    end
    return after.parameters === before.parameters && after.kinds == before.kinds &&
           after.cte_keys == before.cte_keys && after.filters == before.filters
end

# ─────────────────────────────────────────────────────────────────────────────
# #1625: a membership subquery's handler is never written into
# `filter("driverid__@in" => sub)` keeps `sub` by reference, and its render used to call `query(sub)`,
# which wrote the outer build's parameter collector and the projection kinds into the caller's `sub`
# (and, for a `sub` declaring a CTE, the CTE's model and records into its `ctes` dict, and the resolved
# `CTEReference` into its filter). Expected: after the outer query renders and executes, `sub` holds
# exactly what it held: `parameters === nothing`, no kinds, the same CTE keys, a filter naming
# `agg__total`. The rows are the ones the subquery means.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1625: a membership subquery's handler is never written into" begin
    sub = BW.Constructor.objects.filter("name" => "McLaren").values("constructorid")
    before = _bw_snapshot(sub)
    outer = BW.Driver.objects.filter("constructorid__@in" => sub).values("driverid").order_by("driverid")
    outer.list(show_query = :sql)
    @test _bw_unchanged(before, sub)
    @test sub.object.parameters === nothing
    @test isempty(sub.object.projection_kinds)
    @test [r[:driverid] for r in outer.list()] == [1, 2]
    @test _bw_unchanged(before, sub)

    # A `sub` that declares a CTE and filters on its column through a `"agg__total"` path.
    cte_sub = _bw_cte_query(projected = false)
    cte_sub.values("constructorid")
    cte_before = _bw_snapshot(cte_sub)
    @test cte_before.filters == "agg__total = 2"
    cte_outer = BW.Driver.objects.filter("constructorid__@in" => cte_sub).values("driverid").order_by("driverid")
    cte_outer.list(show_query = :sql)
    @test [r[:driverid] for r in cte_outer.list()] == [1, 2]
    @test _bw_unchanged(cte_before, cte_sub)
    @test cte_sub.object.ctes["agg"] |> keys |> collect |> sort == cte_before.cte_keys["agg"]
    @test _BW_QB._filters_repr(cte_sub) == "agg__total = 2"
end

# ─────────────────────────────────────────────────────────────────────────────
# A direct build, and every read terminal, leaves the caller's handler exactly as it was (CTE query)
# The build resolves `"agg__total"` into a `CTEReference` in its own view of the query (`SQLField`
# wrappers on the way rebuilt), so the caller's `SQLField`s are the same objects with the same `.field`
# and `.root` afterwards — a check no test made before #1624, because the read paths deep-copied first.
# Also: no parameters, no kinds, no CTE keys added. `aggregate()` refuses a projected queryset, so it
# runs on the unprojected form.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1624: a build and every terminal leave the caller's handler unchanged (CTE query)" begin
    row_t = NamedTuple{(:constructorid, :name, :t), Tuple{Int64, String, Int64}}
    calls = (
        ("query()",     q -> _BW_QB.query(q; show_query = :sql)),
        ("show_query",  q -> _BW_QB.show_query(q)),
        ("inspect",     q -> _BW_QB.inspect_query(q)),
        ("list()",      q -> q.list()),
        ("list(:dict)", q -> q.list(:dict)),
        ("list(T)",     q -> q.list(row_t)),
        ("get()",       q -> q.get()),
        ("get(T)",      q -> q.get(row_t)),
        ("first()",     q -> q.first()),
        ("last()",      q -> q.last()),
        ("earliest()",  q -> q.earliest("name")),
        ("count()",     q -> q.count()),
        ("count(col)",  q -> q.count("constructorid")),
        ("exists()",    q -> q.exists()),
        ("aggregate()", q -> q.aggregate("n" => Count("constructorid"))),
        ("DataFrame",   q -> _BW_QB.Tables.columns(q)),
    )
    for (name, call) in calls
        q = _bw_cte_query(projected = name != "aggregate()")
        before = _bw_snapshot(q)
        call(q)
        ok = _bw_unchanged(before, q)
        ok || @info "#1624 caller handler changed" terminal = name
        @test ok
    end
    # And the reads mean what they say: McLaren is the one constructor with two drivers.
    @test _bw_cte_query().get().name == "McLaren"
    @test _bw_cte_query().get(row_t) == (constructorid = 1, name = "McLaren", t = 2)
    @test _bw_cte_query().count() == 1
end

# ─────────────────────────────────────────────────────────────────────────────
# inspect_query's insert/update dry runs still leave the caller's `insert` unchanged
# A SELECT inspection builds on the caller's handler itself (the build writes nothing); the
# insert/update dry runs fill defaults and `auto_now` values into the `insert` they are handed, so they
# keep a copy. Expected: `q.object.insert` holds exactly its two keys afterwards.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1624: inspect_query's insert/update dry runs leave insert unchanged" begin
    q_up = BW.Constructor.objects.filter("constructorid" => 1)
    q_up.object.insert = _BW_QB.OrderedCollections.OrderedDict{String,Any}("name" => "Brabham")
    res = _BW_QB.inspect_query(q_up)
    @test res[:operation] === :update
    @test collect(keys(q_up.object.insert)) == ["name"]

    q_in = BW.Constructor.objects
    q_in.object.insert = _BW_QB.OrderedCollections.OrderedDict{String,Any}("constructorid" => 9, "name" => "Brabham")
    res = _BW_QB.inspect_query(q_in)
    @test res[:operation] === :insert
    @test collect(keys(q_in.object.insert)) == ["constructorid", "name"]
end

# ─────────────────────────────────────────────────────────────────────────────
# No read makes a deep copy of the caller's handler
# Each read against the same work done with no copy at all (`_render_select`, `_list_owned`,
# `_list_raw` on a handler already carrying what the terminal adds), as relative allocation counts so
# they hold across Julia versions: a terminal may cost less than three quarters of one `deepcopy` of
# the handler over that. Its own shallow copy (`_terminal_copy`: a struct and two vectors), limit,
# ordering and result shaping stay well under it; a deep copy put back costs a whole one.
# ─────────────────────────────────────────────────────────────────────────────
function _bw_allocs(f::F) where {F}
    f(); f()
    return minimum(Base.gc_alloc_count(@timed(f()).gcstats) for _ in 1:3)
end
function _bw_no_deep_copy(name, terminal::F, baseline::G, q) where {F,G}
    copy_allocs = _bw_allocs(() -> deepcopy(q))
    extra = _bw_allocs(terminal) - _bw_allocs(baseline)
    ok = extra < 3 * copy_allocs / 4
    ok || @info "#1624 deep copy margin" terminal = name extra copy = copy_allocs
    return ok
end

# A read with no copy, composed from the build's parts: render, fetch, parse.
function _bw_manual_read(h, fmt)
    settings, conn, _ = _BW_QB.get_settings(h)
    r = _BW_QB._render_select(h; connection = conn, show_query = :execute)
    result = fetch(settings, r.sql, r.instruction.parameters)
    parsers = _BW_QB._projection_parsers(r.instruction, conn)
    fmt isa Type && return _BW_QB._typed_rows(fmt, result, parsers, _BW_QB._TypedReadSite("bw", h.object.model.name))
    rows = _BW_QB._rows_from_result(result, parsers)
    return fmt === :row ? [_BW_QB.PormGRow(x, h.object.model) for x in rows] : rows
end

@testset "#1624: no read makes a deep copy of the caller's handler" begin
    q = BW.Driver.objects.filter("constructorid" => 1)
    pk1 = BW.Driver.objects.filter("driverid" => 1)
    prepared(base, prep) = (h = deepcopy(base); prep(h); h)
    render(h) = () -> _BW_QB._render_select(h; show_query = :sql)
    show_cases = (
        ("show_query",  () -> _BW_QB.show_query(q),                  render(q)),
        ("list(:sql)",  () -> q.list(show_query = :sql),             render(q)),
        ("first()",     () -> q.first(show_query = :sql),            render(prepared(q, h -> h.limit(1)))),
        ("last()",      () -> q.last(show_query = :sql),             render(prepared(q, h -> (h.order_by("-driverid"); h.limit(1))))),
        ("get()",       () -> q.get(show_query = :sql),              render(prepared(q, h -> h.limit(2)))),
        ("get(T)",      () -> q.get(BwDriverRow; show_query = :sql), render(prepared(q, h -> (h.values("driverid", "surname"); h.limit(2))))),
        ("earliest()",  () -> q.earliest("surname"; show_query = :sql), render(prepared(q, h -> (h.order_by("surname"); h.limit(1))))),
        ("list(T)",     () -> q.list(BwDriverRow; show_query = :sql), render(prepared(q, h -> h.values("driverid", "surname")))),
    )
    for (name, terminal, baseline) in show_cases
        @test _bw_no_deep_copy(name, terminal, baseline, q)
    end
    # The baseline is the read composed by hand — render, fetch, parse — so it shares none of the code
    # under test: a copy put back anywhere in `list`/`_execute_select`/a terminal costs only that side.
    manual(h, fmt) = () -> _bw_manual_read(h, fmt)
    execute_cases = (
        ("list()",      () -> q.list(),                       manual(q, :row), q),
        ("list(:dict)", () -> q.list(:dict),                  manual(q, :dict), q),
        ("get()",       () -> pk1.get(),                      manual(prepared(pk1, h -> h.limit(2)), :row), pk1),
        ("get(T)",      () -> pk1.get(BwDriverRow),
                        manual(prepared(pk1, h -> (h.values("driverid", "surname"); h.limit(2))), BwDriverRow), pk1),
        ("first()",     () -> q.first(),                      manual(prepared(q, h -> h.limit(1)), :row), q),
        ("count(col)",  () -> q.count("driverid"),
                        manual(prepared(q, h -> h.values("pormg_count" => Count("driverid"))), :dict), q),
        ("aggregate()", () -> q.aggregate("n" => Count("driverid")),
                        manual(prepared(q, h -> h.values("n" => Count("driverid"))), :dict), q),
    )
    for (name, terminal, baseline, handler) in execute_cases
        @test _bw_no_deep_copy(name, terminal, baseline, handler)
    end
    @test pk1.get(BwDriverRow) == BwDriverRow(1, "Senna")
    @test q.count("driverid") == 2
end

# ─────────────────────────────────────────────────────────────────────────────
# `.copy()` is still a deep copy: diverging the copy leaves the original intact
# `.copy()` is the user's own branch point and keeps `Base.deepcopy` (#43): a filter added to the copy
# changes the copy's SQL and not the original's, and the CTE dicts are distinct objects.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1624: .copy() still deep-copies" begin
    q = _bw_cte_query()
    sql_before = q.list(show_query = :sql)
    q2 = q.copy()
    q2.filter("name" => "Williams")
    @test q2.list(show_query = :sql) != sql_before
    @test q.list(show_query = :sql) == sql_before
    @test q2.object.ctes["agg"] !== q.object.ctes["agg"]
    @test q2.object.values[1] !== q.object.values[1]
end

# ─────────────────────────────────────────────────────────────────────────────
# A CTE body that takes a row lock is still refused outside a transaction (#26, #1237)
# `.with("agg" => body)` where `body` is `select_for_update()`: the WITH clause renders the body's
# `FOR UPDATE`, which under autocommit locks nothing. The body used to be rendered through `query()`,
# whose default mode runs that refusal; since #1624 `build_cte_clause` renders it with `_render_select`
# and runs the refusal itself. Expected: `list()`, `count()` and `show_query` all raise
# `QueryBuildError` naming `select_for_update()`, exactly as before #1624.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1624: a CTE body that takes a row lock is refused outside a transaction" begin
    function locked_cte_query()
        body = BW.Driver.objects.values("constructorid", "total" => Count("driverid")).select_for_update()
        q = BW.Constructor.objects
        q.with("agg" => body, join_field = "constructorid" => "constructorid")
        q.values("constructorid", "name", "t" => "agg__total")
        return q
    end
    for (name, call) in (("list()", q -> q.list()), ("count()", q -> q.count()), ("show_query", q -> _BW_QB.show_query(q)))
        err = try
            call(locked_cte_query())
            nothing
        catch e
            e
        end
        @test err isa PormG.QueryBuildError
        @test err !== nothing && occursin("select_for_update() must run inside a transaction", sprint(showerror, err))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# The build runs on the caller's query itself: no copy before it
# For a query with no CTE (nothing to resolve), the build's instruction holds the very `SQLObjectQuery`
# the caller holds — a copy put back in `query`, `_render_select`, `build` (before its instruction)
# or `_execute_select` breaks that identity. Those sit on both sides of the allocation margins above,
# which therefore cannot see a copy there; a copy in a wrapper above them (`show_query`, `_show_select`,
# the public `list`) lands on the terminal side only, which those margins do catch. With a CTE, the
# instruction holds the resolved view, a new object.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1624: the build runs on the caller's query itself" begin
    q = BW.Driver.objects.filter("constructorid" => 1).values("driverid", "surname")
    seen = Ref{Any}(nothing)
    _BW_QB.query(q; show_query = :sql, built = instr -> (seen[] = instr.object))
    @test seen[] === q.object
    @test _BW_QB._render_select(q; show_query = :sql).instruction.object === q.object
    @test _BW_QB._execute_select(q)[2].object === q.object
    cte = _bw_cte_query()
    @test _BW_QB._render_select(cte; show_query = :sql).instruction.object !== cte.object
end
