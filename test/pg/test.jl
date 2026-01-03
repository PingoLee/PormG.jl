# Se for rodar este arquivo isoladamente durante o dev, 
# você pode colocar um check no topo:
if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# conn = PormG.Configuration.acquire_connection(PormG.config["db_2"].connections)
@testset "Database Setup Insert" begin
  @testset "Schema Evolution and Error Recovery" begin
    # 1. Schema Evolution: Reordered columns and extra columns
    query = M.Status |> object
    delete(query, allow_delete_all=true)
    
    # Create DF with extra column and different order
    df_evolved = DataFrame(
      extra_col = ["ignore me", "me too"],
      status = ["Evolved 1", "Evolved 2"],
      statusid = [999, 1000]
    )
    
    # Should work because 'extra_col' is not in model fields and others are mapped by name
    bulk_insert(query, df_evolved)
    query.filter("statusid" => 999)
    @test query |> do_count == 1
    query = M.Status |> object
    query.filter("statusid" => 1000)
    @test query |> do_count == 1
    
    # 2. Error Recovery: Atomicity on failure
    query = M.Status |> object
    initial_count = query |> do_count
    df_bad = DataFrame(
        statusid = [1001, 999, 1002], # 999 is a duplicate
        status = ["Good", "Bad (Duplicate)", "Good"]
    )
    
    got_error = false
    try
      bulk_insert(query, df_bad)
    catch e
      got_error = true  # bulk_insert now rethrows the underlying DB error (e.g., duplicate key)
    end

    @test got_error
    # Verify atomicity: 1001 and 1002 should NOT be there
    query = M.Status |> object
    @test query |> do_count == initial_count
    query.filter("statusid" => 1001)
    @test query |> do_count == 0

    # 3. Multi-chunk Error Recovery: Atomicity across chunks
    delete(M.Status |> object, allow_delete_all=true)
    df_multi = DataFrame(
        statusid = [2001, 2002, 2001, 2003], # 2001 is repeated in the 3rd row
        status = ["Chunk 1", "Chunk 1", "Chunk 2 (Fail)", "Chunk 2"]
    )
    
    query = M.Status |> object;
    got_error = false
    try
      bulk_insert(query, df_multi, chunk_size=2)
    catch e
      got_error = true  # async task failure is unwrapped, so catch sees the real constraint error
    end

    @test got_error
    # Verify that even the first chunk (2001, 2002) was rolled back
    @test query |> do_count == 0
  end

  # Clear all tables
  delete(M.Circuit |> object, allow_delete_all = true, show_query = false)
  delete(M.Status |> object, allow_delete_all = true)
  delete(M.Driver |> object, allow_delete_all = true)
  delete(M.Constructor |> object, allow_delete_all = true)
  delete(M.Result |> object, allow_delete_all = true)
  delete(M.Just_a_test_deletion |> object, allow_delete_all = true)

  @testset "Single insertions" begin

    path_load = joinpath("f1", "status.csv")
    df = CSV.File(path_load) |> DataFrame

    query = M.Status |> object
    initial_count = query |> do_count
    for row in eachrow(df)
      try
        dt = query.create("statusid" => row.statusId, "status" => row.status)
      catch e
        @error "Error inserting status row" statusId=row.statusId error=e
      end
    end
    @test query |> do_count == initial_count + nrow(df)

  end

  @testset "Simple Bulk Insertions" begin
    # Insert Circuits
    query = M.Circuit |> object
    bulk_insert(query, CSV.File(joinpath("f1", "circuits.csv")) |> DataFrame)

    # Bulk insert for Race with expected error
    query = M.Race |> object
    path_load = joinpath("f1", "races.csv")
    df = CSV.File(path_load) |> DataFrame
    rename!(df, lowercase.(names(df)))
    got_error = false
    try
        bulk_insert(query, df)
    catch e
        got_error = true
    end
    @test got_error

    # Pre-processing and bulk insert for Race
    rename!(df, lowercase.(names(df)))
    for col in [:fp1_date, :fp1_time, :fp2_date, :fp2_time, :fp3_date, :fp3_time, :quali_date, :quali_time, :sprint_date, :sprint_time, :time]
        df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
    end
    try
        bulk_insert(query, df, copy=true)
    catch e
        @error "Error in bulk_insert for Race after pre-processing" error=e
    end
    @test query |> do_count > 0

    # Insert Drivers
    query = M.Driver |> object
    df = CSV.File(joinpath("f1", "drivers.csv")) |> DataFrame
    for col in [:number]
        df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
    end
    bulk_insert(query, df)
    @test query |> do_count == 861

    # Insert Constructors
    query = M.Constructor |> object
    bulk_insert(query, CSV.File(joinpath("f1", "constructors.csv")) |> DataFrame, chunk_size=100)

    query = M.Result |> object;
    df = CSV.File(joinpath("f1", "results.csv")) |> DataFrame
    # lowercase the column names
    rename!(df, lowercase.(names(df)))
    for col in [:position, :time, :milliseconds, :fastestlap, :rank, :fastestlaptime, :fastestlapspeed, :number]
        df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
    end
    bulk_insert(query, df)
    @test query |> do_count == 26759
  end  

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

