if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# A PostgreSQL TIMESTAMPTZ comes back as a ZonedDateTime rendered in the *session* zone, so the
# #114 testset below normalizes to a UTC instant before comparing. common_setup.jl does not load
# TimeZones (test_django_contract.jl imports it the same way for the same reason).
using TimeZones

# ─────────────────────────────────────────────────────────────────────────────
# Foreign-key fixtures (#323)
#
# `Just_a_test_deletion.test_result` and `.test_result2` are foreign keys onto
# `Result.resultid`. Every integer this file used to write into them silently asserted that
# one particular F1-seeded result row existed right now — true only when
# `test_database_setup.jl` had already run, since that is the only place `result` is
# populated (it wipes the table and reloads it from `f1/results.csv`).
#
# That is what made the file order-dependent — though not in the way it first looks. Earlier
# tests do not delete those particular rows: after a full green suite, every id this file used
# to hard-code (1, 2, 3-9, 10, 20, 100-500, 999) is still present. The real coupling is that
# `result` is populated by that one seeding step and nothing else, so any run which rebuilds
# the schema without reaching it — an interrupted suite, or `test_migration_bootstrap.jl` on
# its own, which drops and recreates every table — leaves the table empty and every literal
# here dangling.
#
# Borrow the ids that actually exist rather than naming them. A `Result` row cannot be
# conjured up here — `raceid`, `driverid` and `constructorid` are non-null foreign keys of
# their own — but these ids are only ever read, never deleted, so borrowing needs no
# teardown. Ascending order matters: the `order_by("test_result")` read-backs below rely on
# the ids sorting the same way as the DataFrame rows that carry them.
# ─────────────────────────────────────────────────────────────────────────────
_bulk_copy_fk_query = M.Result.objects
_bulk_copy_fk_query.order_by("resultid")
_bulk_copy_fk_query.limit(9)
_bulk_copy_fk_query.values("resultid")
_bulk_copy_fk_rows = _bulk_copy_fk_query.list()

# Fail loudly and actionably. Without this the symptom is a raw ForeignKeyViolation naming a
# constraint, which reads like a regression in whatever you were working on — exactly the
# false alarm #323 was filed for (it cost a comparison run against main during #320).
length(_bulk_copy_fk_rows) == 9 || error(
    "test_bulk_copy.jl needs at least 9 rows in `result` to use as foreign-key targets, " *
    "but found $(length(_bulk_copy_fk_rows)) in \"$(PORMG_DB_FOLDER)\". The F1 fixtures are " *
    "not seeded. Run `julia -t auto --project=. test/integration/runtests.jl` first.")

_bulk_copy_fk_ids = [row[:resultid] for row in _bulk_copy_fk_rows]

