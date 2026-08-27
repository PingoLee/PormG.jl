# julia -t auto --project=. test/integration/test_cache_join.jl

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end


@testset "Testing _cache_join in CTE context" begin
    # This test verifies that if we use a join path (with '__') as a join_field in a CTE,
    # the ORM correctly triggers _cache_join to build the necessary intermediate joins.

    # 1. Define a CTE source. 
    # Let's say we want to join Results with a CTE that has some driver statistics,
    # but we want to join using the driver's surname instead of the ID.
    cte_source = M.Driver.objects.values(
        "surname",
        "nationality",
        "driver_count" => Count("driverid") # Just to make it an aggregate query
    )

    # 2. Main Query on Result
    query = M.Result.objects

    # 3. Inject the CTE using a join path in the main table key
    # "driverid__surname" refers to the 'surname' field in the table joined via 'driverid'
    # Initially, 'driverid__surname' is NOT in the cache of the main query.
    # The WITH call will trigger the join building.
    PormG.QueryBuilder._with(query.object, "driver_stats", cte_source, 
         join_field="driverid__surname" => "surname",
         join_type="INNER")

    # 4. Filter and Select
    query.filter("raceid__year" => 2021)
    query.values(
        "raceid__name",
        "driverid__surname",
        CTE("driver_stats", "nationality")
    )

    # # Show query for debugging if needed
    # insp = query |> inspect_query
    # @info insp[:sql_text]

    df = query |> DataFrame

    # 5. Assertions
    @test size(df, 1) > 0
    @test "driver_stats__nationality" in names(df)
    @test "driverid__surname" in names(df)
    
    # Verify a specific row if possible. 
    # Max Verstappen won in 2021.
    verstappen_rows = df[df.driverid__surname .== "Verstappen", :]
    @test !isempty(verstappen_rows)
    @test all(verstappen_rows.driver_stats__nationality .== "Dutch")

    @info "Successfully tested _cache_join with complex CTE join key"
end

@testset "Testing _cache_join with multiple levels" begin
    # Test an even deeper join path in the CTE join_field
    # Result -> Race -> Circuit -> Name
    
    cte_circuit = M.Circuit.objects.values("name", "country")
    
    query = M.Result.objects
    # Join Result to Case stats via circuit name
    # raceid__circuitid__name
    PormG.QueryBuilder._with(query.object, "circuit_info", cte_circuit,
         join_field="raceid__circuitid__name" => "name")
    
    query.filter("raceid__year" => 2021)
    query.values(
        "raceid__name",
        CTE("circuit_info", "country")
    )
    
    df = query |> DataFrame
    @test size(df, 1) > 0
    @test "circuit_info__country" in names(df)
    
    # Monza 2021
    monza_rows = df[df.raceid__name .== "Italian Grand Prix", :]
    @test !isempty(monza_rows)
    @test all(monza_rows.circuit_info__country .== "Italy")
end
