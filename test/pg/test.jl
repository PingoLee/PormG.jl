using Pkg
Pkg.activate(".")
ENV["PORMG_ENV"] = "dev"
using Revise
using PormG
using DataFrames
using CSV
using Test

cd("test")
cd("pg")

# PormG.Configuration.load()
PormG.Configuration.load("db_2")

# teste compation of fields
import PormG: Models, Dialect
import PormG.QueryBuilder: Sum, Avg, Case, When, Count, Q, Qor, F, page, do_count, do_exists, show_query, Max, Min

# load models
Base.include(PormG, "db_2/models.jl")
import PormG.models as M

# PormG.Configuration.__cleanup__()
# PormG.config["db_2"].connections.connections
# PormG.config["db_2"].connections.available

# conn = PormG.Configuration.acquire_connection(PormG.config["db_2"].connections)

@testset "Database Setup and Bulk Insert" begin
    # Clear all tables
    delete(M.Circuit |> object, allow_delete_all = true)
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
    df = query |> list |> DataFrame
    for (index, row) in enumerate(eachrow(df))
        row.name = "test_update_$(index)"
    end
    bulk_update(query, df, columns=["name"], filters=["id"])
    query = M.Just_a_test_deletion |> object
    query.filter("name" => "test_update_1")
    @test query |> do_count == 1
end

@testset "Filtering and Value Selection" begin
    # Filter by status
    query = M.Status |> object;
    query.filter("status" => "Engine");
    @test query |> do_count ==  1
    df = query |> list |> DataFrame
    @test "status" in names(df)
    @test length(names(df)) == 2  # statusid and status

    # Join filter
    query = M.Result |> object;
    query.filter("statusid__status" => "Engine");
    query.values("resultid", "statusid", "statusid__status");
    df = query |> list |> DataFrame;
    @test query |> do_count == 2026
    @test filter(r -> r.statusid__status == "Engine", df) |> x -> nrow(x) == 2026

    # Chained values
    query.values("resultid", "driverid__forename", "constructorid__name", "statusid__status", "grid", "laps");
    df = query |> list |> DataFrame
    @test length(names(df)) == 6
    @test filter(r -> r.statusid__status == "Engine", df) |> x -> nrow(x) == 2026
end


@testset "Ordering and Aggregations" begin
    query = M.Result |> object;
    query.values("statusid__status", "raceid__circuitid__name", "driverid__forename", "constructorid__name", "count_grid" => Count("grid"), "max_grid" => Max("grid"), "min_grid" => Min("grid"));
    query.order_by("raceid__circuitid__name");
    query.filter("statusid__status" => "Finished", "driverid__forename" => "Ayrton");
    df = query |> list |> DataFrame
    @test df[2, :count_grid] == 3
    @test df[2, :max_grid] == 3
    @test df[2, :min_grid] == 2
    @test size(df, 1) == 39
    @test df[1, :raceid__circuitid__name] == "Adelaide Street Circuit"
    @test df[39, :raceid__circuitid__name] == "Suzuka Circuit"
end

@testset "Advanced Filtering" begin
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
end

@testset "Date Operations" begin
    query = M.Race |> object;
    query.filter("date__@year" => 1991);
    query.values("date__@year", "date__@month", "date__@day", "rows" => Count("raceid"));
    query.order_by("date__day");
    df = query |> list |> DataFrame
    @test size(df, 1) == 16
    @test df[16, :date__day] == 29
end

@testset "Comparison and In Operations" begin
    query = M.Result |> object;
    query.filter("positionorder__@lt" => 3);
    query.values("raceid__circuitid__name", "driverid__forename", "constructorid__name", "positionorder");
    query.order_by("-positionorder");
    df = query |> list |> DataFrame
    @test df[1, :positionorder] == 2

    query = M.Result |> object;
    query.filter("positionorder__@in" => [1, 2]);
    query.values("raceid__circuitid__name", "driverid__forename", "constructorid__name");
    @test query |> do_count == size(df, 1)
end

@testset "Reverse Joins" begin
    query = M.Constructor |> object;
    query.values("result__resultid");
    query.filter("result__resultid" => 1);
    # @info query |> show_query
    df = query |> list |> DataFrame
    @test size(df, 1) == 1
    @test df[1, :result__resultid] == 1
end

@testset "FExpression and Filtering" begin
    query = M.Result |> object;
    query.filter(F("driverid__dob__@day") == F("raceid__date__@day"), F("driverid__dob__@month") == F("raceid__date__@month"), "min_grid__@gt" => 0);
    query.values("raceid__circuitid__name", "raceid__date", "driverid__forename", "constructorid__name", "count_grid" => Count("grid"), "max_grid" => Max("grid"), "min_grid" => Min("grid"));
    query.order_by("min_grid", "-raceid__date");
    df = query |> list |> DataFrame
    query |> show_query
    @test size(df, 1) == 75
    @test df[1, :raceid__circuitid__name] == "Nürburgring" && df[1, :driverid__forename] == "Mika"    
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
  df = query2 |> list |> DataFrame
  @test df[df.test_result .== 1, :test_result2][1] == 1

  # F("test_result") + 1
  query.filter("test_result" => 1)
  query.update("test_result2" => F("test_result") + 1)
  df = query2 |> list |> DataFrame
  @test df[df.test_result .== 1, :test_result2][1] == 2

  # F("test_result2") * 2
  query.filter("test_result" => 1)
  query.update("test_result2" => F("test_result2") * 2)
  df = query2 |> list |> DataFrame
  @test df[df.test_result .== 1, :test_result2][1] == 4

  # F("test_result2") / 2
  query.filter("test_result" => 1)
  query.update("test_result2" => F("test_result2") / 2)
  df = query2 |> list |> DataFrame
  @test df[df.test_result .== 1, :test_result2][1] == 2

  # F("test_result") + F("test_result")
  query.filter("test_result" => 1)
  query.update("test_result2" => F("test_result") + F("test_result"))
  df = query2 |> list |> DataFrame
  @test df[df.test_result .== 1, :test_result2][1] == 2

  # F("test_result2") - 1
  query.filter("test_result" => 1)
  query.update("test_result2" => F("test_result2") - 1)
  df = query2 |> list |> DataFrame
  @test df[df.test_result .== 1, :test_result2][1] == 1

  # Set to missing
  query.filter("test_result" => 1)
  query.update("test_result2" => missing)
  df = query2 |> list |> DataFrame
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
  df = query2 |> list |> DataFrame
  @test df[1, :test_result2] == 1  # No update should have occurred

  query = M.Just_a_test_deletion |> object
  query.filter("test_result" => 1)
  try
    query.update("test_result2" => F("test_result__driverid__number"))
  catch e
    @info "Expected error or no-op for join F expression (driverid__number)" error=e
  end
  df = query2 |> list |> DataFrame
  @test df[1, :test_result2] == 44
end

PormG.Configuration.__cleanup__()