# One dependency this file cannot borrow its way out of: `test_result_set_default` is declared
# `ForeignKey(Result, …, default = 1)`, and PormG writes a static default on every insert path —
# `create()` fills it when the key is absent (execution.jl), and the bulk paths add a whole
# column of it when the field is missing from the DataFrame (execution_bulk.jl). Supplying an
# explicit `missing` does not help either: the bulk path rewrites missing/nothing back to the
# default. So every row this file inserts into `just_a_test_deletion` carries
# `test_result_set_default = 1` and needs `resultid = 1` to exist, whatever the other FK
# columns say.
#
# Assert it here rather than let it surface as a ForeignKeyViolation naming a constraint no
# test mentions. Dodging it instead would mean threading a real id through three DataFrames
# that have nothing to do with defaults (and adding a third entry to the column-mapping test),
# which distorts what those tests read as. The asymmetry — `create()` honours an explicit
# `nothing`, the bulk path overwrites it with the default — is a PormG-level quirk, not a
# test-fixture one, and is tracked in #331 rather than worked around here.
M.Result.objects.filter("resultid" => 1).count() == 1 || error(
    "test_bulk_copy.jl requires `result.resultid = 1` to exist in \"$(PORMG_DB_FOLDER)\": " *
    "`Just_a_test_deletion.test_result_set_default` defaults to 1, and PormG writes that " *
    "default on every insert, so every row inserted here references it. " *
    "Run `julia -t auto --project=. test/integration/runtests.jl` to seed the F1 fixtures.")

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
            query.create("name" => "empty-bulk-sentinel", "test_result" => _bulk_copy_fk_ids[1])

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
            @test isnothing(bulk_update(query, empty_update, columns = ["name"], match_on = ["id"]))

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
        query.create("name" => "update-target",
                     "test_result"  => _bulk_copy_fk_ids[1],
                     "test_result2" => _bulk_copy_fk_ids[2])

        current = M.Just_a_test_deletion.objects.filter("name" => "update-target") |> DataFrame
        nullable_update = DataFrames.DataFrame(id = current.id, test_result2 = [missing])
        bulk_update(query, nullable_update, columns = ["test_result2", "id"], match_on = ["id"])

        updated = M.Just_a_test_deletion.objects.filter("name" => "update-target").list() |> first
        @test ismissing(updated[:test_result2]) || isnothing(updated[:test_result2])

        bad_update = DataFrames.DataFrame(id = current.id, test_result = [22.0])
        err = try
            bulk_update(query, bad_update, columns = ["test_result", "id"], match_on = ["id"])
            nothing
        catch e
            e
        end

        @test err !== nothing
        @test occursin("bulk_update", string(err))
        @test occursin("test_result", string(err))
        @test occursin("expected Int64 or an integer string", string(err))

        unchanged = M.Just_a_test_deletion.objects.filter("name" => "update-target").list() |> first
        @test unchanged[:test_result] == _bulk_copy_fk_ids[1]
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# BinaryField payloads through bulk_insert and bulk_update, on BOTH backends (#296)
#
# These sit ABOVE the PostgreSQL-only guard on purpose. The bulk paths reach the driver
# differently per backend — PostgreSQL casts each source column as
# `source."col"::<pg type>` inside an UPDATE … FROM (VALUES …) CTE, SQLite binds `?`
# placeholders into the same CTE shape with no cast at all — so a fix verified on one
# backend proves nothing about the other. bulk_copy's own binary coverage stays below the
# guard, because COPY genuinely is PostgreSQL-only.
#
# The payload carries high bytes and an embedded NUL: that is what separates a real
# BLOB/bytea from a TEXT column that merely looks like it works.
# ─────────────────────────────────────────────────────────────────────────────
@testset "bulk_insert/bulk_update: BinaryField payloads round-trip byte-for-byte" begin
    payload = UInt8[0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0xC3, 0x28]
    updated = UInt8[0x00, 0x01, 0xFE, 0xFF, 0x00]
    slug = "bulk-binary-shared-990701"

    scratch = () -> M.Field_validation_scratch.objects
    _purge = () -> begin
        q = scratch()
        q.filter("slug" => slug)
        q.exists() && q.delete()
    end
    _purge()

    try
        # ── bulk_insert ───────────────────────────────────────────────────────
        df = DataFrames.DataFrame(
            uuid_token    = ["dddddddd-0000-0000-0000-000000009701"],
            canonical_url = ["https://example.com/f1/bulk-binary-shared"],
            slug          = [slug],
            blob_payload  = [payload],
        )
        bulk_insert(scratch(), df)

        stored = scratch().filter("slug" => slug).values("blob_payload").list() |> first
        @test stored[:blob_payload] isa AbstractVector{UInt8}
        @test collect(stored[:blob_payload]) == payload

        # ── bulk_update ───────────────────────────────────────────────────────
        # A different payload, so a no-op update cannot masquerade as success.
        update_df = DataFrames.DataFrame(slug = [slug], blob_payload = [updated])
        bulk_update(M.Field_validation_scratch, update_df;
                    columns = ["blob_payload", "slug"], match_on = ["slug"])

        after = scratch().filter("slug" => slug).values("blob_payload").list() |> first
        @test after[:blob_payload] isa AbstractVector{UInt8}
        @test collect(after[:blob_payload]) == updated
        @test collect(after[:blob_payload]) != payload
    finally
        _purge()
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
    # Ascending FK ids: the read-back below orders by this column, so the ids double as the
    # sort key that pins each row to its expected name.
    data = [
        (name = "Copy Test 1", test_result = _bulk_copy_fk_ids[1]),
        (name = "Copy Test 2", test_result = _bulk_copy_fk_ids[2]),
        (name = "Copy Test 3", test_result = _bulk_copy_fk_ids[3]),
        (name = "Copy Test 4", test_result = _bulk_copy_fk_ids[4]),
        (name = "Copy Test 5", test_result = _bulk_copy_fk_ids[5])
    ]
    df = DataFrames.DataFrame(data)

    # 3. Execute bulk_copy
    bulk_copy(query, df)

    # 4. Verify results
    @test query.count() == 5
    
    # Check specific values
    results = query.order_by("test_result") |> DataFrame
    @test results[1, :name] == "Copy Test 1"
    @test results[1, :test_result] == _bulk_copy_fk_ids[1]
    @test results[5, :name] == "Copy Test 5"
    @test results[5, :test_result] == _bulk_copy_fk_ids[5]

    # 5. Test with column mapping
    query = M.Just_a_test_deletion.objects
    query.delete(allow_delete_all = true)
    df_mapped = DataFrames.DataFrame(
        raw_name = ["Mapped 1", "Mapped 2"],
        raw_val = [_bulk_copy_fk_ids[1], _bulk_copy_fk_ids[2]]
    )
    bulk_copy(query, df_mapped, columns = ["raw_name" => "name", "raw_val" => "test_result"])
    @test M.Just_a_test_deletion.objects.count() == 2
    @test M.Just_a_test_deletion.objects.filter("name" => "Mapped 1").count() == 1

    # 6. Test with automated sequence update
    # Fetch current IDs to see where we are
    last_id = M.Just_a_test_deletion.objects.order_by("-id").values("id").list() |> first |> x -> x[:id]
    
    # Create a new row via standard create() to ensure sequence didn't break
    new_row = M.Just_a_test_deletion.objects.create("name" => "Sequence check",
                                                    "test_result" => _bulk_copy_fk_ids[1])
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

