"""
Insert Operation Integration Tests

This file consolidates all write-path INSERT integration coverage for PormG.
It exercises the public create() and bulk_insert() surfaces against real database
adapters (PostgreSQL via db_2 and SQLite via db_sl).

The "Schema Evolution and Error Recovery" testsets were migrated here from
test_database_setup.jl so that insert-specific behavioral logic is separated
from the F1 fixture seeder, which now acts as a pure data-loading phase.

Scenarios covered:
  — Schema Evolution: bulk_insert tolerates extra and reordered DataFrame columns
  — Error Recovery: bulk_insert rolls back atomically on failure (single + multi-chunk)
  — Insertion Result Semantics: create() returns a Dict containing server-generated
      fields (id, auto_now_add, auto_now) alongside the values that were passed in
    — Auto-Field Integration: auto-generated id and caller-supplied uuid_token are present in the
      returned Dict on both backends
  — Bulk Insert with Manual Mappings: the columns= keyword restricts which DataFrame
      columns are written; Pair mappings survive multi-chunk execution
  — Bulk scratch payload (Bulk_update_*_scratch models): mixed nullable columns,
      explicit PKs, chunking, and FK id 0 (parity with bulk_update in test_updates.jl)

Run with:
  julia -t auto --project=. test/integration/runtests.jl
  \$env:PORMG_DB="db_sl"; julia -t 1 --project=. test/integration/runtests.jl
"""

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# ─────────────────────────────────────────────────────────────────────────────
# Schema Evolution and Error Recovery
#
# Migrated from test_database_setup.jl. Uses M.Status because it is a small,
# structurally simple table (two columns, PK is explicit) that cleanly exposes
# the error/rollback surface without FK complications.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Schema Evolution and Error Recovery" begin

    # 1. Schema Evolution: Reordered columns and extra columns
    #
    # bulk_insert should match DataFrame columns to model fields by name, not by
    # position. An extra DataFrame column that has no corresponding model field
    # must be silently ignored rather than causing an error.
    query = M.Status.objects
    query.delete(allow_delete_all=true)

    df_evolved = DataFrame(
        extra_col = ["ignore me", "me too"],
        status    = ["Evolved 1", "Evolved 2"],
        statusid  = [999, 1000]
    )

    # Both rows must land even though the DataFrame has an extra column and
    # the columns are not in the model's declared field order.
    bulk_insert(query, df_evolved)
    query.filter("statusid" => 999)
    @test query.count() == 1
    query = M.Status.objects
    query.filter("statusid" => 1000)
    @test query.count() == 1

    # 2. Error Recovery: Single-batch atomicity on duplicate PK
    #
    # If any row in a batch violates a constraint, the entire batch must be
    # rolled back — no partial commits. Row 999 already exists from step 1,
    # so the second row is a duplicate and the whole insert must fail.
    query = M.Status.objects
    initial_count = query.count()
    df_bad = DataFrame(
        statusid = [1001, 999, 1002],           # 999 duplicates the row seeded above
        status   = ["Good", "Bad (Duplicate)", "Good"]
    )

    got_error = false
    try
        Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
            bulk_insert(query, df_bad)
        end
    catch e
        got_error = true        # bulk_insert rethrows the underlying DB error (duplicate key / unique violation)
    end

    @test got_error
    # Rows 1001 and 1002 must NOT be present — the whole batch was rolled back.
    query = M.Status.objects
    @test query.count() == initial_count
    query.filter("statusid" => 1001)
    @test query.count() == 0

    # 3. Multi-chunk Error Recovery: Atomicity across chunk boundaries
    #
    # With chunk_size=2: the first chunk (2001, 2002) would normally commit on its
    # own, but the second chunk (2001 again, 2003) has a duplicate that fails.
    # The expected behaviour is that the entire multi-chunk operation is rolled
    # back, including the successfully-sent first chunk.
    M.Status.objects.delete(allow_delete_all=true)
    df_multi = DataFrame(
        statusid = [2001, 2002, 2001, 2003],    # 2001 repeats in row 3 (second chunk)
        status   = ["Chunk 1", "Chunk 1", "Chunk 2 (Fail)", "Chunk 2"]
    )

    query = M.Status.objects
    got_error = false
    try
        Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
            bulk_insert(query, df_multi, chunk_size=2)
        end
    catch e
        got_error = true        # The async task failure is unwrapped; the real constraint error surfaces here.
    end

    @test got_error
    # Even the first successfully-sent chunk must be gone — full rollback.
    @test query.count() == 0
