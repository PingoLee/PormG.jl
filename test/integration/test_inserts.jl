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

    # Clean any residual row from a prior run — both the base label and the "-saved" form the
    # .save() step below produces (label is unique, so a leaked "-saved" row would break save()).
    residual = M.Django_contract_scratch.objects.filter("label__@in" => [label, label * "-saved"])
    residual.exists() && residual.delete()

    try
        result = M.Django_contract_scratch.objects.create("label" => label)

        # create() must return a PormGRow (#166) — the same object get()/first()/list() return,
        # not nothing or an integer row-count. Field access still works via delegation.
        @test result isa PormG.QueryBuilder.PormGRow

        # The server-generated primary key must be present and positive.
        # IDField maps to SERIAL (PostgreSQL) / AUTOINCREMENT (SQLite), so the
        # ORM retrieves the value via RETURNING * rather than a second SELECT.
        @test haskey(result, :id)
        @test result[:id] isa Integer
        @test result[:id] > 0

        # auto_now_add (DateTimeField) must be populated in the returned row.
        # Returning nothing here would break ETL code that reads created_at
        # from the create() result instead of fetching it again.
        @test haskey(result, :created_at)
        @test result[:created_at] !== nothing && !ismissing(result[:created_at])

        # auto_now (DateTimeField) must also be present.
        @test haskey(result, :updated_at)
        @test result[:updated_at] !== nothing && !ismissing(result[:updated_at])

        # The value we explicitly passed must be echoed back correctly (dot-access too).
        @test haskey(result, :label)
        @test result[:label] == label
        @test result.label == label     # PormGRow dot-access

        # Cross-verify: re-read the row and confirm the returned id matches the DB id.
            row = M.Django_contract_scratch.objects.filter(
                "label" => label
            ).values(
                "id"
            ).list() |> first
        @test row[:id] == result[:id]

        # #166: the created PormGRow round-trips through .save() — mutate then persist.
        result.label = label * "-saved"
        result.save()
        reread = M.Django_contract_scratch.objects.filter("id" => result[:id]).values("label").list() |> first
        @test reread[:label] == label * "-saved"

    finally
        # The .save() above renamed the label, so clean up both the original and the "-saved" form.
        cleanup = M.Django_contract_scratch.objects.filter("label__@in" => [label, label * "-saved"])
        cleanup.exists() && cleanup.delete()
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

        # The return value must be a PormGRow (#166), not nothing.
        @test result isa PormG.QueryBuilder.PormGRow

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
# #88: allocate_primary_keys on SQLite reserves ids via a read-then-write on
# sqlite_sequence. It must run under BEGIN IMMEDIATE / with_sqlite_write_lock even when
# the caller did NOT open a transaction — otherwise two concurrent callers could read the
# same MAX and hand out overlapping ranges. These checks deliberately call it OUTSIDE
# run_in_transaction: the fix makes the bare call self-protecting by auto-wrapping in
# run_in_transaction (same idiom as bulk_insert/bulk_copy/bulk_update). SQLite-only —
# PostgreSQL uses an atomic nextval() and never took this path.
# ─────────────────────────────────────────────────────────────────────────────
if PORMG_DB_FOLDER == "db_sl"
    @testset "allocate_primary_keys self-protects outside a transaction (#88)" begin
        # Reservation only: no rows are inserted, so there is nothing to clean up — the calls
        # just bump sqlite_sequence (harmless gaps, like a rolled-back PostgreSQL nextval()).

        # 1. Two back-to-back calls with NO surrounding transaction stay disjoint: each
        #    auto-opened transaction durably persists its reservation to sqlite_sequence,
        #    so the second call reads the bumped counter and starts above the first range.
        first_seq  = allocate_primary_keys(M.Django_contract_scratch.objects,
                                           DataFrame(label = ["alloc-pk-untx-1a", "alloc-pk-untx-1b"]))
        second_seq = allocate_primary_keys(M.Django_contract_scratch.objects,
                                           DataFrame(label = ["alloc-pk-untx-2a", "alloc-pk-untx-2b"]))
        @test length(first_seq.id) == 2
        @test first_seq.id  == collect(minimum(first_seq.id):maximum(first_seq.id))    # contiguous
        @test second_seq.id == collect(minimum(second_seq.id):maximum(second_seq.id))  # contiguous
        @test minimum(second_seq.id) > maximum(first_seq.id)                           # disjoint & ordered

        # 2. Concurrent un-wrapped allocations never overlap. Post-fix each call auto-opens
        #    run_in_transaction, so with_sqlite_write_lock + BEGIN IMMEDIATE serialize the
        #    read-then-write; the pre-fix bare path could interleave two SELECT MAX reads and
        #    duplicate a range. SQLite serializes writers, so this is deterministic post-fix.
        n_tasks  = 8
        per_task = 3
        reserved = Vector{Vector{Int}}(undef, n_tasks)
        @sync for i in 1:n_tasks
            @async begin
                df = allocate_primary_keys(M.Django_contract_scratch.objects,
                        DataFrame(label = ["alloc-pk-race-$(i)-$(j)" for j in 1:per_task]))
                reserved[i] = Vector{Int}(df.id)
            end
        end
        all_ids = reduce(vcat, reserved)
        @test length(all_ids) == n_tasks * per_task
        @test length(unique(all_ids)) == length(all_ids)   # no range overlap across tasks
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

    # ─────────────────────────────────────────────────────────────────────────
    # bulk_insert auto-chunks below the backend bind-parameter limit (#84)
    #
    # Each row binds one param per field, so a flushed statement carries
    # chunk_rows × ncols bind params. bulk_insert must derive an effective chunk of
    # fld(limit, ncols) from the backend ceiling instead of blindly using chunk_size.
    # The 8-column payload table with chunk_size == nrows (== fld(limit, 8) + 1) is
    # exactly one row past a single capped chunk, so the fix must split it into two.
    #
    # Two assertions with distinct jobs:
    #   1. show_query=:sql — builds the INSERTs WITHOUT a DB round-trip and returns one
    #      entry per chunk. This gates the wiring on BOTH backends independently of the
    #      driver's true limit: post-fix → a 2-element Vector; pre-fix (uncapped) → a
    #      single un-split SQL String, so `res isa Vector` fails (mutation gate).
    #   2. execute — proves the auto-split writes the FULL row set correctly across the
    #      chunk boundary. On PostgreSQL 65535 is a hard wire-protocol limit, so pre-fix
    #      this also overflows the driver; on SQLite the runtime limit can exceed our
    #      conservative 32766 default, so there the execute is a correctness check (the
    #      show_query assertion is the SQLite gate).
    #
    # nrows tracks the live backend limit: 4096 rows on SQLite (32766), 8192 on PG.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "auto-chunks to respect the backend bind-parameter limit (#84)" begin
        _clear_bulk_update_scratch_rows!()

        pool  = PormG.config[PORMG_DB_FOLDER].connections
        limit = PormG.QueryBuilder._backend_parameter_limit(pool)

        # Pin the CONCRETE limit value. Every other assertion here derives from `limit`
        # (nrows, chunk count), so it would stay self-consistent — and silently green —
        # even if _backend_parameter_limit returned a wrong (especially under-estimated)
        # value. This is the one check that actually fails if the constant is wrong.
        # SQLite: the shipped SQLite.jl is ≥3.32.0, so the default is 32766 (a regression
        # to 999 on an ancient build would fail here, which is the correct signal).
        @test limit == (PORMG_DB_FOLDER == "db_sl" ? 32766 : 65535)

        ncols = 8                              # all payload columns, incl. the explicit id
        nrows = fld(limit, ncols) + 1          # one row past a single capped chunk

        try
            required_ids, optional_ids = _seed_bulk_update_scratch_parents!(
                ["req-84-autochunk"], ["opt-84-autochunk"],
            )
            req_id = required_ids["req-84-autochunk"]
            opt_id = optional_ids["opt-84-autochunk"]

            base_id = 5_000_000
            columns = ["id", "label", "required_parent_id", "optional_parent_id",
                       "event_date", "is_active", "event_time", "nullable_int"]
            insert_df = DataFrame(
                id                 = [base_id + i for i in 1:nrows],
                label              = ["autochunk-$(i)" for i in 1:nrows],
                required_parent_id = fill(req_id, nrows),
                optional_parent_id = fill(opt_id, nrows),
                event_date         = fill(Date(2024, 1, 1), nrows),
                is_active          = fill(true, nrows),
                event_time         = fill(DateTime(2024, 1, 1, 0, 0, 0), nrows),
                nullable_int       = collect(1:nrows),
            )

            # (1) Driver-independent wiring gate: chunk_size == nrows must still split
            # into exactly two statements because the cap trims it to fld(limit, 8).
            res = bulk_insert(
                M.Bulk_update_payload_scratch.objects, insert_df,
                columns = columns, chunk_size = nrows, show_query = :sql,
            )
            @test res isa Vector       # pre-fix returns one un-split SQL String → gate
            @test length(res) == 2     # effective rows + 1 → two capped chunks

            # (2) End-to-end correctness: the auto-split writes the full set, not a subset.
            bulk_insert(
                M.Bulk_update_payload_scratch.objects, insert_df,
                columns = columns, chunk_size = nrows,
            )
            @test M.Bulk_update_payload_scratch.objects.count() == nrows

            # Spot-check the first and last rows (they straddle the chunk boundary)
            # persisted with the correct values, not just that the count matched.
            first_row = M.Bulk_update_payload_scratch.objects.filter("id" => base_id + 1).list() |> first
            last_row  = M.Bulk_update_payload_scratch.objects.filter("id" => base_id + nrows).list() |> first
            @test first_row[:label] == "autochunk-1"
            @test first_row[:nullable_int] == 1
            @test last_row[:label] == "autochunk-$(nrows)"
            @test last_row[:nullable_int] == nrows
        finally
            _clear_bulk_update_scratch_rows!()
        end
    end
