# julia -t auto --project=test/integration test/integration/test_explain.jl
# PORMG_DB=db_sl julia -t 1 --project=test/integration test/integration/test_explain.jl

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

import PormG.ConnectionPool: fetch
import PormG.QueryBuilder: OuterRef, Subquery
import PormG.Functions: Count

const EXPLAIN_IS_PG = PormG.config[PORMG_DB_FOLDER].connections isa PormG.PormGPostgres

# ─────────────────────────────────────────────────────────────────────────────
# explain(): the plan the database really chooses (#48)
# A primary-key lookup is planned through the key's index, and an unfiltered read of a table is a
# sequential scan — on PostgreSQL by relation name, on SQLite by the query's alias. These are the
# plans both engines choose for the F1 fixture, so the facts are asserted, not just their types.
# ─────────────────────────────────────────────────────────────────────────────
@testset "explain: index lookup vs sequential scan" begin
    # Ayrton Senna's driver row, by primary key.
    by_pk = M.Driver.objects.filter("driverid" => 102).explain()
    @test by_pk[:operation] === :select
    @test by_pk[:analyze] === false
    # PostgreSQL names the primary-key index; SQLite reports the rowid lookup.
    @test by_pk[:indexes_used] == (EXPLAIN_IS_PG ? ["driver_pkey"] : ["INTEGER PRIMARY KEY"])
    @test isempty(by_pk[:seq_scans])

    # Every result row: nothing to search by, so the table is scanned.
    everything = M.Result.objects.explain()
    @test everything[:seq_scans] == (EXPLAIN_IS_PG ? ["result"] : ["Tb"])
    @test isempty(everything[:indexes_used])

    if EXPLAIN_IS_PG
        # Estimates come from the root plan node: a cost and a row estimate near the table's size.
        @test everything[:total_cost] isa Float64 && everything[:total_cost] > 0
        @test everything[:estimated_rows] > 1000
    else
        @test everything[:total_cost] === nothing && everything[:estimated_rows] === nothing
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# explain(): bound parameters and a join
# The query's own parameters are bound to the EXPLAIN statement ($1 / ?), never spliced into it,
# and a joined filter is explained like any other SELECT. Senna's results are found through the
# result table's driverid index on both engines.
# ─────────────────────────────────────────────────────────────────────────────
@testset "explain: bound parameter through a join" begin
    q = M.Result.objects.filter("driverid__surname" => "Senna").values("raceid", "points")
    n_before = length(q.list())   # Ayrton and Bruno Senna's results together
    plan = q.explain()
    @test plan[:parameters] == ["Senna"]
    @test !occursin("Senna", plan[:explain_sql])
    @test any(name -> occursin("driverid", name), plan[:indexes_used])
    # Explaining did not touch the handler: the same query still runs and returns the same rows.
    @test n_before > 0
    @test length(q.list()) == n_before
end

# ─────────────────────────────────────────────────────────────────────────────
# explain(analyze = true): measured timing on PostgreSQL, refused on SQLite
# ANALYZE executes the query, so PostgreSQL reports planning and execution time. SQLite has no
# EXPLAIN ANALYZE, and the option is a BackendCapabilityError rather than a silently ignored flag.
# ─────────────────────────────────────────────────────────────────────────────
@testset "explain: analyze" begin
    q = M.Result.objects.filter("raceid__year" => 1991).values("points")
    if EXPLAIN_IS_PG
        timed = q.explain(analyze = true, buffers = true)
        @test timed[:analyze] === true
        @test timed[:execution_time_ms] isa Float64 && timed[:execution_time_ms] >= 0
        @test timed[:planning_time_ms] isa Float64
        # Measured row counts appear in the plan itself once ANALYZE ran.
        @test haskey(timed[:plan]["Plan"], "Actual Rows")
    else
        @test_throws PormG.BackendCapabilityError q.explain(analyze = true)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# explain() inside a transaction
# explain() fetches through the pool like any read, so inside run_in_transaction it uses the
# transaction's connection. On PostgreSQL a select_for_update() query can be EXPLAIN ANALYZEd there,
# which outside a transaction it refuses (the unit suite pins the refusal).
# ─────────────────────────────────────────────────────────────────────────────
@testset "explain: inside run_in_transaction" begin
    plan = PormG.run_in_transaction(PORMG_DB_FOLDER) do
        q = M.Driver.objects.filter("driverid" => 102).values("surname")
        EXPLAIN_IS_PG ? q.select_for_update().explain(analyze = true) : q.explain()
    end
    @test plan[:indexes_used] == (EXPLAIN_IS_PG ? ["driver_pkey"] : ["INTEGER PRIMARY KEY"])
end

# ─────────────────────────────────────────────────────────────────────────────
# show_query = :pretty executes exactly like :sql
# The formatter changes only whitespace between tokens, so the pretty text — run with the same
# bound parameters — returns the same rows as the compact text. Checked on a statement with a join,
# a grouped aggregate, a correlated subquery and LIMIT, which together exercise every layout rule.
# This is the one place raw SQL runs here: executing the rendered text IS the feature under test.
# ─────────────────────────────────────────────────────────────────────────────
@testset "show_query = :pretty: same rows as the compact SQL" begin
    wins = M.Result.objects.filter("raceid" => OuterRef("raceid"), "positionorder" => 1).
        values("n" => Count("resultid"))
    q = M.Race.objects.filter("year__@gte" => 1988, "circuitid__country" => "Brazil").
        values("name", "year", "winners" => Subquery(wins)).
        order_by("year").
        limit(10)
    settings = PormG.config[PORMG_DB_FOLDER]
    # Build the statement twice, each with its own parameter object, so neither fetch reuses the
    # other's bound state.
    built() = (h = deepcopy(q); sql = PormG.QueryBuilder.query(h, show_query = :execute); (sql, h.object.parameters))
    compact_sql, compact_params = built()
    _, pretty_params = built()
    pretty_sql = show_query(q, :pretty)
    @test pretty_sql != compact_sql && occursin('\n', pretty_sql)
    compact_rows = fetch(settings, compact_sql, compact_params) |> DataFrame
    pretty_rows = fetch(settings, pretty_sql, pretty_params) |> DataFrame
    @test nrow(compact_rows) > 0
    @test isequal(pretty_rows, compact_rows)
end
