if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

@testset "Bulk Validation and Type Normalization" begin
    # These tests exercise the shared validation path used by bulk_insert and bulk_update.
    # The goal is to pin down the new strict policy: bulk operations must reject type
    # mismatches before SQL execution rather than silently coercing values.
    base_query = M.Just_a_test_deletion.objects
    base_query |> do_exists && delete(base_query; allow_delete_all = true)

    @testset "bulk_insert rejects Float64 for integer-backed fields" begin
        # The `test_result` field is a ForeignKey backed by BIGINT. A Float64 like 14.0 used
        # to be silently coerced in the bulk DataFrame preparation path. We now require the
        # caller to provide an actual integer representation so row intent stays explicit.
        df_bad = DataFrames.DataFrame(name = ["bad-float"], test_result = [14.0])

        query = M.Just_a_test_deletion.objects
        err = try
            bulk_insert(query, df_bad)
            nothing
        catch e
            e
        end

        @test err !== nothing
        @test occursin("bulk_insert", string(err))
        @test occursin("test_result", string(err))
        @test occursin("expected Int64 or an integer string", string(err))
        @test query.count() == 0
    end

    @testset "bulk_insert allows missing for nullable fields and rejects missing for required fields" begin
        # `test_result` is nullable, so a missing value should survive validation and round-trip.
        # This matters for fixture imports where optional foreign keys are intentionally absent.
        query = M.Just_a_test_deletion.objects
        df_nullable = DataFrames.DataFrame(name = ["nullable-ok"], test_result = [missing])
        bulk_insert(query, df_nullable)

        row = M.Just_a_test_deletion.objects.filter("name" => "nullable-ok") |> list |> first
        @test ismissing(row[:test_result]) || isnothing(row[:test_result])

        # `name` is required, so missing must fail before the database sees the row. That keeps
        # the error anchored to the field definition instead of a downstream constraint failure.
        df_required = DataFrames.DataFrame(name = [missing], test_result = [missing])

        err = try
            bulk_insert(query, df_required)
            nothing
        catch e
            e
        end

        @test err !== nothing
        @test occursin("name", string(err))
        @test occursin("null values are not allowed", string(err))
        @test M.Just_a_test_deletion.objects.filter("name" => "nullable-ok").count() == 1
    end

    @testset "bulk_update keeps nullable semantics and rejects type mismatches" begin
        # We seed a valid row, then verify two update paths:
        # 1. Setting an optional field to missing should succeed.
        # 2. Passing a Float64 into an integer-backed field should fail without partial writes.
        query = M.Just_a_test_deletion.objects
        query |> do_exists && delete(query; allow_delete_all = true)
        query.create("name" => "update-target", "test_result" => 1, "test_result2" => 2)

        current = M.Just_a_test_deletion.objects.filter("name" => "update-target") |> DataFrame
        nullable_update = DataFrames.DataFrame(id = current.id, test_result2 = [missing])
        bulk_update(query, nullable_update, columns = ["test_result2", "id"], filters = ["id"])

        updated = M.Just_a_test_deletion.objects.filter("name" => "update-target") |> list |> first
        @test ismissing(updated[:test_result2]) || isnothing(updated[:test_result2])

        bad_update = DataFrames.DataFrame(id = current.id, test_result = [22.0])
        err = try
            bulk_update(query, bad_update, columns = ["test_result", "id"], filters = ["id"])
            nothing
        catch e
            e
        end

        @test err !== nothing
        @test occursin("bulk_update", string(err))
        @test occursin("test_result", string(err))
        @test occursin("expected Int64 or an integer string", string(err))

        unchanged = M.Just_a_test_deletion.objects.filter("name" => "update-target") |> list |> first
        @test unchanged[:test_result] == 1
    end
end

# bulk_copy is a PostgreSQL-only feature (COPY protocol)
if adapter_name == "SQLite"
    @info "Skipping bulk_copy tests for SQLite (not supported)"
    return true
else