end


# ─────────────────────────────────────────────────────────────────────────────
# ON CONFLICT bulk_insert (#123)
#
# bulk_insert(...; on_conflict=...) attaches an ON CONFLICT clause so overlapping
# batches skip (DO NOTHING) or merge (DO UPDATE) duplicates instead of erroring —
# the idempotent re-seed pattern. PostgreSQL and SQLite share the syntax, so the
# same assertions run on both backends. Uses M.Status (explicit pk statusid), the
# same duplicate-key fixture as "Schema Evolution and Error Recovery" above.
# The batches deliberately never repeat a statusid WITHIN one batch: PostgreSQL
# rejects a same-batch double-conflict ("cannot affect row a second time") while
# SQLite applies rows serially — cross-engine behavior diverges, so callers must
# dedupe on the target first (documented in docs/src/write/bulk.md).
# ─────────────────────────────────────────────────────────────────────────────
@testset "ON CONFLICT bulk_insert (#123)" begin
    status_ids = [330001, 330002, 330003, 330004]
    created_pk = Ref{Union{Nothing, Int}}(nothing)
    q = M.Status.objects.filter("statusid__@in" => status_ids)
    q.exists() && q.delete()

    try
        # Seed two of the four ids.
        bulk_insert(M.Status.objects, DataFrame(
            statusid = status_ids[1:2],
            status   = ["Finished", "Collision"],
        ))

        # 1. Untargeted DO NOTHING: an overlapping re-insert must not throw, must
        # leave the existing row untouched, and must add only the new row.
        overlap_df = DataFrame(
            statusid = [status_ids[1], status_ids[3]],   # 330001 duplicates the seed
            status   = ["Overwritten?", "Engine"],
        )
        bulk_insert(M.Status.objects, overlap_df, on_conflict = :nothing)

        @test M.Status.objects.filter("statusid__@in" => status_ids).count() == 3
        row1 = M.Status.objects.filter("statusid" => status_ids[1]).values("status").list() |> first
        @test row1[:status] == "Finished"    # DO NOTHING skipped the duplicate
        @test M.Status.objects.filter("statusid" => status_ids[3], "status" => "Engine").count() == 1

        # 2. Targeted DO NOTHING on the pk behaves identically (fully-overlapping batch).
        bulk_insert(M.Status.objects, overlap_df,
            on_conflict = (action = :nothing, target = ["statusid"]))
        @test M.Status.objects.filter("statusid__@in" => status_ids).count() == 3
        row1 = M.Status.objects.filter("statusid" => status_ids[1]).values("status").list() |> first
        @test row1[:status] == "Finished"

        # 3. DO UPDATE (upsert): conflicting rows take the batch's values, the new row
        # inserts, and chunk_size=2 puts conflicts on both sides of a chunk boundary.
        bulk_insert(M.Status.objects, DataFrame(
                statusid = status_ids,
                status   = ["+1 Lap", "Accident", "Gearbox", "Hydraulics"],
            ),
            chunk_size  = 2,
            on_conflict = (action = :update, target = ["statusid"], set = ["status"]))

        @test M.Status.objects.filter("statusid__@in" => status_ids).count() == 4
        by_id = Dict(r[:statusid] => r[:status] for r in
            M.Status.objects.filter("statusid__@in" => status_ids).values("statusid", "status").list())
        @test by_id[status_ids[1]] == "+1 Lap"        # conflict in chunk 1 → updated
        @test by_id[status_ids[2]] == "Accident"      # conflict in chunk 1 → updated
        @test by_id[status_ids[3]] == "Gearbox"       # conflict in chunk 2 → updated
        @test by_id[status_ids[4]] == "Hydraulics"    # no conflict → inserted

        # 4. Sequence consistency survives on_conflict: the post-insert resync still
        # ran, so a follow-up create() without an explicit pk must not collide with
        # the explicit ids above (meaningful on PostgreSQL; harmless on SQLite).
        next_row = M.Status.objects.create("status" => "Sequence Check (#123)")
        created_pk[] = next_row[:statusid]
        @test next_row[:statusid] isa Integer
        @test !(next_row[:statusid] in status_ids)
    finally
        cleanup_ids = created_pk[] === nothing ? status_ids : vcat(status_ids, created_pk[])
        q = M.Status.objects.filter("statusid__@in" => cleanup_ids)
        q.exists() && q.delete()
    end
