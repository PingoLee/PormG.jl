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
