if !isdefined(Main, :PormG)
    include("common_setup.jl")
end
# column_names()/table_exists() live in the migration setup helpers.
if !isdefined(Main, :column_names)
    include("common_migration_setup.jl")
end

# ─────────────────────────────────────────────────────────────────────────────
# db_table (#59) — end-to-end against a live database.
#
# The Db_table_scratch / Db_table_child_scratch / Db_table_col_scratch fixtures declare a LOGICAL
# model name that is lowercase (as every model name must be, #300) and a PHYSICAL table that is
# mixed-case — the spelling PormG had no way to express before this option.
#
# What only a live database can prove, and the unit layer cannot:
#
#   * the table is CREATED under the mixed-case name (not a folded twin);
#   * every subsequent statement finds it — on PostgreSQL a quoted identifier is case-sensitive, so
#     any renderer still emitting the logical name fails loudly with `relation … does not exist`
#     rather than rendering a plausible-looking string; and
#   * the FK constraint actually binds, which is the half that could silently attach to a DIFFERENT
#     table when the CREATE and the REFERENCES disagreed.
#
# SQLite's identifiers compare case-insensitively and so CANNOT distinguish the two spellings. It is
# covered anyway — the point is that the backend which masks the bug does not regress — but the
# case-sensitivity assertions below are meaningful only on PostgreSQL.
# ─────────────────────────────────────────────────────────────────────────────

const DBT_IS_PG = PormG.config[PORMG_DB_FOLDER].connections isa PormG.PormGPostgres

@testset "db_table: the physical table is created under the db_table name" begin
    pool = PormG.config[PORMG_DB_FOLDER].connections

    # The mixed-case physical table exists and has the declared columns. `column_names` returning a
    # non-empty set IS the existence proof — a missing table yields an empty result.
    cols = column_names(pool, "Db_Table_Scratch")
    @test "id" in cols
    @test "name" in cols

    # db_table and db_column compose: mixed-case TABLE, renamed COLUMN, same model.
    ccols = column_names(pool, "Db_Table_Col_Scratch")
    @test "product_sku" in ccols
    @test !("sku" in ccols)

    # The LOGICAL name must not exist as a second, folded table. On PostgreSQL these are genuinely
    # distinct identifiers, so a stray unquoted-DDL path would have created `db_table_scratch`
    # alongside `Db_Table_Scratch` — exactly the "one declaration, two tables" split #300 describes.
    # Skipped on SQLite, where the two names address the same table by definition.
    if DBT_IS_PG
        @test isempty(column_names(pool, "db_table_scratch"))
    end
end

@testset "db_table: CRUD round-trips against the mixed-case table" begin
    M.Db_table_scratch.objects.delete(allow_delete_all=true)

    created = M.Db_table_scratch.objects.create("name" => "senna")
    @test created[:name] == "senna"

    # Read back through the normal query path — this is the assertion that fails with
    # `relation "db_table_scratch" does not exist` if any renderer kept the logical name.
    row = M.Db_table_scratch.objects.filter("name" => "senna").values("id", "name").first()
    @test row.name == "senna"

    M.Db_table_scratch.objects.filter("name" => "senna").update("name" => "prost")
    @test M.Db_table_scratch.objects.filter("name" => "prost").count() == 1

    # DELETE has its own renderer (deletion.jl), which used to write the table bare and lowercased
    # while its `IN (…)` subquery quoted it — one statement, two spellings.
    M.Db_table_scratch.objects.filter("name" => "prost").delete()
    @test M.Db_table_scratch.objects.count() == 0
end

@testset "db_table: foreign keys bind to the parent's physical table" begin
    M.Db_table_child_scratch.objects.delete(allow_delete_all=true)
    M.Db_table_scratch.objects.delete(allow_delete_all=true)

    parent = M.Db_table_scratch.objects.create("name" => "ferrari")
    pid = parent[:id]

    # The INSERT only succeeds if the FK constraint points at the table the parent actually lives
    # in. A constraint bound to a folded twin would reject this row.
    child = M.Db_table_child_scratch.objects.create("parent" => pid, "note" => "sf90")
    @test child[:note] == "sf90"

    # Forward join CHILD → PARENT puts the parent's physical table in the JOIN clause.
    joined = M.Db_table_child_scratch.objects.filter("note" => "sf90").values("note", "parent__name").first()
    @test joined.parent__name == "ferrari"

    # Reverse traversal PARENT → CHILD, the other direction through the same relation.
    back = M.Db_table_scratch.objects.filter("dbtchildren__note" => "sf90").values("name").first()
    @test back.name == "ferrari"

    # ON DELETE CASCADE reaches the child through the FK — proving the constraint is live in the
    # database, not merely rendered into the DDL text.
    M.Db_table_scratch.objects.filter("id" => pid).delete()
    @test M.Db_table_child_scratch.objects.count() == 0
end

@testset "db_table: bulk paths and PK allocation target the physical table" begin
    M.Db_table_scratch.objects.delete(allow_delete_all=true)

    # bulk_insert goes through its own INSERT builder, and PK allocation queries the sequence
    # (PostgreSQL) / sqlite_sequence (SQLite) named after the PHYSICAL table.
    bulk_insert(M.Db_table_scratch.objects, DataFrame(name=["a", "b", "c"]))
    @test M.Db_table_scratch.objects.count() == 3

    # A subsequent auto-PK create must not collide, which means the sequence was found and advanced
    # — the lookup is built from the table name, so a wrong name silently no-ops instead of erroring.
    extra = M.Db_table_scratch.objects.create("name" => "d")
    @test extra[:name] == "d"
    @test M.Db_table_scratch.objects.count() == 4

    M.Db_table_scratch.objects.delete(allow_delete_all=true)
end

# The failure with the worst blast radius: the planner matches the LIVE schema (keyed by the
# physical table name read from the database) against the DECLARED schema. If the declared side
# keyed on anything else, a db_table model would read as "a table to create" PLUS "a live table
# nobody declared" — a CREATE and a DROP of a live table that did not change at all.
#
# The db_table fixtures were migrated by the same bootstrap as every other model here, so a re-diff
# must propose NOTHING for them. Scoped to those tables on purpose: asserting global
# `status().pending` would fold in unrelated drift from other fixtures in this shared database and
# report a #59 regression that isn't one.
@testset "db_table: a re-diff proposes nothing for the db_table-mapped tables" begin
    settings = PormG.config[PORMG_DB_FOLDER]
    conn = settings.connections
    live = PormG.Migrations.convert_schema_to_models(conn)
    declared = PormG.Migrations.get_all_models(M)
    plan = PormG.Migrations.get_migration_plan(live, declared, conn, settings; interactive = false)

    # No plan entry under EITHER spelling: the physical name (a create/alter the planner thinks it
    # needs) or the logical one (proof the two sides were keyed differently).
    for name in (:Db_Table_Scratch, :db_table_scratch, :Db_Table_Col_Scratch, :db_table_col_scratch,
                 :db_table_child_scratch)
        @test !haskey(plan, name)
    end
end