end


# ─────────────────────────────────────────────────────────────────────────────
# update_or_create (#30)
#
# Row-level Django-style upsert: match on the lookup pair(s) (the ON CONFLICT target),
# INSERT on a fresh key, DO UPDATE the `defaults` on a conflict. Returns (PormGRow, created).
# PostgreSQL derives `created` from RETURNING (xmax = 0); SQLite from a pre-check inside its
# serialized write lock. Same assertions run on both backends. Uses M.Status (pk statusid).
#
# NOTE: a composite (multi-column) conflict target is covered at the unit level (SQL rendering in
# test/unit/test_update_or_create.jl). An end-to-end multi-column case needs a model with a real
# composite UNIQUE/PK (a `Models.UniqueConstraint` / unique_together), which the integration
# fixtures don't yet declare — deferred as a prerequisite follow-up rather than silently skipped.
# ─────────────────────────────────────────────────────────────────────────────
@testset "update_or_create (#30)" begin
    status_id = 340001
    created_pk = Ref{Union{Nothing, Int}}(nothing)
    q = M.Status.objects.filter("statusid" => status_id)
    q.exists() && q.delete()

    try
        # 1. Fresh key → INSERT, created == true, PormGRow returned with the inserted value.
        row, created = M.Status.objects.update_or_create(
            "statusid" => status_id; defaults = ["status" => "Created"])
        @test created === true
        @test row isa PormG.QueryBuilder.PormGRow
        @test row.statusid == status_id                 # dot-access (PormGRow, like get())
        @test row.status == "Created"
        @test M.Status.objects.filter("statusid" => status_id).count() == 1

        # 2. Same key, new defaults → DO UPDATE, created == false, value merged, count unchanged.
        row2, created2 = M.Status.objects.update_or_create(
            "statusid" => status_id; defaults = ["status" => "Updated"])
        @test created2 === false
        @test row2.status == "Updated"
        @test M.Status.objects.filter("statusid" => status_id).count() == 1
        persisted = M.Status.objects.filter("statusid" => status_id).values("status").list() |> first
        @test persisted[:status] == "Updated"

        # 3. The returned PormGRow round-trips through .save() (further edits persist).
        row2.status = "Collision"
        row2.save()
        reread = M.Status.objects.filter("statusid" => status_id).values("status").list() |> first
        @test reread[:status] == "Collision"

        # 4. Sequence consistency: row-level writers no longer auto-resync (#358) — an explicit-pk
        #    upsert like step 1 needs resync_sequences() called explicitly before a pk-less create()
        #    is safe again. Asserting merely `!= status_id` would pass whether or not the repair ran
        #    (status_id is a huge constant nowhere near the table's ordinary auto-increment range,
        #    so any normal auto-generated id already satisfies `!=`) — that is not a real regression
        #    guard. Asserting the EXACT next value (`status_id + 1`, what resync_sequences sets the
        #    sequence to) is meaningful on PostgreSQL: without the call, the sequence would still be
        #    at its ordinary low position from earlier fixture rows.
        #
        #    PostgreSQL-discriminating only: `statusid` is an IDField, which SQLite renders as
        #    AUTOINCREMENT, and SQLite's own bookkeeping already tracks MAX(explicit value,
        #    previous) as a side effect of step 1's insert, independent of PormG — so on db_sl this
        #    assertion holds even with the resync_sequences() call above deleted. Real SQLite
        #    regression coverage for resync_sequences() itself lives in
        #    test/unit/test_resync_sequences.jl (via corrupt-then-repair on an AUTOINCREMENT
        #    column, which SQLite's own bookkeeping can't spontaneously reproduce).
        resync_sequences(M.Status)
        next_row = M.Status.objects.create("status" => "Seq Check (#30)")
        created_pk[] = next_row[:statusid]
        @test next_row[:statusid] == status_id + 1
    finally
        cleanup_ids = created_pk[] === nothing ? [status_id] : [status_id, created_pk[]]
        q = M.Status.objects.filter("statusid__@in" => cleanup_ids)
        q.exists() && q.delete()
    end
end
