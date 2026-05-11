if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

_bulk_update_scratch_to_date(value) = value isa Date ? value : Date(string(value))
_bulk_update_scratch_to_bool(value) = value isa Bool ? value : Int(value) != 0
_bulk_update_scratch_fk_string(id::Integer) = SubString("id=$(id)", 4)

function _clear_bulk_update_scratch_rows!()
    M.Bulk_update_payload_scratch.objects.delete(allow_delete_all = true)
    M.Bulk_update_optional_parent_scratch.objects.delete(allow_delete_all = true)
    M.Bulk_update_required_parent_scratch.objects.delete(allow_delete_all = true)
    return nothing
end

function _seed_bulk_update_scratch_parents!(required_labels::Vector{String}, optional_labels::Vector{String})
    required_ids = Dict{String, Int64}()
    optional_ids = Dict{String, Int64}()

    for label in required_labels
        row = M.Bulk_update_required_parent_scratch.objects.create("label" => label)
        required_ids[label] = Int64(row[:id])
    end

    for label in optional_labels
        row = M.Bulk_update_optional_parent_scratch.objects.create("label" => label)
        optional_ids[label] = Int64(row[:id])
    end

    return required_ids, optional_ids
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
        # Bulk Update: mixed-type payload executes end-to-end with string-backed FKs
        #
        # This reproduces the production shape more closely than the existing SQL-only
        # inspection tests: a bulk_update against a real table with a required FK, a
        # nullable FK, a DateField, a BooleanField, and a plain text field. The FK
        # values are passed as AbstractString fragments instead of Int64 so the ORM has
        # to validate them and the database has to enforce the live constraints.
        # ─────────────────────────────────────────────────────────────────────────────
        @testset "Bulk Update mixed-type payload accepts string-backed FK ids and missing" begin
            _clear_bulk_update_scratch_rows!()

            try
                required_ids, optional_ids = _seed_bulk_update_scratch_parents!(
                    ["req-a", "req-b"],
                    ["opt-a", "opt-b"],
                )

                row_a = M.Bulk_update_payload_scratch.objects.create(
                    "label" => "payload-a",
                    "required_parent_id" => required_ids["req-a"],
                    "optional_parent_id" => optional_ids["opt-a"],
                    "event_date" => Date(2024, 1, 10),
                    "is_active" => false,
                )
                row_b = M.Bulk_update_payload_scratch.objects.create(
                    "label" => "payload-b",
                    "required_parent_id" => required_ids["req-b"],
                    "optional_parent_id" => optional_ids["opt-b"],
                    "event_date" => Date(2024, 1, 11),
                    "is_active" => true,
                )

                update_df = DataFrame(
                    id = [row_a[:id], row_b[:id]],
                    label = ["payload-a-updated", "payload-b-updated"],
                    required_parent_id = Any[
                        _bulk_update_scratch_fk_string(required_ids["req-b"]),
                        _bulk_update_scratch_fk_string(required_ids["req-a"]),
                    ],
                    optional_parent_id = Any[
                        _bulk_update_scratch_fk_string(optional_ids["opt-b"]),
                        missing,
                    ],
                    event_date = ["2024-02-10", "2024-02-11"],
                    is_active = [true, false],
                )

                bulk_update(
                    M.Bulk_update_payload_scratch.objects,
                    update_df,
                    columns = ["label", "required_parent_id", "optional_parent_id", "event_date", "is_active"],
                    filters = ["id"],
                )

                persisted_rows = M.Bulk_update_payload_scratch.objects.order_by("id").list()
                by_id = Dict(row[:id] => row for row in persisted_rows)

                @test by_id[row_a[:id]][:label] == "payload-a-updated"
                @test by_id[row_a[:id]][:required_parent_id] == required_ids["req-b"]
                @test by_id[row_a[:id]][:optional_parent_id] == optional_ids["opt-b"]
                @test _bulk_update_scratch_to_date(by_id[row_a[:id]][:event_date]) == Date(2024, 2, 10)
                @test _bulk_update_scratch_to_bool(by_id[row_a[:id]][:is_active]) == true

                @test by_id[row_b[:id]][:label] == "payload-b-updated"
                @test by_id[row_b[:id]][:required_parent_id] == required_ids["req-a"]
                @test by_id[row_b[:id]][:optional_parent_id] === nothing || ismissing(by_id[row_b[:id]][:optional_parent_id])
                @test _bulk_update_scratch_to_date(by_id[row_b[:id]][:event_date]) == Date(2024, 2, 11)
                @test _bulk_update_scratch_to_bool(by_id[row_b[:id]][:is_active]) == false
            finally
                _clear_bulk_update_scratch_rows!()
            end
        end

        # ─────────────────────────────────────────────────────────────────────────────
        # Bulk Update: chunk_size splits one payload across multiple statements
        #
        # The production call uses chunk_size=500. This regression forces the same code
        # path with chunk_size=2 so a five-row DataFrame crosses chunk boundaries and
        # the final persisted state proves every batch used the right dynamic row key.
        # ─────────────────────────────────────────────────────────────────────────────
        @testset "Bulk Update chunking applies all batches for mixed-type payloads" begin
            _clear_bulk_update_scratch_rows!()

            try
                required_ids, optional_ids = _seed_bulk_update_scratch_parents!(
                    ["req-left", "req-right"],
                    ["opt-left", "opt-right"],
                )

                seeded_rows = [
                    M.Bulk_update_payload_scratch.objects.create(
                        "label" => "chunk-seed-$(index)",
                        "required_parent_id" => required_ids["req-left"],
                        "optional_parent_id" => optional_ids["opt-left"],
                        "event_date" => Date(2024, 3, index),
                        "is_active" => false,
                    )
                    for index in 1:5
                ]

                update_df = DataFrame(
                    id = [row[:id] for row in seeded_rows],
                    label = ["chunk-updated-$(index)" for index in 1:5],
                    required_parent_id = Any[
                        _bulk_update_scratch_fk_string(required_ids[index % 2 == 1 ? "req-right" : "req-left"])
                        for index in 1:5
                    ],
                    optional_parent_id = Any[
                        index in (2, 4) ? missing : _bulk_update_scratch_fk_string(optional_ids[index % 2 == 1 ? "opt-right" : "opt-left"])
                        for index in 1:5
                    ],
                    event_date = [Dates.format(Date(2024, 4, index), "yyyy-mm-dd") for index in 1:5],
                    is_active = [index % 2 == 0 for index in 1:5],
                )

                bulk_update(
                    M.Bulk_update_payload_scratch.objects,
                    update_df,
                    columns = ["label", "required_parent_id", "optional_parent_id", "event_date", "is_active"],
                    filters = ["id"],
                    chunk_size = 2,
                )

                persisted_rows = M.Bulk_update_payload_scratch.objects.order_by("id").list()
                by_id = Dict(row[:id] => row for row in persisted_rows)

                observed = [
                    begin
                        persisted = by_id[seeded[:id]]
                        (
                            persisted[:label],
                            persisted[:required_parent_id],
                            persisted[:optional_parent_id] === nothing || ismissing(persisted[:optional_parent_id]) ? nothing : persisted[:optional_parent_id],
                            _bulk_update_scratch_to_date(persisted[:event_date]),
                            _bulk_update_scratch_to_bool(persisted[:is_active]),
                        )
                    end
                    for (index, seeded) in enumerate(seeded_rows)
                ]
                expected = [
                    (
                        "chunk-updated-$(index)",
                        required_ids[index % 2 == 1 ? "req-right" : "req-left"],
                        index in (2, 4) ? nothing : optional_ids[index % 2 == 1 ? "opt-right" : "opt-left"],
                        Date(2024, 4, index),
                        index % 2 == 0,
                    )
                    for index in 1:5
                ]
                @test observed == expected
            finally
                _clear_bulk_update_scratch_rows!()
            end
        end

        # ─────────────────────────────────────────────────────────────────────────────
        # Bulk Update: numeric sentinel 0 is not treated as a nullable FK shortcut
        #
        # The production payload showed 0-like values in FK columns. This regression
        # makes the contract explicit: if the referenced row does not exist, the live
        # database must reject the bulk UPDATE and the prior FK value must remain.
        # ─────────────────────────────────────────────────────────────────────────────
        @testset "Bulk Update rejects zero sentinel for constrained FK columns" begin
            _clear_bulk_update_scratch_rows!()

            try
                required_ids, optional_ids = _seed_bulk_update_scratch_parents!(
                    ["req-only"],
                    ["opt-only"],
                )

                seeded = M.Bulk_update_payload_scratch.objects.create(
                    "label" => "zero-sentinel-target",
                    "required_parent_id" => required_ids["req-only"],
                    "optional_parent_id" => optional_ids["opt-only"],
                    "event_date" => Date(2024, 5, 1),
                    "is_active" => true,
                )

                bad_update = DataFrame(
                    id = [seeded[:id]],
                    optional_parent_id = Any["0"],
                )

                err = try
                    bulk_update(
                        M.Bulk_update_payload_scratch.objects,
                        bad_update,
                        columns = ["optional_parent_id"],
                        filters = ["id"],
                    )
                    nothing
                catch e
                    e
                end

                @test err !== nothing
                @test occursin("foreign key", lowercase(string(err))) || occursin("constraint", lowercase(string(err)))

                persisted = M.Bulk_update_payload_scratch.objects.filter("id" => seeded[:id]).list() |> first
                @test persisted[:optional_parent_id] == optional_ids["opt-only"]
                @test persisted[:label] == "zero-sentinel-target"
            finally
                _clear_bulk_update_scratch_rows!()
            end
        end

        # ─────────────────────────────────────────────────────────────────────────────
        # Bulk Update: combined DateTimeField + nullable IntegerField + FK + BooleanField
        #
        # This mirrors the production call shape that prompted the test:
        #   bulk_update(Model.objects, df0,
        #     columns=[..., "dt_fim", "dt_inicio", ..., "st_fechado_automaticamente",
        #              "nu_responsavel_anterior", ..., "st_registro_tardio", ...],
        #     filters=["id", "ibge_id" => IBGE]
        #   )
        # The key scenarios are:
        #   - A DateTime value lands correctly in a nullable DateTimeField column
        #   - A missing value nulls a nullable DateTimeField column
        #   - An integer value lands in a nullable IntegerField column
        #   - A missing value nulls a nullable IntegerField column
        #   - The static FK filter restricts which rows are affected
        # All four column types (DateTimeField, IntegerField, ForeignKey, BooleanField)
        # are in one single bulk_update call so a regression in parameter ordering or
        # type coercion across the combined path is detected immediately.
        # ─────────────────────────────────────────────────────────────────────────────
        @testset "Bulk Update combined DateTimeField + nullable IntegerField + FK + BooleanField" begin
            _clear_bulk_update_scratch_rows!()

            try
                required_ids, optional_ids = _seed_bulk_update_scratch_parents!(
                    ["req-combo"],
                    ["opt-combo"],
                )

                row_a = M.Bulk_update_payload_scratch.objects.create(
                    "label"              => "combo-a",
                    "required_parent_id" => required_ids["req-combo"],
                    "optional_parent_id" => optional_ids["opt-combo"],
                    "event_date"         => Date(2024, 1, 1),
                    "is_active"          => false,
                    "event_time"         => nothing,
                    "nullable_int"       => nothing,
                )
                row_b = M.Bulk_update_payload_scratch.objects.create(
                    "label"              => "combo-b",
                    "required_parent_id" => required_ids["req-combo"],
                    "optional_parent_id" => nothing,
                    "event_date"         => Date(2024, 1, 2),
                    "is_active"          => true,
                    "event_time"         => DateTime(2024, 1, 2, 8, 0, 0),
                    "nullable_int"       => 99,
                )

                # row_a: fill in event_time and nullable_int from null
                # row_b: null out event_time and nullable_int, swap is_active
                update_df = DataFrame(
                    id           = [row_a[:id], row_b[:id]],
                    event_time   = Any[DateTime(2024, 6, 15, 12, 0, 0), missing],
                    nullable_int = Any[42, missing],
                    is_active    = [true, false],
                )

                # Static filter "label__@in" acts as the ibge_id equivalent:
                # it must restrict the UPDATE to only the combo rows even though the
                # DataFrame IDs would uniquely identify them on their own.
                bulk_update(
                    M.Bulk_update_payload_scratch.objects,
                    update_df,
                    columns = ["event_time", "nullable_int", "is_active"],
                    filters = ["id", "label__@in" => ["combo-a", "combo-b"]],
                )

                persisted = M.Bulk_update_payload_scratch.objects.order_by("id").list()
                by_id = Dict(row[:id] => row for row in persisted)

                # row_a assertions
                pa = by_id[row_a[:id]]
                @test _bulk_update_scratch_to_bool(pa[:is_active]) == true
                @test _bulk_update_scratch_to_bool(pa[:nullable_int] !== nothing && !ismissing(pa[:nullable_int])) == true
                @test pa[:nullable_int] == 42
                # Accept DateTime, ZonedDateTime, or ISO 8601 string from adapter.
                # We only depend on Dates (in scope via common_setup), so we
                # normalise to a plain DateTime by converting via string parsing.
                stored_a = pa[:event_time]
                normalized_a = if stored_a isa DateTime
                    stored_a
                elseif stored_a isa AbstractString
                    DateTime(stored_a[1:19])
                else
                    # ZonedDateTime or similar — convert through string ISO 8601 representation
                    DateTime(string(stored_a)[1:19])
                end
                @test normalized_a == DateTime(2024, 6, 15, 12, 0, 0)

                # row_b assertions — both datetime and int must be null
                pb = by_id[row_b[:id]]
                @test _bulk_update_scratch_to_bool(pb[:is_active]) == false
                @test pb[:nullable_int] === nothing || ismissing(pb[:nullable_int])
                @test pb[:event_time] === nothing || ismissing(pb[:event_time])

            finally
                _clear_bulk_update_scratch_rows!()
            end
        end


