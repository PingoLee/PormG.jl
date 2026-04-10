"""
Integration tests for field validation with database round-trip testing.

This file complements the unit suite by exercising real persistence against the
seeded Formula 1 integration schema. It focuses on field types and delete
behaviour that require an actual database round-trip rather than pure SQL
inspection or validator-only coverage.

Implemented here:
- Duration, date, and time round-trip assertions against seeded integration rows.
- UUID, URL, slug, and JSON round-trip assertions against a dedicated scratch table.
- Cascading delete and nested cascading delete behaviour using scratch fixtures.
- RESTRICT/PROTECT-style delete blocking through existing integration foreign keys.
- DELETE inspection metadata through the public query surface.

Pending here:
- DateTime timezone round-trips.
"""

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# Guard against Revise re-include: module re-definition + const rebinding would error,
# and set_models re-registration would duplicate related_objects entries.
if !@isdefined(ProtectM)
    module delete_protect_scratch_models
    import PormG.Models

    Delete_protect_parent_scratch = Models.Model("delete_protect_parent_scratch",
        id = Models.IDField(),
        name = Models.CharField()
    )

    Delete_protect_child_scratch = Models.Model("delete_protect_child_scratch",
        id = Models.IDField(),
        parent_id = Models.ForeignKey(Delete_protect_parent_scratch, pk_field = "id", on_delete = "PROTECT", null = true, related_name = "protect_children"),
        label = Models.CharField(null = true)
    )

    end

    Models.set_models(delete_protect_scratch_models, joinpath(@__DIR__, PORMG_DB_FOLDER))
    const ProtectM = delete_protect_scratch_models
end

if !@isdefined(KeylessM)
    module keyless_delete_scratch_models
    import PormG.Models

    Keyless_delete_scratch = Models.Model("keyless_delete_scratch",
        bucket = Models.CharField(),
        label = Models.CharField(null = true)
    )

    end

    Models.set_models(keyless_delete_scratch_models, joinpath(@__DIR__, PORMG_DB_FOLDER))
    const KeylessM = keyless_delete_scratch_models
end

if !@isdefined(DoNothingM)
    module do_nothing_delete_scratch_models
    import PormG.Models

    Do_nothing_parent_scratch = Models.Model("do_nothing_parent_scratch",
        id = Models.IDField(),
        name = Models.CharField()
    )

    Do_nothing_child_scratch = Models.Model("do_nothing_child_scratch",
        id = Models.IDField(),
        parent_id = Models.ForeignKey(Do_nothing_parent_scratch, pk_field = "id", on_delete = "DO_NOTHING", null = false, related_name = "do_nothing_children"),
        label = Models.CharField(null = true)
    )

    end

    Models.set_models(do_nothing_delete_scratch_models, joinpath(@__DIR__, PORMG_DB_FOLDER))
    const DoNothingM = do_nothing_delete_scratch_models
end

if !@isdefined(SetNullGuardM)
    module set_null_guard_scratch_models
    import PormG.Models

    Set_null_guard_parent_scratch = Models.Model("set_null_guard_parent_scratch",
        id = Models.IDField(),
        name = Models.CharField()
    )

    # Intentionally invalid: SET_NULL on a non-null field. set_models will log a warning;
    # this model exists only to exercise the delete guard that rejects this configuration.
    Set_null_guard_child_scratch = Models.Model("set_null_guard_child_scratch",
        id = Models.IDField(),
        parent_id = Models.ForeignKey(Set_null_guard_parent_scratch, pk_field = "id", on_delete = "SET_NULL", null = false, related_name = "nonnull_children"),
        label = Models.CharField(null = true)
    )

    end

    Models.set_models(set_null_guard_scratch_models, joinpath(@__DIR__, PORMG_DB_FOLDER))
    const SetNullGuardM = set_null_guard_scratch_models
end

