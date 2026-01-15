if !isdefined(Main, :PormG)
    include("common_setup.jl")
end


@testset "Testing cjoin with simple join" begin
  delete(M.New_join_position |> object, allow_delete_all = true, show_query = false)
  query = M.New_join_position |> object;
  query.create("result" => 1, "description" => "teste 1")
  query.create("result" => 2, "description" => "teste 2")
  query.create("result" => 3, "description" => "teste 3")

  query = M.New_join_position |> object;
  cjoin(query, "result" => "Result");
  query.values("result__statusid__status", "description", "result");

  df = query |> DataFrame

  @test size(df, 1) == 3
  @test unique(df.result__statusid__status) == ["Finished"]
  
end

@testset "Testing cjoin with custom filter" begin
  query = M.New_join_position |> object;
  cjoin(query, "result" => "Result", filters=[
      "description" => "teste 1"]);

  # @info query |> show_query
  df = query |> DataFrame

  # cjoin not is applied because none filter none matches use the join informed
  @test size(df, 1) == 3
  @test df |> names |> length == 3


  query = M.New_join_position |> object;
  cjoin(query, "result" => "Result", filters=[
      "description" => "teste 1"]);

  query.values("result__statusid__status", "description", "result")

  # @info query |> show_query
  df = query |> DataFrame

  @test size(df, 1) == 3
  @test "result__statusid__status" in  df |> names 
  @test df[df.description .== "teste 1", :result__statusid__status][1] == "Finished"
  @test df[df.description .== "teste 2", :result__statusid__status][1] === missing

  query = M.New_join_position |> object;
  cjoin(query, "result" => "Result", filters=[
      "description" => "teste 1"],
      join_type="INNER");

  query.values("result__statusid__status", "description", "result");

  # @info query |> show_query
  df = query |> DataFrame

  @test size(df, 1) == 1
  @test df[1, :description] == "teste 1"
  @test df[1, :result__statusid__status] == "Finished"

end




@testset "Test subquerys" begin
    subquery = M.Status |> object;
    subquery.filter("status" => "Engine");
    subquery.values("statusid");
    

    # Subquery 
    query = M.Result |> object;
    query.filter("statusid__@in" => subquery);
    query.values("resultid", "statusid", "statusid__status", "grid", "driverid");
    df = query |> DataFrame
    @test query |> do_count == 2026

    # added parameter in main query
    query.filter("driverid__@lte" => 7);
    # df = query |> DataFrame
    @test query |> do_count == 40

    # added parameters in select
    query.values("resultid", "statusid", "statusid__status", "grid", "driverid", "raceid__date__@quarter");
    query.order_by("raceid__date__quarter");
    df = query |> DataFrame
    @test query |> do_count == 40
    @test query |> do_exists
end




@testset "Reverse Joins" begin
  query = M.Constructor |> object;
  query.values("result__resultid");
  query.filter("result__resultid" => 1);
  # @info query |> show_query
  df = query |> DataFrame
  @test size(df, 1) == 1
  @test df[1, :result__resultid] == 1

  # get values to compare
  query_a = M.Just_a_test_deletion |> object;
  query_a.values("id", "name", "test_result", "test_result2");
  df_a = query_a |> DataFrame

  # Test reverse join with model with id and multiple fields in reverse model
  query = M.Result |> object;
  query.values("test_deletion__id", "test_deletion__name", "resultid");
  query.filter("test_deletion__id__@isnull" => false);
  df = query |> DataFrame
  query |> show_query
  @test size(df, 1) == size(df_a, 1)
  @test all(in.(df.test_deletion__id, Ref(df_a.id)))
  @test all(in.(df.test_deletion__name, Ref(df_a.name)))
end

