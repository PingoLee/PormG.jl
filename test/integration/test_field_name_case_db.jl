if !isdefined(Main, :PormG)
    include("common_setup.jl")
end
# column_names()/table_exists() live in the migration setup helpers.
if !isdefined(Main, :column_names)
    include("common_migration_setup.jl")
end

# ─────────────────────────────────────────────────────────────────────────────
# Case preservation (#57) — end-to-end against a live database.
#
# The Case_preserve_parent_scratch / _child_scratch fixtures declare camelCase
# columns (driverRef, foreName, parentRef, lapTime). This file proves PormG
# CREATES genuinely mixed-case columns on the real backend, and that
# insert/select/update plus forward FK joins and reverse traversal all resolve
# them case-sensitively — the headline #57 capability, verified beyond the unit
# layer (where everything renders before any DB round-trip).
#
# Table/model names stay lowercase (frozen #33); only the columns are mixed-case.
# ─────────────────────────────────────────────────────────────────────────────

@testset "Case preservation: physical columns are mixed-case" begin
    pool = PormG.config[PORMG_DB_FOLDER].connections

    parent_cols = column_names(pool, "case_preserve_parent_scratch")
    @test "driverRef" in parent_cols
    @test "foreName" in parent_cols
    @test !("driverref" in parent_cols)   # the lowercased form must NOT exist

    child_cols = column_names(pool, "case_preserve_child_scratch")
    @test "parentRef" in child_cols
    @test "lapTime" in child_cols
end

@testset "Case preservation: insert / select / update round-trip" begin
    M.Case_preserve_child_scratch.objects.delete(allow_delete_all=true)
    M.Case_preserve_parent_scratch.objects.delete(allow_delete_all=true)
    try
        parent = M.Case_preserve_parent_scratch.objects.create(
            "driverRef" => "senna", "foreName" => "Ayrton")
        M.Case_preserve_child_scratch.objects.create(
            "parentRef" => parent[:id], "lapTime" => 90)

        # Read back through mixed-case field paths (case-sensitive resolution).
        row = M.Case_preserve_parent_scratch.objects.
            filter("driverRef" => "senna").values("driverRef", "foreName").first()
        @test row.driverRef == "senna"
        @test row.foreName == "Ayrton"

        # Update a mixed-case column.
        M.Case_preserve_parent_scratch.objects.
            filter("driverRef" => "senna").update("foreName" => "Ayrton Senna")
        row2 = M.Case_preserve_parent_scratch.objects.
            filter("driverRef" => "senna").values("foreName").first()
        @test row2.foreName == "Ayrton Senna"
    finally
        M.Case_preserve_child_scratch.objects.delete(allow_delete_all=true)
        M.Case_preserve_parent_scratch.objects.delete(allow_delete_all=true)
    end
end

@testset "Case preservation: forward FK join and reverse traversal" begin
    M.Case_preserve_child_scratch.objects.delete(allow_delete_all=true)
    M.Case_preserve_parent_scratch.objects.delete(allow_delete_all=true)
    try
        parent = M.Case_preserve_parent_scratch.objects.create(
            "driverRef" => "prost", "foreName" => "Alain")
        M.Case_preserve_child_scratch.objects.create(
            "parentRef" => parent[:id], "lapTime" => 88)

        # Forward join: child → parent across a mixed-case FK, projecting a
        # mixed-case parent column under an explicit (lowercase) alias.
        fwd = M.Case_preserve_child_scratch.objects.
            filter("parentRef__driverRef" => "prost").
            values("lapTime", "pforename" => "parentRef__foreName").first()
        @test fwd.lapTime == 88
        @test fwd.pforename == "Alain"

        # Reverse traversal: parent → children via related_name, filtering on a
        # mixed-case child column.
        rev = M.Case_preserve_parent_scratch.objects.
            filter("children__lapTime" => 88).values("driverRef").first()
        @test rev.driverRef == "prost"
    finally
        M.Case_preserve_child_scratch.objects.delete(allow_delete_all=true)
        M.Case_preserve_parent_scratch.objects.delete(allow_delete_all=true)
    end
end