end


# ─────────────────────────────────────────────────────────────────────────────
# Bulk Insert Auto-Generated Primary Keys
#
# Callers should not need a pre-insert max(id) allocator. If an auto-generated
# primary key column is present in the DataFrame but contains only blank values,
# bulk_insert must omit that column and let the database assign ids. Mixed blank
# and explicit id values are rejected because this bulk path cannot express a
# row-wise mix of DEFAULT and explicit values safely.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Bulk Insert Auto-Generated Primary Keys" begin
    cleanup_names = [
        "bulk-blank-pk-a",
        "bulk-blank-pk-b",
        "bulk-blank-pk-c",
        "bulk-blank-pk-mixed-a",
        "bulk-blank-pk-mixed-b"
    ]

    cleanup = M.Django_contract_scratch.objects
    cleanup.filter("label__@in" => cleanup_names)
    cleanup.exists() && cleanup.delete()

    try
        df_blank_pk = DataFrame(
            id = Union{Missing, Int64}[missing, missing],
            label = ["bulk-blank-pk-a", "bulk-blank-pk-b"]
        )

        @test all(ismissing, df_blank_pk.id)

        bulk_insert(M.Django_contract_scratch.objects, df_blank_pk)

        inserted = M.Django_contract_scratch.objects.filter(
            "label__@in" => ["bulk-blank-pk-a", "bulk-blank-pk-b"]
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
            "label" => "bulk-blank-pk-c"
        )
        @test next_row[:id] > maximum(inserted_ids)

        df_mixed_pk = DataFrame(
            id = Union{Missing, Int64}[missing, 991001],
            label = ["bulk-blank-pk-mixed-a", "bulk-blank-pk-mixed-b"]
        )

        err = try
            bulk_insert(M.Django_contract_scratch.objects, df_mixed_pk)
            nothing
        catch e
            e
        end

        @test err !== nothing
        @test occursin("mixed blank and explicit values", string(err))
        @test M.Django_contract_scratch.objects.filter(
            "label__@in" => ["bulk-blank-pk-mixed-a", "bulk-blank-pk-mixed-b"]
        ).count() == 0
    finally
        cleanup = M.Django_contract_scratch.objects
        cleanup.filter("label__@in" => cleanup_names)
        cleanup.exists() && cleanup.delete()
    end
end


