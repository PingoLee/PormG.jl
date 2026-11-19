# julia -t auto --project=test/integration test/integration/test_untyped_read_equivalence_1599.jl
# PORMG_DB=db_sl julia -t 1 --project=test/integration test/integration/test_untyped_read_equivalence_1599.jl

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# #1599 layer 6 — the untyped read (`list()`, `list(:dict)`, `first()`, a `values(...)` projection) decodes its rows
# where the driver's result is concrete (`_ProjectionRowDecoder`): on SQLite's worker, and through the MySQL and
# Postgres.jl extensions' walks. Before, the rows were built after `fetch` returned, by `_rows_from_result` over the
# result typed `Any`, which a `juliac --trim` image has no code for.
#
# The rows must be exactly what they were: the same keys in the same iteration order, the same values and the same
# Julia type for every cell, on every engine and driver. `_rows_from_result` and `_projection_parsers` are unchanged,
# so the oracle here is the old read itself: the statement's raw result (`_execute_select`) handed to them, against
# the new `_list_raw`. The queries cover a whole model wider than a `Dict`'s initial table (key order), NULL cells,
# joined columns, aggregates, a decimal, durations and times, an expression and an empty result.

const _UR_QB = PormG.QueryBuilder

# The old read: the raw result, then the rows `_rows_from_result` built from it.
function _ur_old_rows(q)
    result, built, connection = _UR_QB._execute_select(q)
    return _UR_QB._rows_from_result(result, _UR_QB._projection_parsers(built, connection))
end

# Every difference between two row sets: the row count, a row's keys in iteration order, a cell's type or value.
function _ur_differences(old::Vector{Dict{Symbol,Any}}, new::Vector{Dict{Symbol,Any}})::Vector{String}
    diffs = String[]
    length(old) == length(new) || push!(diffs, "rows: $(length(old)) vs $(length(new))")
    for (i, (a, b)) in enumerate(zip(old, new))
        collect(keys(a)) == collect(keys(b)) || push!(diffs, "row $i keys: $(collect(keys(a))) vs $(collect(keys(b)))")
        for k in keys(a)
            haskey(b, k) || continue
            typeof(a[k]) === typeof(b[k]) || push!(diffs, "row $i $k type: $(typeof(a[k])) vs $(typeof(b[k]))")
            isequal(a[k], b[k]) || push!(diffs, "row $i $k value: $(repr(a[k])) vs $(repr(b[k]))")
        end
    end
    return diffs
end

# Each query, built fresh for every read (a read never writes into its handler, #1624, but fresh is the plain form).
const _UR_QUERIES = [
    ("a whole model: more columns than a Dict's first table holds, with dates, times, a timestamp and NULLs",
     () -> M.Race.objects.filter("year" => 2008).order_by("round"), true),
    ("NULL integer and text cells",
     () -> M.Driver.objects.filter("nationality" => "Brazilian").order_by("surname", "driverid"), true),
    ("joined columns",
     () -> M.Result.objects.filter("raceid__year" => 2008).
         values("resultid", "driverid__surname", "raceid__date", "points", "laps").order_by("resultid").limit(60), true),
    ("aggregates: a sum, an average and a count per group",
     () -> M.Result.objects.filter("raceid__year" => 2008).
         values("driverid__surname", "total" => Sum("points"), "avg_laps" => Avg("laps"), "n" => Count("resultid")).
         order_by("driverid__surname"), true),
    ("a decimal column",
     () -> M.Constructor_results.objects.values("constructorresultsid", "points").order_by("constructorresultsid").limit(40), true),
    ("a duration column",
     () -> M.Lap_times.objects.values("raceid", "driverid", "lap", "time", "milliseconds").
         order_by("raceid", "driverid", "lap").limit(40), true),
    ("a time and a duration column",
     () -> M.Pit_stops.objects.values("raceid", "driverid", "stop", "time", "duration").
         order_by("raceid", "driverid", "stop").limit(40), true),
    ("nullable durations",
     () -> M.Qualifying.objects.values("qualifyingid", "q1", "q2", "q3").order_by("qualifyingid").limit(40), true),
    ("an expression",
     () -> M.Race.objects.filter("year" => 2008).values("raceid", "month" => Extract("date", "month")).order_by("raceid"), true),
    ("an empty result",
     () -> M.Race.objects.filter("year" => 1800), false),
]

@testset "The untyped read decodes the rows it read before (#1599 layer 6)" begin
    # Expected SQL: each query's own SELECT, run twice (once for the oracle, once through `_list_raw`). Why: a
    # trimmed image can read the untyped rows only once they are decoded at the driver's concrete result type, and
    # the decode must not change a key, its order, a value or a type on any engine.
    for (label, make, nonempty) in _UR_QUERIES
        @testset "$label" begin
            old = _ur_old_rows(make())
            new = _UR_QB._list_raw(make())
            @test isempty(old) != nonempty
            @test _ur_differences(old, new) == String[]
        end
    end
end

@testset "The untyped terminals return the old rows (#1599 layer 6)" begin
    # Expected SQL: `SELECT … FROM race … WHERE year = 2008 ORDER BY round` (and `LIMIT 1` for `first()`). Why: the
    # public terminals hand out the decoded rows, `list(:dict)` as they are and `list()`/`first()` inside a `PormGRow`.
    old = _ur_old_rows(M.Race.objects.filter("year" => 2008).order_by("round"))
    @test _ur_differences(old, M.Race.objects.filter("year" => 2008).order_by("round").list(:dict)) == String[]
    rows = M.Race.objects.filter("year" => 2008).order_by("round").list()
    @test _ur_differences(old, Dict{Symbol,Any}[getfield(r, :_data) for r in rows]) == String[]
    one = M.Race.objects.filter("year" => 2008).order_by("round").first()
    @test _ur_differences(old[1:1], Dict{Symbol,Any}[getfield(one, :_data)]) == String[]
end

@testset "get_or_create's reads decode the row _row_to_field_keyed_dict built (#1599 layer 6)" begin
    # Expected SQL: `SELECT * FROM race WHERE raceid = ? LIMIT 1` (the lookup's locking read, without `FOR SHARE`) and
    # the read-back's `SELECT <declared columns> …`, each run twice. Why: `get_or_create` read these rows through
    # `Tables.rowtable` and `_row_to_field_keyed_dict`, which a trimmed image has no code for; the decoder must give
    # the same row: the same keys in the same iteration order (sized as the old `Dict` was), values and types.
    rid = first(M.Race.objects.filter("year" => 2008).order_by("round").values("raceid").list(:dict))[:raceid]
    _UR_QB._with_connection(M.Race.objects) do settings, connection, _
        real_obj = _UR_QB.SQLObjectQuery(model = M.Race)
        real_obj.insert["raceid"] = rid
        table = _UR_QB.safe_table_identifier(PormG.Models.model_table_name(M.Race), connection)
        for head in (_UR_QB._FOUND_ROW_HEAD, "SELECT $(_UR_QB._returned_columns(M.Race, connection, table))")
            sql, params = _UR_QB._select_by_target(head, real_obj, M.Race, ["raceid"], table, connection)
            old = _UR_QB._row_to_field_keyed_dict(first(_UR_QB.Tables.rowtable(_UR_QB.fetch(settings, sql, params))),
                                                  M.Race, connection)
            sql2, params2 = _UR_QB._select_by_target(head, real_obj, M.Race, ["raceid"], table, connection)
            new = _UR_QB._read_back_rows(settings, sql2, params2, _UR_QB._FieldRowDecoder(M.Race, connection; sized = true))
            @test length(new) == 1
            @test _ur_differences([old], new) == String[]
        end
    end
end