# ─────────────────────────────────────────────────────────────────────────────
# Bulk Insert combined: explicit id + DateTimeField + nullable IntegerField
#                       + nullable FK + BooleanField
#
# Mirrors the production `bulk_insert` pattern where:
#   - "id" is explicitly included in columns= so the caller controls the PKs
#   - nullable columns (event_time, nullable_int, optional_parent_id, event_date)
#       carry a mix of concrete values and missing across rows
#   - chunk_size=2 forces the 3-row DataFrame to span two DB round-trips,
#       exercising column-map consistency across chunks
# ─────────────────────────────────────────────────────────────────────────────
@testset "Bulk Insert combined explicit-id + DateTimeField + nullable IntegerField + FK + BooleanField" begin
    _clear_bulk_update_scratch_rows!()

    try
        required_ids, optional_ids = _seed_bulk_update_scratch_parents!(
            ["req-bi-combo"],
            ["opt-bi-combo"],
        )

        # IDs well above any auto-sequence value; table is empty after the clear
        # above, so there is no PK collision risk.
        explicit_ids = [990_100, 990_101, 990_102]

        insert_df = DataFrame(
            id                 = explicit_ids,
            label              = ["bi-combo-a", "bi-combo-b", "bi-combo-c"],
            required_parent_id = fill(required_ids["req-bi-combo"], 3),
            optional_parent_id = Any[optional_ids["opt-bi-combo"], missing, optional_ids["opt-bi-combo"]],
            event_date         = Any[Date(2024, 3, 1), Date(2024, 3, 2), missing],
            is_active          = [true, false, true],
            event_time         = Any[DateTime(2024, 3, 1, 9, 0, 0), missing, DateTime(2024, 3, 3, 10, 30, 0)],
            nullable_int       = Any[7, missing, 77],
        )

        # chunk_size=2 splits the 3-row DataFrame into two DB round-trips.
        bulk_insert(
            M.Bulk_update_payload_scratch.objects,
            insert_df,
            columns    = ["id", "label", "required_parent_id", "optional_parent_id",
                          "event_date", "is_active", "event_time", "nullable_int"],
            chunk_size = 2,
        )

        rows = M.Bulk_update_payload_scratch.objects.filter(
            "label__@in" => ["bi-combo-a", "bi-combo-b", "bi-combo-c"]
        ).order_by("id").values(
            "id", "label", "required_parent_id", "optional_parent_id",
            "event_date", "is_active", "event_time", "nullable_int"
        ).list()

        @test length(rows) == 3
        @test Set(r[:id] for r in rows) == Set(explicit_ids)

        by_label = Dict(r[:label] => r for r in rows)

        # ── row A: all non-null values ────────────────────────────────────────
        ra = by_label["bi-combo-a"]
        @test ra[:id] == 990_100
        @test _bulk_update_scratch_to_bool(ra[:is_active]) == true
        @test ra[:nullable_int] == 7
        @test ra[:optional_parent_id] == optional_ids["opt-bi-combo"]
        stored_a = ra[:event_time]
        norm_a = if stored_a isa DateTime
            stored_a
        elseif stored_a isa AbstractString
            DateTime(stored_a[1:19])
        else
            DateTime(string(stored_a)[1:19])
        end
        @test norm_a == DateTime(2024, 3, 1, 9, 0, 0)

        # ── row B: all nullable columns are null/missing ──────────────────────
        rb = by_label["bi-combo-b"]
        @test rb[:id] == 990_101
        @test _bulk_update_scratch_to_bool(rb[:is_active]) == false
        @test rb[:nullable_int] === nothing || ismissing(rb[:nullable_int])
        @test rb[:event_time] === nothing || ismissing(rb[:event_time])
        @test rb[:optional_parent_id] === nothing || ismissing(rb[:optional_parent_id])

        # ── row C: event_date missing, event_time and nullable_int non-null ───
        rc = by_label["bi-combo-c"]
        @test rc[:id] == 990_102
        @test _bulk_update_scratch_to_bool(rc[:is_active]) == true
        @test rc[:nullable_int] == 77
        @test rc[:event_date] === nothing || ismissing(rc[:event_date])
        stored_c = rc[:event_time]
        norm_c = if stored_c isa DateTime
            stored_c
        elseif stored_c isa AbstractString
            DateTime(stored_c[1:19])
        else
            DateTime(string(stored_c)[1:19])
        end
        @test norm_c == DateTime(2024, 3, 3, 10, 30, 0)

    finally
        _clear_bulk_update_scratch_rows!()
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