# ─────────────────────────────────────────────────────────────────────────────
# Insertion Result Semantics
#
# The public contract of query.create() is that it returns a Dict{Symbol, Any}
# containing ALL columns from the inserted row, including server-computed values
# (SERIAL/AUTOINCREMENT pk, TIMESTAMPTZ auto_now_add, TIMESTAMPTZ auto_now).
#
# This testset verifies the RETURN VALUE of create(), which is distinct from the
# subsequent-read tests in test_django_contract.jl. The goal is to confirm that
# callers can rely on auto-populated fields without issuing a follow-up SELECT.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Insertion Result Semantics" begin
    label = "insert-return-semantics-9901"

    # Clean any residual row from a prior run.
    M.Django_contract_scratch.objects.filter("label" => label).exists() &&
        M.Django_contract_scratch.objects.filter("label" => label).delete()

    try
        result = M.Django_contract_scratch.objects.create("label" => label)

        # create() must return a Dict, not nothing or an integer row-count.
        @test result isa Dict

        # The server-generated primary key must be present and positive.
        # IDField maps to SERIAL (PostgreSQL) / AUTOINCREMENT (SQLite), so the
        # ORM retrieves the value via RETURNING * rather than a second SELECT.
        @test haskey(result, :id)
        @test result[:id] isa Integer
        @test result[:id] > 0

        # auto_now_add (DateTimeField) must be populated in the returned dict.
        # Returning nothing here would break ETL code that reads created_at
        # from the create() result instead of fetching it again.
        @test haskey(result, :created_at)
        @test result[:created_at] !== nothing && !ismissing(result[:created_at])

        # auto_now (DateTimeField) must also be present.
        @test haskey(result, :updated_at)
        @test result[:updated_at] !== nothing && !ismissing(result[:updated_at])

        # The value we explicitly passed must be echoed back correctly.
        @test haskey(result, :label)
        @test result[:label] == label

        # Cross-verify: re-read the row and confirm the returned id matches the DB id.
            row = M.Django_contract_scratch.objects.filter(
                "label" => label
            ).values(
                "id"
            ).list() |> first
        @test row[:id] == result[:id]

    finally
        M.Django_contract_scratch.objects.filter("label" => label).exists() &&
            M.Django_contract_scratch.objects.filter("label" => label).delete()
    end
end


# ─────────────────────────────────────────────────────────────────────────────
# Auto-Field Integration
#
# Verifies that fields configured for server-side or ORM-side automatic
# population behave consistently across backends and that their values are
# reflected in the create() return dict.
#
# Covered:
#   - IDField: the auto-generated pk is > 0 and is an Integer
#   - UUIDField: a caller-supplied UUID value is echoed back in the
#       returned dict (case-insensitive — some adapters normalise hex case)
# ─────────────────────────────────────────────────────────────────────────────
@testset "Auto-Field Integration" begin
    slug     = "auto-field-integ-9901"
    uuid_val = string(uuid4())

    # Clean any residual row from a prior run.
    M.Field_validation_scratch.objects.filter("slug" => slug).exists() &&
        M.Field_validation_scratch.objects.filter("slug" => slug).delete()

    try
        result = M.Field_validation_scratch.objects.create(
            "uuid_token"    => uuid_val,
            "canonical_url" => "https://example.com/f1/auto-field-test",
            "slug"          => slug
        )

        # The return value must be a Dict, not nothing.
        @test result isa Dict

        # The auto-incremented id must be present and positive.
        @test haskey(result, :id)
        @test result[:id] isa Integer
        @test result[:id] > 0

        # The UUID token we supplied must be echoed back.
        # Some adapters (e.g. PostgreSQL) return it in uppercase; normalise before
        # comparing so the test is adapter-agnostic.
        @test haskey(result, :uuid_token)
        @test lowercase(string(result[:uuid_token])) == uuid_val

    finally
        M.Field_validation_scratch.objects.filter("slug" => slug).exists() &&
            M.Field_validation_scratch.objects.filter("slug" => slug).delete()
    end
end


