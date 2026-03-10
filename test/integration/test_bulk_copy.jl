if !isdefined(Main, :PormG)
    include("common_setup.jl")
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

end # End of if adapter_name != "SQLite"