# ─────────────────────────────────────────────────────────────────────────────
# Bulk Update: empty DataFrame is a no-op, not an error
#
# The production call site may legitimately produce an empty DataFrame (e.g.
# after filtering a CSV with no matching rows). The implementation must log a
# warning and return nothing without touching the database.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Bulk Update empty DataFrame is a no-op" begin
    M.Just_a_test_deletion.objects.exists() &&
        M.Just_a_test_deletion.objects.delete(allow_delete_all=true)
    M.Just_a_test_deletion.objects.create("name" => "no-op-sentinel", "test_result" => 1, "test_result_set_default" => nothing)

    # Build a zero-row DataFrame that still has the right column schema.
    # This can happen naturally when a read query returns no results.
    empty_df = M.Just_a_test_deletion.objects.filter("test_result" => 99999) |> DataFrame
    @test size(empty_df, 1) == 0

    result = bulk_update(
        M.Just_a_test_deletion.objects,
        empty_df,
        columns = ["name"],
        filters = ["id"],
    )

    # Must return nothing — the empty path must not raise.
    @test isnothing(result)

    # The sentinel row must be completely unaffected.
    sentinel = M.Just_a_test_deletion.objects.filter("name" => "no-op-sentinel").list() |> first
    @test sentinel[:name] == "no-op-sentinel"

    M.Just_a_test_deletion.objects.delete(allow_delete_all=true)
