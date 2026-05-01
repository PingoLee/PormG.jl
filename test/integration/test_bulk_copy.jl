if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

@testset "Bulk Validation and Type Normalization" begin
    # These tests exercise the shared validation path used by bulk_insert and bulk_update.
    # The goal is to pin down the new strict policy: bulk operations must reject type
    # mismatches before SQL execution rather than silently coercing values.
    base_query = M.Just_a_test_deletion.objects
    base_query.exists() && base_query.delete(allow_delete_all = true)

    @testset "empty bulk_insert and bulk_update are no-ops" begin
        query = M.Just_a_test_deletion.objects
        query.exists() && query.delete(allow_delete_all = true)
        try
            query.create("name" => "empty-bulk-sentinel", "test_result" => 1)

            initial_count = query.count()

            empty_insert = DataFrames.DataFrame(
                name = String[],
                test_result = Int64[]
            )
            @test isnothing(bulk_insert(query, empty_insert))
            @test M.Just_a_test_deletion.objects.count() == initial_count

            empty_update = DataFrames.DataFrame(
                id = Int64[],
                name = String[]
            )
            @test isnothing(bulk_update(query, empty_update, columns = ["name"], filters = ["id"]))

            persisted = M.Just_a_test_deletion.objects.filter("name" => "empty-bulk-sentinel").list() |> first
            @test persisted[:name] == "empty-bulk-sentinel"
            @test M.Just_a_test_deletion.objects.count() == initial_count
        finally
            query = M.Just_a_test_deletion.objects
            query.exists() && query.delete(allow_delete_all = true)
        end
    end

    @testset "bulk_insert rejects Float64 for integer-backed fields" begin
        # The `test_result` field is a ForeignKey backed by BIGINT. A Float64 like 14.0 used
        # to be silently coerced in the bulk DataFrame preparation path. We now require the
        # caller to provide an actual integer representation so row intent stays explicit.
        query = M.Just_a_test_deletion.objects
        query.exists() && query.delete(allow_delete_all = true)

        df_bad = DataFrames.DataFrame(name = ["bad-float"], test_result = [14.0])

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
        query.exists() && query.delete(allow_delete_all = true)
        df_nullable = DataFrames.DataFrame(name = ["nullable-ok"], test_result = [missing])
        bulk_insert(query, df_nullable)

        row = M.Just_a_test_deletion.objects.filter("name" => "nullable-ok").list() |> first
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
        query.exists() && query.delete(allow_delete_all = true)
        query.create("name" => "update-target", "test_result" => 1, "test_result2" => 2)

        current = M.Just_a_test_deletion.objects.filter("name" => "update-target") |> DataFrame
        nullable_update = DataFrames.DataFrame(id = current.id, test_result2 = [missing])
        bulk_update(query, nullable_update, columns = ["test_result2", "id"], filters = ["id"])

        updated = M.Just_a_test_deletion.objects.filter("name" => "update-target").list() |> first
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

        unchanged = M.Just_a_test_deletion.objects.filter("name" => "update-target").list() |> first
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
    query.exists() && query.delete(allow_delete_all = true)
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
    query.delete(allow_delete_all = true)
    df_mapped = DataFrames.DataFrame(
        raw_name = ["Mapped 1", "Mapped 2"],
        raw_val = [10, 20]
    )
    bulk_copy(query, df_mapped, columns = ["raw_name" => "name", "raw_val" => "test_result"])
    @test query.count() == 2
    @test query.filter("name" => "Mapped 1").count() == 1

    # 6. Test with automated sequence update
    # Fetch current IDs to see where we are
    last_id = query.order_by("-id").values("id").list() |> first |> x -> x[:id]
    
    # Create a new row via standard create() to ensure sequence didn't break
    new_row = query.create("name" => "Sequence check", "test_result" => 999)
    @test new_row[:id] > last_id

