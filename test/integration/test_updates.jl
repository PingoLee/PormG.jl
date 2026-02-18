if !isdefined(Main, :PormG)
    include("common_setup.jl")
end



@testset "Single and Bulk Insert/Update" begin
  query = M.Just_a_test_deletion.objects;
  query.exists() && delete(query; allow_delete_all = true);
  # Seed the table with a few rows so updates have targets
  query.create("name" => "test", "test_result" => 1)
  query.create("name" => "test", "test_result" => 2)
  query.create("name" => "test", "test_result" => 3)
  @test query.count() == 3

  # Update a single row and ensure the filtered row is the only one affected
  query.filter("test_result" => 1)
  query.update("name" => "test_update")
  query.filter("name" => "test_update")
  @test query.count() == 1

  # Bulk update every row by reloading the query and mutating a DataFrame copy
  query = M.Just_a_test_deletion.objects
  df = query |> DataFrame
  for (index, row) in enumerate(eachrow(df))
      row.name = "test_update_$(index)"
  end
  bulk_update(query, df, columns=["name"], filters=["id"])
  query = M.Just_a_test_deletion.objects
  query.filter("name" => "test_update_1")
  @test query.count() == 1

  # Bulk update with an extra static filter to show the filter override behavior
  query = M.Just_a_test_deletion.objects
  df = query |> DataFrame
  for (index, row) in enumerate(eachrow(df))
      row.name = "test_bulk_update"
  end
  bulk_update(query, df, columns=["name"], filters=["id", "test_result" => 1], show_query=:execute)
  query = M.Just_a_test_deletion.objects
  query.filter("name" => "test_bulk_update")
  @test query.count() == 1

  # Removing the static filter restores the ability to update every row again
  bulk_update(query, df, columns=["name"], filters=["id"], show_query=:execute)
  query = M.Just_a_test_deletion.objects
  query.filter("name" => "test_bulk_update")
  @test query.count() == 3
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
  # query.update("points" => 10, show_query=:sql)

end


@testset "FExpression and Filtering" begin
  query = M.Result.objects;
  query.filter(F("driverid__dob__@day") == F("raceid__date__@day"), F("driverid__dob__@month") == F("raceid__date__@month"), "min_grid__@gt" => 0);
  query.values("raceid__circuitid__name", "raceid__date", "driverid__forename", "constructorid__name", "count_grid" => Count("grid"), "max_grid" => Max("grid"), "min_grid" => Min("grid"));
  query.order_by("min_grid", "-raceid__date");
  df = query |> DataFrame
  # query |> show_query
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

@testset "Complex Join Updates and Date Arithmetic" begin
  # 1. Update using a value from a joined table (Cross-table update)
  query = M.Just_a_test_deletion.objects
  query.exists() && delete(query; allow_delete_all = true)
  query.create("name" => "temp", "test_result" => 1) # Result 1 driver is Lewis Hamilton
  
  # Join from Just_a_test_deletion -> Result -> Driver
  query.filter("id__@gt" => 0)
  query.update("name" => F("test_result__driverid__forename"))
  
  updated_row = query |> list |> first
  @test updated_row[:name] == "Lewis"

  # 2. Date Arithmetic in Updates (Testing the dialect-specific date math)
  # Australian Grand Prix 2009 is 2009-03-29
  race_query = M.Race.objects.filter("raceid" => 1)
  original_row = race_query |> list |> first
  
  # Ensure we have Date objects for calculation (SQLite might return strings)
  orig_date = original_row[:date] isa String ? Date(original_row[:date]) : original_row[:date]
  
  # Add 7 days: 2009-03-29 + 7 = 2009-04-05
  race_query.update("date" => F("date") + 7)
  new_date_row = (race_query |> list |> first)
  new_date = new_date_row[:date] isa String ? Date(new_date_row[:date]) : new_date_row[:date]
  
  @test new_date == (orig_date + Dates.Day(7))
  
  # Subtract 7 days: Back to 2009-03-29
  race_query.update("date" => F("date") - 7)
  restored_row = (race_query |> list |> first)
  restored_date = restored_row[:date] isa String ? Date(restored_row[:date]) : restored_row[:date]
  @test restored_date == orig_date
  
  # Restore original just in case
  race_query.update("date" => orig_date)