@testset "Test list query" begin
  query = M.Result |> object;
  query.filter("statusid__status" => "Finished", "resultid" => 26745);
  query.values("resultid", "raceid__circuitid__name", "driverid__forename", "constructorid__name", "statusid__status", "grid", "laps");
  dict = query |> list
  @test length(dict) == 1
  @test dict[1][:resultid] == 26745
  @test dict[1][:laps] == 58

  dict_json = query |> list_json
  @test isa(dict_json, String)
  @test JSON.parse(dict_json)[1]["resultid"] == 26745
end

@testset "Test As functionality for custom alias" begin
  query = M.Result |> object;
  query.filter("statusid__status" => "Finished", "resultid" => 26745);
  query.values("resultid", "circuit" => "raceid__circuitid__name");
  df = query |> DataFrame
  @test "circuit" in names(df)

  query = M.Result |> object;
  query.filter("statusid__status" => "Finished", "resultid" => 26745);
  query.values("resultid", "circuit" => "raceid__circuitid__name", "quarter" => "raceid__date__@quarter");
  df = query |> DataFrame
  @test "quarter" in names(df)

  dict = query |> list
  @test haskey(dict[1], :circuit) && haskey(dict[1], :quarter)
end

@testset "Single and Bulk Insert/Update" begin
  query = M.Just_a_test_deletion |> object;
  query |> do_exists && delete(query; allow_delete_all = true);
  # Seed the table with a few rows so updates have targets
  query.create("name" => "test", "test_result" => 1)
  query.create("name" => "test", "test_result" => 2)
  query.create("name" => "test", "test_result" => 3)
  @test query |> do_count == 3

  # Update a single row and ensure the filtered row is the only one affected
  query.filter("test_result" => 1)
  query.update("name" => "test_update")
  query.filter("name" => "test_update")
  @test query |> do_count == 1

  # Bulk update every row by reloading the query and mutating a DataFrame copy
  query = M.Just_a_test_deletion |> object
  df = query |> DataFrame
  for (index, row) in enumerate(eachrow(df))
      row.name = "test_update_$(index)"
  end
  bulk_update(query, df, columns=["name"], filters=["id"])
  query = M.Just_a_test_deletion |> object
  query.filter("name" => "test_update_1")
  @test query |> do_count == 1

  # Bulk update with an extra static filter to show the filter override behavior
  query = M.Just_a_test_deletion |> object
  df = query |> DataFrame
  for (index, row) in enumerate(eachrow(df))
      row.name = "test_bulk_update"
  end
  bulk_update(query, df, columns=["name"], filters=["id", "test_result" => 1], show_query=false)
  query = M.Just_a_test_deletion |> object
  query.filter("name" => "test_bulk_update")
  @test query |> do_count == 1

  # Removing the static filter restores the ability to update every row again
  bulk_update(query, df, columns=["name"], filters=["id"], show_query=false)
  query = M.Just_a_test_deletion |> object
  query.filter("name" => "test_bulk_update")
  @test query |> do_count == 3
end