end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL COPY: Blank Auto PK Columns
#
# COPY should follow the same contract as bulk_insert for auto-generated
# primary keys. A DataFrame that carries an all-blank id column should still
# let PostgreSQL allocate ids, and the sequence must remain usable for the
# next create() call.
# ─────────────────────────────────────────────────────────────────────────────
@testset "bulk_copy omits blank auto-generated primary keys" begin
    cleanup_names = [
        "copy-blank-pk-a",
        "copy-blank-pk-b",
        "copy-blank-pk-c"
    ]

    cleanup = M.Django_contract_scratch.objects
    cleanup.filter("label__@in" => cleanup_names)
    cleanup.exists() && cleanup.delete()

    try
        df_blank_pk = DataFrames.DataFrame(
            id = Union{Missing, Int64}[missing, missing],
            label = ["copy-blank-pk-a", "copy-blank-pk-b"]
        )

        @test all(ismissing, df_blank_pk.id)

        bulk_copy(M.Django_contract_scratch.objects, df_blank_pk)

        inserted = M.Django_contract_scratch.objects.filter(
            "label__@in" => ["copy-blank-pk-a", "copy-blank-pk-b"]
        ).order_by(
            "label"
        ).values(
            "id", "label"
        ).list()

        inserted_ids = [row[:id] for row in inserted]

        @test length(inserted) == 2
        @test all(id -> id isa Integer && id > 0, inserted_ids)
        @test length(unique(inserted_ids)) == 2
        @test all(ismissing, df_blank_pk.id)

        next_row = M.Django_contract_scratch.objects.create(
            "label" => "copy-blank-pk-c"
        )
        @test next_row[:id] > maximum(inserted_ids)
    finally
        cleanup = M.Django_contract_scratch.objects
        cleanup.filter("label__@in" => cleanup_names)
        cleanup.exists() && cleanup.delete()
    end
end

@testset "bulk_copy: empty DataFrame is a no-op" begin
    query = M.Just_a_test_deletion.objects
    query.exists() && query.delete(allow_delete_all = true)
    query.create("name" => "copy-empty-sentinel", "test_result" => 1)

    initial_count = query.count()
    empty_copy = DataFrames.DataFrame(
        name = String[],
        test_result = Int64[]
    )

    @test isnothing(bulk_copy(query, empty_copy))
    @test query.count() == initial_count
    @test query.filter("name" => "copy-empty-sentinel").count() == 1
end

@testset "bulk_copy: duplicate-key failure rolls back the whole batch" begin
    query = M.Status.objects
    scratch_ids = collect(310001:320000)
    duplicate_id = first(scratch_ids)

    cleanup = M.Status.objects
    cleanup.filter("statusid__@in" => scratch_ids)
    cleanup.exists() && cleanup.delete()

    try
        df_duplicate = DataFrames.DataFrame(
            statusid = vcat(scratch_ids, duplicate_id),
            status = vcat(["copy-batch-$(id)" for id in scratch_ids], ["copy-batch-duplicate"])
        )

        err = try
            Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
                bulk_copy(query, df_duplicate)
            end
            nothing
        catch e
            e
        end

        @test err !== nothing
        @test any(token -> occursin(token, lowercase(string(err))), ["unique", "duplicate", "constraint"])
        @test M.Status.objects.filter("statusid__@in" => scratch_ids).count() == 0
    finally
        cleanup = M.Status.objects
        cleanup.filter("statusid__@in" => scratch_ids)
        cleanup.exists() && cleanup.delete()
    end
end

@testset "SQL Injection Protection (bulk_copy)" begin
    # This test verifies that bulk_copy is safe from SQL injection attacks.
    # We attempt to insert data containing SQL metacharacters and verify they
    # are stored as literal strings, not executed.
    query = M.Just_a_test_deletion.objects
    
    # Clean up from any previous test runs
    try
        query.exists() && query.delete(allow_delete_all = true)
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
    query.exists() && query.delete(allow_delete_all = true)

    # This confirms COPY respects the same nullable-field policy as bulk_insert. We allow
    # missing on `test_result` because the model marks that foreign key as nullable.
    df_nullable = DataFrames.DataFrame(name = ["copy-nullable"], test_result = [missing])
    bulk_copy(query, df_nullable)
    row = query.filter("name" => "copy-nullable").list() |> first
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