end

@testset "Null and Missing handling in Updates" begin
  query = M.Just_a_test_deletion.objects
  query.exists() && delete(query; allow_delete_all = true)
  query.create("name" => "null_test", "test_result" => 1, "test_result2" => 1)
  
  # Update to nothing (NULL)
  query.filter("name" => "null_test").update("test_result2" => nothing)
  res1 = query |> list |> first
  @test ismissing(res1[:test_result2]) || isnothing(res1[:test_result2])
  
  # Update to missing (NULL)
  query.filter("name" => "null_test").update("test_result2" => 1) # set back
  query.filter("name" => "null_test").update("test_result2" => missing)
  res2 = query |> list |> first
  @test ismissing(res2[:test_result2]) || isnothing(res2[:test_result2])
end

@testset "Update Validation and Constraints" begin
    query = M.Just_a_test_deletion.objects
    query.exists() && delete(query; allow_delete_all = true)
    query.create("name" => "valid", "test_result" => 1)
    
    # 1. Primary Key Protection: Attempting to update the ID field should throw
    @test_throws ErrorException query.filter("name" => "valid").update("id" => 999)
    
    # 2. Max Length Validation: CharField default max_length is 250
    long_name = "a"^256
    @test_throws ErrorException query.filter("name" => "valid").update("name" => long_name)
    
    # 3. Non-existent field: Should throw informative error
    @test_throws ErrorException query.filter("name" => "valid").update("non_existent" => "foo")
end

@testset "Update Edge Cases: Zero matches and Multi-F" begin
    # Use fresh query objects for each step to avoid filter accumulation
    M.Just_a_test_deletion.objects.exists() && delete(M.Just_a_test_deletion.objects; allow_delete_all = true)
    M.Just_a_test_deletion.objects.create("name" => "multi_f", "test_result" => 10, "test_result2" => 20)
    
    # 1. Update matching zero rows: should not error and return nothing
    @test isnothing(M.Just_a_test_deletion.objects.filter("name" => "no_such_row").update("test_result" => 100))
    
    # 2. Multiple F expressions in the same update
    M.Just_a_test_deletion.objects.filter("name" => "multi_f").update(
        "test_result" => F("test_result") + 5,
        "test_result2" => F("test_result2") * 2
    )
    res = M.Just_a_test_deletion.objects.filter("name" => "multi_f") |> list |> first
    @test res[:test_result] == 15
    @test res[:test_result2] == 40
end

@testset "Transaction Rollback in Updates" begin
    # Note: PormG.run_in_transaction wraps operations in BEGIN/COMMIT and handles ROLLBACK on error.
    db_key = PORMG_DB_FOLDER
    
    # 1. Setup fresh data
    M.Just_a_test_deletion.objects.exists() && delete(M.Just_a_test_deletion.objects; allow_delete_all=true)
    M.Just_a_test_deletion.objects.create("name" => "row1", "test_result" => 10)
    M.Just_a_test_deletion.objects.create("name" => "row2", "test_result" => 20)
    
    # Verify initial state
    @test M.Just_a_test_deletion.objects.count() == 2
    
    try
        PormG.run_in_transaction(db_key) do
            # This update should succeed initially within the transaction
            M.Just_a_test_deletion.objects.filter("name" => "row1").update("test_result" => 11)
            
            # This update will fail due to PK protection
            # and trigger a transaction rollback.
            M.Just_a_test_deletion.objects.filter("name" => "row2").update("id" => 999)
        end
    catch e
        @info "Caught expected error for transaction rollback" error=e
    end
    
    # After rollback, row1 should still have its ORIGINAL value (10), not 11.
    res1 = M.Just_a_test_deletion.objects.filter("name" => "row1") |> list |> first
    @test res1[:test_result] == 10
    
    # Clean up
    delete(M.Just_a_test_deletion.objects, allow_delete_all=true)