end

# ─────────────────────────────────────────────────────────────────────────────
# Bulk Update: filters=nothing auto-detects the model primary key
#
# When no filters are passed, the implementation falls through to:
#   dinanic_filters = pks
# and infers the row identity from the model's primary key field(s). This is
# the simplest caller shape. Use upper-case DataFrame columns here so the test
# also proves the case-insensitive PK fallback branch.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Bulk Update auto-PK filter inference is case-insensitive" begin
    M.Just_a_test_deletion.objects.exists() &&
        M.Just_a_test_deletion.objects.delete(allow_delete_all=true)

    M.Just_a_test_deletion.objects.create("name" => "auto-pk-a", "test_result" => 1, "test_result_set_default" => nothing)
    M.Just_a_test_deletion.objects.create("name" => "auto-pk-b", "test_result" => 2, "test_result_set_default" => nothing)

    # Read back so we have real PKs in the DataFrame, then rename columns to
    # upper-case so bulk_update has to use its lowercase-matching fallback.
    df = M.Just_a_test_deletion.objects.order_by("id") |> DataFrame
    rename!(df, "id" => "ID", "name" => "NAME")
    df[1, "NAME"] = "auto-pk-a-updated"
    df[2, "NAME"] = "auto-pk-b-updated"

    # No filters= argument: the ORM must discover "id" as the PK automatically.
    bulk_update(
        M.Just_a_test_deletion.objects,
        df,
        columns = ["name"],
    )

    rows = M.Just_a_test_deletion.objects.order_by("id").list()
    @test rows[1][:name] == "auto-pk-a-updated"
    @test rows[2][:name] == "auto-pk-b-updated"

    M.Just_a_test_deletion.objects.delete(allow_delete_all=true)