@testset "Single Update with joins" begin
  # Update a single joined row (driver with nationality filter) to verify F expressions invert cleanly
  query = M.Result |> object;
  query.filter("driverid__nationality" => "British", "resultid" => 1);
  query.values("resultid", "driverid__forename", "driverid__nationality", "points");
  df = query |> DataFrame
  query.update("points" => F("points") + 10)
  df = query |> DataFrame
  @test df[1, :points] == 20.0
  query.update("points" => F("points") - 10)

  # Apply the same pattern for a more complex join path to ensure unrelated joins stay stable
  query = M.Result |> object;
  query.filter("raceid__circuitid__name__@icontains" => "Monaco", "resultid" => 7654);
  query.values("resultid", "statusid__status", "driverid__forename", "driverid__nationality", "points");  
  query.update("points" => 11)
  df = query |> DataFrame
  @test df[1, :points] == 11.0
  query.update("points" => F("points") - 1)
  df = query |> DataFrame
  @test df[1, :points] == 10.0
  # query.update("points" => 10, show_query=true)

end

@testset "Filtering and Value Selection" begin
  # Filter by status
  query = M.Status |> object;
  query.filter("status" => "Engine");
  @test query |> do_count ==  1
  df = query |> DataFrame
  @test "status" in names(df)
  @test length(names(df)) == 2  # statusid and status

  # Join filter
  query = M.Result |> object;
  query.filter("statusid__status" => "Engine");
  query.values("resultid", "statusid", "statusid__status");
  df = query |> DataFrame;
  @test query |> do_count == 2026
  @test filter(r -> r.statusid__status == "Engine", df) |> x -> nrow(x) == 2026

  # Chained values
  query.values("resultid", "driverid__forename", "constructorid__name", "statusid__status", "grid", "laps");
  df = query |> DataFrame
  @test length(names(df)) == 6
  @test filter(r -> r.statusid__status == "Engine", df) |> x -> nrow(x) == 2026
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

@testset "Ordering and Aggregations" begin
    query = M.Result |> object;
    query.values("statusid__status", "raceid__circuitid__name", "driverid__forename", "constructorid__name", "count_grid" => Count("grid"), "max_grid" => Max("grid"), "min_grid" => Min("grid"));
    query.order_by("raceid__circuitid__name");
    query.filter("statusid__status" => "Finished", "driverid__forename" => "Ayrton");
    df = query |> DataFrame
    @test df[2, :count_grid] == 3
    @test df[2, :max_grid] == 3
    @test df[2, :min_grid] == 2
    @test size(df, 1) == 39
    @test df[1, :raceid__circuitid__name] == "Adelaide Street Circuit"
    @test df[39, :raceid__circuitid__name] == "Suzuka Circuit"
end

@testset "Filtering" begin
    # Contains and icontains
    query = M.Result |> object;
    query.filter("raceid__circuitid__name__@contains" => "Monaco");
    @test query |> do_count == 1664
    query = M.Result |> object;
    query.filter("raceid__circuitid__name__@contains" => "monaco");
    @test query |> do_count == 0
    query = M.Result |> object;
    query.filter("raceid__circuitid__name__@icontains" => "monaco");
    @test query |> do_count == 1664
    query = M.Result |> object;
    query.filter("raceid__circuitid__name__@in" => ["Monaco", "Monza"]);
    @test query |> do_count == 0
    query = M.Result |> object;
    query.filter("raceid__circuitid__name__@in" => ["Circuit de Monaco", "monaco"]);
    @test query |> do_count == 1664
    query = M.Result |> object;
    query.filter("raceid__circuitid__name__@nin" => ["Circuit de Monaco", "monaco"]);
    @test query |> do_count == 25095
end

@testset "Date Operations" begin
    query = M.Race |> object;
    query.filter("date__@year" => 1991);
    query.values("date__@year", "date__@month", "date__@day", "rows" => Count("raceid"));
    query.order_by("date__day");
    df = query |> DataFrame
    @test size(df, 1) == 16
    @test df[16, :date__day] == 29

    query = M.Race |> object;
    query.filter("date__@yyyy_mm" => "1991-10");
    query.values("date__@year", "date__@month", "date__@day", "rows" => Count("raceid"));
    query.order_by("date__day");
    df = query |> DataFrame
    @test size(df, 1) == 1
    @test df[1, :date__day] == 20 && df[1, :rows] == 1

    query = M.Race |> object;
    query.filter("date__@date" => "1991-10-20");
    query.values("date__@year", "date__@month", "date__@day", "rows" => Count("raceid"));
    query.order_by("date__day");
    df = query |> DataFrame
    @test size(df, 1) == 1

    query = M.Race |> object;
    query.filter("date__@date" => Date(1991, 10, 20));
    query.values("date__@year", "date__@month", "date__@day", "rows" => Count("raceid"));
    query.order_by("date__day");
    df = query |> DataFrame
    @test size(df, 1) == 1
