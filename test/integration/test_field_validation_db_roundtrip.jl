"""
Integration tests for field validation with database round-trip testing.

This file complements the unit suite by exercising real persistence against the
seeded Formula 1 integration schema. It focuses on field type serialization and
persistence that require an actual database round-trip rather than pure SQL
inspection or validator-only coverage.

Implemented here:
- Duration, date, and time round-trip assertions against seeded integration rows.
- UUID, URL, slug, and JSON round-trip assertions against a dedicated scratch table.
- Unique-constraint create/update failure verification.

Delete FK constraint tests live in test_deletes.jl.
"""

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end



function _normalize_date_value(value)
    value isa Date && return value
    return Date(string(value))
end

function _normalize_time_value(value)
    value isa Time && return value
    return Time(string(value))
end

_normalize_duration_value(value) = Models.format_duration_sql(value)

function _normalize_json_value(value)
    value isa AbstractDict && return JSON.parse(JSON.json(value))
    if value === nothing || ismissing(value)
        return nothing
    end
    return JSON.parse(string(value))
end

function _restore_nullable_value(raw_value, normalized_value)
    return raw_value === nothing || ismissing(raw_value) ? nothing : normalized_value
end

function _cleanup_field_validation_scratch_rows!(slugs::Vector{String})
    isempty(slugs) && return nothing

    query = M.Field_validation_scratch.objects
    query.filter("slug__@in" => slugs)
    query.exists() && query.delete()
    return nothing
end

function _seed_field_validation_scratch!(; uuid_token::String, canonical_url::String, slug::String, payload=nothing)
    _cleanup_field_validation_scratch_rows!([slug])

    return M.Field_validation_scratch.objects.create(
        "uuid_token" => uuid_token,
        "canonical_url" => canonical_url,
        "slug" => slug,
        "payload" => payload
    )
end



# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# Field Validation: database round-trips for temporal field types already present
# in the seeded Formula 1 schemas.
# These tests verify write/read behaviour against the real adapters instead of
# stopping at validator-only assertions.
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
@testset "Field Validation DB Round-Trip Tests" begin
    # â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    # DurationField: seeded F1 fixtures already contain canonical elapsed-time
    # values, so we can assert both query matching and read-back normalization.
    # â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    @testset "Temporal Fields: DurationField (F1 elapsed times)" begin
        result_query = M.Result.objects
        result_query.filter("resultid" => 1, "fastestlaptime" => Minute(1) + Second(27) + Millisecond(452))
        result_row = result_query.values("fastestlaptime").list() |> first
        @test result_query.count() == 1
        @test _normalize_duration_value(result_row[:fastestlaptime]) == "00:01:27.452"

        qualifying_query = M.Qualifying.objects
        qualifying_query.filter("qualifyingid" => 1, "q1" => "1:26.572")
        qualifying_row = qualifying_query.values("q1").list() |> first
        @test qualifying_query.count() == 1
        @test _normalize_duration_value(qualifying_row[:q1]) == "00:01:26.572"

        lap_query = M.Lap_times.objects
        lap_query.filter("raceid" => 841, "driverid" => 20, "lap" => 1, "time" => "1:38.109")
        lap_row = lap_query.values("time").list() |> first
        @test lap_query.count() == 1
        @test _normalize_duration_value(lap_row[:time]) == "00:01:38.109"

        pit_query = M.Pit_stops.objects
        pit_query.filter("raceid" => 841, "driverid" => 153, "stop" => 1, "duration" => "26.898")
        pit_row = pit_query.values("duration").list() |> first
        @test pit_query.count() == 1
        @test _normalize_duration_value(pit_row[:duration]) == "00:00:26.898"
    end

    # DateTimeField timezone round-trips now live in test_django_contract.jl via
    # Django_contract_scratch, which provides dedicated DateTimeField coverage on
    # real adapters without leaving a placeholder broken test here.

    # â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    # DateField: update a real Race row, read it back, and restore the original
    # value so the test proves persistence without leaving the dataset mutated.
    # â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    @testset "Temporal Fields: DateField Consistency" begin
        race_query = M.Race.objects
        race_query.filter("raceid" => 1)
        original_row = race_query.values("date").list() |> first
        original_date = _normalize_date_value(original_row[:date])

        try
            first_round_trip = original_date + Day(1)
            race_query.update("date" => first_round_trip)
            first_updated = race_query.values("date").list() |> first
            @test _normalize_date_value(first_updated[:date]) == first_round_trip

            second_round_trip = original_date + Day(2)
            race_query.update("date" => (DateTime(second_round_trip) + Hour(12)))
            second_updated = race_query.values("date").list() |> first
            @test _normalize_date_value(second_updated[:date]) == second_round_trip
        finally
            race_query.update("date" => original_date)
        end
    end

    # â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    # TimeField: store and read back time-only values through a nullable Race.time
    # column, verifying that no date component leaks into the persisted value.
    # â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    @testset "Temporal Fields: TimeField (time-only)" begin
        race_query = M.Race.objects
        race_query.filter("raceid" => 1)
        original_row = race_query.values("time").list() |> first
        original_raw_time = original_row[:time]
        original_time = original_raw_time === nothing || ismissing(original_raw_time) ? nothing : _normalize_time_value(original_raw_time)

        try
            first_round_trip = Time(14, 30, 0)
            race_query.update("time" => first_round_trip)
            first_updated = race_query.values("time").list() |> first
            @test _normalize_time_value(first_updated[:time]) == first_round_trip
            @test !occursin('-', string(first_updated[:time]))

            second_round_trip = Time(16, 5, 7)
            race_query.update("time" => second_round_trip)
            second_updated = race_query.values("time").list() |> first
            @test _normalize_time_value(second_updated[:time]) == second_round_trip
            @test !occursin('T', string(second_updated[:time]))
        finally
            race_query.update("time" => _restore_nullable_value(original_raw_time, original_time))
        end
    end

    # â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    # TimeField edge values belong in integration coverage because backend adapters
    # can serialize midnight and end-of-day differently even when validation passes.
    # â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    @testset "Temporal Fields: TimeField Details" begin
        pit_query = M.Pit_stops.objects
        pit_query.filter("raceid" => 841, "driverid" => 153, "stop" => 1)
        original_row = pit_query.values("time").list() |> first
        original_time = _normalize_time_value(original_row[:time])

        try
            pit_query.update("time" => Time(0, 0, 0))
            midnight_row = pit_query.values("time").list() |> first
            @test _normalize_time_value(midnight_row[:time]) == Time(0, 0, 0)

            pit_query.update("time" => Time(23, 59, 59))
            end_of_day_row = pit_query.values("time").list() |> first
            @test _normalize_time_value(end_of_day_row[:time]) == Time(23, 59, 59)
        finally
            pit_query.update("time" => original_time)
        end
    end

    # â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    # These field types still have no Formula 1 seed-table representation, so we
    # exercise them through a dedicated scratch table created on demand. That keeps
    # the public ORM round-trip coverage real without fabricating F1 fixture columns.
    # â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    @testset "Scratch Fields: UUIDField Round-Trip" begin
        scratch_slug = "uuid-field-roundtrip-990501"
        seeded_uuid = string(uuid4())
        updated_uuid = string(uuid4())

        try
            _seed_field_validation_scratch!(
                uuid_token=seeded_uuid,
                canonical_url="https://example.com/f1/uuid-field",
                slug=scratch_slug,
                payload=Dict("kind" => "uuid")
            )

            scratch_query = M.Field_validation_scratch.objects
            scratch_query.filter("slug" => scratch_slug)
            seeded_row = scratch_query.values("uuid_token").list() |> first
            @test lowercase(string(seeded_row[:uuid_token])) == seeded_uuid

            lookup_query = M.Field_validation_scratch.objects
            lookup_query.filter("uuid_token" => seeded_uuid)
            @test lookup_query.count() == 1

            scratch_query.update("uuid_token" => updated_uuid)
            updated_row = scratch_query.values("uuid_token").list() |> first
            @test lowercase(string(updated_row[:uuid_token])) == updated_uuid

            updated_lookup = M.Field_validation_scratch.objects
            updated_lookup.filter("uuid_token" => updated_uuid)
            @test updated_lookup.count() == 1
        finally
            _cleanup_field_validation_scratch_rows!([scratch_slug])
        end
    end

    @testset "Scratch Fields: URLField Round-Trip" begin
        scratch_slug = "url-field-roundtrip-990502"
        seeded_url = "https://example.com/f1/url-field"
        updated_url = "https://example.com/f1/url-field/updated"

        try
            _seed_field_validation_scratch!(
                uuid_token=string(uuid4()),
                canonical_url=seeded_url,
                slug=scratch_slug,
                payload=Dict("kind" => "url")
            )

            scratch_query = M.Field_validation_scratch.objects
            scratch_query.filter("slug" => scratch_slug)
            seeded_row = scratch_query.values("canonical_url").list() |> first
            @test seeded_row[:canonical_url] == seeded_url

            lookup_query = M.Field_validation_scratch.objects
            lookup_query.filter("canonical_url" => seeded_url)
            @test lookup_query.count() == 1

            scratch_query.update("canonical_url" => updated_url)
            updated_row = scratch_query.values("canonical_url").list() |> first
            @test updated_row[:canonical_url] == updated_url
        finally
            _cleanup_field_validation_scratch_rows!([scratch_slug])
        end
    end

    @testset "Scratch Fields: SlugField Round-Trip" begin
        scratch_slug = "slug-field-roundtrip-990503"
        updated_slug = "slug-field-roundtrip-updated-990503"

        try
            _seed_field_validation_scratch!(
                uuid_token=string(uuid4()),
                canonical_url="https://example.com/f1/slug-field",
                slug=scratch_slug,
                payload=Dict("kind" => "slug")
            )

            scratch_query = M.Field_validation_scratch.objects
            scratch_query.filter("slug" => scratch_slug)
            seeded_row = scratch_query.values("slug").list() |> first
            @test seeded_row[:slug] == scratch_slug

            scratch_query.update("slug" => updated_slug)
            updated_query = M.Field_validation_scratch.objects
            updated_query.filter("slug" => updated_slug)
            updated_row = updated_query.values("slug").list() |> first
            @test updated_row[:slug] == updated_slug

            lookup_query = M.Field_validation_scratch.objects
            lookup_query.filter("slug" => updated_slug)
            @test lookup_query.count() == 1
        finally
            _cleanup_field_validation_scratch_rows!([scratch_slug, updated_slug])
        end
    end

    @testset "Scratch Fields: JSONField Round-Trip" begin
        scratch_slug = "json-field-roundtrip-990504"
        seeded_payload = Dict("driver" => "Piastri", "points" => 15, "tags" => ["scratch", "json"])
        updated_payload = Dict("driver" => "Norris", "points" => 18.5, "tags" => ["updated"])

        try
            _seed_field_validation_scratch!(
                uuid_token=string(uuid4()),
                canonical_url="https://example.com/f1/json-field",
                slug=scratch_slug,
                payload=seeded_payload
            )

            scratch_query = M.Field_validation_scratch.objects
            scratch_query.filter("slug" => scratch_slug)
            seeded_row = scratch_query.values("payload").list() |> first
            @test _normalize_json_value(seeded_row[:payload]) == JSON.parse(JSON.json(seeded_payload))

            scratch_query.update("payload" => updated_payload)
            updated_row = scratch_query.values("payload").list() |> first
            @test _normalize_json_value(updated_row[:payload]) == JSON.parse(JSON.json(updated_payload))
        finally
            _cleanup_field_validation_scratch_rows!([scratch_slug])
        end
    end

    @testset "Scratch Fields: Unique Create Failure Leaves State Unchanged" begin
        scratch_slug = "slug-unique-create-990505"
        duplicate_uuid = string(uuid4())

        try
            _seed_field_validation_scratch!(
                uuid_token=string(uuid4()),
                canonical_url="https://example.com/f1/slug-unique-create",
                slug=scratch_slug,
                payload=Dict("kind" => "seed")
            )

            err = try
                M.Field_validation_scratch.objects.create(
                    "uuid_token" => duplicate_uuid,
                    "canonical_url" => "https://example.com/f1/slug-unique-create/duplicate",
                    "slug" => scratch_slug,
                    "payload" => Dict("kind" => "duplicate")
                )
                nothing
            catch e
                e
            end

            @test err !== nothing
            @test any(token -> occursin(token, lowercase(string(err))), ["unique", "duplicate", "constraint"])
            @test M.Field_validation_scratch.objects.filter("slug" => scratch_slug).count() == 1
            @test M.Field_validation_scratch.objects.filter("uuid_token" => duplicate_uuid).count() == 0
        finally
            _cleanup_field_validation_scratch_rows!([scratch_slug])
        end
    end

    @testset "Scratch Fields: Unique Update Failure Leaves Rows Unchanged" begin
        original_slug = "slug-unique-update-a-990506"
        conflicting_slug = "slug-unique-update-b-990506"

        try
            _seed_field_validation_scratch!(
                uuid_token=string(uuid4()),
                canonical_url="https://example.com/f1/slug-unique-update/a",
                slug=original_slug,
                payload=Dict("kind" => "original")
            )
            _seed_field_validation_scratch!(
                uuid_token=string(uuid4()),
                canonical_url="https://example.com/f1/slug-unique-update/b",
                slug=conflicting_slug,
                payload=Dict("kind" => "conflicting")
            )

            update_query = M.Field_validation_scratch.objects
            update_query.filter("slug" => conflicting_slug)

            err = try
                update_query.update("slug" => original_slug)
                nothing
            catch e
                e
            end

            @test err !== nothing
            @test any(token -> occursin(token, lowercase(string(err))), ["unique", "duplicate", "constraint"])
            @test M.Field_validation_scratch.objects.filter("slug" => original_slug).count() == 1
            @test M.Field_validation_scratch.objects.filter("slug" => conflicting_slug).count() == 1

            persisted_row = M.Field_validation_scratch.objects.filter("slug" => conflicting_slug).values("slug").list() |> first
            @test persisted_row[:slug] == conflicting_slug
        finally
            _cleanup_field_validation_scratch_rows!([original_slug, conflicting_slug])
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # BinaryField: raw bytes survive a real BYTEA/BLOB round-trip (#296)
    # Nothing exercised this before: the field rendered as TEXT on both backends, so a
    # binary payload was never actually stored as binary. The payloads below are chosen
    # to fail loudly if the column is text again — an embedded 0x00 (which truncates a
    # C-string parameter), a 0xFF high byte, and the C3 28 pair, which is invalid UTF-8
    # and cannot survive a text encode/decode cycle.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "Scratch Fields: BinaryField Byte Round-Trip" begin
        scratch_slug = "binary-field-roundtrip-990507"
        # PNG magic + a NUL + a high byte + an invalid-UTF-8 sequence.
        payload = UInt8[0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0xC3, 0x28]
        updated_payload = UInt8[0x00, 0x01, 0xFE, 0xFF]

        try
            _seed_field_validation_scratch!(
                uuid_token=string(uuid4()),
                canonical_url="https://example.com/f1/binary-field",
                slug=scratch_slug,
                payload=Dict("kind" => "binary")
            )

            scratch_query = M.Field_validation_scratch.objects
            scratch_query.filter("slug" => scratch_slug)
            scratch_query.update("blob_payload" => payload)

            seeded_row = scratch_query.values("blob_payload").list() |> first
            stored = seeded_row[:blob_payload]

            # The contract is raw bytes out — not a String, not a hex/Base64 rendering.
            @test stored isa AbstractVector{UInt8}
            # Byte-for-byte identity is the whole point; a length check alone would pass
            # even if every byte were mangled.
            @test collect(stored) == payload

            # Update to a different payload and re-read, so the UPDATE bind path is covered
            # as well as INSERT.
            scratch_query.update("blob_payload" => updated_payload)
            updated_row = scratch_query.values("blob_payload").list() |> first
            @test collect(updated_row[:blob_payload]) == updated_payload

            # An empty payload is distinct from NULL.
            scratch_query.update("blob_payload" => UInt8[])
            empty_row = scratch_query.values("blob_payload").list() |> first
            @test collect(empty_row[:blob_payload]) == UInt8[]

            # NULL still round-trips as nothing/missing on a null=true column.
            scratch_query.update("blob_payload" => nothing)
            null_row = scratch_query.values("blob_payload").list() |> first
            @test null_row[:blob_payload] === nothing || ismissing(null_row[:blob_payload])

            # A String is stored as its UTF-8 code units — the form that keeps a column
            # which used to render as TEXT writable without an app edit.
            scratch_query.update("blob_payload" => "Senna")
            text_row = scratch_query.values("blob_payload").list() |> first
            @test collect(text_row[:blob_payload]) == collect(codeunits("Senna"))
        finally
            _cleanup_field_validation_scratch_rows!([scratch_slug])
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # BinaryField max_length is a BYTE bound, enforced in two independent places
    # The ORM rejects an oversize payload before any SQL is built, and the DDL CHECK
    # (octet_length on PostgreSQL, length on SQLite) is the backstop. The ORM assertions
    # alone would pass even if the constraint never reached the database, so the last
    # block deliberately goes around the ORM to prove the constraint is really there.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "Scratch Fields: BinaryField byte bound" begin
        scratch_slug = "binary-field-bound-990508"

        try
            _seed_field_validation_scratch!(
                uuid_token=string(uuid4()),
                canonical_url="https://example.com/f1/binary-bound",
                slug=scratch_slug,
                payload=Dict("kind" => "binary-bound")
            )

            scratch_query = M.Field_validation_scratch.objects
            scratch_query.filter("slug" => scratch_slug)

            # Exactly at the bound is accepted and round-trips.
            at_bound = UInt8[1, 2, 3, 4, 5, 6, 7, 8]
            scratch_query.update("bounded_blob" => at_bound)
            @test collect((scratch_query.values("bounded_blob").list() |> first)[:bounded_blob]) == at_bound

            # One byte over is rejected by the ORM before the query is built. Assert the concrete
            # type, not the abstract PormGError root — a typo'd field name also raises a PormGError,
            # so the root would pass for the wrong reason.
            oversize = UInt8[1, 2, 3, 4, 5, 6, 7, 8, 9]
            @test_throws PormG.InvalidValueError scratch_query.update("bounded_blob" => oversize)
            err = try
                scratch_query.update("bounded_blob" => oversize); nothing
            catch e
                e
            end
            @test occursin("max_length is 8 bytes", err.msg)

            # A 5-character string that is 10 UTF-8 bytes must also be rejected: the bound counts
            # bytes, and the pre-#296 check counted characters — which would have let this through.
            over_by_bytes = "ééééé"
            @test length(over_by_bytes) == 5 && ncodeunits(over_by_bytes) == 10
            @test_throws PormG.InvalidValueError scratch_query.update("bounded_blob" => over_by_bytes)

            # The stored value is untouched by the rejected writes.
            @test collect((scratch_query.values("bounded_blob").list() |> first)[:bounded_blob]) == at_bound

            # ── The DDL CHECK itself ──────────────────────────────────────────────
            # Bypass the ORM validator with raw SQL so the database is the only thing that can
            # reject this. Without the CHECK in the schema the 9-byte write would simply succeed.
            # This is the one place raw SQL is warranted: the assertion IS about the DDL.
            settings = PormG.config[PORMG_DB_FOLDER]
            pool = settings.connections
            # Bind the exception rather than setting a flag in a bare `catch`. A bare catch is
            # satisfied by a typo'd table name, a wrong placeholder style, or a MethodError on
            # `fetch` — none of which involve the database rejecting anything — and the
            # "row unchanged" assertion below holds in every one of those cases too, because the
            # statement never ran. Asserting on the message is what makes this test fail when the
            # CHECK stops reaching the DDL.
            raw_err = try
                if pool isa PormG.PormGPostgres
                    PormG.fetch(pool, "UPDATE field_validation_scratch SET bounded_blob = \$1 WHERE slug = \$2",
                                ["\\x010203040506070809", scratch_slug])
                else
                    PormG.fetch(pool, "UPDATE field_validation_scratch SET bounded_blob = ? WHERE slug = ?",
                                [oversize, scratch_slug])
                end
                nothing
            catch e
                e
            end
            @test raw_err !== nothing
            # PostgreSQL: `violates check constraint "…"`. SQLite: `CHECK constraint failed: …`.
            # Both contain "check constraint" once case is normalized.
            @test occursin("check constraint", lowercase(sprint(showerror, raw_err)))
            # And the row is unchanged, so the failed statement wrote nothing.
            @test collect((scratch_query.values("bounded_blob").list() |> first)[:bounded_blob]) == at_bound
        finally
            _cleanup_field_validation_scratch_rows!([scratch_slug])
        end
    end
end

