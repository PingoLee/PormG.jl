if !isdefined(Main, :PormG)
    include("common_setup.jl")
end



@testset "Single and Bulk Insert/Update" begin
  query = M.Just_a_test_deletion.objects;
    query.exists() && query.delete(allow_delete_all = true);
  # Seed the table with a few rows so updates have targets
  query.create("name" => "test", "test_result" => 1, "test_result_set_default" => nothing)
  query.create("name" => "test", "test_result" => 2, "test_result_set_default" => nothing)
  query.create("name" => "test", "test_result" => 3, "test_result_set_default" => nothing)
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

@testset "F Expression Updates" begin
  query = M.Just_a_test_deletion.objects
    query.exists() && query.delete(allow_delete_all = true)
  query.create("name" => "fexpr", "test_result" => 1, "test_result_set_default" => nothing)
  query.create("name" => "fexpr", "test_result" => 2, "test_result_set_default" => nothing)
  query.create("name" => "fexpr", "test_result" => 3, "test_result_set_default" => nothing)

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
    M.Just_a_test_deletion.objects.exists() &&
        M.Just_a_test_deletion.objects.delete(allow_delete_all = true)

    source_result = M.Result.objects.filter("resultid" => 1).values("resultid", "statusid", "driverid").list() |> first
    source_driver = M.Driver.objects.filter("driverid" => source_result[:driverid]).values("number").list() |> first

    try
        M.Just_a_test_deletion.objects.create(
            "name" => "joined-fexpr",
            "test_result" => source_result[:resultid],
            "test_result_set_default" => nothing
        )

        # Joined F expressions are a supported cross-table UPDATE path: the SET
        # clause may read from joined aliases while the WHERE still scopes the base row.
        M.Just_a_test_deletion.objects.filter("name" => "joined-fexpr").update(
            "test_result2" => F("test_result__statusid")
        )
        row_after_status = M.Just_a_test_deletion.objects.filter("name" => "joined-fexpr").list() |> first
        @test row_after_status[:test_result2] == source_result[:statusid]

        M.Just_a_test_deletion.objects.filter("name" => "joined-fexpr").update(
            "test_result2" => F("test_result__driverid__number")
        )
        row_after_driver_number = M.Just_a_test_deletion.objects.filter("name" => "joined-fexpr").list() |> first
        @test row_after_driver_number[:test_result2] == source_driver[:number]
    finally
        M.Just_a_test_deletion.objects.exists() &&
            M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
    end
end

@testset "Complex Join Updates and Date Arithmetic" begin
  # 1. Update using a value from a joined table (Cross-table update)
  query = M.Just_a_test_deletion.objects
    query.exists() && query.delete(allow_delete_all = true)
  query.create("name" => "temp", "test_result" => 1, "test_result_set_default" => nothing) # Result 1 driver is Lewis Hamilton
  
  # Join from Just_a_test_deletion -> Result -> Driver
  query.filter("id__@gt" => 0)
  query.update("name" => F("test_result__driverid__forename"))
  
    updated_row = query.list() |> first
  @test updated_row[:name] == "Lewis"

  # 2. Date Arithmetic in Updates (Testing the dialect-specific date math)
  # Australian Grand Prix 2009 is 2009-03-29
  race_query = M.Race.objects.filter("raceid" => 1)
    original_row = race_query.list() |> first
  
  # Ensure we have Date objects for calculation (SQLite might return strings)
  orig_date = original_row[:date] isa String ? Date(original_row[:date]) : original_row[:date]
  
  # Add 7 days: 2009-03-29 + 7 = 2009-04-05
  race_query.update("date" => F("date") + 7)
    new_date_row = (race_query.list() |> first)
  new_date = new_date_row[:date] isa String ? Date(new_date_row[:date]) : new_date_row[:date]
  
  @test new_date == (orig_date + Dates.Day(7))
  
  # Subtract 7 days: Back to 2009-03-29
  race_query.update("date" => F("date") - 7)
    restored_row = (race_query.list() |> first)
  restored_date = restored_row[:date] isa String ? Date(restored_row[:date]) : restored_row[:date]
  @test restored_date == orig_date
  
  # Restore original just in case
  race_query.update("date" => orig_date)