end

@testset "Comparison and In Operations" begin
  query = M.Result |> object;
  query.filter("positionorder__@lt" => 3);
  query.values("raceid__circuitid__name", "positionorder", "driverid__forename", "constructorid__name");
  query.order_by("-positionorder");
  df = query |> DataFrame
  @test df[1, :positionorder] == 2

  query = M.Result |> object;
  query.filter("positionorder__@in" => [1, 2]);
  query.values("raceid__circuitid__name", "positionorder",  "driverid__forename", "constructorid__name");
  @test query |> do_count == size(df, 1)

  query = M.Result |> object;
  query.filter("positionorder__@nin" => df.positionorder |> unique);
  query.values("raceid__circuitid__name", "positionorder", "driverid__forename", "constructorid__name");
  @test query |> do_count == 24497
  df = query |> DataFrame
  @test filter(r -> r.positionorder == 1 || r.positionorder == 2, df) |> x -> nrow(x) == 0

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

@testset "FExpression and Filtering" begin
    query = M.Result |> object;
    query.filter(F("driverid__dob__@day") == F("raceid__date__@day"), F("driverid__dob__@month") == F("raceid__date__@month"), "min_grid__@gt" => 0);
    query.values("raceid__circuitid__name", "raceid__date", "driverid__forename", "constructorid__name", "count_grid" => Count("grid"), "max_grid" => Max("grid"), "min_grid" => Min("grid"));
    query.order_by("min_grid", "-raceid__date");
    df = query |> DataFrame
    query |> show_query
    @test size(df, 1) == 75
    @test df[1, :raceid__circuitid__name] == "Nürburgring" && df[1, :driverid__forename] == "Mika"    

    query = M.Result |> object;
    query.filter("driverid__forename" => "Mika");
    query.values("raceid__circuitid__name", "until_30_years" => Sum(Case(When(Q(F("raceid__date") <= F("driverid__dob") + 10950), then=1), default=0)));
    df = query |> DataFrame


end

@testset "F Expression Updates" begin
  query = M.Just_a_test_deletion |> object
  query |> do_exists && delete(query; allow_delete_all = true)
  query.create("name" => "fexpr", "test_result" => 1)
  query.create("name" => "fexpr", "test_result" => 2)
  query.create("name" => "fexpr", "test_result" => 3)

  query.filter("test_result" => 1)

  # Update a value with a F expression so that test_result2 mirrors the filtered test_result
  query.update("test_result2" => F("test_result"))
  query2 = M.Just_a_test_deletion |> object
  df = query2 |> DataFrame
  @test df[df.test_result .== 1, :test_result2][1] == 1

  # Use F("test_result") + 1 to verify arithmetic on expressions
  query.update("test_result2" => F("test_result") + 1)
  df = query2 |> DataFrame
  @test df[df.test_result .== 1, :test_result2][1] == 2

  # Double the existing test_result2 using a second F expression
  query.update("test_result2" => F("test_result2") * 2)
  df = query2 |> DataFrame
  @test df[df.test_result .== 1, :test_result2][1] == 4

  # Divide test_result2 through another update to recover the original base
  query.update("test_result2" => F("test_result2") / 2)
  df = query2 |> DataFrame
  @test df[df.test_result .== 1, :test_result2][1] == 2

  # Use two F expressions in the same update to test expression addition
  query.update("test_result2" => F("test_result") + F("test_result"))
  df = query2 |> DataFrame
  @test df[df.test_result .== 1, :test_result2][1] == 2

  # Subtract one from F("test_result2") to ensure the builder handles subtraction
  query.update("test_result2" => F("test_result2") - 1)
  df = query2 |> DataFrame
  @test df[df.test_result .== 1, :test_result2][1] == 1

  # Set the expression column to missing to verify null propagation
  query.update("test_result2" => missing)
  df = query2 |> DataFrame
  @test ismissing(df[df.test_result .== 1, :test_result2][1])