# ─────────────────────────────────────────────────────────────────────────────
# bulk_copy: binary payloads survive the CSV COPY stream byte-for-byte (#296)
# bulk_copy does not bind parameters — it formats each cell and streams CSV into
# `COPY … FROM STDIN`. A binary payload therefore takes a completely different route to
# the database than create()/bulk_insert, and reaches it as text: PostgreSQL's hex input
# syntax, which survives FORMAT CSV because backslash is not a CSV escape character. This
# asserts the two routes agree, which a shape-only check could not.
# ─────────────────────────────────────────────────────────────────────────────
@testset "bulk_copy: BinaryField payloads round-trip byte-for-byte" begin
    slug = "bulk-copy-binary-990601"
    # NUL, a high byte, and an invalid-UTF-8 pair — none of which survive a text round-trip.
    payload = UInt8[0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0xC3, 0x28]

    cleanup = M.Field_validation_scratch.objects
    cleanup.filter("slug" => slug)
    cleanup.exists() && cleanup.delete()

    try
        df = DataFrames.DataFrame(
            uuid_token = ["bbbbbbbb-0000-0000-0000-000000009601"],
            canonical_url = ["https://example.com/f1/bulk-copy-binary"],
            slug = [slug],
            blob_payload = [payload]
        )
        bulk_copy(M.Field_validation_scratch, df)

        stored = M.Field_validation_scratch.objects.filter("slug" => slug).
            values("blob_payload").list() |> first

        @test stored[:blob_payload] isa AbstractVector{UInt8}
        # Byte identity, not just "a row arrived" — the whole point is that COPY did not
        # mangle the payload into the Julia literal or a text encoding of it.
        @test collect(stored[:blob_payload]) == payload
    finally
        final_cleanup = M.Field_validation_scratch.objects
        final_cleanup.filter("slug" => slug)
        final_cleanup.exists() && final_cleanup.delete()
    end
end

