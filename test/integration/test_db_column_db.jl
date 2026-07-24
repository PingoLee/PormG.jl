if !isdefined(Main, :PormG)
    include("common_setup.jl")
end
# column_names() lives in the migration setup helpers.
if !isdefined(Main, :column_names)
    include("common_migration_setup.jl")
end

# ─────────────────────────────────────────────────────────────────────────────
# db_column (#50) — end-to-end against a live database.
#
# The Db_column_scratch / Db_column_child_scratch fixtures declare fields whose
# names differ from their physical columns (sku → "product_sku", FK parent →
# "parent_fk"). This file proves PormG CREATES those db_column physical columns on
# the real backend and that create/get/update/values, FK joins, reverse traversal,
# and the bulk APIs all target the db_column — while every result the user sees
# stays keyed by the FIELD name (the headline #50 contract), verified beyond the
# unit layer where everything renders before any DB round-trip.
# ─────────────────────────────────────────────────────────────────────────────

@testset "db_column: physical columns use the db_column name" begin
    pool = PormG.config[PORMG_DB_FOLDER].connections

    cols = column_names(pool, "db_column_scratch")
    @test "product_sku" in cols        # the db_column physical name exists
    @test !("sku" in cols)             # the field name is NOT a column

    ccols = column_names(pool, "db_column_child_scratch")
    @test "parent_fk" in ccols         # FK local column uses db_column
    @test !("parent" in ccols)

    pkcols = column_names(pool, "db_column_pk_scratch")
    @test "pk_code" in pkcols          # a PRIMARY KEY can use db_column
    @test !("code" in pkcols)
end

# A primary key declared with db_column must round-trip: the INSERT/RETURNING remap keys
# the result by the field name, and the post-insert sequence-sync / id-allocation must
# target the PHYSICAL column (regression for the four key-field fixes in #50).
@testset "db_column: primary key with db_column round-trips (sequence sync)" begin
    M.Db_column_pk_scratch.objects.delete(allow_delete_all=true)
    try
        # Explicit PK value → triggers _update_sequence on the db_column PK column.
        created = M.Db_column_pk_scratch.objects.create("code" => 100, "label" => "first")
        @test created[:code] == 100            # returned keyed by the FIELD name
        @test !haskey(created, :pk_code)

        row = M.Db_column_pk_scratch.objects.filter("code" => 100).values("code", "label").first()
        @test row.code == 100
        @test row.label == "first"

        M.Db_column_pk_scratch.objects.filter("code" => 100).update("label" => "second")
        @test M.Db_column_pk_scratch.objects.filter("code" => 100).values("label").first().label == "second"

        # Bulk insert with explicit PKs → sequence sync + id handling on the db_column column.
        bulk_insert(M.Db_column_pk_scratch.objects, DataFrame(code=[200, 201], label=["b1", "b2"]))
        @test M.Db_column_pk_scratch.objects.count() == 3

        # A subsequent AUTO-PK create must not collide — proves the sequence was advanced
        # past 201 against the physical "pk_code" column (the bug would have errored earlier).
        auto = M.Db_column_pk_scratch.objects.create("label" => "auto")
        @test auto[:code] > 201
    finally
        M.Db_column_pk_scratch.objects.delete(allow_delete_all=true)
    end
end

# allocate_primary_keys pre-reserves ids for a db_column PK — exercises _allocate_pg_ids /
# _allocate_sqlite_ids against the physical column, then proves the reserved ids insert.
@testset "db_column: allocate_primary_keys on a db_column PK" begin
    M.Db_column_pk_scratch.objects.delete(allow_delete_all=true)
    try
        allocated = allocate_primary_keys(M.Db_column_pk_scratch.objects, DataFrame(label=["x", "y", "z"]))
        @test "code" in DataFrames.names(allocated)         # filled under the FIELD name
        @test length(unique(allocated[!, "code"])) == 3     # three distinct ids
        @test all(allocated[!, "code"] .> 0)

        # The reserved ids must insert cleanly into the db_column PK column.
        bulk_insert(M.Db_column_pk_scratch.objects, allocated)
        @test M.Db_column_pk_scratch.objects.count() == 3
    finally
        M.Db_column_pk_scratch.objects.delete(allow_delete_all=true)
    end
end

