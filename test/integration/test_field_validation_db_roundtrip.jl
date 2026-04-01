"""
Integration tests for field validation with database round-trip testing.

This file complements the unit suite by exercising real persistence against the
seeded Formula 1 integration schema. It focuses on field types and delete
behaviour that require an actual database round-trip rather than pure SQL
inspection or validator-only coverage.

Implemented here:
- Duration, date, and time round-trip assertions against seeded integration rows.
- Cascading delete and nested cascading delete behaviour using scratch fixtures.
- RESTRICT/PROTECT-style delete blocking through existing integration foreign keys.
- DELETE inspection metadata through the public query surface.

Pending here:
- DateTime timezone round-trips and missing field types that are not represented
    in the current db_2/db_sl integration schemas yet.
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

function _restore_nullable_value(raw_value, normalized_value)
    return raw_value === nothing || ismissing(raw_value) ? nothing : normalized_value
end

function _cleanup_scratch_delete_graph!(result_id::Int; deletion_ids::Vector{Int}=Int[], nested_ids::Vector{Int}=Int[])
    if !isempty(nested_ids)
        query = M.Just_a_nested_roll_back.objects
        query.filter("id__@in" => nested_ids)
        query.exists() && query.delete()
    end

    if !isempty(deletion_ids)
        query = M.Just_a_test_deletion.objects
        query.filter("id__@in" => deletion_ids)
        query.exists() && query.delete()
    end

    result_query = M.Result.objects
    result_query.filter("resultid" => result_id)
    result_query.exists() && result_query.delete()
    return nothing
end

function _seed_scratch_result!(result_id::Int)
    template_query = M.Result.objects
    template_query.filter("resultid" => 1)
    template = template_query.list() |> first

    scratch_query = M.Result.objects
    scratch_query.filter("resultid" => result_id)
    scratch_query.exists() && scratch_query.delete()

    return M.Result.objects.create(
        "resultid" => result_id,
        "raceid" => template[:raceid],
        "driverid" => template[:driverid],
        "constructorid" => template[:constructorid],
        "number" => template[:number],
        "grid" => template[:grid],
        "position" => template[:position],
        "positiontext" => "scratch-$(result_id)",
        "positionorder" => result_id % 1000,
        "points" => template[:points],
        "laps" => template[:laps],
        "time" => template[:time],
        "milliseconds" => template[:milliseconds],
        "fastestlap" => template[:fastestlap],
        "rank" => template[:rank],
        "fastestlaptime" => template[:fastestlaptime],
        "fastestlapspeed" => template[:fastestlapspeed],
        "statusid" => template[:statusid]
    )
end

# ─────────────────────────────────────────────────────────────────────────────
# Field Validation: database round-trips for temporal field types already present
# in the seeded Formula 1 schemas.
# These tests verify write/read behaviour against the real adapters instead of
# stopping at validator-only assertions.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Field Validation DB Round-Trip Tests" begin
    # ─────────────────────────────────────────────────────────────────────────
    # DurationField: seeded F1 fixtures already contain canonical elapsed-time
    # values, so we can assert both query matching and read-back normalization.
    # ─────────────────────────────────────────────────────────────────────────
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

    # ─────────────────────────────────────────────────────────────────────────
    # DateTimeField timezone coverage is intentionally skipped here because the
    # current integration schema exposes no DateTimeField-backed model/table.
    # This should move from skipped to real coverage once seeded schema support exists.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Temporal Fields: DateTime with Timezone" begin
        @test_skip false
    end

    # ─────────────────────────────────────────────────────────────────────────
    # DateField: update a real Race row, read it back, and restore the original
    # value so the test proves persistence without leaving the dataset mutated.
    # ─────────────────────────────────────────────────────────────────────────
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

    # ─────────────────────────────────────────────────────────────────────────
    # TimeField: store and read back time-only values through a nullable Race.time
    # column, verifying that no date component leaks into the persisted value.
    # ─────────────────────────────────────────────────────────────────────────
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

    # ─────────────────────────────────────────────────────────────────────────
    # TimeField edge values belong in integration coverage because backend adapters
    # can serialize midnight and end-of-day differently even when validation passes.
    # ─────────────────────────────────────────────────────────────────────────
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

    # ─────────────────────────────────────────────────────────────────────────
    # These field types are still absent from the seeded integration schemas, so
    # the correct behaviour is to keep the gaps explicit rather than fabricate coverage.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Missing Field Types: UUIDField" begin
        @test_skip false
    end

    @testset "Missing Field Types: URLField" begin
        @test_skip false
    end

    @testset "Missing Field Types: SlugField" begin
        @test_skip false
    end

    @testset "Missing Field Types: JSONField" begin
        @test_skip false
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Delete operations: use scratch Result rows plus real reverse relationships so
# the delete collector has to execute CASCADE and RESTRICT logic against the DB.
# These tests verify behaviour that unit SQL inspection cannot prove.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Delete Operations with FK Constraints" begin
    # ─────────────────────────────────────────────────────────────────────────
    # CASCADE: deleting a scratch Result should remove the Just_a_test_deletion
    # children that reference it through the public delete API.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete with CASCADE: Verify Related Records are Removed" begin
        scratch_result_id = 990001
        child_ids = [990101, 990102, 990103]

        _cleanup_scratch_delete_graph!(scratch_result_id; deletion_ids=child_ids)
        _seed_scratch_result!(scratch_result_id)

        try
            for (index, child_id) in enumerate(child_ids)
                M.Just_a_test_deletion.objects.create(
                    "id" => child_id,
                    "name" => "cascade-child-$(index)",
                    "test_result" => scratch_result_id
                )
            end

            child_query = M.Just_a_test_deletion.objects
            child_query.filter("id__@in" => child_ids)
            @test child_query.count() == 3

            delete_query = M.Result.objects
            delete_query.filter("resultid" => scratch_result_id)
            total_deleted, deleted_counter = delete_query.delete()

            @test total_deleted >= 4
            @test haskey(deleted_counter, "result")
            @test haskey(deleted_counter, "just_a_test_deletion")
            @test M.Result.objects.filter("resultid" => scratch_result_id).count() == 0
            @test M.Just_a_test_deletion.objects.filter("id__@in" => child_ids).count() == 0
        finally
            _cleanup_scratch_delete_graph!(scratch_result_id; deletion_ids=child_ids)
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # SET_NULL is exercised through a dedicated nullable scratch FK so the test
    # does not overload the existing CASCADE/lookup fixture field.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete with SET_NULL: Verify FK Field Nullified" begin
        scratch_result_id = 990003
        survivor_id = 990401

        _cleanup_scratch_delete_graph!(scratch_result_id; deletion_ids=[survivor_id])
        _seed_scratch_result!(scratch_result_id)

        try
            M.Just_a_test_deletion.objects.create(
                "id" => survivor_id,
                "name" => "set-null-child",
                "test_result_set_null" => scratch_result_id
            )

            seeded_query = M.Just_a_test_deletion.objects
            seeded_query.filter("id" => survivor_id)
            @test seeded_query.count() == 1

            seeded_row = seeded_query.values("test_result_set_null").list() |> first
            @test seeded_row[:test_result_set_null] == scratch_result_id

            delete_query = M.Result.objects
            delete_query.filter("resultid" => scratch_result_id)
            total_deleted, deleted_counter = delete_query.delete()

            @test total_deleted == 1
            @test deleted_counter == Dict("result" => 1)
            @test M.Result.objects.filter("resultid" => scratch_result_id).count() == 0

            survivor_query = M.Just_a_test_deletion.objects
            survivor_query.filter("id" => survivor_id)
            @test survivor_query.count() == 1

            survivor_row = survivor_query.values("id", "test_result_set_null").list() |> first
            @test survivor_row[:id] == survivor_id
            @test ismissing(survivor_row[:test_result_set_null]) || isnothing(survivor_row[:test_result_set_null])
        finally
            _cleanup_scratch_delete_graph!(scratch_result_id; deletion_ids=[survivor_id])
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # SET_DEFAULT uses a dedicated scratch FK with a stable default of Result 1.
    # Deleting the scratch parent should preserve the child row and repoint the
    # FK to that default value through the public delete API.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete with SET_DEFAULT: Verify FK Field Reset" begin
        scratch_result_id = 990004
        survivor_id = 990402

        _cleanup_scratch_delete_graph!(scratch_result_id; deletion_ids=[survivor_id])
        _seed_scratch_result!(scratch_result_id)

        try
            M.Just_a_test_deletion.objects.create(
                "id" => survivor_id,
                "name" => "set-default-child",
                "test_result_set_default" => scratch_result_id
            )

            seeded_query = M.Just_a_test_deletion.objects
            seeded_query.filter("id" => survivor_id)
            @test seeded_query.count() == 1

            seeded_row = seeded_query.values("test_result_set_default").list() |> first
            @test seeded_row[:test_result_set_default] == scratch_result_id

            delete_query = M.Result.objects
            delete_query.filter("resultid" => scratch_result_id)
            total_deleted, deleted_counter = delete_query.delete()

            @test total_deleted == 1
            @test deleted_counter == Dict("result" => 1)
            @test M.Result.objects.filter("resultid" => scratch_result_id).count() == 0

            survivor_query = M.Just_a_test_deletion.objects
            survivor_query.filter("id" => survivor_id)
            @test survivor_query.count() == 1

            survivor_row = survivor_query.values("id", "test_result_set_default").list() |> first
            @test survivor_row[:id] == survivor_id
            @test survivor_row[:test_result_set_default] == 1
        finally
            cleanup_default = M.Just_a_test_deletion.objects
            cleanup_default.filter("id" => survivor_id)
            cleanup_default.exists() && cleanup_default.delete()
            _cleanup_scratch_delete_graph!(scratch_result_id)
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # RESTRICT uses existing seeded Driver relationships, so attempting to delete
    # a referenced driver should be rejected before any mutation happens.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete with PROTECT: Verify Deletion is Blocked" begin
        protected_query = M.Driver.objects
        protected_query.filter("driverid" => 1)

        @test protected_query.count() == 1
        @test_throws ArgumentError protected_query.delete()
        @test M.Driver.objects.filter("driverid" => 1).count() == 1
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Nested CASCADE: deleting a Just_a_test_deletion parent must also remove
    # its Just_a_nested_roll_back descendants while leaving sibling branches
    # untouched. This still proves multi-level cascade behavior without
    # depending on the separate Result multi-FK collector path.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Nested CASCADE Delete: Multiple Levels Deep" begin
        scratch_result_id = 990002
        child_ids = [990201, 990202]
        nested_ids = [990301, 990302, 990303]

        _cleanup_scratch_delete_graph!(scratch_result_id; deletion_ids=child_ids, nested_ids=nested_ids)
        _seed_scratch_result!(scratch_result_id)

        try
            M.Just_a_test_deletion.objects.create("id" => child_ids[1], "name" => "nested-parent-a", "test_result" => scratch_result_id)
            M.Just_a_test_deletion.objects.create("id" => child_ids[2], "name" => "nested-parent-b", "test_result" => scratch_result_id)

            M.Just_a_nested_roll_back.objects.create("id" => nested_ids[1], "test" => child_ids[1], "description" => "nested-child-a")
            M.Just_a_nested_roll_back.objects.create("id" => nested_ids[2], "test" => child_ids[1], "description" => "nested-child-b")
            M.Just_a_nested_roll_back.objects.create("id" => nested_ids[3], "test" => child_ids[2], "description" => "nested-child-c")

            child_query = M.Just_a_test_deletion.objects
            child_query.filter("id__@in" => child_ids)
            nested_query = M.Just_a_nested_roll_back.objects
            nested_query.filter("id__@in" => nested_ids)
            @test child_query.count() == 2
            @test nested_query.count() == 3

            delete_query = M.Just_a_test_deletion.objects
            delete_query.filter("id" => child_ids[1])
            total_deleted, deleted_counter = delete_query.delete()

            @test total_deleted == 3
            @test haskey(deleted_counter, "just_a_test_deletion")
            @test haskey(deleted_counter, "just_a_nested_roll_back")
            @test M.Result.objects.filter("resultid" => scratch_result_id).count() == 1
            @test M.Just_a_test_deletion.objects.filter("id" => child_ids[1]).count() == 0
            @test M.Just_a_test_deletion.objects.filter("id" => child_ids[2]).count() == 1
            @test M.Just_a_nested_roll_back.objects.filter("id__@in" => nested_ids[1:2]).count() == 0
            @test M.Just_a_nested_roll_back.objects.filter("id" => nested_ids[3]).count() == 1
        finally
            _cleanup_scratch_delete_graph!(scratch_result_id; deletion_ids=child_ids, nested_ids=nested_ids)
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Delete inspection should expose the same structured metadata as other public
# query inspections, including parameter ordering for positional backends.
# This keeps behaviour-focused integration coverage on the explicit inspection API.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Query Inspection for DELETE Operations" begin
    @testset "DELETE Inspection: Verify SQL and Metadata" begin
        query = M.Just_a_test_deletion.objects
        query.filter("id" => 880001)

        inspection = PormG.QueryBuilder.inspect_query(query; operation=:delete)

        @test inspection[:operation] === :delete
        @test contains(inspection[:sql_text], "DELETE FROM")
        @test occursin("just_a_test_deletion", lowercase(inspection[:sql_text]))
        @test inspection[:parameter_count] == 1
        @test inspection[:parameters] == [880001]

        if inspection[:bucketing] === :positional
            @test haskey(inspection[:parameter_buckets], :where)
            @test inspection[:parameter_buckets][:where] == [880001]
        end
    end
end