end

@testset "Null and Missing handling in Updates" begin
  query = M.Just_a_test_deletion.objects
    query.exists() && query.delete(allow_delete_all = true)
  query.create("name" => "null_test", "test_result" => 1, "test_result2" => 1, "test_result_set_default" => nothing)
  
  # Update to nothing (NULL)
  query.filter("name" => "null_test").update("test_result2" => nothing)
    res1 = query.list() |> first
  @test ismissing(res1[:test_result2]) || isnothing(res1[:test_result2])
  
  # Update to missing (NULL)
  query.filter("name" => "null_test").update("test_result2" => 1) # set back
  query.filter("name" => "null_test").update("test_result2" => missing)
    res2 = query.list() |> first
  @test ismissing(res2[:test_result2]) || isnothing(res2[:test_result2])
end

@testset "Update Validation and Constraints" begin
    query = M.Just_a_test_deletion.objects
    query.exists() && query.delete(allow_delete_all = true)
    query.create("name" => "valid", "test_result" => 1, "test_result_set_default" => nothing)

    # Updates must be scoped by a WHERE clause. This protects callers from
    # accidentally mutating an entire table by forgetting a filter.
    err = try
        M.Just_a_test_deletion.objects.update("name" => "should_not_update_everything")
        nothing
    catch e
        e
    end
    @test err !== nothing
    @test occursin("must have a filter", lowercase(string(err)))

    row_after_unfiltered_attempt = M.Just_a_test_deletion.objects.filter("name" => "valid").list() |> first
    @test row_after_unfiltered_attempt[:name] == "valid"
    
    # 1. Primary Key Protection: Attempting to update the ID field should throw
    @test_throws ErrorException query.filter("name" => "valid").update("id" => 999)
    
    # 2. Max Length Validation: CharField default max_length is 250
    long_name = "a"^256
    @test_throws ErrorException query.filter("name" => "valid").update("name" => long_name)
    
    # 3. Non-existent field: Should throw informative error
    @test_throws ErrorException query.filter("name" => "valid").update("non_existent" => "foo")
end

@testset "Update inspection modes do not execute" begin
    M.Just_a_test_deletion.objects.exists() &&
        M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
    M.Just_a_test_deletion.objects.create("name" => "inspect-update", "test_result" => 1, "test_result_set_default" => nothing)

    try
        inspection = M.Just_a_test_deletion.objects.filter("name" => "inspect-update").update(
            "name" => "should-not-land",
            show_query = :dict
        )

        @test inspection[:operation] == :update
        @test inspection[:model] == "just_a_test_deletion"
        @test occursin("update", lowercase(inspection[:sql_text]))
        @test inspection[:parameter_count] >= 2
        @test M.Just_a_test_deletion.objects.filter("name" => "inspect-update").count() == 1
        @test M.Just_a_test_deletion.objects.filter("name" => "should-not-land").count() == 0

        sql_text = M.Just_a_test_deletion.objects.filter("name" => "inspect-update").update(
            "test_result" => 12,
            show_query = :sql
        )
        @test sql_text isa String
        @test occursin("set", lowercase(sql_text))
        @test M.Just_a_test_deletion.objects.filter("test_result" => 12).count() == 0

        params = M.Just_a_test_deletion.objects.filter("name" => "inspect-update").update(
            "test_result" => 12,
            show_query = :params
        )
        @test params isa Vector
        @test 12 in params
        @test "inspect-update" in params

        none_result = M.Just_a_test_deletion.objects.filter("name" => "inspect-update").update(
            "name" => "still-not-landed",
            show_query = :none # useful for benchmarking the overhead of building an UPDATE without executing
        )
        @test isnothing(none_result)
        @test M.Just_a_test_deletion.objects.filter("name" => "still-not-landed").count() == 0

        @test_throws ArgumentError M.Just_a_test_deletion.objects.filter("name" => "inspect-update").update(
            "name" => "bad-mode",
            show_query = :bogus
        )
        @test M.Just_a_test_deletion.objects.filter("name" => "bad-mode").count() == 0
    finally
        M.Just_a_test_deletion.objects.exists() &&
            M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
    end
end