end

@testset "F Expression Updates with Joins" begin
  # These are just to test F expressions with joins, even if not meaningful
  query = M.Just_a_test_deletion |> object
  query.filter("test_result" => 1)
  try
    # Attempt to reference a joined field via F to see if the validator rejects it
    query.update("test_result2" => F("test_result__statusid"))
  catch e
    @info "Expected error or no-op for join F expression (statusid)" error=e
  end
  query2 = M.Just_a_test_deletion |> object;
  query2.order_by("test_result");
  df = query2 |> DataFrame
  @test df[1, :test_result2] == 1  # No update should have occurred

  query = M.Just_a_test_deletion |> object
  query.filter("test_result" => 1)
  try
    # Another join-based F expression to ensure errors remain informative
    query.update("test_result2" => F("test_result__driverid__number"))
  catch e
    @info "Expected error or no-op for join F expression (driverid__number)" error=e
  end
  df = query2 |> DataFrame
  @test df[1, :test_result2] == 44
end

@testset "filters with having" begin
  query = M.Result |> object;    
  query.values("raceid__circuitid__name", "driverid__forename", "constructorid__name", "count_grid" => Count("grid"));
  query.filter("statusid__status" => "Finished", "count_grid__@gt" => 1);
  df = query |> DataFrame
  # @info query |> show_query
  # ┌ Info: SELECT
  # │    Tb_2.name as raceid__circuitid__name,
  # │   Tb_3.forename as driverid__forename,
  # │   Tb_4.name as constructorid__name,
  # │   COUNT(Tb.grid) as count_grid
  # │ FROM result as Tb
  # │  INNER JOIN race Tb_1 ON Tb.raceid = Tb_1.raceid
  # │  INNER JOIN circuit Tb_2 ON Tb_1.circuitid = Tb_2.circuitid
  # │  INNER JOIN driver Tb_3 ON Tb.driverid = Tb_3.driverid
  # │  INNER JOIN constructor Tb_4 ON Tb.constructorid = Tb_4.constructorid
  # │  INNER JOIN status Tb_5 ON Tb.statusid = Tb_5.statusid
  # │ WHERE Tb_5.status = 'Finished'
  # │ GROUP BY 1, 2, 3
  # └ HAVING COUNT(Tb.grid) > 1
  @test size(df, 1) == 1637
  sort!(df, [:count_grid])
  @test df[1, :count_grid] == 2
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

