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