@testset "Update Edge Cases: Zero matches and Multi-F" begin
    # Use fresh query objects for each step to avoid filter accumulation
    M.Just_a_test_deletion.objects.exists() && M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
    M.Just_a_test_deletion.objects.create("name" => "multi_f", "test_result" => 10, "test_result2" => 20, "test_result_set_default" => nothing)
    
    # 1. Update matching zero rows: should not error and return nothing
    @test isnothing(M.Just_a_test_deletion.objects.filter("name" => "no_such_row").update("test_result" => 100))
    
    # 2. Multiple F expressions in the same update
    M.Just_a_test_deletion.objects.filter("name" => "multi_f").update(
        "test_result" => F("test_result") + 5,
        "test_result2" => F("test_result2") * 2
    )
    res = M.Just_a_test_deletion.objects.filter("name" => "multi_f").list() |> first
    @test res[:test_result] == 15
    @test res[:test_result2] == 40
end

# ─────────────────────────────────────────────────────────────────────────────
# Update filters: Qor must update exactly the OR-matched rows
# Selection tests already cover Qor for reads. This block keeps the mutation path
# honest by proving an OR filter feeds the UPDATE WHERE clause without widening
# to unrelated rows.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Update with Qor filters" begin
    M.Just_a_test_deletion.objects.exists() &&
        M.Just_a_test_deletion.objects.delete(allow_delete_all = true)

    result_rows = M.Result.objects.order_by("resultid").limit(3).values("resultid").list()
    @test length(result_rows) == 3
    result_ids = [row[:resultid] for row in result_rows]

    M.Just_a_test_deletion.objects.create("name" => "qor-target-a", "test_result" => result_ids[1], "test_result_set_default" => nothing)
    M.Just_a_test_deletion.objects.create("name" => "qor-target-b", "test_result" => result_ids[2], "test_result_set_default" => nothing)
    M.Just_a_test_deletion.objects.create("name" => "qor-skip", "test_result" => result_ids[3], "test_result_set_default" => nothing)

    query = M.Just_a_test_deletion.objects
    query.filter(Qor("name" => "qor-target-a", "test_result" => result_ids[2]))
    query.update("test_result2" => 77)

    rows = M.Just_a_test_deletion.objects.order_by("id").list()
    by_name = Dict(row[:name] => row for row in rows)

    @test by_name["qor-target-a"][:test_result2] == 77
    @test by_name["qor-target-b"][:test_result2] == 77
    @test by_name["qor-skip"][:test_result2] === nothing || ismissing(by_name["qor-skip"][:test_result2])
end

@testset "Transaction Rollback in Updates" begin
    # run_in_transaction wraps the block in BEGIN/COMMIT and issues ROLLBACK on any
    # exception. The error trigger here is PormG's ORM-layer PK protection, which
    # throws before sending SQL. That is intentional: it proves that ANY Julia
    # exception inside the block — not just a DB constraint — causes the whole
    # transaction to roll back. The key assertion is that row1 retains its
    # pre-transaction value (10), not the value written before the error (11).
    db_key = PORMG_DB_FOLDER

    M.Just_a_test_deletion.objects.exists() && M.Just_a_test_deletion.objects.delete(allow_delete_all=true)
    M.Just_a_test_deletion.objects.create("name" => "row1", "test_result" => 10, "test_result_set_default" => nothing)
    M.Just_a_test_deletion.objects.create("name" => "row2", "test_result" => 20, "test_result_set_default" => nothing)
    @test M.Just_a_test_deletion.objects.count() == 2

    try
        err = try
            PormG.run_in_transaction(db_key) do
                # This update executes successfully within the transaction.
                M.Just_a_test_deletion.objects.filter("name" => "row1").update("test_result" => 11)

                # This throws at the ORM layer (PK protection) and triggers ROLLBACK,
                # undoing the row1 update above.
                M.Just_a_test_deletion.objects.filter("name" => "row2").update("id" => 999)
            end
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("id", lowercase(sprint(showerror, err))) || occursin("primary", lowercase(sprint(showerror, err)))

        # row1 must be back to 10 — the proof that the transaction rolled back.
        res1 = M.Just_a_test_deletion.objects.filter("name" => "row1").list() |> first
        @test res1[:test_result] == 10

        # row2 was never the update target; its value being 20 does not prove rollback
        # but confirms no unintended side-effect touched it either.
        res2 = M.Just_a_test_deletion.objects.filter("name" => "row2").list() |> first
        @test res2[:test_result] == 20
    finally
        M.Just_a_test_deletion.objects.exists() &&
            M.Just_a_test_deletion.objects.delete(allow_delete_all=true)
    end