@testset "bulk_copy: empty DataFrame is a no-op" begin
    query = M.Just_a_test_deletion.objects
    query.exists() && query.delete(allow_delete_all = true)
    query.create("name" => "copy-empty-sentinel", "test_result" => _bulk_copy_fk_ids[1])

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
    
    # Clean up from any previous test runs. Deliberately unguarded, like every other testset
    # in this file: a swallowed exception here does not make the run more robust, it makes the
    # diagnosis worse. If the delete fails the rows survive, and then four separate assertions
    # below (the count, the round-trip vector, and the final recount) report as plain failures
    # with the real cause discarded — the "a failure tells you nothing" symptom of #323.
    query.exists() && query.delete(allow_delete_all = true)
    @test (query.count()) == 0

    # Test vectors: strings that would exploit SQL injection if not properly escaped
    # `test_result` carries ascending FK ids purely as an ordering key: the read-back below
    # sorts on it so each escaped string can be pinned to its own slot.
    injection_vectors = [
        (name = "'; DROP TABLE just_a_test_deletion; --", test_result = _bulk_copy_fk_ids[1]),
        (name = "\" OR \"1\"=\"1", test_result = _bulk_copy_fk_ids[2]),
        (name = "test\nwith\nnewlines", test_result = _bulk_copy_fk_ids[3]),
        (name = "test,with,commas", test_result = _bulk_copy_fk_ids[4]),
        (name = "test\"with\"quotes", test_result = _bulk_copy_fk_ids[5]),
        (name = "test'with'single", test_result = _bulk_copy_fk_ids[6]),
        (name = "UNION SELECT * FROM drivers", test_result = _bulk_copy_fk_ids[7]),
        (name = "test`with`backticks", test_result = _bulk_copy_fk_ids[8]),
        (name = "test\\with\\backslash", test_result = _bulk_copy_fk_ids[9]),
    ]
    df_injection = DataFrames.DataFrame(injection_vectors)

    # Execute bulk_copy with malicious-looking data
    bulk_copy(query, df_injection)

    # Verify: 1) All rows inserted successfully (table still exists)
    count_after_insert = query.count()
    @test count_after_insert == 9

    # Verify: 2) Data round-trips correctly without SQL execution
    results = query.order_by("test_result") |> DataFrame
    @test collect(results.name) == [vector.name for vector in injection_vectors]

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

# ─────────────────────────────────────────────────────────────────────────────
# bulk_copy data fidelity (#86)
# bulk_copy must store the SAME values as bulk_insert / create(): it now serializes
# through the field formatter (so a naive DateTime becomes UTC, matching the other
# paths) and it disambiguates an empty string from NULL (an unquoted \N sentinel is
# NULL; a quoted "" is the empty string). Pre-fix, bulk_copy wrote the raw DataFrame
# values (naive datetime) and let "" collapse to NULL — a silent divergence.
#
# Scope note (#114): only the empty-string ↔ NULL half below is mutation-guarded. Under a UTC
# session the datetime assertions here cannot fail — see the "#114" testset further down, which
# is the one that actually catches a regression of the formatter application.
# ─────────────────────────────────────────────────────────────────────────────
@testset "bulk_copy stores identical values to bulk_insert / create() (#86)" begin
    scratch = () -> M.Bulk_copy_fidelity_scratch.objects

    # A naive DateTime: the DateTimeField formatter converts it to UTC (format_timezone_sql).
    # Pre-fix bulk_copy wrote the naive value → a different stored instant than bulk_insert.
    dt = DateTime(2021, 3, 14, 9, 26, 53)

    # Row 1 exercises "" (empty string, must stay "") and the naive-datetime conversion.
    # Row 2 exercises missing across char/float/datetime (must become NULL) and bool false.
    # Row 3 is a second populated row so id-order comparison covers more than one live row.
    df = DataFrames.DataFrame(
        name       = Union{Missing, String}["", missing, "brake bias"],
        amount     = Union{Missing, Float64}[1.5, missing, 0.1],
        active     = Union{Missing, Bool}[true, false, missing],
        event_time = Union{Missing, DateTime}[dt, missing, dt],
    )

    read_back = () -> begin
        q = scratch()
        q.order_by("id")                                   # ids assigned in insert order == df order
        q.values("name", "amount", "active", "event_time")
        q.list(:dict)
    end

    # ── bulk_insert baseline ──────────────────────────────────────────────────
    scratch().exists() && scratch().delete(allow_delete_all = true)
    bulk_insert(scratch(), df)
    insert_rows = read_back()

    # ── bulk_copy under test ──────────────────────────────────────────────────
    scratch().delete(allow_delete_all = true)
    bulk_copy(scratch(), df)
    copy_rows = read_back()

    @test length(insert_rows) == 3
    @test length(copy_rows) == 3

    # AC1/AC3: identical stored values across every field (datetime/bool/float/string),
    # row for row. isequal so a NULL (missing) matches a NULL. Pre-fix the datetime and
    # empty-string columns diverged here.
    for f in (:name, :amount, :active, :event_time)
        @test isequal([r[f] for r in copy_rows], [r[f] for r in insert_rows])
    end

    # AC2: an empty string round-trips as "" (NOT NULL); a missing round-trips as NULL.
    # isequal (not ==): pre-fix this value is `missing`, and `missing == ""` is `missing`,
    # which would ERROR @test rather than fail cleanly. isequal yields a Bool.
    @test isequal(copy_rows[1][:name], "")     # pre-fix: became missing/NULL (or NOT NULL error)
    @test ismissing(copy_rows[2][:name])       # genuine missing → NULL

    # Three-way parity: create() (the canonical single-row path) agrees with bulk_copy on the
    # divergence-prone fields (naive datetime → UTC, empty string, bool, float).
    scratch().delete(allow_delete_all = true)
    created = scratch().create("name" => "", "amount" => 1.5, "active" => true, "event_time" => dt)
    cq = scratch()
    cq.filter("id" => created[:id])
    cq.values("name", "amount", "active", "event_time")
    created_row = cq.list(:dict) |> first

    @test isequal(created_row[:name], "")
    @test isequal(created_row[:event_time], copy_rows[1][:event_time])   # same UTC instant
    @test isequal(created_row[:active], copy_rows[1][:active])
    @test isequal(created_row[:amount], copy_rows[1][:amount])

    # Cleanup
    scratch().exists() && scratch().delete(allow_delete_all = true)