# ─────────────────────────────────────────────────────────────────────────────
# Bulk Insert with Manual Mappings
#
# PormG bulk_insert accepts a `columns=` keyword that either names model fields
# directly, or supplies Pair{String,String} mappings (DataFrame col → model field).
# This testset covers aspects not touched by the Adaptor tests that live in the
# update-path coverage:
#
#   - Column subset: omitting a nullable field leaves it NULL while extra columns
#       are ignored and required fields are still mapped explicitly
#   - Pair mapping with chunk_size: the mapping definition must survive across
#       multiple DB round-trips without mismatching columns
# ─────────────────────────────────────────────────────────────────────────────
@testset "Bulk Insert with Manual Mappings" begin

    @testset "Column subset: omitted nullable fields remain null" begin
        # Field_validation_scratch has one nullable JSONField (payload) plus three
        # required fields. By explicitly mapping only the required fields, we can
        # prove that the omitted nullable field lands as NULL while an extra
        # DataFrame column is ignored.
        cleanup_slugs = ["subset-null-9901", "subset-null-9902"]
        q = M.Field_validation_scratch.objects.filter("slug__@in" => cleanup_slugs)
        q.exists() && q.delete()

        df = DataFrame(
            "ext_uuid"   => [string(uuid4()), string(uuid4())],
            "ext_url"    => ["https://example.com/f1/subset-1", "https://example.com/f1/subset-2"],
            "ext_slug"   => cleanup_slugs,
            "ext_extra"  => [99, 55]            # extra column — must be silently ignored
        )

        # Only the required fields are mapped; payload is intentionally omitted.
        bulk_insert(
            M.Field_validation_scratch.objects,
            df,
            columns = [
                "ext_uuid" => "uuid_token",
                "ext_url" => "canonical_url",
                "ext_slug" => "slug",
            ]
        )

        @test M.Field_validation_scratch.objects.filter("slug" => cleanup_slugs[1]).count() == 1
        @test M.Field_validation_scratch.objects.filter("slug" => cleanup_slugs[2]).count() == 1

        # payload was never provided — it must remain NULL.
        row = M.Field_validation_scratch.objects.filter(
            "slug" => cleanup_slugs[1]
        ).values(
            "payload"
        ).list() |> first

        @test row[:payload] === nothing || ismissing(row[:payload])

        q = M.Field_validation_scratch.objects
        q.filter("slug__@in" => cleanup_slugs)
        q.exists() && q.delete()
    end

    @testset "Pair mapping survives multi-chunk execution" begin
        # chunk_size=2 splits the 4-row DataFrame into two separate DB round-trips.
        # Status is a minimal two-column model with no FK defaults, so it isolates
        # the mapping behaviour without unrelated insert-side constraints.
        status_ids = [320001, 320002, 320003, 320004]
        q = M.Status.objects.filter("statusid__@in" => status_ids);
        q.exists() && q.delete()

        df = DataFrame(
            "input_id"     => status_ids,
            "input_status" => ["Mapped Hamilton", "Mapped Verstappen", "Mapped Leclerc", "Mapped Norris"]
        )

        bulk_insert(
            M.Status.objects,
            df,
            columns    = ["input_id" => "statusid", "input_status" => "status"],
            chunk_size = 2
        )

        @test M.Status.objects.filter("statusid" => status_ids[1], "status" => "Mapped Hamilton").count() == 1
        @test M.Status.objects.filter("statusid" => status_ids[2], "status" => "Mapped Verstappen").count() == 1
        @test M.Status.objects.filter("statusid" => status_ids[3], "status" => "Mapped Leclerc").count() == 1
        @test M.Status.objects.filter("statusid" => status_ids[4], "status" => "Mapped Norris").count() == 1

        # The original DataFrame must not have been mutated (no in-place rename).
        @test "input_status" in names(df)
        @test !("status" in names(df))

        q = M.Status.objects
        q.filter("statusid__@in" => status_ids)
        q.exists() && q.delete()
    end
end