end

@testset "Advanced Update Scenarios" begin
    # Use fresh objects for each test to avoid filter accumulation
    
    @testset "CASE Expressions in SET" begin
        # Reset table
        M.Just_a_test_deletion.objects.exists() && M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
        
        M.Just_a_test_deletion.objects.create("name" => "row1", "test_result" => 10, "test_result_set_default" => nothing)
        M.Just_a_test_deletion.objects.create("name" => "row2", "test_result" => 20, "test_result_set_default" => nothing)
        
        # Update using CASE: if name is row1, set result to 100, else 200
        # PormG requires a filter for updates
        M.Just_a_test_deletion.objects.filter("id__@gt" => 0).update("test_result" => Case(
            When(Q("name" => "row1"), then=100),
            default=200
        ))
        
        res1 = M.Just_a_test_deletion.objects.filter("name" => "row1").list() |> first
        @test res1[:test_result] == 100
        
        res2 = M.Just_a_test_deletion.objects.filter("name" => "row2").list() |> first
        @test res2[:test_result] == 200
    end

    @testset "Deep Join Chains (A->B->C->D)" begin
        # Result -> Race -> Circuit -> country (verified parameter ordering)
        M.Just_a_test_deletion.objects.exists() && M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
        M.Just_a_test_deletion.objects.create("name" => "temp", "test_result" => 1, "test_result_set_default" => nothing) # Result 1 = Lewis Hamilton, British, Australian GP, Australia
        
        # We use a value from 3 levels deep: Result -> Race -> Circuit -> Name
        M.Just_a_test_deletion.objects.filter(
            "test_result__raceid__circuitid__country" => "Australia",
            "test_result__driverid__nationality" => "British"
        ).update("name" => F("test_result__raceid__circuitid__name"))
        
        res = M.Just_a_test_deletion.objects.filter("test_result" => 1).list() |> first
        @test res[:name] == "Albert Park Grand Prix Circuit"
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Forward FK anti-join UPDATE: mutate base FK columns safely
    # A LEFT anti-join on a forward FK must preserve SELECT semantics when the
    # UPDATE targets base-table columns, including nullable FK columns. The SQL
    # should target primary keys through a subquery instead of flattening the
    # LEFT JOIN into an impossible UPDATE FROM predicate.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Forward-FK anti-join UPDATE via Primary Key Subquery" begin
        # 1. Reset
        M.Just_a_test_deletion.objects.exists() && M.Just_a_test_deletion.objects.delete(allow_delete_all = true)

        result_rows = M.Result.objects.order_by("resultid").limit(2).values("resultid").list()
        @test length(result_rows) == 2
        first_result = result_rows[1]
        second_result = result_rows[2]

        # 2. Create one row with a valid relation, one without
        M.Just_a_test_deletion.objects.create(
            "name"                    => "has_result",
            "test_result"             => first_result[:resultid],
            "test_result_set_default" => nothing
        )
        M.Just_a_test_deletion.objects.create(
            "name"                    => "no_result",
            "test_result"             => nothing,
            "test_result_set_default" => nothing
        )

        # The anti-join matches the row without a joined Result. Mutating the FK
        # itself proves the base-table SET path is not limited to plain columns.
        anti_join_update = M.Just_a_test_deletion.objects
        anti_join_update.filter("test_result__resultid__@isnull" => true)
        anti_join_update.update(
            "name" => "updated_no_result",
            "test_result" => second_result[:resultid]
        )

        rows_after_anti_join = M.Just_a_test_deletion.objects.order_by("id").list()
        by_name_after_anti_join = Dict(row[:name] => row for row in rows_after_anti_join)

        @test by_name_after_anti_join["has_result"][:test_result] == first_result[:resultid]
        @test by_name_after_anti_join["updated_no_result"][:test_result] == second_result[:resultid]

        # The original user-facing repair shape nulls a nullable FK through a
        # joined predicate. With real FK constraints we cannot seed a dangling FK,
        # so this uses a valid joined row and proves the nullable FK SET path.
        null_fk_update = M.Just_a_test_deletion.objects
        null_fk_update.filter("name" => "updated_no_result", "test_result__resultid" => second_result[:resultid])
        null_fk_update.update("test_result" => nothing)

        row1 = M.Just_a_test_deletion.objects.filter("name" => "has_result").list() |> first
        row2 = M.Just_a_test_deletion.objects.filter("name" => "updated_no_result").list() |> first

        @test row1[:test_result] == first_result[:resultid]
        @test row2[:test_result] === nothing || ismissing(row2[:test_result])
    end

    @testset "Subquery in WHERE" begin
        M.Just_a_test_deletion.objects.exists() && M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
        M.Just_a_test_deletion.objects.create("name" => "target", "test_result" => 1, "test_result_set_default" => nothing)
        M.Just_a_test_deletion.objects.create("name" => "other", "test_result" => 2, "test_result_set_default" => nothing)
        
        # Subquery: select resultids for British drivers
        # Result 1 is Lewis Hamilton (British)
        subquery = M.Result.objects.filter("driverid__nationality" => "British").values("resultid")
        
        # Update where test_result is in subquery
        M.Just_a_test_deletion.objects.filter("test_result__@in" => subquery).update("name" => "updated_by_subquery")
        
        @test M.Just_a_test_deletion.objects.filter("name" => "updated_by_subquery").count() == 1
    end

    # ─────────────────────────────────────────────────────────────────────────
    # bulk_update pre-flight validation rejects ALL rows when ANY row is invalid
    #
    # The error trigger (`"a"^300`) is caught by ORM-layer max_length validation
    # before any SQL is sent. This is validation-layer all-or-nothing, NOT
    # transactional rollback after partial DB execution. The key proof is that
    # row1 (which would have passed validation) is still unchanged in the DB.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Bulk Update pre-flight validation rejects all rows on error" begin
        M.Just_a_test_deletion.objects.exists() && M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
        M.Just_a_test_deletion.objects.create("name" => "row1", "test_result" => 1, "test_result_set_default" => nothing)
        M.Just_a_test_deletion.objects.create("name" => "row2", "test_result" => 2, "test_result_set_default" => nothing)

        try
            # order_by ensures df[1] is always row1 (test_result=1) and df[2] is row2
            df = M.Just_a_test_deletion.objects.order_by("test_result") |> DataFrame
            df[1, :name] = "success1"
            df[2, :name] = "a"^300 # Triggers max_length validation on the second row

            err = try
                bulk_update(M.Just_a_test_deletion.objects, df, columns=["name"], filters=["id"])
                nothing
            catch e
                e
            end
            @test err !== nothing
            @test occursin("bulk_update", lowercase(sprint(showerror, err)))

            # Neither row must have been written: the validation pass rejected the
            # entire batch before sending any SQL.
            res1 = M.Just_a_test_deletion.objects.filter("test_result" => 1).list() |> first
            res2 = M.Just_a_test_deletion.objects.filter("test_result" => 2).list() |> first
            @test res1[:name] == "row1"
            @test res2[:name] == "row2"
        finally
            M.Just_a_test_deletion.objects.exists() &&
                M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
        end
    end

      @testset "Bulk Update rejects duplicate dynamic filter keys" begin
        M.Just_a_test_deletion.objects.exists() && M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
        M.Just_a_test_deletion.objects.create("name" => "dup-key-row-1", "test_result" => 1, "test_result_set_default" => nothing)
        M.Just_a_test_deletion.objects.create("name" => "dup-key-row-2", "test_result" => 2, "test_result_set_default" => nothing)

        seeded = M.Just_a_test_deletion.objects.order_by("id") |> DataFrame
        duplicate_id = seeded[1, :id]

        dup_df = DataFrame(
          id = [duplicate_id, duplicate_id],
          name = ["dup-target-a", "dup-target-b"]
        )

        err = try
          bulk_update(M.Just_a_test_deletion.objects, dup_df, columns = ["name"], filters = ["id"])
          nothing
        catch e
          e
        end

        @test err !== nothing
        @test occursin("duplicate dynamic filter key", lowercase(string(err)))

        row1 = M.Just_a_test_deletion.objects.filter("name" => "dup-key-row-1").list() |> first
        row2 = M.Just_a_test_deletion.objects.filter("name" => "dup-key-row-2").list() |> first
        @test row1[:id] == duplicate_id
        @test row1[:name] == "dup-key-row-1"
        @test row2[:name] == "dup-key-row-2"
      end

    @testset "Bulk Operations Mapping Adaptor" begin
        # This test ensures that the 'Adaptor' strategy correctly maps DataFrame columns
        # to Model fields without renaming the original DataFrame columns.
        
        M.Just_a_test_deletion.objects.exists() && M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
        
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
            
            res1 = M.Just_a_test_deletion.objects.filter("name" => "Mapped1").list() |> first
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
            query.exists() && query.delete(allow_delete_all = true)
            
            # Setup: Cat1 (update) and Cat2 (skip)
            query.create("name" => "Cat1", "test_result" => 10, "test_result_set_default" => nothing)
            query.create("name" => "Cat1", "test_result" => 20, "test_result_set_default" => nothing)
            query.create("name" => "Cat2", "test_result" => 30, "test_result_set_default" => nothing)
            
            ids = query.order_by("id").list()
            
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
            results = M.Just_a_test_deletion.objects.order_by("id").list()
            @test length(results) == 3
            @test results[1][:test_result] == 100
            @test results[2][:test_result] == 200
            @test results[3][:test_result] == 30    # Remains 30 because name was Cat2
        end

            @testset "bulk_update with lookup operators in filters" begin
              # Production code combines DataFrame-driven row matching with static
              # lookup filters. Keep this here so the regression stays on the bulk
              # UPDATE path instead of relying on lower-level WHERE builder tests.
              M.Just_a_test_deletion.objects.exists() && M.Just_a_test_deletion.objects.delete(allow_delete_all=true)

              M.Just_a_test_deletion.objects.create("name" => "lookup_test_1", "test_result" => 1, "test_result_set_default" => nothing)
              M.Just_a_test_deletion.objects.create("name" => "lookup_test_2", "test_result" => 2, "test_result_set_default" => nothing)
              M.Just_a_test_deletion.objects.create("name" => "lookup_test_3", "test_result" => 3, "test_result_set_default" => nothing)
              M.Just_a_test_deletion.objects.create("name" => "lookup_test_4", "test_result" => 4, "test_result_set_default" => nothing)

              q = M.Just_a_test_deletion.objects.filter("name" => "lookup_test_1")
              q.update("test_result2" => 1)

              query = M.Just_a_test_deletion.objects
              df = query.filter("name__@icontains" => "lookup_test").order_by("id") |> DataFrame

              for row in eachrow(df)
                row.name = "updated_$(row.id)"
              end

              bulk_update(M.Just_a_test_deletion.objects, df,
                columns=["name"],
                filters=["id", "test_result2__@isnull" => true, "test_result__@in" => [2, 3]])

              row1 = M.Just_a_test_deletion.objects.filter("test_result" => 1).list() |> first
              row2 = M.Just_a_test_deletion.objects.filter("test_result" => 2).list() |> first
              row3 = M.Just_a_test_deletion.objects.filter("test_result" => 3).list() |> first
              row4 = M.Just_a_test_deletion.objects.filter("test_result" => 4).list() |> first

              @test row1[:name] == "lookup_test_1"
              @test row2[:name] == "updated_$(row2[:id])"
              @test row3[:name] == "updated_$(row3[:id])"
              @test row4[:name] == "lookup_test_4"
            end

    end