end

@testset "Advanced Update Scenarios" begin
    # Use fresh objects for each test to avoid filter accumulation
    
    @testset "CASE Expressions in SET" begin
        # Reset table
        M.Just_a_test_deletion.objects.exists() && delete(M.Just_a_test_deletion.objects; allow_delete_all = true)
        
        M.Just_a_test_deletion.objects.create("name" => "row1", "test_result" => 10)
        M.Just_a_test_deletion.objects.create("name" => "row2", "test_result" => 20)
        
        # Update using CASE: if name is row1, set result to 100, else 200
        # PormG requires a filter for updates
        M.Just_a_test_deletion.objects.filter("id__@gt" => 0).update("test_result" => Case(
            When(Q("name" => "row1"), then=100),
            default=200
        ))
        
        res1 = M.Just_a_test_deletion.objects.filter("name" => "row1") |> list |> first
        @test res1[:test_result] == 100
        
        res2 = M.Just_a_test_deletion.objects.filter("name" => "row2") |> list |> first
        @test res2[:test_result] == 200
    end

    @testset "Deep Join Chains (A->B->C->D)" begin
        # Result -> Race -> Circuit -> country (verified parameter ordering)
        M.Just_a_test_deletion.objects.exists() && delete(M.Just_a_test_deletion.objects; allow_delete_all = true)
        M.Just_a_test_deletion.objects.create("name" => "temp", "test_result" => 1) # Result 1 = Lewis Hamilton, British, Australian GP, Australia
        
        # We use a value from 3 levels deep: Result -> Race -> Circuit -> Name
        M.Just_a_test_deletion.objects.filter(
            "test_result__raceid__circuitid__country" => "Australia",
            "test_result__driverid__nationality" => "British"
        ).update("name" => F("test_result__raceid__circuitid__name"))
        
        res = M.Just_a_test_deletion.objects.filter("test_result" => 1) |> list |> first
        @test res[:name] == "Albert Park Grand Prix Circuit"
    end

    @testset "Subquery in WHERE" begin
        M.Just_a_test_deletion.objects.exists() && delete(M.Just_a_test_deletion.objects; allow_delete_all = true)
        M.Just_a_test_deletion.objects.create("name" => "target", "test_result" => 1)
        M.Just_a_test_deletion.objects.create("name" => "other", "test_result" => 2)
        
        # Subquery: select resultids for British drivers
        # Result 1 is Lewis Hamilton (British)
        subquery = M.Result.objects.filter("driverid__nationality" => "British").values("resultid")
        
        # Update where test_result is in subquery
        M.Just_a_test_deletion.objects.filter("test_result__@in" => subquery).update("name" => "updated_by_subquery")
        
        @test M.Just_a_test_deletion.objects.filter("name" => "updated_by_subquery").count() == 1
    end

    @testset "Bulk Update Atomicity on Partial Failure" begin
        M.Just_a_test_deletion.objects.exists() && delete(M.Just_a_test_deletion.objects; allow_delete_all = true)
        M.Just_a_test_deletion.objects.create("name" => "row1", "test_result" => 1)
        M.Just_a_test_deletion.objects.create("name" => "row2", "test_result" => 2)
        
        query = M.Just_a_test_deletion.objects.all()
        df = query |> DataFrame
        df[1, :name] = "success1"
        df[2, :name] = "a"^300 # Should trigger max_length validation error
        
        try
            bulk_update(M.Just_a_test_deletion.objects, df, columns=["name"], filters=["id"])
        catch e
            @info "Caught expected error in bulk_update" error=e
        end
        
        # Verify row1 was NOT updated to "success1"
        res1 = M.Just_a_test_deletion.objects.filter("test_result" => 1) |> list |> first
        @test res1[:name] == "row1"
    end

    @testset "Bulk Operations Mapping Adaptor" begin
        # This test ensures that the 'Adaptor' strategy correctly maps DataFrame columns
        # to Model fields without renaming the original DataFrame columns.
        
        M.Just_a_test_deletion.objects.exists() && delete(M.Just_a_test_deletion.objects; allow_delete_all = true)
        
        @testset "bulk_insert with explicit mapping" begin
            # DataFrame has names different from model
            # Model fields: name, test_result
            df = DataFrame(
                "input_name" => ["Mapped1", "Mapped2"],
                "input_result" => [100, 200]
            )
            
            # Map columns explicitly
            bulk_insert(M.Just_a_test_deletion, df, 
                columns=["input_name" => "name", "input_result" => "test_result"])
            
            @test M.Just_a_test_deletion.objects.filter("name" => "Mapped1").count() == 1
            @test M.Just_a_test_deletion.objects.filter("name" => "Mapped2", "test_result" => 200).count() == 1
            
            # Verify DataFrame columns were NOT renamed
            @test "input_name" in names(df)
            @test !("name" in names(df))
        end
        
        @testset "bulk_update with explicit mapping and filter mapping" begin
            # Get IDs for the rows we just inserted
            df_ids = M.Just_a_test_deletion.objects.filter("name__@contains" => "Mapped") |> DataFrame
            
            update_df = DataFrame(
                "record_id" => df_ids.id,
                "update_val" => [101, 201]
            )
            
            # Map all necessary columns in 'columns'
            # Use 'filters' to specify which fields identify the row
            bulk_update(M.Just_a_test_deletion, update_df, 
                columns=["update_val" => "test_result", "record_id" => "id"], 
                filters=["id"])
            
            res1 = M.Just_a_test_deletion.objects.filter("name" => "Mapped1") |> list |> first
            @test res1[:test_result] == 101
            
            # Verify DataFrame columns were NOT renamed
            @test "record_id" in names(update_df)
            @test !("id" in names(update_df))
        end
        
        @testset "Auto-lowercase mapping" begin
            # Model field is 'name' (lowercase)
            # DataFrame has 'NAME' (uppercase)
            df = DataFrame("NAME" => ["CaseTest"], "TEST_RESULT" => [50])
            
            # Should auto-detect without explicit Pair
            bulk_insert(M.Just_a_test_deletion, df)
            
            @test M.Just_a_test_deletion.objects.filter("name" => "CaseTest").count() == 1
            @test "NAME" in names(df)
        end

        @testset "Mixed Static and Dynamic Filters" begin
            query = M.Just_a_test_deletion.objects
            query.exists() && delete(query; allow_delete_all = true)
            
            # Setup: Cat1 (update) and Cat2 (skip)
            query.create("name" => "Cat1", "test_result" => 10)
            query.create("name" => "Cat1", "test_result" => 20)
            query.create("name" => "Cat2", "test_result" => 30)
            
            ids = query.order_by("id") |> list
            
            df = DataFrame(
                "df_id" => [ids[1][:id], ids[2][:id], ids[3][:id]],
                "new_val" => [100, 200, 300]
            )
            
            # Update points for specific IDs BUT only if category is Cat1
            bulk_update(query, df,
                columns=["new_val" => "test_result"],
                filters=[
                    "df_id" => "id",    # Dynamic (Mapping)
                    "name" => "Cat1"    # Static (Query criteria)
                ]
            )
            
            # Verify with a fresh query to include all categories
            results = M.Just_a_test_deletion.objects.order_by("id") |> list
            @test length(results) == 3
            @test results[1][:test_result] == 100
            @test results[2][:test_result] == 200
            @test results[3][:test_result] == 30    # Remains 30 because name was Cat2
        end
    end
end