# ─────────────────────────────────────────────────────────────────────────────
# allocate_primary_keys
#
# Verifies that allocate_primary_keys() pre-populates the id column before any
# insert happens. This is the recommended replacement for the legacy
# max(id)+range DataFrame indexing pattern.
#
# Three scenarios are exercised:
#   1. No id column in the DataFrame: the function adds one with database-assigned ids.
#   2. All-blank id column (missing values): the function fills it in.
#   3. DataFrame already has explicit ids: the function leaves it unchanged.
#
# The test also verifies two sequence-consistency guarantees:
#   - the next create() call after the bulk_insert does not collide, and
#   - on SQLite, repeated pre-allocation before any insert still yields disjoint
#     id ranges because the reserved range is reflected in sqlite_sequence.
# ─────────────────────────────────────────────────────────────────────────────
@testset "allocate_primary_keys" begin
    labels_a = ["alloc-pk-no-col-a", "alloc-pk-no-col-b"]
    labels_b = ["alloc-pk-blank-a",  "alloc-pk-blank-b"]
    labels_c = ["alloc-pk-after-c"]
    labels_d = ["alloc-pk-sqlite-first-a", "alloc-pk-sqlite-first-b"]
    labels_e = ["alloc-pk-sqlite-second-a", "alloc-pk-sqlite-second-b"]
    labels_f = ["alloc-pk-sqlite-create-a"]
    all_labels = vcat(labels_a, labels_b, labels_c, labels_d, labels_e, labels_f)

    cleanup = M.Django_contract_scratch.objects
    cleanup.filter("label__@in" => all_labels)
    cleanup.exists() && cleanup.delete()

    try
        # 1. No id column: allocate_primary_keys adds it
        df_no_col = DataFrame(label = labels_a)
        @test !("id" in names(df_no_col))

        df_with_ids = allocate_primary_keys(M.Django_contract_scratch.objects, df_no_col)

        # Must have returned a new column without mutating the original
        @test "id" in names(df_with_ids)
        @test !("id" in names(df_no_col))   # original is untouched (clone=true default)
        @test length(df_with_ids.id) == 2
        @test all(id -> id isa Integer && id > 0, df_with_ids.id)
        @test length(unique(df_with_ids.id)) == 2

        bulk_insert(M.Django_contract_scratch.objects, df_with_ids)

        rows_a = M.Django_contract_scratch.objects.filter(
            "label__@in" => labels_a
        ).values("id", "label").list()
        @test length(rows_a) == 2
        @test Set(r[:id] for r in rows_a) == Set(df_with_ids.id)

        # 2. All-blank id column: allocate_primary_keys fills it in
        df_blank = DataFrame(
            id    = Union{Missing, Int64}[missing, missing],
            label = labels_b
        )
        @test all(ismissing, df_blank.id)

        df_filled = allocate_primary_keys(M.Django_contract_scratch.objects, df_blank)

        @test all(id -> id isa Integer && id > 0, df_filled.id)
        @test all(ismissing, df_blank.id)   # original untouched

        bulk_insert(M.Django_contract_scratch.objects, df_filled)

        rows_b = M.Django_contract_scratch.objects.filter(
            "label__@in" => labels_b
        ).values("id", "label").list()
        @test length(rows_b) == 2
        @test Set(r[:id] for r in rows_b) == Set(df_filled.id)

        if PORMG_DB_FOLDER == "db_sl"
            first_reserved, second_reserved, created_row = PormG.run_in_transaction(PORMG_DB_FOLDER) do
                first_reserved = allocate_primary_keys(
                    M.Django_contract_scratch.objects,
                    DataFrame(label = labels_d)
                )
                second_reserved = allocate_primary_keys(
                    M.Django_contract_scratch.objects,
                    DataFrame(label = labels_e)
                )

                @test minimum(second_reserved.id) > maximum(first_reserved.id)

                created_row = M.Django_contract_scratch.objects.create("label" => labels_f[1])
                @test created_row[:id] > maximum(second_reserved.id)

                bulk_insert(M.Django_contract_scratch.objects, first_reserved)
                bulk_insert(M.Django_contract_scratch.objects, second_reserved)

                return first_reserved, second_reserved, created_row
            end

            rows_sqlite = M.Django_contract_scratch.objects.filter(
                "label__@in" => vcat(labels_d, labels_e, labels_f)
            ).values("id", "label").list()
            @test length(rows_sqlite) == 5

            reserved_ids = vcat(first_reserved.id, second_reserved.id)
            @test length(unique(reserved_ids)) == 4
            @test !(created_row[:id] in reserved_ids)
            @test Set(r[:id] for r in rows_sqlite if r[:label] in Set(labels_d)) == Set(first_reserved.id)
            @test Set(r[:id] for r in rows_sqlite if r[:label] in Set(labels_e)) == Set(second_reserved.id)
        end

        # 3. Explicit ids: allocate_primary_keys must not overwrite them
        max_seen = maximum(vcat(df_with_ids.id, df_filled.id))
        df_explicit = DataFrame(
            id    = [max_seen + 10000, max_seen + 10001],
            label = ["explicit-pk-check-a", "explicit-pk-check-b"]
        )
        df_after_alloc = allocate_primary_keys(M.Django_contract_scratch.objects, df_explicit)
        @test df_after_alloc.id == df_explicit.id   # ids not changed

        # 4. Sequence consistency: the next create() must not collide
        next_row = M.Django_contract_scratch.objects.create("label" => labels_c[1])
        @test next_row[:id] isa Integer && next_row[:id] > 0
        all_inserted_ids = vcat(df_with_ids.id, df_filled.id)
        @test !(next_row[:id] in all_inserted_ids)

    finally
        cleanup = M.Django_contract_scratch.objects
        cleanup.filter("label__@in" => vcat(all_labels, ["explicit-pk-check-a", "explicit-pk-check-b"])).exists() &&
            cleanup.filter("label__@in" => vcat(all_labels, ["explicit-pk-check-a", "explicit-pk-check-b"])).delete()
    end