end


# ─────────────────────────────────────────────────────────────────────────────
# JSONField Updates
#
# Field_validation_scratch.payload is a JSONField(null=true). This testset
# verifies that:
#   1. A null payload can be updated to a full JSON object
#   2. A subsequent update fully replaces the stored object (no partial merge)
#   3. A payload can be set back to null
#
# JSON is serialised to a string before passing to update() because both
# PostgreSQL (jsonb) and SQLite (TEXT) accept a JSON string as the wire format.
# ─────────────────────────────────────────────────────────────────────────────
@testset "JSONField Updates" begin
    slug     = "json-update-9901"
    uuid_val = string(uuid4())

    M.Field_validation_scratch.objects.filter("slug" => slug).exists() &&
        M.Field_validation_scratch.objects.filter("slug" => slug).delete()

    try
        # Insert with null payload — the field is nullable so this must succeed.
        result = M.Field_validation_scratch.objects.create(
            "uuid_token"    => uuid_val,
            "canonical_url" => "https://example.com/f1/json-update",
            "slug"          => slug
        )
        @test result[:payload] === nothing || ismissing(result[:payload])

        # Update 1: null → dict (serialised as a JSON string)
        first_payload = Dict("race" => "Monaco GP", "year" => 2024)
        M.Field_validation_scratch.objects.filter("slug" => slug).update(
            "payload" => JSON.json(first_payload)
        )
        row1 = M.Field_validation_scratch.objects.filter(
            "slug" => slug
        ).values(
            "payload"
        ).list() |> first
        # Adapters may return the JSON as a Dict (PostgreSQL jsonb) or a String (SQLite TEXT).
        stored1 = row1[:payload] isa AbstractDict ?
                      row1[:payload] :
                      JSON.parse(string(row1[:payload]))
        @test stored1["race"] == "Monaco GP"
        @test stored1["year"] == 2024

        # Update 2: replace with a completely different dict — must be a full replacement.
        # The key "year" that existed in the first payload must NOT survive.
        second_payload = Dict("race" => "Silverstone", "lap" => 52)
        M.Field_validation_scratch.objects.filter("slug" => slug).update(
            "payload" => JSON.json(second_payload)
        )
        row2 = M.Field_validation_scratch.objects.filter(
            "slug" => slug
        ).values(
            "payload"
        ).list() |> first
        stored2 = row2[:payload] isa AbstractDict ?
                      row2[:payload] :
                      JSON.parse(string(row2[:payload]))
        @test stored2["race"] == "Silverstone"
        @test stored2["lap"]  == 52
        @test !haskey(stored2, "year")  # evicted by full replacement — not a merge

        # Update 3: dict → null
        M.Field_validation_scratch.objects.filter("slug" => slug).update("payload" => nothing)
        row3 = M.Field_validation_scratch.objects.filter(
            "slug" => slug
        ).values(
            "payload"
        ).list() |> first
        @test row3[:payload] === nothing || ismissing(row3[:payload])

    finally
        M.Field_validation_scratch.objects.filter("slug" => slug).exists() &&
            M.Field_validation_scratch.objects.filter("slug" => slug).delete()
    end