end

# ─────────────────────────────────────────────────────────────────────────────
# bulk_copy datetime parity, made mutation-discriminating (#114)
#
# The #86 testset above asserts bulk_copy and bulk_insert store the same instant, but under a UTC
# session that assertion cannot fail:
#
#   formatter applied  → CSV cell "2021-03-14T09:26:53.000+00:00" → explicit +00:00 → 09:26:53Z
#   formatter reverted → CSV cell  2021-03-14T09:26:53            → session TimeZone → 09:26:53Z
#
# Identical, so reverting the formatter application in bulk_copy leaves #86 green. Under a NON-UTC
# session the two land on different instants, which is what makes the assertion a guard rather than
# a statement. `SET LOCAL` is transaction-scoped, so this needs every operation — the COPY, the
# reference INSERT, create() and the read-back — pinned to the ONE connection the zone was set on:
# an outer run_in_transaction does exactly that (bulk_copy/bulk_insert/create()/fetch all detect an
# active transaction context and reuse its connection instead of leasing their own), and the zone
# self-resets at COMMIT so nothing leaks back into the pool.
#
# PostgreSQL-only, like every COPY test in this file.
# ─────────────────────────────────────────────────────────────────────────────
@testset "bulk_copy datetime parity is guarded under a non-UTC session (#114)" begin
    settings = PormG.config[PORMG_DB_FOLDER]
    scratch  = () -> M.Bulk_copy_fidelity_scratch.objects

    # America/Sao_Paulo has had no DST since 2019, so this date is a flat UTC-3: the raw-write path
    # would store 12:26:53Z where the formatter path stores 09:26:53Z.
    dt = DateTime(2021, 3, 14, 9, 26, 53)

    # TIMESTAMPTZ reads back as a ZonedDateTime in the SESSION zone (-03:00 here), and TimeZones'
    # isequal compares the zone as well as the instant — so normalize to a naive UTC DateTime
    # before comparing, and never compare ZonedDateTimes directly.
    to_utc = raw -> (raw === nothing || ismissing(raw)) ? missing : DateTime(astimezone(raw, TimeZone("UTC")))

    read_back = () -> begin
        q = scratch()
        q.order_by("id")                                   # ids assigned in insert order == df order
        q.values("event_time")
        [to_utc(r[:event_time]) for r in q.list(:dict)]
    end

    # Inside the transaction this reads the PINNED connection (fetch reuses the tx context), so it
    # reports the zone COPY itself will parse under; outside, it reports an arbitrary pooled one.
    test_zone    = "America/Sao_Paulo"
    session_zone = () -> (PormG.ConnectionPool.fetch(settings,
        "SELECT current_setting('TimeZone') AS tz;") |> DataFrame)[1, :tz]

    try
        scratch().exists() && scratch().delete(allow_delete_all = true)
        baseline_zone = session_zone()                     # whatever db_2's server default is

        PormG.run_in_transaction(settings) do
            PormG.ConnectionPool.fetch(settings, "SET LOCAL TIME ZONE '$(test_zone)';")

            # Guard the guard, twice. If the zone ever stops taking effect (a pooling change, a
            # different transaction helper, a server that rejects the zone) this testset would
            # silently decay back into the non-discriminating shape #114 exists to fix.
            #
            # (i) The statement landed, on the connection COPY will use. Asserted against the zone
            #     NAME rather than "differs from the ambient default": db_2/connection.yml already
            #     carries time_zone: 'America/Sao_Paulo' — inert today (it only feeds Julia-side
            #     now() for auto_now), but wire it into a connect-time SET and a `!= baseline_zone`
            #     check would go red on correct code.
            @test session_zone() == test_zone

            # (ii) The semantic precondition: an UNLABELLED timestamp — exactly what a reverted
            #      bulk_copy writes — resolves to a different instant than the same text labelled
            #      UTC. This is what makes the parity assertions below able to fail at all.
            probe = PormG.ConnectionPool.fetch(settings,
                "SELECT (TIMESTAMP '2021-03-14 09:26:53')::timestamptz <> TIMESTAMPTZ '2021-03-14 09:26:53+00' AS non_utc_session;") |> DataFrame
            @test probe[1, :non_utc_session]

            df = DataFrames.DataFrame(
                name       = ["tz-parity-a", "tz-parity-b"],
                event_time = Union{Missing, DateTime}[dt, missing],
            )

            # ── reference path: bulk_insert applies the formatter (labels the naive value UTC) ──
            bulk_insert(scratch(), df)
            insert_utc = read_back()

            # ── path under test ───────────────────────────────────────────────────────────────
            scratch().delete(allow_delete_all = true)
            bulk_copy(scratch(), df)
            copy_utc = read_back()

            @test length(insert_utc) == 2
            @test length(copy_utc) == 2

            # (a) Parity with bulk_insert. Reverting the formatter application in bulk_copy puts
            #     this 3 hours out.
            @test isequal(copy_utc, insert_utc)

            # (b) Absolute instant. Independent of (a), so it still fires if BOTH write paths
            #     regress together.
            @test copy_utc[1] == dt
            @test ismissing(copy_utc[2])                    # missing → NULL, unaffected by the zone

            # (c) Three-way: create(), the canonical single-row path, on the same TZ-set session.
            scratch().delete(allow_delete_all = true)
            created = scratch().create("name" => "tz-parity-c", "event_time" => dt)
            cq = scratch()
            cq.filter("id" => created[:id])
            cq.values("event_time")
            @test to_utc((cq.list(:dict) |> first)[:event_time]) == dt
        end

        # The zone must NOT survive the transaction. `SET LOCAL` is transaction-scoped, but a
        # future edit to a plain `SET` would keep every assertion above green while releasing a
        # connection still carrying the test zone back into the 20-slot pool — surfacing as a
        # by-pool-draw failure in some later test file, pointing nowhere near here. Compared against
        # the default captured before the transaction, not against "UTC": the server's own default
        # is whatever it is and this must not assume. release_connection returns the slot and
        # acquire_connection takes the first available one, so in this single-task suite the check
        # almost always lands back on the very connection it should — but "almost", and db_2 is a
        # shared host, so read a failure as near-certain contamination rather than as proof.
        @test session_zone() == baseline_zone
    finally
        # run_in_transaction COMMITs on success (a failed @test is recorded, not thrown), so the
        # rows survive the block and are cleaned up here; on a thrown error the ROLLBACK already
        # removed them and exists() short-circuits.
        scratch().exists() && scratch().delete(allow_delete_all = true)
    end
end

end # End of if adapter_name != "SQLite"