_strip_ansi(text::AbstractString) = replace(String(text), r"\e\[[0-9;]*m" => "")

_scratch_id_type(pool) = pool isa PormG.PormGPostgres ? "SERIAL" : "INTEGER"

function _drop_delete_protect_scratch_schema!()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    PormG.ConnectionPool.fetch(pool, "DROP TABLE IF EXISTS \"delete_protect_child_scratch\";")
    PormG.ConnectionPool.fetch(pool, "DROP TABLE IF EXISTS \"delete_protect_parent_scratch\";")
    return nothing
end

function _reset_delete_protect_scratch_schema!()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    _drop_delete_protect_scratch_schema!()

    # PostgreSQL needs SERIAL so that PormG's _update_sequence can find the backing sequence
    # after inserting explicit IDs. SQLite uses INTEGER PRIMARY KEY (maps to ROWID, no sequence).
    id_type = _scratch_id_type(pool)

    PormG.ConnectionPool.fetch(pool, """
    CREATE TABLE \"delete_protect_parent_scratch\" (
        \"id\" $id_type PRIMARY KEY,
        \"name\" TEXT NOT NULL
    );
    """)

    # Inline REFERENCES is valid on both SQLite and PostgreSQL.
    PormG.ConnectionPool.fetch(pool, """
    CREATE TABLE \"delete_protect_child_scratch\" (
        \"id\" $id_type PRIMARY KEY,
        \"parent_id\" INTEGER REFERENCES \"delete_protect_parent_scratch\" (\"id\"),
        \"label\" TEXT
    );
    """)

    return nothing
end

function _drop_keyless_delete_scratch_schema!()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    PormG.ConnectionPool.fetch(pool, "DROP TABLE IF EXISTS \"keyless_delete_scratch\";")
    return nothing
end

function _reset_keyless_delete_scratch_schema!()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    _drop_keyless_delete_scratch_schema!()

    PormG.ConnectionPool.fetch(pool, """
    CREATE TABLE \"keyless_delete_scratch\" (
        \"bucket\" TEXT NOT NULL,
        \"label\" TEXT
    );
    """)

    return nothing
end

function _drop_do_nothing_delete_scratch_schema!()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    PormG.ConnectionPool.fetch(pool, "DROP TABLE IF EXISTS \"do_nothing_child_scratch\";")
    PormG.ConnectionPool.fetch(pool, "DROP TABLE IF EXISTS \"do_nothing_parent_scratch\";")
    return nothing
end

function _reset_do_nothing_delete_scratch_schema!()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    _drop_do_nothing_delete_scratch_schema!()

    id_type = _scratch_id_type(pool)

    PormG.ConnectionPool.fetch(pool, """
    CREATE TABLE \"do_nothing_parent_scratch\" (
        \"id\" $id_type PRIMARY KEY,
        \"name\" TEXT NOT NULL
    );
    """)

    PormG.ConnectionPool.fetch(pool, """
    CREATE TABLE \"do_nothing_child_scratch\" (
        \"id\" $id_type PRIMARY KEY,
        \"parent_id\" INTEGER NOT NULL REFERENCES \"do_nothing_parent_scratch\" (\"id\"),
        \"label\" TEXT
    );
    """)

    return nothing
end

function _drop_set_null_guard_scratch_schema!()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    PormG.ConnectionPool.fetch(pool, "DROP TABLE IF EXISTS \"set_null_guard_child_scratch\";")
    PormG.ConnectionPool.fetch(pool, "DROP TABLE IF EXISTS \"set_null_guard_parent_scratch\";")
    return nothing
end