end


# ─────────────────────────────────────────────────────────────────────────────
# Bulk scratch payload: bulk_insert on Bulk_update_*_scratch tables
#
# Uses shared helpers from common_bulk_scratch_setup.jl. bulk_update regressions
# for the same models live in test_updates.jl.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Bulk scratch payload: bulk_insert" begin

    @testset "combined explicit-id + DateTimeField + nullable IntegerField + FK + BooleanField" begin
        _clear_bulk_update_scratch_rows!()

        try
            required_ids, optional_ids = _seed_bulk_update_scratch_parents!(
                ["req-bi-combo"],
                ["opt-bi-combo"],
            )

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

            rb = by_label["bi-combo-b"]
            @test rb[:id] == 990_101
            @test _bulk_update_scratch_to_bool(rb[:is_active]) == false
            @test rb[:nullable_int] === nothing || ismissing(rb[:nullable_int])
            @test rb[:event_time] === nothing || ismissing(rb[:event_time])
            @test rb[:optional_parent_id] === nothing || ismissing(rb[:optional_parent_id])

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

    # Parity: test_updates.jl — "Bulk Update accepts zero-valued constrained FK columns".
    @testset "accepts zero-valued constrained FK columns" begin
        _clear_bulk_update_scratch_rows!()

        try
            required_ids, optional_ids = _seed_bulk_update_scratch_parents!(
                ["req-bi-zero"],
                ["opt-bi-nonzero"],
            )

            zero_parent = M.Bulk_update_optional_parent_scratch.objects.create(
                "id" => 0,
                "label" => "opt-bi-zero",
            )
            @test zero_parent[:id] == 0

            insert_df = DataFrame(
                id = [990_200],
                label = ["bi-zero-fk"],
                required_parent_id = [required_ids["req-bi-zero"]],
                optional_parent_id = Any["0"],
                event_date = Any[Date(2024, 6, 1)],
                is_active = [true],
                event_time = Any[missing],
                nullable_int = Any[missing],
            )

            bulk_insert(
                M.Bulk_update_payload_scratch.objects,
                insert_df,
                columns = [
                    "id", "label", "required_parent_id", "optional_parent_id",
                    "event_date", "is_active", "event_time", "nullable_int"
                ],
            )

            persisted = M.Bulk_update_payload_scratch.objects.filter("id" => 990_200).list() |> first
            @test persisted[:optional_parent_id] == 0
            @test persisted[:label] == "bi-zero-fk"
            @test _bulk_update_scratch_to_bool(persisted[:is_active]) == true
        finally
            _clear_bulk_update_scratch_rows!()
        end
    end
end