end

# ─────────────────────────────────────────────────────────────────────────────
# Bulk Update: explicit columns and filters use case-insensitive DF matching
#
# This covers the separate fallback branch where bulk_update must resolve both
# an update column and a dynamic filter column from upper-case DataFrame names
# while the caller still uses lower-case model field names.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Bulk Update explicit filters are case-insensitive against DataFrame columns" begin
    M.Just_a_test_deletion.objects.exists() &&
        M.Just_a_test_deletion.objects.delete(allow_delete_all=true)

    M.Just_a_test_deletion.objects.create("name" => "ci-filter-a", "test_result" => 1, "test_result_set_default" => nothing)
    M.Just_a_test_deletion.objects.create("name" => "ci-filter-b", "test_result" => 2, "test_result_set_default" => nothing)

    df = M.Just_a_test_deletion.objects.order_by("id") |> DataFrame
    rename!(df, "id" => "ID", "name" => "NAME")
    df[1, "NAME"] = "ci-filter-a-updated"
    df[2, "NAME"] = "ci-filter-b-updated"

    bulk_update(
        M.Just_a_test_deletion.objects,
        df,
        columns = ["name"],
        filters = ["id"],
    )

    rows = M.Just_a_test_deletion.objects.order_by("id").list()
    @test rows[1][:name] == "ci-filter-a-updated"
    @test rows[2][:name] == "ci-filter-b-updated"

    M.Just_a_test_deletion.objects.delete(allow_delete_all=true)