end


# ─────────────────────────────────────────────────────────────────────────────
# Bulk Update Constraint: JOINs Rejected
#
# execution_bulk.jl line 744 explicitly throws when the source query already
# has JOIN conditions attached. This is the correct limitation: the VALUES (…)
# bulk approach generates its own CTE/subquery and cannot also carry an outer
# JOIN that was baked into the query object.
#
# The test documents this guard so a silent regression cannot slip through.
# If PormG ever lifts the restriction, this test will fail and the developer
# will know to update both the guard and this test.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Bulk Update Constraint: JOINs Rejected" begin
    M.Just_a_test_deletion.objects.exists() &&
        M.Just_a_test_deletion.objects.delete(allow_delete_all=true)
    M.Just_a_test_deletion.objects.create("name" => "join-guard-row", "test_result" => 1, "test_result_set_default" => nothing)

    df = M.Just_a_test_deletion.objects.order_by("id") |> DataFrame
    df[1, :name] = "should-not-land"

    err = try
      # The JOIN-producing predicate has to be passed through the bulk_update
      # filters= API because bulk_update clears any pre-applied query filters
      # before rebuilding its instruction object.
      bulk_update(
        M.Just_a_test_deletion.objects,
        df,
        columns=["name"],
        filters=["id", "test_result__positionorder" => 1]
      )
        nothing
    catch e
        e
    end

    # The guard must have fired — error must be non-null.
    @test err !== nothing
    # The error message must mention "join" (case-insensitive) so the caller
    # understands why the operation was rejected rather than seeing a cryptic failure.
    @test occursin("join", lowercase(string(err)))

    # The row must NOT have been mutated during the failed attempt.
    row = M.Just_a_test_deletion.objects.filter("name" => "join-guard-row").list() |> first
    @test row[:name] == "join-guard-row"

    M.Just_a_test_deletion.objects.delete(allow_delete_all=true)
