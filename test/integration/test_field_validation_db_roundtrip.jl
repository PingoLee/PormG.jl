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
end