@testset "db_column: create / get / update / values keyed by field name" begin
    M.Db_column_child_scratch.objects.delete(allow_delete_all=true)
    M.Db_column_scratch.objects.delete(allow_delete_all=true)
    try
        # create() returns a dict keyed by the FIELD name, not the physical column —
        # this exercises the INSERT/RETURNING column → field-name remap.
        created = M.Db_column_scratch.objects.create("sku" => "ABC", "name" => "Widget")
        @test created[:sku] == "ABC"
        @test !haskey(created, :product_sku)

        # filter/values resolve `sku` to "product_sku" in SQL but key the row by `sku`.
        row = M.Db_column_scratch.objects.filter("sku" => "ABC").values("sku", "name").first()
        @test row.sku == "ABC"
        @test row.name == "Widget"
        @test_throws Exception row.product_sku   # the physical column name is not a field

        # update targets the db_column in the SET clause.
        M.Db_column_scratch.objects.filter("sku" => "ABC").update("name" => "Gadget")
        row2 = M.Db_column_scratch.objects.filter("sku" => "ABC").values("name").first()
        @test row2.name == "Gadget"
    finally
        M.Db_column_child_scratch.objects.delete(allow_delete_all=true)
        M.Db_column_scratch.objects.delete(allow_delete_all=true)
    end
end

@testset "db_column: FK forward join and reverse traversal via the db_column column" begin
    M.Db_column_child_scratch.objects.delete(allow_delete_all=true)
    M.Db_column_scratch.objects.delete(allow_delete_all=true)
    try
        parent = M.Db_column_scratch.objects.create("sku" => "P1", "name" => "Parent")
        M.Db_column_child_scratch.objects.create("parent" => parent[:id], "note" => "child-note")

        # Forward join child → parent across the db_column FK ("parent_fk" = "id"),
        # projecting a parent field (itself a db_column field) under an alias.
        fwd = M.Db_column_child_scratch.objects.
            filter("parent__sku" => "P1").values("note", "psku" => "parent__sku").first()
        @test fwd.note == "child-note"
        @test fwd.psku == "P1"

        # Reverse traversal parent → children, filtering on a child column.
        rev = M.Db_column_scratch.objects.
            filter("children__note" => "child-note").values("sku").first()
        @test rev.sku == "P1"
    finally
        M.Db_column_child_scratch.objects.delete(allow_delete_all=true)
        M.Db_column_scratch.objects.delete(allow_delete_all=true)
    end
end

# Live join over an FK whose REFERENCED parent PK is itself renamed via db_column: the
# ON clause must resolve the parent's db_column (child."parent_code_fk" = parent."pk_code").
# Covers fk_target_column's resolved branch end-to-end (beyond the unit/render + Phase 15 DDL).
@testset "db_column: FK join over a renamed parent PK" begin
    M.Db_column_pk_child_scratch.objects.delete(allow_delete_all=true)
    M.Db_column_pk_scratch.objects.delete(allow_delete_all=true)
    try
        M.Db_column_pk_scratch.objects.create("code" => 500, "label" => "RP")
        M.Db_column_pk_child_scratch.objects.create("parent" => 500, "tag" => "rp-child")

        # Forward join child → parent on the renamed parent PK, projecting a parent field.
        fwd = M.Db_column_pk_child_scratch.objects.
            filter("parent__label" => "RP").values("tag", "plabel" => "parent__label").first()
        @test fwd.tag == "rp-child"
        @test fwd.plabel == "RP"

        # Reverse traversal parent → children.
        rev = M.Db_column_pk_scratch.objects.
            filter("pkchildren__tag" => "rp-child").values("label").first()
        @test rev.label == "RP"
    finally
        M.Db_column_pk_child_scratch.objects.delete(allow_delete_all=true)
        M.Db_column_pk_scratch.objects.delete(allow_delete_all=true)
    end
end