end


# ─────────────────────────────────────────────────────────────────────────────
# Decimal Precision in F-expressions
#
# Django_contract_scratch.price is a DecimalField(max_digits=10, decimal_places=2),
# which maps to NUMERIC(10,2) on both PostgreSQL and SQLite.
#
# The key assertion is that F-expression arithmetic on a NUMERIC column does NOT
# introduce floating-point drift: 10.50 * 2 must come back as exactly 21.0
# (or the string equivalent), not 20.999999... or 21.000000001.
#
# The comparison is done by parsing the stored value via string to avoid any
# implicit float widening in the Julia comparison layer.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Decimal Precision in F-expressions" begin
    label = "decimal-f-expr-9902"

    M.Django_contract_scratch.objects.filter("label" => label).exists() &&
        M.Django_contract_scratch.objects.filter("label" => label).delete()

    try
        M.Django_contract_scratch.objects.create("label" => label, "price" => "10.50")

        # Multiply the stored NUMERIC value by 2 using an F-expression.
        # Integer multiplier avoids introducing a floating-point literal into the SQL.
        # Expected result: 10.50 * 2 = 21.00 exactly.
        M.Django_contract_scratch.objects.filter("label" => label).update(
            "price" => F("price") * 2
        )

        row = M.Django_contract_scratch.objects.filter(
            "label" => label
        ).values(
            "price"
        ).list() |> first

        # parse via string → Float64 to avoid adapter-specific Decimal/String types.
        # 21.0 is exactly representable in Float64, so == is appropriate here.
        stored = parse(Float64, string(row[:price]))
        @test stored == 21.0

    finally
        M.Django_contract_scratch.objects.filter("label" => label).exists() &&
            M.Django_contract_scratch.objects.filter("label" => label).delete()
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Pagination guard on update():
# Standard SQL UPDATE does not natively support LIMIT, OFFSET, or ORDER BY.
# If a user chains any of these before calling .update(), PormG must throw
# an ArgumentError before touching the database, so a developer never
# accidentally mutates all matching rows when they intended to update only N.
# ─────────────────────────────────────────────────────────────────────────────
@testset "update() rejects limit, offset, and order_by" begin
    # Minimal setup: one row is enough; the guard fires before SQL is sent.
    M.Just_a_test_deletion.objects.exists() &&
        M.Just_a_test_deletion.objects.delete(allow_delete_all=true)
    M.Just_a_test_deletion.objects.create("name" => "guard-row", "test_result" => 1, "test_result_set_default" => nothing)

    base = M.Just_a_test_deletion.objects

    # limit() must be rejected
    err_limit = try
        base.filter("test_result__@gt" => 0).limit(1).update("name" => "should-not-land")
        nothing
    catch e
        e
    end
    @test err_limit isa ArgumentError
    @test occursin("limit", lowercase(sprint(showerror, err_limit)))

    # offset() must be rejected
    err_offset = try
        base.filter("test_result__@gt" => 0).offset(1).update("name" => "should-not-land")
        nothing
    catch e
        e
    end
    @test err_offset isa ArgumentError
    @test occursin("offset", lowercase(sprint(showerror, err_offset)))

    # order_by() must be rejected
    err_order = try
        base.filter("test_result__@gt" => 0).order_by("id").update("name" => "should-not-land")
        nothing
    catch e
        e
    end
    @test err_order isa ArgumentError
    @test occursin("order_by", lowercase(sprint(showerror, err_order)))

    # Verify no mutations slipped through despite the guard being in the execution path.
    @test M.Just_a_test_deletion.objects.filter("name" => "guard-row").count() == 1

    M.Just_a_test_deletion.objects.delete(allow_delete_all=true)
end