function _reset_set_null_guard_scratch_schema!()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    _drop_set_null_guard_scratch_schema!()

    id_type = _scratch_id_type(pool)

    PormG.ConnectionPool.fetch(pool, """
    CREATE TABLE \"set_null_guard_parent_scratch\" (
        \"id\" $id_type PRIMARY KEY,
        \"name\" TEXT NOT NULL
    );
    """)

    PormG.ConnectionPool.fetch(pool, """
    CREATE TABLE \"set_null_guard_child_scratch\" (
        \"id\" $id_type PRIMARY KEY,
        \"parent_id\" INTEGER NOT NULL REFERENCES \"set_null_guard_parent_scratch\" (\"id\"),
        \"label\" TEXT
    );
    """)

    return nothing
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

    # DateTimeField timezone round-trips now live in test_django_contract.jl via
    # Django_contract_scratch, which provides dedicated DateTimeField coverage on
    # real adapters without leaving a placeholder broken test here.

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
    # These field types still have no Formula 1 seed-table representation, so we
    # exercise them through a dedicated scratch table created on demand. That keeps
    # the public ORM round-trip coverage real without fabricating F1 fixture columns.
    # ─────────────────────────────────────────────────────────────────────────
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

# ─────────────────────────────────────────────────────────────────────────────
# Delete operations: use scratch Result rows plus real reverse relationships so
# the delete collector has to execute CASCADE and RESTRICT logic against the DB.
# These tests verify behaviour that unit SQL inspection cannot prove.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Delete Operations with FK Constraints" begin
    # ─────────────────────────────────────────────────────────────────────────
    # A filtered delete that matches no rows should short-circuit cleanly and
    # report zero work instead of warning, mutating state, or building a bogus
    # deletion plan. This covers the execute-time do_exists early return.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete with No Matches: Returns Empty Count" begin
        missing_slug = "delete-missing-990508"

        _cleanup_field_validation_scratch_rows!([missing_slug])

        delete_query = M.Field_validation_scratch.objects
        delete_query.filter("slug" => missing_slug)

        total_deleted, deleted_counter = delete_query.delete()

        @test total_deleted == 0
        @test isempty(deleted_counter)
        @test !M.Field_validation_scratch.objects.filter("slug" => missing_slug).exists()
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Public delete should refuse unfiltered destructive operations unless the
    # caller explicitly opts in. This keeps the guard covered by an executing
    # integration test instead of only by indirect cleanup call sites.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete Guard: Unfiltered Delete is Rejected" begin
        scratch_slug = "delete-guard-990507"

        try
            _seed_field_validation_scratch!(
                uuid_token=string(uuid4()),
                canonical_url="https://example.com/f1/delete-guard",
                slug=scratch_slug,
                payload=Dict("kind" => "guard")
            )

            err = try
                M.Field_validation_scratch.objects.delete()
                nothing
            catch e
                e
            end

            @test err !== nothing
            @test occursin("delete must have a filter", lowercase(string(err)))
            @test M.Field_validation_scratch.objects.filter("slug" => scratch_slug).count() == 1
        finally
            _cleanup_field_validation_scratch_rows!([scratch_slug])
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Keyless fixture tables have a dedicated delete path: filtered execution is
    # intentionally rejected, while delete-all inspection must still emit a
    # direct table DELETE for maintenance workflows.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete on Keyless Models: Guard and Direct SQL" begin
        lap_query = M.Lap_times.objects
        lap_query.filter("raceid" => 841, "driverid" => 20, "lap" => 1)

        @test lap_query.count() == 1
        @test_throws ArgumentError lap_query.delete()
        @test lap_query.count() == 1

        inspection = M.Lap_times.objects.delete(allow_delete_all = true, show_query = :dict)
        @test inspection[:operation] === :delete
        @test inspection[:parameter_count] == 0
        @test isempty(inspection[:parameters])
        @test occursin("delete from lap_times", lowercase(inspection[:sql_text]))

        _reset_keyless_delete_scratch_schema!()

        try
            KeylessM.Keyless_delete_scratch.objects.create("bucket" => "alpha", "label" => "row-a")
            KeylessM.Keyless_delete_scratch.objects.create("bucket" => "beta", "label" => "row-b")

            @test KeylessM.Keyless_delete_scratch.objects.count() == 2

            total_deleted, deleted_counter = KeylessM.Keyless_delete_scratch.objects.delete(allow_delete_all = true)

            @test total_deleted == 2
            @test deleted_counter == Dict("keyless_delete_scratch" => 2)
            @test !KeylessM.Keyless_delete_scratch.objects.exists()
        finally
            _drop_keyless_delete_scratch_schema!()
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # DO_NOTHING should not be preemptively handled by the collector. The ORM
    # attempts the parent delete directly and defers the final outcome to the
    # backend: PostgreSQL rejects the FK violation, while SQLite may allow the
    # delete if foreign-key enforcement is not active for the scratch schema.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete with DO_NOTHING: ORM Defers to Database" begin
        parent_id = 920001
        child_id = 920101

        _reset_do_nothing_delete_scratch_schema!()

        try
            DoNothingM.Do_nothing_parent_scratch.objects.create(
                "id" => parent_id,
                "name" => "do-nothing-parent"
            )
            DoNothingM.Do_nothing_child_scratch.objects.create(
                "id" => child_id,
                "parent_id" => parent_id,
                "label" => "db-protected-child"
            )

            inspect_query = DoNothingM.Do_nothing_parent_scratch.objects
            inspect_query.filter("id" => parent_id)
            inspection = inspect_query.delete(show_query = :dict)

            @test inspection isa Dict
            @test inspection[:operation] == :delete
            @test occursin("delete from do_nothing_parent_scratch", lowercase(inspection[:sql_text]))

            pool = PormG.config[PORMG_DB_FOLDER].connections
            delete_query = DoNothingM.Do_nothing_parent_scratch.objects
            delete_query.filter("id" => parent_id)

            delete_result = try
                delete_query.delete()
            catch e
                e
            end

            if pool isa PormG.PormGPostgres
                @test delete_result !== nothing
                @test !(delete_result isa Tuple)
                @test DoNothingM.Do_nothing_parent_scratch.objects.filter("id" => parent_id).exists()
            else
                @test delete_result == (1, Dict("do_nothing_parent_scratch" => 1))
                @test !DoNothingM.Do_nothing_parent_scratch.objects.filter("id" => parent_id).exists()
            end

            @test DoNothingM.Do_nothing_child_scratch.objects.filter("id" => child_id).exists()
        finally
            _drop_do_nothing_delete_scratch_schema!()
        end
    end

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
    # SET_NULL requires a nullable FK. If a model declares SET_NULL on a non-null
    # field, delete must fail before any SQL mutation so the schema contract is
    # not silently violated.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete with SET_NULL: Non-null FK is Rejected" begin
        parent_id = 930001
        child_id = 930101

        _reset_set_null_guard_scratch_schema!()

        try
            SetNullGuardM.Set_null_guard_parent_scratch.objects.create(
                "id" => parent_id,
                "name" => "set-null-guard-parent"
            )
            SetNullGuardM.Set_null_guard_child_scratch.objects.create(
                "id" => child_id,
                "parent_id" => parent_id,
                "label" => "nonnull-child"
            )

            delete_query = SetNullGuardM.Set_null_guard_parent_scratch.objects
            delete_query.filter("id" => parent_id)

            err = try
                delete_query.delete()
                nothing
            catch e
                e
            end

            @test err isa ArgumentError
            msg = _strip_ansi(lowercase(sprint(showerror, err)))
            @test occursin("parent_id", msg)
            @test occursin("not allow null", msg)
            @test SetNullGuardM.Set_null_guard_parent_scratch.objects.filter("id" => parent_id).exists()
            @test SetNullGuardM.Set_null_guard_child_scratch.objects.filter("id" => child_id).exists()
        finally
            _drop_set_null_guard_scratch_schema!()
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
    @testset "Delete with RESTRICT: Verify Deletion is Blocked" begin
        restricted_query = M.Driver.objects
        restricted_query.filter("driverid" => 1)

        @test restricted_query.count() == 1

        err = try
            restricted_query.delete()
            nothing
        catch e
            e
        end

        @test err isa ArgumentError
        msg = _strip_ansi(lowercase(sprint(showerror, err)))
        @test occursin("cannot delete driver", msg)
        @test occursin("on delete restrict", msg)
        @test occursin(".driverid", msg)
        @test M.Driver.objects.filter("driverid" => 1).count() == 1
    end

    # ─────────────────────────────────────────────────────────────────────────
    # PROTECT should only block delete when matching child rows exist.
    # This guards the public delete API against false positives during
    # show_query=:dict inspection while still proving the user-facing error
    # points at the deleted parent and the referencing child field.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete with PROTECT: Empty reverse relation does not block inspection" begin
        orphan_parent_id = 910001
        protected_parent_id = 910002
        child_id = 910101

        _reset_delete_protect_scratch_schema!()

        try
            ProtectM.Delete_protect_parent_scratch.objects.create(
                "id" => orphan_parent_id,
                "name" => "orphan-parent"
            )

            @test !ProtectM.Delete_protect_child_scratch.objects.filter("parent_id" => orphan_parent_id).exists()

            inspect_query = ProtectM.Delete_protect_parent_scratch.objects
            inspect_query.filter("id" => orphan_parent_id)
            inspection = inspect_query.delete(show_query = :dict)

            @test inspection isa Dict
            @test inspection[:operation] == :delete
            @test occursin("delete from delete_protect_parent_scratch", lowercase(inspection[:sql_text]))

            delete_query = ProtectM.Delete_protect_parent_scratch.objects
            delete_query.filter("id" => orphan_parent_id)
            total_deleted, deleted_counter = delete_query.delete()

            @test total_deleted == 1
            @test deleted_counter == Dict("delete_protect_parent_scratch" => 1)
            @test !ProtectM.Delete_protect_parent_scratch.objects.filter("id" => orphan_parent_id).exists()

            ProtectM.Delete_protect_parent_scratch.objects.create(
                "id" => protected_parent_id,
                "name" => "protected-parent"
            )
            ProtectM.Delete_protect_child_scratch.objects.create(
                "id" => child_id,
                "parent_id" => protected_parent_id,
                "label" => "blocking-child"
            )

            protected_query = ProtectM.Delete_protect_parent_scratch.objects
            protected_query.filter("id" => protected_parent_id)

            err = try
                protected_query.delete()
                nothing
            catch e
                e
            end

            @test err isa ArgumentError
            msg = _strip_ansi(sprint(showerror, err))
            @test occursin("Cannot delete delete_protect_parent_scratch", msg)
            @test occursin("delete_protect_child_scratch.parent_id", msg)
            @test occursin("ON DELETE PROTECT", msg)
            @test ProtectM.Delete_protect_parent_scratch.objects.filter("id" => protected_parent_id).exists()
        finally
            _drop_delete_protect_scratch_schema!()
        end
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
# Delete Integration: Functional Verification
# Verify that a simple delete operation actually removes the record 
# from the database. This complements the pure SQL inspection in unit tests.
# ─────────────────────────────────────────────────────────────────────────────
@testset "DELETE Integration: Functional Verification" begin
    # Cleanup and seed a specific record
    scratch_id = 880002
    _cleanup_scratch_delete_graph!(0; deletion_ids=[scratch_id])
    
    M.Just_a_test_deletion.objects.create("id" => scratch_id, "name" => "to be deleted")
    @test M.Just_a_test_deletion.objects.filter("id" => scratch_id).exists()

    # Execute delete
    M.Just_a_test_deletion.objects.filter("id" => scratch_id).delete()

    # Verify removal
    @test !M.Just_a_test_deletion.objects.filter("id" => scratch_id).exists()
end