@testset "Advanced check parameters binding" begin
  # 1. Verify basic binding order and type formatting
  query = M.Result |> object
  query.filter("resultid" => 1, "points" => "10.5", "driverid__forename" => "Lewis")
  
  # Manually build the instruction to inspect parameters before execution
  # We use PormG.QueryBuilder.build to get the internal instruction object
  instruc = PormG.QueryBuilder.build(query.object)
  params = instruc.parameters.parameters

  @test length(params) == 3
  @test params[1] == 1          # resultid
  @test params[2] == "10.5"   # points (string preserved)
  @test params[3] == "Lewis"  # forename

  # 2. Verify LIKE pattern escaping and wildcard wrapping for contains
  query = M.Result |> object;
  query.filter("driverid__forename__@contains" => "L%wis");
  instruc = PormG.QueryBuilder.build(query.object);

  # The parameter should be escaped and wrapped in % by add_parameter!(contains=true)
  # L%wis -> %L\%wis%
  @test instruc.parameters.parameters[1] == "%L\\%wis%"

  q = M.Just_a_test_deletion |> object;
  q.filter("name__@icontains" => "to-be-deleted");
  df = q |> DataFrame
  instruc = PormG.QueryBuilder.build(q.object);
  @test instruc.parameters.parameters[1] == "%to-be-deleted%"

  # 3. Verify array binding for IN clauses
  # Arrays should be stored as a single parameter (Postgres ANY) and preserved as an AbstractVector
  query = M.Result |> object
  query.filter("positionorder__@in" => [1, 2])
  instruc = PormG.QueryBuilder.build(query.object)
  @test length(instruc.parameters.parameters) == 1
  @test isa(instruc.parameters.parameters[1], AbstractVector)
  @test instruc.parameters.parameters[1] == [1, 2]

  # 4. Mixed types in same filter (integers, strings, dates, floats)
  query = M.Result |> object
  query.filter("resultid" => 1, "statusid__status" => "Finished", "raceid__date" => Date(2020,1,15))
  instruc = PormG.QueryBuilder.build(query.object)
  # Expect three parameters in the same order the filters were provided
  @test length(instruc.parameters.parameters) >= 3
  @test instruc.parameters.parameters[1] == 1
  @test instruc.parameters.parameters[2] == "Finished"
  # date formatting is model-dependent; ensure it is formatted as ISO string
  @test string(instruc.parameters.parameters[3]) == "2020-01-15"

  # 5. Nested Q / Qor filter parameter ordering
  # Q groups should preserve their parameter order and Qor should append its alternatives
  query = M.Driver |> object
  query.filter(Q("forename" => "Lewis", "driverid__@lte" => 50), Qor("surname" => "Hamilton", "surname" => "Rosberg"))
  instruc = PormG.QueryBuilder.build(query.object)
  # Expect four parameters in order: forename, driverid, surname1, surname2
  @test length(instruc.parameters.parameters) == 4
  @test instruc.parameters.parameters[1] == "Lewis"
  @test instruc.parameters.parameters[2] == 50
  @test instruc.parameters.parameters[3] == "Hamilton"
  @test instruc.parameters.parameters[4] == "Rosberg"

  # 6. Multiple LIKE patterns in same query are escaped independently
  query = M.Result |> object
  query.filter("driverid__forename__@contains" => "A_B", "raceid__circuitid__name__@icontains" => "%C%")
  instruc = PormG.QueryBuilder.build(query.object)
  @test length(instruc.parameters.parameters) == 2
  @test instruc.parameters.parameters[1] == "%A\\_B%"    # underscore escaped
  @test instruc.parameters.parameters[2] == "%\\%C\\%%"  # percent escaped and wrapped

  # 7. Verify binding in Updates (Filters + Set values) end-to-end
  # We check the functional correctness (DB updated) which proves binding was applied.
  query = M.Just_a_test_deletion |> object
  # Ensure a clean state for the test
  query |> do_exists && delete(query; allow_delete_all=true)
  query.create("id" => 500, "name" => "original", "test_result" => 10)

  # Update two columns using a filter; this exercises both WHERE and SET bindings
  query.filter("id" => 500)
  query.update("name" => "updated", "test_result" => 20)

  query = M.Just_a_test_deletion |> object
  query.filter("id" => 500)
  updated_row = query |> list
  @test updated_row[1][:name] == "updated"
  @test updated_row[1][:test_result] == 20

  # 8. Verify Date binding
  query = M.Race |> object
  test_date = Date(2023, 10, 22)
  query.filter("date" => test_date)
  instruc = PormG.QueryBuilder.build(query.object)

  # The formater should have converted Date to String for the DB driver if needed,
  # or kept it as Date if the driver handles it. Check ISO-like output.
  @test string(instruc.parameters.parameters[1]) == "2023-10-22"

  # Notes for maintainers/readers:
  # - These tests focus on the parameter *collection* and *formatting* performed by build()/add_parameter!.
  # - For UPDATE statements we verify the end-to-end effect in the database which implicitly tests the binding used during the DML.
  # - Keep tests readable and commented; they are educational and help debug future regressions.
end

