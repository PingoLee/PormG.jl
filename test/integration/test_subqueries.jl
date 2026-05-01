# julia -t auto  --project=. test/integration/test_subqueries.jl

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end


# ─────────────────────────────────────────────────────────────────────────────
# Subqueries
# A sub-SELECT used as the right-hand side of a field__@in filter.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Subqueries test" begin
    subquery = M.Status.objects
    subquery.filter("status" => "Engine")
    subquery.values("statusid")

    # The subquery narrows results to only "Engine"-status results
    query = M.Result.objects
    query.filter("statusid__@in" => subquery)
    query.values("resultid", "statusid", "statusid__status", "grid", "driverid")
    df = query |> DataFrame
    @test query.count() == 2026

    # A second filter added after the subquery is already attached
    query.filter("driverid__@lte" => 7)
    @test query.count() == 40

    # Deep joins and aggregated date expressions coexist with the subquery
    query.values("resultid", "statusid", "statusid__status", "grid", "driverid", "raceid__date__@quarter")
    query.order_by("raceid__date__quarter")
    text = query |> inspect_query
    df = query |> DataFrame
    @test query.count() == 40
    @test query.exists()
end

# ─────────────────────────────────────────────────────────────────────────────
# Subqueries: missing projection should fail before database execution
# A field__@in subquery must project exactly one key. Forgetting .values(...)
# used to leak a raw SQL backend error; now it should raise a clear fix-oriented
# ArgumentError at the PormG boundary.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Subqueries require a single projected field for IN filters" begin
    subquery = M.Status.objects
    subquery.filter("status" => "Engine")

    query = M.Result.objects
    query.filter("statusid__@in" => subquery)

    err = try
        query |> DataFrame
        nothing
    catch e
        e
    end

    @test err isa ArgumentError

    message = sprint(showerror, err)
    @test occursin("'statusid__@in' requires a subquery that returns exactly one column", message)
    @test occursin("selects all columns from 'status' because .values(...) was not called", message)
    @test occursin("call .values(\"field_name\") on the subquery", message)
end

# ─────────────────────────────────────────────────────────────────────────────
# Subqueries: a single SQL-function projection is still a valid IN subquery
# The validator should accept a one-column aggregate subquery and let the query
# execute end to end instead of crashing while inspecting the projection type.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Subqueries accept single SQL-function projections" begin
    max_id_subquery = M.Result.objects
    max_id_subquery.values("max_resultid" => Max("resultid"))

    expected_max = maximum((M.Result.objects.values("resultid") |> DataFrame).resultid)

    query = M.Result.objects
    query.filter("resultid__@in" => max_id_subquery)
    rows = query.values("resultid").list()

    @test length(rows) == 1
    @test rows[1][:resultid] == expected_max
end
