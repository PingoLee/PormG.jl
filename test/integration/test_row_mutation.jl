if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# ─────────────────────────────────────────────────────────────────────────────
# PormGRow mutation: assignment validation and dirty tracking
# Verifies write-side field-name normalization, unknown-field rejection,
# projected-FK validation, and primary-key mutation protection.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PormGRow assignment validation" begin
    row = M.Driver_standings.objects.values(
        "driverstandingsid",
        "positiontext",
        "driverid",
        "driverid__forename",
    ).limit(1).first()

    original_position_text = row.positiontext

    row.positionText = "Phase 2 pending"
    @test row.positiontext == "Phase 2 pending"
    @test row[:positionText] == "Phase 2 pending"
    @test :positiontext in row._dirty

    row.positiontext = original_position_text
    @test row.positionText == original_position_text
    @test :positiontext in row._dirty

    @test_throws ArgumentError (row.unknownField = 1)
    @test_throws ArgumentError (row.badFk__name = "x")

    driver = M.Driver.objects.get("driverref" => "hamilton")
    @test_throws ArgumentError (driver.driverId = driver.driverid + 1)
end

# ─────────────────────────────────────────────────────────────────────────────
# PormGRow save: own-table update and inspection contract
# Verifies that show_query mode plans an UPDATE without execution, preserves
# dirty state, and execute mode persists the change and clears dirty state.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PormGRow own-table save" begin
    label = "row_mutation_save_$(uuid4())"
    updated_label = "$(label)_updated"
    created = nothing

    try
        created = M.Just_a_test_deletion.objects.create("name" => label)
        row = M.Just_a_test_deletion.objects.get("id" => created[:id])

        row.name = updated_label
        dirty_before_inspection = copy(row._dirty)
        inspections = row.save(show_query=:sql)

        @test inspections isa Vector
        @test length(inspections) == 1
        @test inspections[1] isa String
        @test occursin("UPDATE", uppercase(inspections[1]))
        @test row._dirty == dirty_before_inspection

        unchanged = M.Just_a_test_deletion.objects.get("id" => created[:id])
        @test unchanged.name == label

        saved = row.save()
        @test saved === row
        @test isempty(row._dirty)

        reloaded = M.Just_a_test_deletion.objects.get("id" => created[:id])
        @test reloaded.name == updated_label
    finally
        if created !== nothing
            M.Just_a_test_deletion.objects.filter("id" => created[:id]).delete()
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# PormGRow save: projected related-table updates and FK race guard
# Verifies that dirty `fk__field` values route to the related model table, and
# that mutating an FK and its projected fields before one save is rejected.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PormGRow projected save" begin
    parent = nothing
    payload = nothing

    try
        parent = M.Bulk_update_required_parent_scratch.objects.create("label" => "row_parent_$(uuid4())")
        payload = M.Bulk_update_payload_scratch.objects.create(
            "label" => "row_payload_$(uuid4())",
            "required_parent_id" => parent[:id],
        )

        row = M.Bulk_update_payload_scratch.objects.filter("id" => payload[:id]).values(
            "id",
            "required_parent_id",
            "required_parent_id__label",
        ).get()

        updated_parent_label = "row_parent_updated_$(uuid4())"
        row.required_parent_id__label = updated_parent_label

        inspections = row.save(show_query=:dict)
        @test inspections isa Vector
        @test length(inspections) == 1
        @test inspections[1] isa Dict
        @test inspections[1][:operation] == :update
        @test !isempty(row._dirty)

        row.save()
        @test isempty(row._dirty)

        parent_after = M.Bulk_update_required_parent_scratch.objects.get("id" => parent[:id])
        @test parent_after.label == updated_parent_label

        race_row = M.Bulk_update_payload_scratch.objects.filter("id" => payload[:id]).values(
            "id",
            "required_parent_id",
            "required_parent_id__label",
        ).get()
        race_row.required_parent_id = parent[:id]
        race_row.required_parent_id__label = "race_guard_$(uuid4())"
        @test_throws ArgumentError race_row.save()
    finally
        if payload !== nothing
            M.Bulk_update_payload_scratch.objects.filter("id" => payload[:id]).delete()
        end
        if parent !== nothing
            M.Bulk_update_required_parent_scratch.objects.filter("id" => parent[:id]).delete()
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# PormGRow save: unsupported model identifiers
# Verifies that save() rejects keyless rows and rows whose model has multiple
# primary-key fields before attempting any SQL execution.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PormGRow unsupported save targets" begin
    keyless = M.Lap_times.objects.values("raceid", "driverid", "lap", "position").limit(1).first()
    keyless.position = keyless.position
    @test_throws ArgumentError keyless.save()

    multi_pk_model = Models.Model("row_mutation_multi_pk_scratch",
        firstid = Models.IDField(),
        secondid = Models.IDField(),
        label = Models.CharField(),
    )
    multi_pk_row = PormGRow(Dict(:firstid => 1, :secondid => 2, :label => "before"), multi_pk_model)
    multi_pk_row.label = "after"
    @test_throws ArgumentError multi_pk_row.save()
end

# ─────────────────────────────────────────────────────────────────────────────
# PormGRow save: FK pk_field not resolved (BUG-6 regression)
# Verifies that save() raises ArgumentError when a projected FK update is
# attempted but fk_meta.pk_field is nothing (model not fully initialised).
# Before the fix, String(nothing) = "nothing" produced a silent wrong query.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PormGRow save FK pk_field guard (BUG-6)" begin
    # Build a synthetic FK whose pk_field has NOT been set (simulating an
    # uninitialised model that was never passed through set_models()).
    unresolved_fk = Models.ForeignKey("SomeModel", on_delete=Models.CASCADE)
    # Confirm pk_field is indeed nothing before we proceed
    @test unresolved_fk.pk_field === nothing

    # Create a synthetic model with that unresolved FK
    synthetic_model = Models.Model("pk_guard_scratch",
        id       = Models.IDField(),
        parentid = unresolved_fk,
    )
    # Synthetic PormGRow: data contains both the FK value and a projected field
    row_data = Dict{Symbol,Any}(
        :id       => 1,
        :parentid => 99,
        :parentid__label => "new label",
    )
    row = PormGRow(row_data, synthetic_model)

    # Mark the projected field as dirty (simulate a setproperty! call)
    push!(getfield(row, :_dirty), :parentid__label)

    # save() must detect pk_field === nothing and throw ArgumentError
    # instead of building a filter on the literal string "nothing".
    @test_throws ArgumentError row.save()
end