end

# ─────────────────────────────────────────────────────────────────────────────
# Bulk Update: missing DataFrame columns fail with clear caller-facing errors
#
# Both error branches are important in practice:
#   1. explicit filters=["id"] but the DF has no id column
#   2. filters omitted, so PK inference runs, but the DF still has no id column
# Neither path should touch the database.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Bulk Update missing filter and PK columns error clearly" begin
    M.Just_a_test_deletion.objects.exists() &&
        M.Just_a_test_deletion.objects.delete(allow_delete_all=true)
    M.Just_a_test_deletion.objects.create("name" => "missing-col-sentinel", "test_result" => 7, "test_result_set_default" => nothing)

    try
        missing_filter_df = DataFrame(name = ["should-not-land"])
        err_filter = try
            bulk_update(
                M.Just_a_test_deletion.objects,
                missing_filter_df,
                columns = ["name"],
                filters = ["id"],
            )
            nothing
        catch e
            e
        end

        @test err_filter isa ArgumentError
        @test occursin("filter column", lowercase(sprint(showerror, err_filter)))
        @test occursin("id", lowercase(sprint(showerror, err_filter)))

        missing_pk_df = DataFrame(name = ["should-not-land-either"])
        err_pk = try
            bulk_update(
                M.Just_a_test_deletion.objects,
                missing_pk_df,
                columns = ["name"],
            )
            nothing
        catch e
            e
        end

        @test err_pk isa ArgumentError
        @test occursin("primary key column", lowercase(sprint(showerror, err_pk)))
        @test occursin("id", lowercase(sprint(showerror, err_pk)))

        sentinel = M.Just_a_test_deletion.objects.filter("test_result" => 7).list() |> first
        @test sentinel[:name] == "missing-col-sentinel"
    finally
        M.Just_a_test_deletion.objects.exists() &&
            M.Just_a_test_deletion.objects.delete(allow_delete_all=true)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Bulk Update: pre-applied query filters are cleared before rebuilding WHERE
#
# bulk_update intentionally ignores any filters already attached to the query
# object and rebuilds the WHERE clause from filters=. Use a query with a stale
# no-match predicate so the only way rows 2 and 3 update is if the reset path
# runs and the new static filter is the only predicate that survives.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Bulk Update rebuilds filters instead of inheriting stale query state" begin
    M.Just_a_test_deletion.objects.exists() &&
        M.Just_a_test_deletion.objects.delete(allow_delete_all=true)

    try
        M.Just_a_test_deletion.objects.create("name" => "reset-a", "test_result" => 1, "test_result_set_default" => nothing)
        M.Just_a_test_deletion.objects.create("name" => "reset-b", "test_result" => 2, "test_result_set_default" => nothing)
        M.Just_a_test_deletion.objects.create("name" => "reset-c", "test_result" => 3, "test_result_set_default" => nothing)

        df = M.Just_a_test_deletion.objects.order_by("id") |> DataFrame
        df[1, :name] = "reset-a-attempted"
        df[2, :name] = "reset-b-updated"
        df[3, :name] = "reset-c-updated"

        stale_query = M.Just_a_test_deletion.objects
        stale_query.filter("name" => "definitely-no-match")

        bulk_update(
            stale_query,
            df,
            columns = ["name"],
            filters = ["id", "test_result__@in" => [2, 3]],
        )

        rows = M.Just_a_test_deletion.objects.order_by("test_result").list()
        @test rows[1][:name] == "reset-a"
        @test rows[2][:name] == "reset-b-updated"
        @test rows[3][:name] == "reset-c-updated"
    finally
        M.Just_a_test_deletion.objects.exists() &&
            M.Just_a_test_deletion.objects.delete(allow_delete_all=true)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Bulk Update: copy flag controls whether caller DataFrames are mutated