@testset "PostgreSQL COPY Protocol (bulk_copy)" begin
    # Use the auxiliary model for destructive tests
    query = M.Just_a_test_deletion.objects
    
    # 1. Clean up
    query |> do_exists && delete(query; allow_delete_all = true)
    @test query.count() == 0

    # 2. Create a DataFrame for bulk copy
    data = [
        (name = "Copy Test 1", test_result = 100),
        (name = "Copy Test 2", test_result = 200),
        (name = "Copy Test 3", test_result = 300),
        (name = "Copy Test 4", test_result = 400),
        (name = "Copy Test 5", test_result = 500)
    ]
    df = DataFrames.DataFrame(data)

    # 3. Execute bulk_copy
    bulk_copy(query, df)

    # 4. Verify results
    @test query.count() == 5
    
    # Check specific values
    results = query.order_by("test_result") |> DataFrame
    @test results[1, :name] == "Copy Test 1"
    @test results[1, :test_result] == 100
    @test results[5, :name] == "Copy Test 5"
    @test results[5, :test_result] == 500

    # 5. Test with column mapping
    delete(query, allow_delete_all = true)
    df_mapped = DataFrames.DataFrame(
        raw_name = ["Mapped 1", "Mapped 2"],
        raw_val = [10, 20]
    )
    bulk_copy(query, df_mapped, columns = ["raw_name" => "name", "raw_val" => "test_result"])
    @test query.count() == 2
    @test query.filter("name" => "Mapped 1").count() == 1

    # 6. Test with automated sequence update
    # Fetch current IDs to see where we are
    last_id = query.order_by("-id").values("id") |> list |> first |> x -> x[:id]
    
    # Create a new row via standard create() to ensure sequence didn't break
    new_row = query.create("name" => "Sequence check", "test_result" => 999)
    @test new_row[:id] > last_id

end

@testset "SQL Injection Protection (bulk_copy)" begin
    # This test verifies that bulk_copy is safe from SQL injection attacks.
    # We attempt to insert data containing SQL metacharacters and verify they
    # are stored as literal strings, not executed.
    query = M.Just_a_test_deletion.objects
    
    # Clean up from any previous test runs
    try
        query |> do_exists && delete(query; allow_delete_all = true)
    catch
        # Ignore errors if table doesn't exist yet
    end
    @test (query.count()) == 0

    # Test vectors: strings that would exploit SQL injection if not properly escaped
    injection_vectors = [
        (name = "'; DROP TABLE just_a_test_deletion; --", test_result = 1),
        (name = "\" OR \"1\"=\"1", test_result = 2),
        (name = "test\nwith\nnewlines", test_result = 3),
        (name = "test,with,commas", test_result = 4),
        (name = "test\"with\"quotes", test_result = 5),
        (name = "test'with'single", test_result = 6),
        (name = "UNION SELECT * FROM drivers", test_result = 7),
        (name = "test`with`backticks", test_result = 8),
        (name = "test\\with\\backslash", test_result = 9),
    ]
    df_injection = DataFrames.DataFrame(injection_vectors)

    # Execute bulk_copy with malicious-looking data
    bulk_copy(query, df_injection)

    # Verify: 1) All rows inserted successfully (table still exists)
    count_after_insert = query.count()
    @test count_after_insert == 9

    # Verify: 2) Data round-trips correctly without SQL execution
    results = query.order_by("test_result") |> DataFrame
    for (i, vector) in enumerate(injection_vectors)
        retrieved = results[i, :name]
        expected = vector.name
        @test retrieved == expected
    end

    # Verify: 3) Attempt to filter by one of the suspicious strings succeeds
    suspicious_name = "'; DROP TABLE just_a_test_deletion; --"
    found = query.filter("name" => suspicious_name).count()
    @test found == 1

    # Verify: 4) Original table structure is intact (no actual DROP was executed)
    # Recount to make sure rows haven't been deleted
    final_count = M.Just_a_test_deletion.objects.count()
    @test final_count == 9 

  
end

@testset "COPY Validation and Missing Handling" begin
    query = M.Just_a_test_deletion.objects
    query |> do_exists && delete(query; allow_delete_all = true)

    # This confirms COPY respects the same nullable-field policy as bulk_insert. We allow
    # missing on `test_result` because the model marks that foreign key as nullable.
    df_nullable = DataFrames.DataFrame(name = ["copy-nullable"], test_result = [missing])
    bulk_copy(query, df_nullable)
    row = query.filter("name" => "copy-nullable") |> list |> first
    @test ismissing(row[:test_result]) || isnothing(row[:test_result])

    # Required-field failures should be reported before the COPY stream is sent, otherwise the
    # user only sees a generic database error with no direct link back to the offending field.
    df_required = DataFrames.DataFrame(name = [missing], test_result = [missing])
    err_required = try
        bulk_copy(query, df_required)
        nothing
    catch e
        e
    end
    @test err_required !== nothing
    @test occursin("bulk_copy", string(err_required))
    @test occursin("name", string(err_required))
    @test occursin("null values are not allowed", string(err_required))

    # Float64 for a BIGINT-backed foreign key must also fail before COPY reaches PostgreSQL.
    df_bad_type = DataFrames.DataFrame(name = ["copy-bad-float"], test_result = [12.0])
    err_type = try
        bulk_copy(query, df_bad_type)
        nothing
    catch e
        e
    end
    @test err_type !== nothing
    @test occursin("test_result", string(err_type))
    @test occursin("expected Int64 or an integer string", string(err_type))
end

end # End of if adapter_name != "SQLite"