@testset "CTE with JOIN functionality" begin
    
    @testset "Basic CTE with JOIN" begin
        # Example similar to the one you provided
        # Find duplicates using CTE and join with main table
        
        # Create a CTE that finds duplicate evaluations
        duplicates = M.Result |> object;
        duplicates.filter("statusid" => 1);
        duplicates.values("driverid", "dias" => Count("resultid"));
        
        # Main query that joins with the CTE
        main_query = M.Result |> object;
        With(main_query.object, "tb_dup", duplicates, join_field="driverid" => "driverid");
        
        # Now we can filter and select using CTE fields
        main_query.filter("resultid__@lte" => 100);
        main_query.values("resultid", "driverid", "tb_dup__dias");
        
        df = main_query |> DataFrame        
        @test nrow(df) == 100
        @test filter(row -> row.resultid == 1, df)[1, :tb_dup__dias] == 312
        @test filter(row -> row.resultid == 1, df) |> nrow == 1
        @test filter(row -> row.resultid == 100, df)[1, :driverid] == 5
    end
    
    @testset "CTE with aggregation and multiple fields" begin
        # Create CTE with multiple aggregated fields
        stats = M.Result |> object;
        stats.filter("raceid__@lte" => 100);
        stats.values(
            "driverid",
            "total_results" => Count("resultid"),
            "avg_grid" => Sum("grid")
        );
        
        # Main query
        query = M.Driver |> object;
        With(query.object, "driver_stats", stats, join_field="driverid" => "driverid");
        
        query.filter("driverid__@lte" => 50);
        query.values(
            "driverid",
            "forename",
            "surname",
            "driver_stats__total_results",
            "driver_stats__avg_grid"
        );
        
        df = query |> DataFrame

        @test nrow(df) == 50
        @test nrow(filter(row -> row.driver_stats__total_results |> !ismissing, df)) == 48
        @test filter(row -> row.driverid == 22, df)[1, :driver_stats__total_results] == 100
        @test filter(row -> row.driverid == 22, df)[1, :driver_stats__avg_grid] == 986
        @test nrow(filter(row -> row.driverid == 22, df)) == 1
        
    end
    
    @testset "Multiple CTEs" begin
        # First CTE: Recent races
        recent_races = M.Race |> object;
        recent_races.filter("year__@gte" => 2020);
        recent_races.values("raceid", "name", "year");
        
        # Second CTE: Top drivers
        top_drivers = M.Driver |> object;
        top_drivers.filter("driverid__@lte" => 100);
        top_drivers.values("driverid", "forename", "surname");
        
        # Main query using both CTEs
        query = M.Result |> object;
        With(query.object, "recent", recent_races, join_field="raceid" => "raceid");
        With(query.object, "top_d", top_drivers, join_field="driverid" => "driverid");

        query.values(
            "resultid",
            "recent__name",
            "top_d__forename",
            "points"
        );
        query.filter("recent__name__@isnull" => false, "top_d__forename__@isnull" => false);
        
        df = query |> DataFrame

        @test nrow(df) == 294
        @test nrow(filter(row -> row.top_d__forename == "Lewis", df)) == 106
        @test nrow(filter(row -> row.recent__name == "Australian Grand Prix", df)) == 7
      
    end        
    
    @testset "CTE with join_type in JOIN" begin
        # Create CTE
        high_scorers = M.Result |> object;
        high_scorers.filter("points__@gte" => 10);
        high_scorers.values("driverid", "max_points" => Sum("points"));
        
        # Main query with F expression referencing CTE
        query = M.Driver |> object;
        With(query.object, "high_scorers", high_scorers, join_field="driverid" => "driverid", join_type="INNER");        
        query.values("driverid", "forename", "max_points" => "high_scorers__max_points");
        query.filter("driverid__@lte" => 100);
        
        df = query |> DataFrame

        @test nrow(df) == 29
        @test nrow(filter(row -> row.driverid == 1, df)) == 1
        @test filter(row -> row.driverid == 22, df)[1, :max_points] == 132
        
    end
    
end


# As vezes existem joins antes da chave tipo co_cid__pront__cad_id não esta em Prod_atend_ind
# query_cad = biM.Bas_cad_ind.objects.filter("saida_id"=>3, "st_fora_area"=>false, "st_defi_auditiva" => 1, "ibge_id"=>172100);

# query_df = query_cad |> deepcopy;

# query_df.count()

# query_at = biM.Prod_atend_ind.objects;
# With(query_at.object, "tb_quant", query_cad.values("id", "nu_cnes_id", "quant_cad" => Sum("id")), 
# join_field="co_cid__pront__cad_id" => "id");

# query_at.filter(
#     "ibge_id"=>172100,
#     "dt_inicio__@gte"=>"2025-01-01",
#     "dt_inicio__@lte"=>"2025-12-31",
#     "co_cid__pront__cad_id__@in"=>query_df.values("id")
# );

# query_at.values("lotacao__nu_cnes__no_cnes_a", 
#     "n_atend" => Count("id"),
#     "tb_quant__quant_cad"
# );

# df_at = query_at |> DataFrame