#
# The default copy=true deep-copies df_o before processing so the caller's
# DataFrame is never modified by ORM-side auto-population. Use the
# Django_contract_scratch model here because updated_at has auto_now=true, so
# _prepare_bulk_df! will inject an updated_at column during bulk_update.
# That makes the copy/no-copy distinction externally visible.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Bulk Update copy flag controls caller DataFrame mutation" begin
    safe_label = "copy-flag-safe-9903"
    inplace_label = "copy-flag-inplace-9904"

    M.Django_contract_scratch.objects.filter("label" => safe_label).exists() &&
        M.Django_contract_scratch.objects.filter("label" => safe_label).delete()
    M.Django_contract_scratch.objects.filter("label" => inplace_label).exists() &&
        M.Django_contract_scratch.objects.filter("label" => inplace_label).delete()

    try
        safe_row = M.Django_contract_scratch.objects.create("label" => safe_label, "price" => "10.50")
        df_safe = DataFrame(id = [safe_row[:id]], price = ["11.50"])
        @test !("updated_at" in names(df_safe))

        bulk_update(
            M.Django_contract_scratch.objects,
            df_safe,
            columns = ["price"],
            filters = ["id"],
            copy    = true,
        )

        @test !("updated_at" in names(df_safe))

        safe_persisted = M.Django_contract_scratch.objects.filter("label" => safe_label).values("price", "updated_at").list() |> first
        @test parse(Float64, string(safe_persisted[:price])) == 11.5
        @test !(safe_persisted[:updated_at] === nothing || ismissing(safe_persisted[:updated_at]))

        inplace_row = M.Django_contract_scratch.objects.create("label" => inplace_label, "price" => "20.50")
        df_inplace = DataFrame(id = [inplace_row[:id]], price = ["21.50"])
        @test !("updated_at" in names(df_inplace))

        bulk_update(
            M.Django_contract_scratch.objects,
            df_inplace,
            columns = ["price"],
            filters = ["id"],
            copy    = false,
        )

        @test "updated_at" in names(df_inplace)
        @test all(x -> !(x === nothing || ismissing(x)), df_inplace[!, "updated_at"])

        inplace_persisted = M.Django_contract_scratch.objects.filter("label" => inplace_label).values("price", "updated_at").list() |> first
        @test parse(Float64, string(inplace_persisted[:price])) == 21.5
        @test !(inplace_persisted[:updated_at] === nothing || ismissing(inplace_persisted[:updated_at]))

    finally
        M.Django_contract_scratch.objects.filter("label" => safe_label).exists() &&
            M.Django_contract_scratch.objects.filter("label" => safe_label).delete()
        M.Django_contract_scratch.objects.filter("label" => inplace_label).exists() &&
            M.Django_contract_scratch.objects.filter("label" => inplace_label).delete()
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Bulk Update: show_query inspection modes work on the scratch FK model
#
# The :dict, :sql, and :params modes must return structured results without
# hitting the database — the same contract as single update(show_query=...).
# The multi-chunk :dict path (length(results) > 1) must return a Vector while
# the single-chunk path returns the Dict directly.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Bulk Update show_query inspection modes" begin
    _clear_bulk_update_scratch_rows!()

    try
        required_ids, optional_ids = _seed_bulk_update_scratch_parents!(
            ["insp-req"],
            ["insp-opt"],
        )

        rows = [
            M.Bulk_update_payload_scratch.objects.create(
                "label"              => "insp-$(i)",
                "required_parent_id" => required_ids["insp-req"],
                "optional_parent_id" => optional_ids["insp-opt"],
                "event_date"         => Date(2025, 1, i),
                "is_active"          => false,
            )
            for i in 1:3
        ]

        df = DataFrame(
            id    = [r[:id] for r in rows],
            label = ["insp-$(i)-dry" for i in 1:3],
        )

        # ── :dict mode — single chunk (chunk_size=1000 > 3 rows) ─────────────
        result_dict = bulk_update(
            M.Bulk_update_payload_scratch.objects,
            df,
            columns    = ["label"],
            filters    = ["id"],
            show_query = :dict,
        )
        # Single chunk → direct Dict, not Vector{Dict}
        @test result_dict isa Dict
        @test result_dict[:operation] == :update
        @test occursin("update", lowercase(result_dict[:sql_text]))

        # ── :inspection mode — alias of :dict with the same metadata contract ─
        inspection_result = bulk_update(
            M.Bulk_update_payload_scratch.objects,
            df,
            columns    = ["label"],
            filters    = ["id"],
            show_query = :inspection,
        )
        @test inspection_result isa Dict
        @test inspection_result[:operation] == :update
        @test occursin("update", lowercase(inspection_result[:sql_text]))

        # DB must be untouched — labels still "insp-N" not "insp-N-dry"
        live = M.Bulk_update_payload_scratch.objects.order_by("id").list()
        @test [row[:label] for row in live] == ["insp-$(i)" for i in eachindex(live)]

        # ── :dict mode — multi-chunk path returns Vector ──────────────────────
        result_vec = bulk_update(
            M.Bulk_update_payload_scratch.objects,
            df,
            columns    = ["label"],
            filters    = ["id"],
            show_query = :dict,
            chunk_size = 1,   # forces 3 separate chunks → Vector of 3 dicts
        )
        @test result_vec isa Vector
        @test length(result_vec) == 3
        @test all(chunk_result -> chunk_result isa Dict && chunk_result[:operation] == :update, result_vec)

        # ── :sql mode ─────────────────────────────────────────────────────────
        sql_result = bulk_update(
            M.Bulk_update_payload_scratch.objects,
            df,
            columns    = ["label"],
            filters    = ["id"],
            show_query = :sql,
        )
        @test sql_result isa String
        @test occursin("update", lowercase(sql_result))

        # ── :params mode ──────────────────────────────────────────────────────
        params_result = bulk_update(
            M.Bulk_update_payload_scratch.objects,
            df,
            columns    = ["label"],
            filters    = ["id"],
            show_query = :params,
        )
        @test params_result isa Vector
        # Parameters must include at least the label values and the id values.
        @test length(params_result) >= length(rows)

        # ── :none mode — build the statement, return nothing, execute nothing ─
        none_result = bulk_update(
            M.Bulk_update_payload_scratch.objects,
            df,
            columns    = ["label"],
            filters    = ["id"],
            show_query = :none,
        )
        @test isnothing(none_result)

        # Final sanity: no inspection call wrote to the DB.
        live_final = M.Bulk_update_payload_scratch.objects.order_by("id").list()
        @test [row[:label] for row in live_final] == ["insp-$(i)" for i in eachindex(live_final)]

    finally
        _clear_bulk_update_scratch_rows!()
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Bulk Update: all-missing optional FK column writes NULL to every row
#
# When an entire column in the update DataFrame is `missing`, the ORM must
# write NULL for every row rather than skipping the column or erroring.
# This closes a gap left by the zero-sentinel test where only one row was
# given a bad value; here all rows receive `missing` for the nullable column.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Bulk Update all-missing optional FK column nulls every row" begin
    _clear_bulk_update_scratch_rows!()

    try
        required_ids, optional_ids = _seed_bulk_update_scratch_parents!(
            ["null-req-a", "null-req-b"],
            ["null-opt-a", "null-opt-b"],
        )

        seeded = [
            M.Bulk_update_payload_scratch.objects.create(
                "label"              => "null-col-$(i)",
                "required_parent_id" => required_ids["null-req-a"],
                "optional_parent_id" => optional_ids["null-opt-a"],
                "event_date"         => Date(2025, 6, i),
                "is_active"          => true,
            )
            for i in 1:3
        ]

        # All rows carry missing for optional_parent_id — the entire column is NULL.
        df = DataFrame(
            id                 = [r[:id] for r in seeded],
            optional_parent_id = [missing, missing, missing],
        )

        bulk_update(
            M.Bulk_update_payload_scratch.objects,
            df,
            columns = ["optional_parent_id"],
            filters = ["id"],
        )

        persisted = M.Bulk_update_payload_scratch.objects.order_by("id").list()
        @test all(row -> row[:optional_parent_id] === nothing || ismissing(row[:optional_parent_id]), persisted)
        @test all(row -> row[:required_parent_id] == required_ids["null-req-a"], persisted)
        @test all(row -> _bulk_update_scratch_to_bool(row[:is_active]) == true, persisted)

    finally
        _clear_bulk_update_scratch_rows!()
    end
end
