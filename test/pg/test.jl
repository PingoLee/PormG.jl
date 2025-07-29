using Pkg
Pkg.activate(".")
ENV["PORMG_ENV"] = "dev"
using Revise
using PormG
using DataFrames
using CSV
using Test
using Dates
using JSON

cd("test")
cd("pg")

# PormG.Configuration.load()
PormG.Configuration.load("db_2")

# teste compation of fields
import PormG: Models, Dialect
import PormG.QueryBuilder: Sum, Avg, Case, When, Count, Q, Qor, F, page, do_count, do_exists, show_query, Max, Min
import PormG.QueryBuilder: quote_identifier, safe_table_identifier, escape_like_pattern


# load models
Base.include(PormG, "db_2/models.jl")
import PormG.models as M

# PormG.Configuration.__cleanup__()
# PormG.config["db_2"].connections.connections
# PormG.config["db_2"].connections.available

# conn = PormG.Configuration.acquire_connection(PormG.config["db_2"].connections)

@testset "Database Setup and Bulk Insert" begin
    # Clear all tables
    delete(M.Circuit |> object, allow_delete_all = true, show_query = false)
    delete(M.Status |> object, allow_delete_all = true)
    delete(M.Driver |> object, allow_delete_all = true)
    delete(M.Constructor |> object, allow_delete_all = true)
    delete(M.Result |> object, allow_delete_all = true)
    delete(M.Just_a_test_deletion |> object, allow_delete_all = true)

    # Single insertions for Status
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
    bulk_insert(query, CSV.File(joinpath("f1", "constructors.csv")) |> DataFrame)

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

@testset "Single and Bulk Insert/Update" begin
    query = M.Just_a_test_deletion |> object;
    query |> do_exists && delete(query; allow_delete_all = true);
    query.create("name" => "test", "test_result" => 1)
    query.create("name" => "test", "test_result" => 2)
    query.create("name" => "test", "test_result" => 3)
    @test query |> do_count == 3

    # Update single row
    query.filter("test_result" => 1)
    query.update("name" => "test_update")
    query.filter("name" => "test_update")
    @test query |> do_count == 1

    # Bulk update
    query = M.Just_a_test_deletion |> object
    df = query |> DataFrame
    for (index, row) in enumerate(eachrow(df))
        row.name = "test_update_$(index)"
    end
    bulk_update(query, df, columns=["name"], filters=["id"])
    query = M.Just_a_test_deletion |> object
    query.filter("name" => "test_update_1")
    @test query |> do_count == 1

    # Bulk update with static filters
    query = M.Just_a_test_deletion |> object
    df = query |> DataFrame
    for (index, row) in enumerate(eachrow(df))
        row.name = "test_bulk_update"
    end
    bulk_update(query, df, columns=["name"], filters=["id", "test_result" => 1], show_query=false)
    query = M.Just_a_test_deletion |> object
    query.filter("name" => "test_bulk_update")
    @test query |> do_count == 1

    bulk_update(query, df, columns=["name"], filters=["id"], show_query=false)
    query = M.Just_a_test_deletion |> object
    query.filter("name" => "test_bulk_update")
    @test query |> do_count == 3

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

  # Update a value with a F expression
  query.filter("test_result" => 1)
  query.update("test_result2" => F("test_result"))
  query2 = M.Just_a_test_deletion |> object
  df = query2 |> DataFrame
  @test df[df.test_result .== 1, :test_result2][1] == 1

  # F("test_result") + 1
  query.filter("test_result" => 1)
  query.update("test_result2" => F("test_result") + 1)
  df = query2 |> DataFrame
  @test df[df.test_result .== 1, :test_result2][1] == 2

  # F("test_result2") * 2
  query.filter("test_result" => 1)
  query.update("test_result2" => F("test_result2") * 2)
  df = query2 |> DataFrame
  @test df[df.test_result .== 1, :test_result2][1] == 4

  # F("test_result2") / 2
  query.filter("test_result" => 1)
  query.update("test_result2" => F("test_result2") / 2)
  df = query2 |> DataFrame
  @test df[df.test_result .== 1, :test_result2][1] == 2

  # F("test_result") + F("test_result")
  query.filter("test_result" => 1)
  query.update("test_result2" => F("test_result") + F("test_result"))
  df = query2 |> DataFrame
  @test df[df.test_result .== 1, :test_result2][1] == 2

  # F("test_result2") - 1
  query.filter("test_result" => 1)
  query.update("test_result2" => F("test_result2") - 1)
  df = query2 |> DataFrame
  @test df[df.test_result .== 1, :test_result2][1] == 1

  # Set to missing
  query.filter("test_result" => 1)
  query.update("test_result2" => missing)
  df = query2 |> DataFrame
  @test ismissing(df[df.test_result .== 1, :test_result2][1])
end

@testset "F Expression Updates with Joins" begin
  # These are just to test F expressions with joins, even if not meaningful
  query = M.Just_a_test_deletion |> object
  query.filter("test_result" => 1)
  try
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

@testset "Print Query" begin
  query = M.Result |> object;
  query.filter("statusid__status" => "Finished", "driverid__forename" => "Ayrton");
  query.values("resultid", "driverid__forename", "constructorid__name", "statusid__status");
  @test typeof(query |> show_query) == String 

  try
    delete(M.Circuit |> object, allow_delete_all=true, show_query=true)
    @test true
  catch e
      @error "Error during delete with show_query" error=e
      @test false  # Fail the test if an error occurs
  end

  @test M.Circuit |> object |> do_exists

  query = M.Constructor |> object
  try
    bulk_insert(query, CSV.File(joinpath("f1", "constructors.csv")) |> DataFrame, show_query=true)
    @test true
  catch e
    @error "Error during bulk_insert with show_query" error=e
    @test false  # Fail the test if an error occurs
  end

  query = M.Just_a_test_deletion |> object;
  df = query |> DataFrame
  for (index, row) in enumerate(eachrow(df))
    row.name = "test_update_$(index)"
  end
  try
    bulk_update(query, df, columns=["name"], filters=["id"], show_query=false)
    @test true
  catch e
    @error "Error during bulk_update with show_query" error=e
    @test false  # Fail the test if an error occurs
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

PormG.Configuration.__cleanup__()