# #62: the SAME renamed-parent join, but the child's FK was declared with a STRING target
# ("Db_column_pk_scratch") instead of the model instance. set_models must have resolved it
# so the join ON clause targets the parent's db_column ("pk_code") — proving the runtime
# write-back end-to-end (the table itself was created via the migration prelude in Phase 0).
@testset "db_column: FK join over a renamed parent PK via a STRING target" begin
    M.Db_column_pk_strchild_scratch.objects.delete(allow_delete_all=true)
    M.Db_column_pk_scratch.objects.delete(allow_delete_all=true)
    try
        M.Db_column_pk_scratch.objects.create("code" => 600, "label" => "SP")
        M.Db_column_pk_strchild_scratch.objects.create("parent" => 600, "tag" => "sp-child")

        # Forward join child → parent on the renamed parent PK, projecting a parent field.
        fwd = M.Db_column_pk_strchild_scratch.objects.
            filter("parent__label" => "SP").values("tag", "plabel" => "parent__label").first()
        @test fwd.tag == "sp-child"
        @test fwd.plabel == "SP"

        # Reverse traversal parent → children over the string-declared FK.
        rev = M.Db_column_pk_scratch.objects.
            filter("pkstrchildren__tag" => "sp-child").values("label").first()
        @test rev.label == "SP"
    finally
        M.Db_column_pk_strchild_scratch.objects.delete(allow_delete_all=true)
        M.Db_column_pk_scratch.objects.delete(allow_delete_all=true)
    end
end

@testset "db_column: bulk_insert / bulk_update target the db_column" begin
    M.Db_column_child_scratch.objects.delete(allow_delete_all=true)
    M.Db_column_scratch.objects.delete(allow_delete_all=true)
    try
        df = DataFrame(sku=["B1", "B2"], name=["n1", "n2"])
        bulk_insert(M.Db_column_scratch.objects, df)
        @test M.Db_column_scratch.objects.count() == 2

        # bulk_update: match on the db_column field, set another — SET targets the
        # db_column ("product_sku") while the source columns stay field-named.
        upd = DataFrame(sku=["B1"], name=["updated"])
        bulk_update(M.Db_column_scratch.objects, upd, columns=["name"], match_on=["sku"])
        r = M.Db_column_scratch.objects.filter("sku" => "B1").values("name").first()
        @test r.name == "updated"
    finally
        M.Db_column_child_scratch.objects.delete(allow_delete_all=true)
        M.Db_column_scratch.objects.delete(allow_delete_all=true)
    end
end

# Deleting a parent must cascade across db_column FK columns: a CASCADE child is removed
# and a SET_NULL child has its db_column FK column nulled (covers the deletion.jl key-field
# fixes — the cascade collection filters by "parent_fk" and the SET_NULL UPDATE targets it).
@testset "db_column: cascade delete + SET_NULL over a db_column FK" begin
    M.Db_column_child_scratch.objects.delete(allow_delete_all=true)
    M.Db_column_setnull_child_scratch.objects.delete(allow_delete_all=true)
    M.Db_column_scratch.objects.delete(allow_delete_all=true)
    try
        parent = M.Db_column_scratch.objects.create("sku" => "CASC", "name" => "Parent")
        cascade_child = M.Db_column_child_scratch.objects.create("parent" => parent[:id], "note" => "cascade")
        setnull_child = M.Db_column_setnull_child_scratch.objects.create("parent" => parent[:id], "note" => "setnull")

        # Delete the parent → PormG cascades over the db_column FK columns.
        M.Db_column_scratch.objects.filter("sku" => "CASC").delete()

        # CASCADE child is gone.
        @test M.Db_column_child_scratch.objects.filter("id" => cascade_child[:id]).count() == 0
        # SET_NULL child survives with its db_column FK column nulled.
        survivor = M.Db_column_setnull_child_scratch.objects.filter("id" => setnull_child[:id]).values("note", "parent").first()
        @test survivor.note == "setnull"
        @test survivor.parent === nothing || ismissing(survivor.parent)   # SQL NULL → missing/nothing
    finally
        M.Db_column_child_scratch.objects.delete(allow_delete_all=true)
        M.Db_column_setnull_child_scratch.objects.delete(allow_delete_all=true)
        M.Db_column_scratch.objects.delete(allow_delete_all=true)
    end
end

