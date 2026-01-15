if !isdefined(Main, :PormG)
    include("common_setup.jl")
end



@testset "Single and Bulk Insert/Update" begin
  query = M.Just_a_test_deletion.objects;
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
  query = M.Just_a_test_deletion.objects
  df = query |> DataFrame
  for (index, row) in enumerate(eachrow(df))
      row.name = "test_update_$(index)"
  end
  bulk_update(query, df, columns=["name"], filters=["id"])
  query = M.Just_a_test_deletion.objects
  query.filter("name" => "test_update_1")
  @test query |> do_count == 1

  # Bulk update with an extra static filter to show the filter override behavior
  query = M.Just_a_test_deletion.objects
  df = query |> DataFrame
  for (index, row) in enumerate(eachrow(df))
      row.name = "test_bulk_update"
  end
  bulk_update(query, df, columns=["name"], filters=["id", "test_result" => 1], show_query=false)
  query = M.Just_a_test_deletion.objects
  query.filter("name" => "test_bulk_update")
  @test query |> do_count == 1

  # Removing the static filter restores the ability to update every row again
  bulk_update(query, df, columns=["name"], filters=["id"], show_query=false)
  query = M.Just_a_test_deletion.objects
  query.filter("name" => "test_bulk_update")
  @test query |> do_count == 3
end

@testset "Single Update with joins" begin
  # Update a single joined row (driver with nationality filter) to verify F expressions invert cleanly
  query = M.Result.objects;
  query.filter("driverid__nationality" => "British", "resultid" => 1);
  query.values("resultid", "driverid__forename", "driverid__nationality", "points");
  df = query |> DataFrame
  query.update("points" => F("points") + 10)
  df = query |> DataFrame
  @test df[1, :points] == 20.0
  query.update("points" => F("points") - 10)

  # Apply the same pattern for a more complex join path to ensure unrelated joins stay stable
  query = M.Result.objects;
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


@testset "FExpression and Filtering" begin
    query = M.Result.objects;
    query.filter(F("driverid__dob__@day") == F("raceid__date__@day"), F("driverid__dob__@month") == F("raceid__date__@month"), "min_grid__@gt" => 0);
    query.values("raceid__circuitid__name", "raceid__date", "driverid__forename", "constructorid__name", "count_grid" => Count("grid"), "max_grid" => Max("grid"), "min_grid" => Min("grid"));
    query.order_by("min_grid", "-raceid__date");
    df = query |> DataFrame
    query |> show_query
    @test size(df, 1) == 75
    @test df[1, :raceid__circuitid__name] == "Nürburgring" && df[1, :driverid__forename] == "Mika"    

    query = M.Result.objects;
    query.filter("driverid__forename" => "Mika");
    query.values("raceid__circuitid__name", "until_30_years" => Sum(Case(When(Q(F("raceid__date") <= F("driverid__dob") + 10950), then=1), default=0)));
    df = query |> DataFrame


end

@testset "F Expression Updates" begin
  query = M.Just_a_test_deletion.objects
  query |> do_exists && delete(query; allow_delete_all = true)
  query.create("name" => "fexpr", "test_result" => 1)
  query.create("name" => "fexpr", "test_result" => 2)
  query.create("name" => "fexpr", "test_result" => 3)

  query.filter("test_result" => 1)

  # Update a value with a F expression so that test_result2 mirrors the filtered test_result
  query.update("test_result2" => F("test_result"))
  query2 = M.Just_a_test_deletion.objects
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
  query = M.Just_a_test_deletion.objects
  query.filter("test_result" => 1)
  try
    # Attempt to reference a joined field via F to see if the validator rejects it
    query.update("test_result2" => F("test_result__statusid"))
  catch e
    @info "Expected error or no-op for join F expression (statusid)" error=e
  end
  query2 = M.Just_a_test_deletion.objects;
  query2.order_by("test_result");
  df = query2 |> DataFrame
  @test df[1, :test_result2] == 1  # No update should have occurred

  query = M.Just_a_test_deletion.objects
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