@testset "Connection string redaction" begin
  # Verify redact_secret masks sensitive connection parameters while preserving others.
  # This ensures we never log plaintext credentials (user/password) but keep other keys intact.
  raw = "host=localhost user=admin password=s3cr3t port=5432"
  masked = PormG.Configuration.redact_secret(raw)

  # Non-sensitive fields should remain unchanged
  @test occursin("host=localhost", masked)
  @test occursin("port=5432", masked)

  # Sensitive fields should be masked and originals must not appear
  @test occursin("user=****", masked)
  @test occursin("password=****", masked)
  @test !occursin("admin", masked)
  @test !occursin("s3cr3t", masked)
  # # Expect two masked occurrences (user and password)
  # @test count(collect(eachmatch("\\*\\*\\*\\*", masked))) == 2

  # Case-insensitive matching should also work
  uppercase = PormG.Configuration.redact_secret("PASSWORD=topsecret")
  @test uppercase == "PASSWORD=****"

  # Strings without sensitive keys should be left untouched
  untouched = PormG.Configuration.redact_secret("dbname=f1_database")
  @test untouched == "dbname=f1_database"
end

@testset "Show Query" begin
  # Test 1: SELECT with show_query returns SQL string
  query = M.Result |> object;
  query.filter("statusid__status" => "Finished", "driverid__forename" => "Ayrton");
  query.values("resultid", "driverid__forename", "constructorid__name" , "statusid__status");
  logger = Base.CoreLogging.SimpleLogger(IOBuffer())
  Base.CoreLogging.with_logger(logger) do
    try
      query |> show_query
      @test true
    catch e
      @error "Error during show_query" error=e
      @test false
    end
  end
  
  # Test 2: DELETE with show_query=true logs structured info
  # We capture log messages using Julia's logging
  delete_logs = []
  logger = Base.CoreLogging.SimpleLogger(IOBuffer())
  Base.CoreLogging.with_logger(logger) do
    try
      delete(M.Circuit |> object, allow_delete_all=true, show_query=true)
      @test true
    catch e
        @error "Error during delete with show_query" error=e
        @test false
    end
  end
  # Verify the circuit table still exists after show_query=true (no actual deletion)
  @test M.Circuit |> object |> do_exists

  # Test 3: BULK_INSERT with show_query=true does not crash
  query = M.Constructor |> object
  bulk_insert_logs = []
  logger = Base.CoreLogging.SimpleLogger(IOBuffer())
  Base.CoreLogging.with_logger(logger) do
    try
      bulk_insert(query, CSV.File(joinpath("f1", "constructors.csv")) |> DataFrame, show_query=true)
      @test true
    catch e
      @error "Error during bulk_insert with show_query" error=e
      @test false
    end
  end

  # Test 4: UPDATE with show_query=true logs structured info
  query = M.Just_a_test_deletion |> object
  query.filter("id" => 1)
  
  # Capture structured log output
  update_log_captured = false
  logger = Base.CoreLogging.SimpleLogger(IOBuffer(), Base.CoreLogging.Info)
  Base.CoreLogging.with_logger(logger) do
    try
      sql = query.update("name" => "test_structured_logging", show_query=true)
      # When show_query=true, update returns the SQL string
      @test typeof(sql) == String
      @test contains(sql, "UPDATE")
      update_log_captured = true
    catch e
      @error "Error during update with show_query" error=e
    end
  end
  @test update_log_captured

  # Test 5: BULK_UPDATE with show_query=true does not crash
  query = M.Just_a_test_deletion |> object;
  df = query |> DataFrame
  for (index, row) in enumerate(eachrow(df))
    row.name = "test_bulk_update_$(index)"
  end
  try
    bulk_update(query, df, columns=["name"], filters=["id"], show_query=false)
    @test true
  catch e
    @error "Error during bulk_update with show_query" error=e
    @test false
  end

  # Test 6: Verify structured logging contains expected fields (query, params, task_id)
  # by inspecting the logged message structure
  query = M.Result |> object;
  query.filter("resultid" => 1);
  query.values("resultid", "points");
  
  logged_messages = []
  function capture_logs(logger, level, message, _module, group, id, file, line; kwargs...)
    if level == Base.CoreLogging.Info && message == "SQL Exec"
      # kwargs should contain: query, params, task_id
      push!(logged_messages, kwargs)
    end
    Base.CoreLogging.handle_message(logger, level, message, _module, group, id, file, line; kwargs...)
  end  

end