# bulk_copy is PostgreSQL-only (SQLite falls back to bulk_insert elsewhere).
@testset "db_column: bulk_copy targets the db_column (PostgreSQL)" begin
    pool = PormG.config[PORMG_DB_FOLDER].connections
    if pool isa PormG.PormGPostgres
        M.Db_column_child_scratch.objects.delete(allow_delete_all=true)
        M.Db_column_scratch.objects.delete(allow_delete_all=true)
        try
            df = DataFrame(sku=["C1", "C2"], name=["cn1", "cn2"])
            bulk_copy(M.Db_column_scratch.objects, df)
            @test M.Db_column_scratch.objects.count() == 2
            r = M.Db_column_scratch.objects.filter("sku" => "C1").values("name").first()
            @test r.name == "cn1"
        finally
            M.Db_column_child_scratch.objects.delete(allow_delete_all=true)
            M.Db_column_scratch.objects.delete(allow_delete_all=true)
        end
    else
        @test true  # SQLite: bulk_copy unsupported; covered by bulk_insert above.
    end
end

# #64: an M2M where BOTH participating models' PKs are renamed via db_column. The through-table
# join must target the physical PK columns ("driver_pk"/"sponsor_pk"). `add` writes the through
# table regardless of the fix (it uses through-table columns), so the discriminator is the READ:
# forward/reverse filters join on the parent PK columns and would target a non-existent "code"
# column without the fix.
@testset "db_column: M2M join over renamed PKs (#64)" begin
    M.M2m_rpk_driver_scratch.objects.delete(allow_delete_all=true)
    M.M2m_rpk_sponsor_scratch.objects.delete(allow_delete_all=true)
    try
        sponsor_a = M.M2m_rpk_sponsor_scratch.objects.create("name" => "Petrolux")
        sponsor_b = M.M2m_rpk_sponsor_scratch.objects.create("name" => "AeroFuel")
        driver_x  = M.M2m_rpk_driver_scratch.objects.create("driverref" => "ham44")

        manager = M.M2m_rpk_driver_scratch.sponsors(driver_x)
        @test manager.add(sponsor_a, sponsor_b) === nothing
        @test length(manager.all().list()) == 2            # all() routes through the fixed join

        # Forward: driver → sponsors (through-join on "driver_pk", related-join on "sponsor_pk").
        fwd = M.M2m_rpk_driver_scratch.objects
        fwd.filter("sponsors__name" => "Petrolux")
        fwd.values("driverref")
        fwd_rows = fwd.list()
        @test length(fwd_rows) == 1
        @test fwd_rows[1][:driverref] == "ham44"

        # Reverse: sponsor → drivers via related_name "rpkdrivers".
        rev = M.M2m_rpk_sponsor_scratch.objects
        rev.filter("rpkdrivers__driverref" => "ham44")
        rev.values("name")
        @test Set([row[:name] for row in rev.list()]) == Set(["Petrolux", "AeroFuel"])
    finally
        M.M2m_rpk_driver_scratch.objects.delete(allow_delete_all=true)
        M.M2m_rpk_sponsor_scratch.objects.delete(allow_delete_all=true)
    end
end

# #64: a CTE over a renamed-PK model, joined on the renamed PK field ("code"). The main
# physical-table side resolves "code"→"pk_code"; without the fix the join targets a
# non-existent "code" column and errors. (The CTE side stays the alias "code".)
@testset "db_column: CTE join over a renamed PK (#64)" begin
    # Clear the CASCADE children before the parent so this testset is self-contained and
    # order-independent (mirrors the renamed-parent-PK testsets above).
    M.Db_column_pk_child_scratch.objects.delete(allow_delete_all=true)
    M.Db_column_pk_strchild_scratch.objects.delete(allow_delete_all=true)
    M.Db_column_pk_scratch.objects.delete(allow_delete_all=true)
    try
        M.Db_column_pk_scratch.objects.create("code" => 700, "label" => "CT")
        M.Db_column_pk_scratch.objects.create("code" => 701, "label" => "other")

        cte = M.Db_column_pk_scratch.objects
        cte.filter("label" => "CT")
        cte.values("code", "label")

        main = M.Db_column_pk_scratch.objects
        main.with("rpk_cte" => cte, join_field="code" => "code", join_type="INNER")
        main.values("code", "lbl" => "rpk_cte__label")
        rows = main.list()
        @test length(rows) == 1                 # INNER join keeps only the matched code (700)
        @test rows[1][:code] == 700
        @test rows[1][:lbl] == "CT"
    finally
        M.Db_column_pk_child_scratch.objects.delete(allow_delete_all=true)
        M.Db_column_pk_strchild_scratch.objects.delete(allow_delete_all=true)
        M.Db_column_pk_scratch.objects.delete(allow_delete_all=true)
    end
end