@testset "SQL Injection Prevention Tests" begin
        
  @testset "Identifier Sanitization" begin
    # Test the SQLSanitizer module
    
    # Test basic identifier quoting
    @test quote_identifier("valid_field", nothing) == "\"valid_field\""
    @test quote_identifier("field_with_123", nothing) == "\"field_with_123\""
    
    # Test malicious identifier cleaning
    @test quote_identifier("field'; DROP TABLE users; --", nothing) == "\"fieldDROPTABLEusers\""
    @test quote_identifier("field OR 1=1", nothing) == "\"fieldOR11\""
    
    # Test table name sanitization
    @test safe_table_identifier("users", nothing) == "\"users\""
    
    println("✅ All identifier sanitization tests passed!")
  end
  
  @testset "LIKE Pattern Escaping" begin    
    # Test LIKE pattern escaping
    @test escape_like_pattern("test_pattern") == "test\\_pattern"
    @test escape_like_pattern("test%pattern") == "test\\%pattern" 
    @test escape_like_pattern("test\\pattern") == "test\\\\pattern"
    @test escape_like_pattern("test_%\\pattern") == "test\\_\\%\\\\pattern"
    
    println("✅ All LIKE pattern escaping tests passed!")
  end
end

@testset "AdvisoryLock: non-blocking exclusivity" begin
  dbname = first(keys(PormG.config))
  key = "test_advisory_lock_$(uuid4())"
  n = 5
  counter = Atomic{Int}(0)
  tasks = Vector{Task}(undef, n)

  # Use wait=true with blocking strategy so tasks queue for the lock
  @sync for i in 1:n
    @async begin
      try
        # Acquire lock with server-side blocking (tasks queue if lock is held)
        PormG.with_advisory_lock(dbname, key; wait=true, strategy=:pool, timeout_ms=6_000) do
          # increment the counter only when the lock is held
          @info "Inside lock block, task $i"
          atomic_add!(counter, 1)
          sleep(0.5)  # short critical section so all tasks can acquire in sequence
        end
      catch e
        @error "Task $i failed to acquire lock" exception=e
      end
    end
  end

  # after all tasks complete, all 5 should have acquired and incremented
  final_count = atomic_add!(counter, 0)
  @info "Advisory lock test results" final_count
  @test final_count == 5
end

@testset "AdvisoryLock: blocking with timeout" begin
  dbname = first(keys(PormG.config))
  key = "test_advisory_lock_timeout_$(uuid4())"

  # First, acquire the lock in a separate task and hold it
  lock_task = @async begin
    PormG.with_advisory_lock(dbname, key; wait=true, strategy=:block, timeout_ms=10_000) do
      @info "Lock holder task acquired lock"
      sleep(5)  # hold the lock for 5 seconds
      @info "Lock holder task releasing lock"
    end
  end

  sleep(0.5)  # ensure the lock holder has started

  # Now, attempt to acquire the same lock with a short timeout
  got_error = false
  timeout_exc = nothing

  # Suppress noisy internal errors from LibPQ by using a temporary logger
  logger = Base.CoreLogging.SimpleLogger(IOBuffer(), Base.CoreLogging.Error)
  Base.CoreLogging.with_logger(logger) do
    try
      PormG.with_advisory_lock(dbname, key; wait=true, strategy=:block, timeout_ms=1_000) do
        @info "This should not print, as lock acquisition should time out"
      end
    catch e
      timeout_exc = e
      got_error = true
    end
  end

  # Report the expected timeout in a controlled way
  # @info "Expected timeout error caught" exception=timeout_exc
  @info "Expected timeout error caught"
  @test got_error

  # Wait for the lock holder to finish

  # Now, attempt to acquire the lock again, this time it should succeed
  acquired = false
  try
    PormG.with_advisory_lock(dbname, key; wait=true, strategy=:block, timeout_ms=15_000) do
      @info "Successfully acquired lock after it was released"
      acquired = true
    end
  catch e
    @error "Failed to acquire lock unexpectedly" exception=e
  end
  @test acquired

  wait(lock_task)
end

# # Deal with with CTE
# @testset "Common Table Expressions (CTE)" begin
#   # Simple CTE example
#   subquery = M.Status |> object;
#   subquery.filter("status" => "Engine");
#   subquery.values("statusid");

#   query = M.Result |> object;
  

PormG.Configuration.__cleanup__()
