# ==============================================================================
# MIGRATION BOOTSTRAP — Backend-Aware Integration Tests
#
# This file is included from runtests.jl AFTER common_setup.jl.
# It runs against the SAME selected database (PORMG_DB_FOLDER) so that
# both SQLite and PostgreSQL go through identical orchestration.
#
# Structure:
#   Phase A — Migration Preflight (validates the migration engine on the
#             selected DB starting from an empty state)
#   Phase B — Real Schema Bootstrap (runs makemigrations + migrate with
#             the real integration models, leaving the DB ready for fixture
#             seeding in test_database_setup.jl)
#   Phase C — Migration Engine Edge Cases using an isolated temp DB to
#             exercise rename, drop field, FK, types, destructive guard,
#             status, dry_run, and repair operations without mutating
#             the main integration database. Runs on both SQLite and
#             PostgreSQL using adapter-neutral introspection helpers.
# ==============================================================================

if !isdefined(Main, :reset_database!)
  include("common_migration_setup.jl")
end

using OrderedCollections

# ─── Phase A: Migration Preflight ────────────────────────────────────────────
# Goal: prove the migration engine can start from an empty selected DB,
#       create the history table, generate a plan, and apply it.
@testset "Migration Preflight ($(PORMG_DB_FOLDER))" begin

  # A1. Reset the selected database to a completely empty state.
  #     After this, no user tables and no pormg_migrations table exist.
  settings = PormG.config[PORMG_DB_FOLDER]
  reset_database!(settings)

  # Reload pool so the connection objects are fresh after the reset.
  settings = reload_config_and_models!()

  # A2. init_migrations() should create the history table idempotently.
  init_migrations(settings.connections)
  init_migrations(settings.connections)  # second call must not fail

  st = status(settings.connections, settings)
  @test st.has_history_table == true
  @test isempty(st.applied)
  @test isempty(st.failed)

  # A3. makemigrations against the real selected models should produce a plan.
  makemigrations(PORMG_DB_FOLDER, interactive=false)
  pending_path = joinpath(settings.db_def_folder, "migrations", "pending_migrations.jl")
  @test isfile(pending_path)

  # A4. migrate should apply the schema without error.
  #     destructive=true because some backends may need it for fresh creation.
  migrate(PORMG_DB_FOLDER, interactive=false, destructive=true)

  # A5. Verify post-migration state.
  st2 = status(settings.connections, settings)
  @test st2.has_history_table == true
  @test length(st2.applied) > 0
  @test isempty(st2.failed)
  @test !st2.pending  # pending file should be archived

  @info "Migration preflight passed" adapter=adapter_name applied=length(st2.applied)
end

# ─── Phase A2: format_version backfill on a legacy history table ─────────────
# Goal: prove init_migrations() idempotently upgrades a `pormg_migrations` table created by a
#       PRE-`format_version` PormG release. The column must be added in place (not via a failed
#       CREATE) and legacy rows must backfill to 1 (issue #32). Runs on both SQLite and PostgreSQL.
@testset "Format-version backfill ($(PORMG_DB_FOLDER))" begin
  settings = PormG.config[PORMG_DB_FOLDER]
  conn = settings.connections
  is_pg = conn isa PormG.PormGPostgres

  # Recreate pormg_migrations WITHOUT format_version, mimicking an older release's schema.
  PormG.ConnectionPool.fetch(conn, "DROP TABLE IF EXISTS pormg_migrations;")
  legacy_ddl = is_pg ?
    """CREATE TABLE pormg_migrations (
      "id" SERIAL PRIMARY KEY,
      "version" VARCHAR(17) NOT NULL UNIQUE,
      "name" VARCHAR(255) NOT NULL,
      "checksum" VARCHAR(64) NOT NULL,
      "sql_content" TEXT NOT NULL DEFAULT '',
      "applied_at" TIMESTAMP NOT NULL DEFAULT NOW(),
      "status" VARCHAR(20) NOT NULL DEFAULT 'applied',
      "is_destructive" BOOLEAN NOT NULL DEFAULT FALSE
    );""" :
    """CREATE TABLE pormg_migrations (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "version" VARCHAR(17) NOT NULL UNIQUE,
      "name" VARCHAR(255) NOT NULL,
      "checksum" VARCHAR(64) NOT NULL,
      "sql_content" TEXT NOT NULL DEFAULT '',
      "applied_at" DATETIME NOT NULL DEFAULT (datetime('now')),
      "status" VARCHAR(20) NOT NULL DEFAULT 'applied',
      "is_destructive" BOOLEAN NOT NULL DEFAULT 0
    );"""
  PormG.ConnectionPool.fetch(conn, legacy_ddl)

  # A legacy applied record, written before the column existed.
  PormG.ConnectionPool.fetch(conn,
    """INSERT INTO pormg_migrations ("version", "name", "checksum", "status")
       VALUES ('20250101000000000', 'legacy_init', 'deadbeef', 'applied');""")

  # Backend-neutral "does format_version exist?" probe via the system catalog (returns 0/1 rows; no
  # reliance on a SELECT raising). Avoids the SQLite-only `column_names` helper, whose `using SQLite`
  # import only loads later in Phase C.
  format_version_present() = begin
    sql = is_pg ?
      "SELECT 1 FROM information_schema.columns WHERE table_name = 'pormg_migrations' AND column_name = 'format_version';" :
      "SELECT 1 FROM pragma_table_info('pormg_migrations') WHERE name = 'format_version';"
    nrow(DataFrame(PormG.ConnectionPool.fetch(conn, sql))) > 0
  end

  # The column is absent before the upgrade.
  @test format_version_present() == false

  # init_migrations() must add it idempotently — a second call must not fail.
  init_migrations(conn)
  init_migrations(conn)

  # The column now exists and the legacy row backfilled to 1 via the DEFAULT.
  @test format_version_present() == true
  legacy = DataFrame(PormG.ConnectionPool.fetch(conn,
    """SELECT "format_version" FROM pormg_migrations WHERE "version" = '20250101000000000';"""))
  @test nrow(legacy) == 1
  @test legacy[1, :format_version] == 1

  # A migration recorded AFTER the upgrade is stamped with the current format version.
  # mark_applied requires a verifiable checksum basis (issue #81), so pass sql_content.
  Migrations.mark_applied(conn, settings, "20250101000001000", "after_upgrade";
                          sql_content = "-- post-upgrade reconciliation (format-version backfill test)")
  fresh = DataFrame(PormG.ConnectionPool.fetch(conn,
    """SELECT "format_version" FROM pormg_migrations WHERE "version" = '20250101000001000';"""))
  @test fresh[1, :format_version] == Migrations.MIGRATION_FORMAT_VERSION

  @info "Format-version backfill passed" adapter=adapter_name
end

# ─── Phase B: Real Schema Bootstrap ─────────────────────────────────────────
# Goal: wipe any residue left by the preflight, run the full migration
#       lifecycle with the real models, and leave the DB in the exact schema
#       expected before fixture seeding.
@testset "Schema Bootstrap ($(PORMG_DB_FOLDER))" begin

  settings = PormG.config[PORMG_DB_FOLDER]

  # B1. Destructive reset — start completely fresh.
  reset_database!(settings)
  settings = reload_config_and_models!()

  # B2. Run the real migration lifecycle.
  makemigrations(PORMG_DB_FOLDER, interactive=false)
  migrate(PORMG_DB_FOLDER, interactive=false, destructive=true)

  # B3. Reload everything so M.*.objects point at the rebuilt schema.
  settings = reload_config_and_models!()

  # B4. Smoke test: assert the DB is in a clean state.
  assert_clean_state()

  # B5. Verify the imported model module can actually query the schema.
  #     This is the explicit "prove M works after reload" assertion from
  #     the planning doc (step 10 / verification item 6).
  @test M.Status.objects.count() == 0
  @test M.Circuit.objects.count() == 0

  @info "Schema bootstrap complete — DB ready for fixture seeding" adapter=adapter_name
end

# ─── Phase C: Migration Engine Edge Cases (Isolated Temp DB) ─────────────────
# These tests exercise schema evolution scenarios (add/drop field, rename,
# FK, types, destructive guard, status, dry_run, repair) on a throwaway
# database so they do not interfere with the main integration DB.
#
# SQLite: creates a disposable db_test_migration/ folder (deleted after).
# PostgreSQL: uses db_test_migration_pg/ when present, otherwise creates a
#             temporary fixture on demand, resetting the public schema between runs.
#
# All introspection is done through adapter-neutral helpers defined in
# common_migration_setup.jl (table_exists, column_names, column_nullable,
# index_names, all_table_names).
# ==============================================================================

# SQLite.jl is a weak dependency since #34 and cannot be `using`-ed directly under
# `--project=.`. It is loaded and bound in Main by test/load_drivers.jl (included from
# common_setup.jl), so the qualified `SQLite.*` calls in the column-introspection helpers
# resolve to that binding for the SQLite adapter path.

# Determine the temp DB folder based on the adapter
edge_db_name = adapter_name == "SQLite" ? "db_test_migration" : "db_test_migration_pg"
const edge_db_reuses_selected_db = Ref(false)
const edge_db_fixture_generated = Ref(false)

function postgres_connection_identity(settings)
  cfg = settings.db_config_settings
  return (
    get(cfg, "host", nothing),
    string(get(cfg, "port", nothing)),
    get(cfg, "database", nothing),
    get(cfg, "username", nothing),
  )
end

# Helper to write models.jl dynamically into the temp migration folder.
function write_edge_models(content::String)
  models_path = joinpath(@__DIR__, edge_db_name, "models.jl")
  open(models_path, "w") do f
    write(f, "module models\nimport PormG.Models\n")
    write(f, content)
    write(f, "\nend")
  end
end

@testset "Migration Engine Edge Cases ($(adapter_name) temp DB)" begin
  # ── Setup: create/reset the isolated temp database ──────────────────
  if adapter_name == "SQLite"
    # SQLite: create a fresh disposable folder
    try; PormG.Configuration.close_pool!(joinpath(@__DIR__, edge_db_name)); catch; end
    try; ispath(joinpath(@__DIR__, edge_db_name)) && rm(joinpath(@__DIR__, edge_db_name), recursive=true); catch; end

    PormG.Generator.create_db_folder_and_yml(path=joinpath(@__DIR__, edge_db_name), adapter="SQLite")

    yml_path = joinpath(@__DIR__, edge_db_name, "connection.yml")
    yml_content = read(yml_path, String)
    yml_content = replace(yml_content, "database: database.sqlite" => "database: migration_test.sqlite")
    open(yml_path, "w") do f; write(f, yml_content); end
  else
    # PostgreSQL: load the committed credential-free fixture (issue #36) and hydrate
    # host/username/password IN-MEMORY from the selected DB — the tracked connection.yml is
    # never rewritten. ensure_postgres_test_config! only regenerates a blank fixture if the
    # committed file was deleted.
    selected_settings = PormG.Configuration.get_settings(PORMG_DB_FOLDER)
    edge_db_fixture_generated[] = ensure_postgres_test_config!(joinpath(@__DIR__, edge_db_name))

    PormG.Configuration.load(joinpath(@__DIR__, edge_db_name))
    pg_edge_settings = PormG.Configuration.get_settings(joinpath(@__DIR__, edge_db_name))
    hydrate_postgres_settings!(pg_edge_settings, selected_settings, joinpath(@__DIR__, edge_db_name))

    # Detect whether the edge-case database resolves to the SAME PostgreSQL database as the
    # selected integration environment. With the committed fixture (distinct `database`) this is
    # false; it can only be true in the degraded case where the fixture was removed and
    # regenerated blank, in which case the final reactivation block rebuilds the selected schema.
    edge_db_reuses_selected_db[] = postgres_connection_identity(selected_settings) == postgres_connection_identity(pg_edge_settings)
    # #36 acceptance: with the committed fixture the edge DB MUST resolve to a database distinct
    # from the selected one. Guards runtime isolation — if hydration ever overwrote `database`,
    # this fails (a silent @warn + fallback would otherwise keep the suite green). Skipped only in
    # the degraded case where the committed fixture was deleted and regenerated blank.
    !edge_db_fixture_generated[] && @test !edge_db_reuses_selected_db[]
    if edge_db_reuses_selected_db[]
      @warn "db_test_migration_pg/connection.yml resolves to the same PostgreSQL database as the selected integration DB; the final bootstrap step will rebuild $(PORMG_DB_FOLDER) as a fallback." db=PORMG_DB_FOLDER edge_db=edge_db_name
    else
      # Auto-create the dedicated disposable DB if absent (Django/Rails/Prisma style), so there is
      # no manual pre-create step; the connecting role just needs CREATEDB. The name is read from
      # the loaded fixture (not hardcoded) so it always matches what the edge pool connects to.
      ensure_postgres_database!(pg_edge_settings, string(pg_edge_settings.db_config_settings["database"]))
    end

    # Reset the public schema to start clean.
    _reset_postgres!(pg_edge_settings.connections)
    PormG.Configuration.close_pool!(joinpath(@__DIR__, edge_db_name))
    delete!(PormG.config, joinpath(@__DIR__, edge_db_name))

    # Clean up any leftover migration artifacts
    mig_dir = joinpath(@__DIR__, edge_db_name, "migrations")
    ispath(mig_dir) && rm(mig_dir, recursive=true)
  end

  PormG.Configuration.load(joinpath(@__DIR__, edge_db_name))
  edge_settings = PormG.Configuration.get_settings(joinpath(@__DIR__, edge_db_name))
  if adapter_name != "SQLite"
    # This reload re-read the credential-free fixture, so re-hydrate in-memory (PG only). The
    # edge-case tests below reuse this pool and never reload the fixture, so one hydrate suffices.
    hydrate_postgres_settings!(edge_settings,
      PormG.Configuration.get_settings(PORMG_DB_FOLDER), joinpath(@__DIR__, edge_db_name))
  end
  pool = edge_settings.connections

  # ── Phase 1: Initial table creation ───────────────────────────────
  @testset "Phase 1: Initial Creation" begin
    write_edge_models("""
    MigrationTest = Models.Model(
        id = Models.IDField(),
        name = Models.CharField()
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    @test isfile(joinpath(@__DIR__, edge_db_name, "migrations", "pending_migrations.jl"))

    migrate(joinpath(@__DIR__, edge_db_name), interactive=false)

    @test table_exists(pool, "migrationtest")
    cols = column_names(pool, "migrationtest")
    @test "id" in cols
    @test "name" in cols
  end

  # ── Phase 2: Add a nullable field ─────────────────────────────────
  @testset "Phase 2: Add Field" begin
    write_edge_models("""
    MigrationTest = Models.Model(
        id = Models.IDField(),
        name = Models.CharField(),
        age = Models.IntegerField(null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false)

    cols = column_names(pool, "migrationtest")
    @test "age" in cols
  end

  # ── Phase 3: Drop a field (destructive) ───────────────────────────
  @testset "Phase 3: Drop Field" begin
    write_edge_models("""
    MigrationTest = Models.Model(
        id = Models.IDField(),
        name = Models.CharField()
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    cols = column_names(pool, "migrationtest")
    @test !("age" in cols)
  end

  # ── Phase 4: Multiple tables + Foreign Keys ───────────────────────
  @testset "Phase 4: Multiple Tables and Foreign Keys" begin
    write_edge_models("""
    MigrationTest = Models.Model(
        id = Models.IDField(),
        name = Models.CharField()
    )
    SecondTable = Models.Model(
        id = Models.IDField(),
        test_id = Models.ForeignKey("MigrationTest", on_delete=Models.CASCADE),
        description = Models.CharField(null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    @test table_exists(pool, "secondtable")
    cols = column_names(pool, "secondtable")
    @test "test_id" in cols
  end

  # ── Phase 4b: Remove an FK constraint via field alteration (#83) ──
  # SQLite's `drop_foreign_key` used to call an undefined `get_constraints` and crash makemigrations,
  # and it embedded its own BEGIN/COMMIT. FK removal is now routed through the table rebuild (which
  # omits the FK) with the planner's SQLite FK-drop as a no-op. Seed a parent+child row, flip
  # `test_id` to `db_constraint=false`, migrate, and assert the FK is gone AND the data survives the
  # rebuild — with no embedded transaction control in the generated plan. Runs on both backends.
  @testset "Phase 4b: Remove Foreign Key Constraint (#83)" begin
    # Baseline: phase 4 left secondtable with an FK on test_id.
    @assert foreign_key_count(pool, "secondtable") >= 1 "Phase 4b requires the FK created in phase 4"

    # Seed a parent + child row (raw SQL; explicit ids keep the child's parent reference deterministic).
    PormG.ConnectionPool.fetch(pool, """INSERT INTO "migrationtest" ("id", "name") VALUES (900, 'fk-parent-83');""")
    PormG.ConnectionPool.fetch(pool, """INSERT INTO "secondtable" ("id", "test_id", "description") VALUES (901, 900, 'fk-child-83');""")

    # Desired model: keep the column, drop only the DB-level FK constraint.
    write_edge_models("""
    MigrationTest = Models.Model(
        id = Models.IDField(),
        name = Models.CharField()
    )
    SecondTable = Models.Model(
        id = Models.IDField(),
        test_id = Models.ForeignKey("MigrationTest", on_delete=Models.CASCADE, db_constraint=false),
        description = Models.CharField(null=true)
    )
    """)

    # Must NOT raise UndefVarError (the old broken SQLite drop_foreign_key path).
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)

    # AC2: the generated plan must not embed its own transaction control (the old draft did).
    pending = read(joinpath(@__DIR__, edge_db_name, "migrations", "pending_migrations.jl"), String)
    @test !occursin("BEGIN TRANSACTION", pending)

    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    # AC1: the FK constraint is gone, and the column is preserved.
    @test foreign_key_count(pool, "secondtable") == 0
    @test "test_id" in column_names(pool, "secondtable")

    # Data fidelity: the child row survived the table rebuild with its values intact.
    surviving = PormG.ConnectionPool.fetch(pool,
      """SELECT "test_id", "description" FROM "secondtable" WHERE "id" = 901;""") |> DataFrame
    @test nrow(surviving) == 1
    # `isequal` (not `==`) so a would-be NULL never propagates `missing` into `@test` (house convention).
    @test isequal(surviving[1, :test_id], 900)
    @test isequal(surviving[1, :description], "fk-child-83")

    # Cleanup: restore the empty-table precondition later phases assume.
    PormG.ConnectionPool.fetch(pool, """DELETE FROM "secondtable" WHERE "id" = 901;""")
    PormG.ConnectionPool.fetch(pool, """DELETE FROM "migrationtest" WHERE "id" = 900;""")
  end

  # ── Phase 4c: Delete a live FK field (#116) ───────────────────────
  # Sibling of #83: #83 dropped an FK *constraint* via field alteration; this deletes the whole FK
  # *field*. On SQLite `ALTER TABLE DROP COLUMN` refuses a column bound by a FOREIGN KEY, so the
  # deletion path must route through the same model-based table rebuild the alteration path uses —
  # which omits the deleted column + its FK clause and preserves the survivors. It also exercises the
  # column-aware index filter: an FK field is db_index=true by default, so a naïve rebuild would try to
  # re-create the dropped column's index and fail "no such column" (the Django #33899 crash).
  #
  # Uses a DEDICATED child table with TWO FKs defined in CREATE TABLE (guaranteed-live, indexed FKs) plus
  # a plain `doomed` column. The deletion removes BOTH the `drop_id` FK field AND the non-FK `doomed`
  # column in one migration — exercising that a single table rebuild drops every removed column at once (a
  # per-column DROP COLUMN for `doomed` after the rebuild would race with "no such column"). `keep_id`
  # (sibling FK) and `label` survive. Placed after 4b so it can't disturb 4b's baseline; the leftover table
  # is swept away by Phase 5's model redefinition. Runs on both backends (PostgreSQL takes the plain
  # DROP CONSTRAINT + DROP COLUMN path; SQLite takes the rebuild).
  @testset "Phase 4c: Delete Foreign Key Field (#116)" begin
    write_edge_models("""
    MigrationTest = Models.Model(
        id = Models.IDField(),
        name = Models.CharField()
    )
    SecondTable = Models.Model(
        id = Models.IDField(),
        test_id = Models.ForeignKey("MigrationTest", on_delete=Models.CASCADE, db_constraint=false),
        description = Models.CharField(null=true)
    )
    ChildFKTable = Models.Model(
        id = Models.IDField(),
        keep_id = Models.ForeignKey("MigrationTest", on_delete=Models.CASCADE, null=true),
        drop_id = Models.ForeignKey("MigrationTest", on_delete=Models.CASCADE, null=true),
        doomed = Models.CharField(null=true),
        label = Models.CharField(null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    # Baseline: the new table has TWO live FKs (both created via CREATE TABLE) and the doomed column.
    @assert foreign_key_count(pool, "childfktable") == 2 "Phase 4c requires two live FKs on childfktable"
    @test "drop_id" in column_names(pool, "childfktable")
    @test "doomed" in column_names(pool, "childfktable")

    # Seed a parent + child; keep_id/label carry data that must survive the rebuild.
    PormG.ConnectionPool.fetch(pool, """INSERT INTO "migrationtest" ("id", "name") VALUES (920, 'fk-parent-116');""")
    PormG.ConnectionPool.fetch(pool, """INSERT INTO "childfktable" ("id", "keep_id", "drop_id", "doomed", "label") VALUES (921, 920, 920, 'gone-116', 'child-116');""")

    # Desired model: delete BOTH the `drop_id` FK field and the plain `doomed` column (keep keep_id + label).
    write_edge_models("""
    MigrationTest = Models.Model(
        id = Models.IDField(),
        name = Models.CharField()
    )
    SecondTable = Models.Model(
        id = Models.IDField(),
        test_id = Models.ForeignKey("MigrationTest", on_delete=Models.CASCADE, db_constraint=false),
        description = Models.CharField(null=true)
    )
    ChildFKTable = Models.Model(
        id = Models.IDField(),
        keep_id = Models.ForeignKey("MigrationTest", on_delete=Models.CASCADE, null=true),
        label = Models.CharField(null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)

    # AC2: the generated plan must not embed its own transaction control (composes with the runner tx).
    pending = read(joinpath(@__DIR__, edge_db_name, "migrations", "pending_migrations.jl"), String)
    @test !occursin("BEGIN TRANSACTION", pending)

    # AC1: this must NOT raise (pre-fix, SQLite `DROP COLUMN "drop_id"` aborts because drop_id is an FK
    # column; a naïve rebuild would instead fail re-creating drop_id's index — both are the #116 bug).
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    # Both deleted columns are gone (drop_id via the FK-forced rebuild, doomed swept up in the same rebuild);
    # the sibling FK column, its FK, and the remaining columns survive.
    cols = column_names(pool, "childfktable")
    @test !("drop_id" in cols)
    @test !("doomed" in cols)
    @test "keep_id" in cols
    @test "label" in cols
    @test foreign_key_count(pool, "childfktable") == 1   # drop_id's FK removed; keep_id's preserved

    # Data fidelity: the child row survived the rebuild with its surviving values intact.
    surviving = PormG.ConnectionPool.fetch(pool,
      """SELECT "keep_id", "label" FROM "childfktable" WHERE "id" = 921;""") |> DataFrame
    @test nrow(surviving) == 1
    # `isequal` (not `==`) so a would-be NULL never propagates `missing` into `@test` (house convention).
    @test isequal(surviving[1, :keep_id], 920)
    @test isequal(surviving[1, :label], "child-116")

    # Cleanup child-then-parent so the DELETE never depends on ON DELETE CASCADE (childfktable itself is
    # dropped later by Phase 5's model redefinition).
    PormG.ConnectionPool.fetch(pool, """DELETE FROM "childfktable" WHERE "id" = 921;""")
    PormG.ConnectionPool.fetch(pool, """DELETE FROM "migrationtest" WHERE "id" = 920;""")
  end

  # ── Phase 4d: Alter a field AND delete an FK field together (#116) ─
  # Gates the COMBINED path on one SQLite table in a single migration: the FK deletion forces a table
  # rebuild, and the field alteration ALSO rebuilds under the same "Alter table:" key. Both must feed
  # `surviving_columns` so the deleted FK column's index is dropped from the preserved set — if the
  # ALTERATION-site rebuild re-created keep_id's index, `migrate` would fail "no such column: keep_id".
  # After Phase 4c, childfktable = {id, keep_id (FK, nullable), label (nullable)}. Runs on both backends
  # (PostgreSQL: DROP CONSTRAINT/COLUMN for keep_id + ALTER COLUMN label SET NOT NULL; SQLite: one rebuild).
  @testset "Phase 4d: Alter Field + Delete FK Field Together (#116)" begin
    @assert foreign_key_count(pool, "childfktable") == 1 "Phase 4d requires childfktable's keep_id FK from 4c"
    @assert column_nullable(pool, "childfktable", "label") "Phase 4d requires label to start nullable"

    # Seed a parent + child; label carries data that must survive, and must be non-NULL for SET NOT NULL.
    PormG.ConnectionPool.fetch(pool, """INSERT INTO "migrationtest" ("id", "name") VALUES (930, 'fk-parent-116d');""")
    PormG.ConnectionPool.fetch(pool, """INSERT INTO "childfktable" ("id", "keep_id", "label") VALUES (931, 930, 'child-116d');""")

    # Desired model: delete keep_id (FK) AND alter label (null=true -> null=false) in the SAME migration.
    write_edge_models("""
    MigrationTest = Models.Model(
        id = Models.IDField(),
        name = Models.CharField()
    )
    SecondTable = Models.Model(
        id = Models.IDField(),
        test_id = Models.ForeignKey("MigrationTest", on_delete=Models.CASCADE, db_constraint=false),
        description = Models.CharField(null=true)
    )
    ChildFKTable = Models.Model(
        id = Models.IDField(),
        label = Models.CharField(null=false)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)

    pending = read(joinpath(@__DIR__, edge_db_name, "migrations", "pending_migrations.jl"), String)
    @test !occursin("BEGIN TRANSACTION", pending)

    # Must NOT raise: on SQLite the FK-delete rebuild and the label alteration collapse into one recreation
    # whose preserved indexes exclude keep_id's (a broken alteration-site filter → "no such column: keep_id").
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    cols = column_names(pool, "childfktable")
    @test !("keep_id" in cols)                            # FK field deleted
    @test "label" in cols
    @test foreign_key_count(pool, "childfktable") == 0    # keep_id's FK gone
    @test !column_nullable(pool, "childfktable", "label") # the alteration applied: label is now NOT NULL

    # Data fidelity: the row survived the combined rebuild.
    surviving = PormG.ConnectionPool.fetch(pool,
      """SELECT "label" FROM "childfktable" WHERE "id" = 931;""") |> DataFrame
    @test nrow(surviving) == 1
    @test isequal(surviving[1, :label], "child-116d")

    # Cleanup (childfktable is dropped by Phase 5's model redefinition).
    PormG.ConnectionPool.fetch(pool, """DELETE FROM "childfktable" WHERE "id" = 931;""")
    PormG.ConnectionPool.fetch(pool, """DELETE FROM "migrationtest" WHERE "id" = 930;""")
  end

  # ── Phase 4e: Rename an FK field whose FK constraint also changes (#150) ─
  # The rename-path sibling of #83/#116. On SQLite the FK clause lives inside CREATE TABLE, so a plain
  # `RENAME COLUMN` keeps the OLD constraint; renaming an FK field while ALSO changing its FK — here
  # flipping db_constraint true→false, i.e. dropping the constraint — must route through the same
  # model-based table rebuild. Before the fix, SQLite renamed the column but silently KEPT the FK
  # (foreign_key_count stays 1); after, the rebuild drops it (→ 0) with data + the field's secondary index
  # preserved (the index is re-created against the RENAMED column via `column_renames`, so a broken rewrite
  # would fail "no such column"). PostgreSQL is clean either way (DROP CONSTRAINT + RENAME COLUMN). Field-
  # rename detection is INTERACTIVE (readline), so the rename step feeds the confirmation number via a
  # redirected stdin. Uses a dedicated child table; carries childfktable through unchanged so the setup is
  # a pure table-ADD (no add/remove pairing ⇒ no table-rename prompt to consume the fed answer).
  @testset "Phase 4e: Rename FK Field + Change FK Constraint (#150)" begin
    write_edge_models("""
    MigrationTest = Models.Model(
        id = Models.IDField(),
        name = Models.CharField()
    )
    SecondTable = Models.Model(
        id = Models.IDField(),
        test_id = Models.ForeignKey("MigrationTest", on_delete=Models.CASCADE, db_constraint=false),
        description = Models.CharField(null=true)
    )
    ChildFKTable = Models.Model(
        id = Models.IDField(),
        label = Models.CharField(null=false)
    )
    RenameFKChild = Models.Model(
        id = Models.IDField(),
        old_parent_id = Models.ForeignKey("MigrationTest", on_delete=Models.CASCADE, null=true, db_index=true),
        note = Models.CharField(null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    # Baseline: one live FK on the indexed old_parent_id column, plus the field's secondary index (db_index).
    @assert foreign_key_count(pool, "renamefkchild") == 1 "Phase 4e requires a live FK on renamefkchild"
    @test "old_parent_id" in column_names(pool, "renamefkchild")
    idx_before = index_names(pool, "renamefkchild")
    @assert !isempty(idx_before) "Phase 4e requires the db_index secondary index on the FK field"

    # Seed a parent + child row whose FK value must survive the rebuild.
    PormG.ConnectionPool.fetch(pool, """INSERT INTO "migrationtest" ("id", "name") VALUES (940, 'fk-parent-150');""")
    PormG.ConnectionPool.fetch(pool, """INSERT INTO "renamefkchild" ("id", "old_parent_id", "note") VALUES (941, 940, 'child-150');""")

    # Desired: RENAME old_parent_id → new_parent_id AND flip db_constraint true→false (drop the FK) in the
    # same migration. Everything else is identical so the only interactive decision is this one field rename.
    write_edge_models("""
    MigrationTest = Models.Model(
        id = Models.IDField(),
        name = Models.CharField()
    )
    SecondTable = Models.Model(
        id = Models.IDField(),
        test_id = Models.ForeignKey("MigrationTest", on_delete=Models.CASCADE, db_constraint=false),
        description = Models.CharField(null=true)
    )
    ChildFKTable = Models.Model(
        id = Models.IDField(),
        label = Models.CharField(null=false)
    )
    RenameFKChild = Models.Model(
        id = Models.IDField(),
        new_parent_id = Models.ForeignKey("MigrationTest", on_delete=Models.CASCADE, null=true, db_index=true, db_constraint=false),
        note = Models.CharField(null=true)
    )
    """)

    # Field-rename detection is interactive: feed "1" (old_parent_id is the sole rename candidate) to the
    # readline prompt via a redirected stdin. EOF would yield "no" ⇒ a loud failure below, never a hang.
    mktemp() do _path, io
      write(io, "1\n"); flush(io); seekstart(io)
      redirect_stdin(io) do
        makemigrations(joinpath(@__DIR__, edge_db_name), interactive=true)
      end
    end

    # AC2: the generated block carries no embedded transaction control (composes with the runner tx).
    pending = read(joinpath(@__DIR__, edge_db_name, "migrations", "pending_migrations.jl"), String)
    @test !occursin("BEGIN TRANSACTION", pending)

    # Must NOT raise. Pre-fix on SQLite the rename emitted only RENAME COLUMN (no rebuild); the rebuild here
    # re-creates the field's secondary index against the RENAMED column, so a broken column_renames rewrite
    # would abort with "no such column: old_parent_id".
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    # The column is renamed and the FK constraint change took effect on BOTH backends.
    cols = column_names(pool, "renamefkchild")
    @test !("old_parent_id" in cols)
    @test "new_parent_id" in cols
    @test foreign_key_count(pool, "renamefkchild") == 0   # #150: FK actually dropped (was silently kept on SQLite)
    # The field's secondary index survived the rebuild (count preserved, not lost to the DROP TABLE)…
    @test length(index_names(pool, "renamefkchild")) == length(idx_before)
    # …and on SQLite it now references the RENAMED column — direct proof the `column_renames` rewrite ran
    # (a naïve rebuild would have re-created it against old_parent_id and aborted "no such column").
    if adapter_name == "SQLite"
      idxcols = String[]
      for idx in index_names(pool, "renamefkchild")
        info = PormG.ConnectionPool.fetch(pool, """PRAGMA index_info("$(idx)");""") |> DataFrame
        append!(idxcols, string.(info.name))
      end
      @test "new_parent_id" in idxcols
      @test !("old_parent_id" in idxcols)
    end

    # Data fidelity: the child row survived with its (renamed) FK value intact.
    surviving = PormG.ConnectionPool.fetch(pool,
      """SELECT "new_parent_id", "note" FROM "renamefkchild" WHERE "id" = 941;""") |> DataFrame
    @test nrow(surviving) == 1
    # `isequal` (not `==`) so a would-be NULL never propagates `missing` into `@test` (house convention).
    @test isequal(surviving[1, :new_parent_id], 940)
    @test isequal(surviving[1, :note], "child-150")

    # Cleanup child-then-parent (renamefkchild is dropped by Phase 5's model redefinition).
    PormG.ConnectionPool.fetch(pool, """DELETE FROM "renamefkchild" WHERE "id" = 941;""")
    PormG.ConnectionPool.fetch(pool, """DELETE FROM "migrationtest" WHERE "id" = 940;""")
  end

  # ── Phase 4f: Rename FK field (constraint change) + delete another field, same migration (#150) ─
  # Regression for the co-occurrence the rename-rebuild must handle: renaming an FK field whose constraint
  # changes AND deleting a DIFFERENT field on the SAME table in one migration. The rebuild is generated from
  # `current_model` (which already omits the deleted field), so the deletion loop must DEFER to it — emitting
  # a separate `DROP COLUMN` for the already-removed column would abort "no such column" on SQLite (the bug
  # this phase guards). Carries the prior phases' tables forward unchanged so adding RenameDelChild is a pure
  # table-ADD (no table-rename prompt). PostgreSQL takes RENAME COLUMN + DROP CONSTRAINT + DROP COLUMN.
  @testset "Phase 4f: Rename FK Field + Delete Field Together (#150)" begin
    base_models = """
    MigrationTest = Models.Model(
        id = Models.IDField(),
        name = Models.CharField()
    )
    SecondTable = Models.Model(
        id = Models.IDField(),
        test_id = Models.ForeignKey("MigrationTest", on_delete=Models.CASCADE, db_constraint=false),
        description = Models.CharField(null=true)
    )
    ChildFKTable = Models.Model(
        id = Models.IDField(),
        label = Models.CharField(null=false)
    )
    RenameFKChild = Models.Model(
        id = Models.IDField(),
        new_parent_id = Models.ForeignKey("MigrationTest", on_delete=Models.CASCADE, null=true, db_index=true, db_constraint=false),
        note = Models.CharField(null=true)
    )
    """
    # Setup: add RenameDelChild with a live FK (link_id) plus a doomed non-FK column.
    write_edge_models(base_models * """
    RenameDelChild = Models.Model(
        id = Models.IDField(),
        link_id = Models.ForeignKey("MigrationTest", on_delete=Models.CASCADE, null=true),
        zztombstone = Models.CharField(null=true),
        note = Models.CharField(null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    @assert foreign_key_count(pool, "renamedelchild") == 1 "Phase 4f requires a live FK on renamedelchild"
    @assert "zztombstone" in column_names(pool, "renamedelchild") "Phase 4f requires the doomed column"

    PormG.ConnectionPool.fetch(pool, """INSERT INTO "migrationtest" ("id", "name") VALUES (950, 'fk-parent-150f');""")
    PormG.ConnectionPool.fetch(pool, """INSERT INTO "renamedelchild" ("id", "link_id", "zztombstone", "note") VALUES (951, 950, 'gone', 'child-150f');""")

    # Desired: rename link_id → link_ref_id (flip db_constraint true→false) AND delete zztombstone.
    write_edge_models(base_models * """
    RenameDelChild = Models.Model(
        id = Models.IDField(),
        link_ref_id = Models.ForeignKey("MigrationTest", on_delete=Models.CASCADE, null=true, db_constraint=false),
        note = Models.CharField(null=true)
    )
    """)

    # Interactive: the sole addition (link_ref_id) prompts once with the name-sorted deletion candidates
    # "1 - link_id, 2 - zztombstone" (sorting is now deterministic, see _colect_numbered_fields); feed "1"
    # to map it onto link_id, leaving zztombstone as a pure deletion on the same table.
    mktemp() do _path, io
      write(io, "1\n"); flush(io); seekstart(io)
      redirect_stdin(io) do
        makemigrations(joinpath(@__DIR__, edge_db_name), interactive=true)
      end
    end

    pending = read(joinpath(@__DIR__, edge_db_name, "migrations", "pending_migrations.jl"), String)
    @test !occursin("BEGIN TRANSACTION", pending)

    # Must NOT raise: pre-fix on SQLite the deletion loop emitted `DROP COLUMN "zztombstone"` AFTER the
    # rename-rebuild already dropped it → "no such column". The deletion-loop skip defers to the rebuild.
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    cols = column_names(pool, "renamedelchild")
    @test !("link_id" in cols)        # renamed away
    @test "link_ref_id" in cols       # renamed to
    @test !("zztombstone" in cols)    # deleted in the SAME migration (handled by the rebuild, not a DROP COLUMN)
    @test foreign_key_count(pool, "renamedelchild") == 0   # FK dropped by the db_constraint flip

    # Data fidelity: the row survived the combined rebuild with its renamed FK value intact.
    surviving = PormG.ConnectionPool.fetch(pool,
      """SELECT "link_ref_id", "note" FROM "renamedelchild" WHERE "id" = 951;""") |> DataFrame
    @test nrow(surviving) == 1
    @test isequal(surviving[1, :link_ref_id], 950)
    @test isequal(surviving[1, :note], "child-150f")

    # Cleanup child-then-parent (renamedelchild is dropped by Phase 5's model redefinition).
    PormG.ConnectionPool.fetch(pool, """DELETE FROM "renamedelchild" WHERE "id" = 951;""")
    PormG.ConnectionPool.fetch(pool, """DELETE FROM "migrationtest" WHERE "id" = 950;""")
  end

  # ── Phase 5: Indexes and unique constraints ───────────────────────
  @testset "Phase 5: Indexes and Unique Constraints" begin
    write_edge_models("""
    MigrationTest = Models.Model(
        id = Models.IDField(),
        name = Models.CharField(db_index=true, unique=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    indices = index_names(pool, "migrationtest")
    # Must have at least one user-defined index (beyond the implicit PK)
    @test !isempty(indices)
    # The index created by db_index=true, unique=true must reference "name"
    @test any(occursin("name", idx) for idx in indices)
  end

  # ── Phase 6: Alter nullability ────────────────────────────────────
  @testset "Phase 6: Alter Field Properties (Nullability)" begin
    # Baseline guard: phase 5 must have left migrationtest with a "name" column
    @assert "name" in column_names(pool, "migrationtest") "Phase 6 requires 'name' column from phase 5"

    write_edge_models("""
    MigrationTest = Models.Model(
        id = Models.IDField(),
        name = Models.CharField(null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    @test column_nullable(pool, "migrationtest", "name")
  end

  # ── Phase 7: Rename column ────────────────────────────────────────
  @testset "Phase 7: Rename Column" begin
    # Baseline guard: phase 6 must have left migrationtest with a "name" column
    @assert "name" in column_names(pool, "migrationtest") "Phase 7 requires 'name' column from phase 6"

    write_edge_models("""
    MigrationTest = Models.Model(
        id = Models.IDField(),
        fullname = Models.CharField(null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    cols = column_names(pool, "migrationtest")
    @test "fullname" in cols
    # The old column must be absent — an ADD instead of RENAME would fail here
    @test !("name" in cols)
  end

  # ── Phase 8: Additional field types ───────────────────────────────
  @testset "Phase 8: Add More Types" begin
    write_edge_models("""
    MigrationTest = Models.Model(
        id = Models.IDField(),
        fullname = Models.CharField(null=true)
    )
    TypesTable = Models.Model(
        id = Models.IDField(),
        is_active = Models.BooleanField(default=true),
        score = Models.DecimalField(max_digits=5, decimal_places=2, null=true),
        created_at = Models.DateTimeField(null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    cols = column_names(pool, "typestable")
    @test "is_active" in cols
    @test "score" in cols
    @test "created_at" in cols
  end

  # ── Phase 8a2: PositiveSmallIntegerField non-negative CHECK lifecycle ──
  # Regression test for Django-style CHECK constraint diffing. Neither PostgreSQL
  # nor SQLite has an unsigned integer type, so a PositiveSmallIntegerField is a
  # SMALLINT guarded by `CHECK (col >= 0)`. The engine must keep that constraint in
  # sync with the model as a column's type transitions in and out of the field:
  #   IntegerField → PositiveSmallIntegerField  adds the CHECK
  #   PositiveSmallIntegerField → IntegerField  drops it
  # On PostgreSQL the DROP path runs the real get_constraints_check introspection
  # against information_schema; on SQLite the CHECK is re-derived on table recreation.
  # MigrationTest and TypesTable must stay in every model file written by the
  # 8a2/8a3 lifecycle phases: the destructive migrate would otherwise DROP them
  # and break the Phase 8b baseline, which expects migrationtest to survive
  # from earlier phases.
  phase8_models = """
  MigrationTest = Models.Model(
      id = Models.IDField(),
      fullname = Models.CharField(null=true)
  )
  TypesTable = Models.Model(
      id = Models.IDField(),
      is_active = Models.BooleanField(default=true),
      score = Models.DecimalField(max_digits=5, decimal_places=2, null=true),
      created_at = Models.DateTimeField(null=true)
  )
  """

  @testset "Phase 8a2: PositiveSmallIntegerField CHECK lifecycle" begin
    # Start with a plain IntegerField column — no CHECK expected.
    write_edge_models(phase8_models * """
    PosIntCheck = Models.Model(
        id = Models.IDField(),
        level = Models.IntegerField(null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)
    @test "level" in column_names(pool, "posintcheck")
    @test !column_has_nonneg_check(pool, "posintcheck", "level")

    # Transition into PositiveSmallIntegerField — the CHECK must now exist.
    write_edge_models(phase8_models * """
    PosIntCheck = Models.Model(
        id = Models.IDField(),
        level = Models.PositiveSmallIntegerField(null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)
    @test column_has_nonneg_check(pool, "posintcheck", "level")

    # Transition back out to IntegerField — the CHECK must be dropped. On PostgreSQL
    # this exercises the get_constraints_check + DROP CONSTRAINT path end to end.
    write_edge_models(phase8_models * """
    PosIntCheck = Models.Model(
        id = Models.IDField(),
        level = Models.IntegerField(null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)
    @test !column_has_nonneg_check(pool, "posintcheck", "level")
  end

  # ── Phase 8a3: PositiveIntegerField CHECK lifecycle and round-trip ──
  # PositiveIntegerField renders as plain `integer` on PostgreSQL (only the CHECK
  # distinguishes it from IntegerField) and as `INTEGER UNSIGNED` on SQLite. Besides
  # the CHECK lifecycle, this phase locks the round-trip: after migrating, a second
  # makemigrations must see the introspected column as PositiveIntegerField again and
  # report no pending changes — otherwise every run would emit a spurious ALTER.
  @testset "Phase 8a3: PositiveIntegerField CHECK lifecycle" begin
    # Transition the column into PositiveIntegerField — the CHECK must exist.
    write_edge_models(phase8_models * """
    PosIntCheck = Models.Model(
        id = Models.IDField(),
        level = Models.PositiveIntegerField(null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)
    @test "level" in column_names(pool, "posintcheck")
    @test column_has_nonneg_check(pool, "posintcheck", "level")

    # Round-trip guard: with the model unchanged, makemigrations must not plan any
    # change for posintcheck — an introspection mismatch would emit a spurious ALTER
    # on every run. Scoped to this table because unrelated pre-existing drift exists
    # (e.g. DecimalField max_digits is not recovered by SQLite PRAGMA introspection,
    # so typestable is re-planned chronically).
    pending_path = joinpath(@__DIR__, edge_db_name, "migrations", "pending_migrations.jl")
    @assert !isfile(pending_path) "migrate should have archived pending_migrations.jl"
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    @test !isfile(pending_path) || !occursin("posintcheck", lowercase(read(pending_path, String)))

    # Transition back out to IntegerField — same column type on PostgreSQL, so this
    # exercises the CHECK drop without a type cast masking it.
    write_edge_models(phase8_models * """
    PosIntCheck = Models.Model(
        id = Models.IDField(),
        level = Models.IntegerField(null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)
    @test !column_has_nonneg_check(pool, "posintcheck", "level")
  end

  # ── Phase 8b: Add DateTimeField / DateField to existing table ──────
  # Regression test for the bug where `_add_new_field` called
  # `Dialect.alter_field(conn, model_name::Symbol, ...)` instead of
  # `Dialect.alter_field(conn, model::PormGModel, ...)` when a
  # temporary default value was needed (DateTimeField / DateField added
  # to a table that already exists in the database).  SQLite has no
  # `alter_field` overload for the Symbol path, so the call raised a
  # MethodError before the fix was applied.
  @testset "Phase 8b: Add DateTimeField to existing table" begin
    # Baseline: MigrationTest table exists from earlier phases
    # (fullname column from phase 7). Confirm the starting state.
    @assert table_exists(pool, "migrationtest") "Phase 8b requires migrationtest from earlier phases"

    # Add a DateTimeField to an already-migrated table.
    # _add_new_field will call _get_temporary_default_value, which returns
    # a non-nothing timestamp, triggering the alter_field path that was
    # broken (MethodError on SQLite before the fix).
    write_edge_models("""
    MigrationTest = Models.Model(
        id = Models.IDField(),
        fullname = Models.CharField(null=true),
        updated_at = Models.DateTimeField()
    )
    TypesTable = Models.Model(
        id = Models.IDField(),
        is_active = Models.BooleanField(default=true),
        score = Models.DecimalField(max_digits=5, decimal_places=2, null=true),
        created_at = Models.DateTimeField(null=true)
    )
    """)
    # This must not throw a MethodError on either SQLite or PostgreSQL.
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    cols = column_names(pool, "migrationtest")
    @test "updated_at" in cols
  end

  # ── Phase 8c: SQLite recreation deduplication ─────────────────────
  # Regression test: when multiple temporal fields (DateTimeField /
  # DateField) are added to the SAME existing table in a single
  # makemigrations call, SQLite must emit exactly ONE table-recreation
  # statement, not one per field. Before the fix the stable "Alter table:"
  # key was missing and each field produced its own identical recreation.
  #
  # We use dry_run to inspect the plan before touching the database, so
  # the assertion is purely on the migration plan output.
  # PostgreSQL uses ALTER COLUMN and never needs recreation, so the
  # destructive-count assertion is skipped there.
  @testset "Phase 8c: SQLite single recreation per table (deduplication)" begin
    # Add TWO temporal fields simultaneously to MigrationTest (one DateField
    # + one DateTimeField).  Each one that needs a temporary default would
    # have triggered its own table recreation prior to the fix.
    write_edge_models("""
    MigrationTest = Models.Model(
        id = Models.IDField(),
        fullname = Models.CharField(null=true),
        updated_at = Models.DateTimeField(),
        created_date = Models.DateField(),
        activated_at = Models.DateTimeField()
    )
    TypesTable = Models.Model(
        id = Models.IDField(),
        is_active = Models.BooleanField(default=true),
        score = Models.DecimalField(max_digits=5, decimal_places=2, null=true),
        created_at = Models.DateTimeField(null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    @test isfile(joinpath(@__DIR__, edge_db_name, "migrations", "pending_migrations.jl"))

    result = Migrations.dry_run(pool, edge_settings)

    if adapter_name == "SQLite"
      # Count statements that look like SQLite table recreations for "migrationtest".
      # Each recreation starts with DROP TABLE IF EXISTS "migrationtest_new".
      recreation_count = count(
        s -> occursin("DROP TABLE IF EXISTS", uppercase(s)) && occursin("MIGRATIONTEST_NEW", uppercase(s)),
        result.statements
      )
      # Before the fix this was 2 (one per added temporal field). Must be exactly 1.
      @test recreation_count == 1
      @test Migrations.is_destructive(result) == true
      # Count only MigrationTest-related destructive statements; other tables
      # (e.g. TypesTable) may also be recreated due to schema drift.
      mt_destructive = count(s -> occursin("migrationtest", lowercase(s)), result.destructive_statements)
      @test mt_destructive == 1
    end

    # Apply the plan so the table is in a consistent state for later phases.
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)
    cols = column_names(pool, "migrationtest")
    @test "activated_at" in cols
  end

  # ── Phase 8d: Rename a column (non-interactive = add+drop path) ───
  # Verifies that renaming a column in the model definition (e.g.
  # `fullname` → `display_name`) is handled correctly when
  # `interactive=false`.
  #
  # In non-interactive mode PormG cannot ask the user whether the new
  # field is a rename of an old one, so it falls back to the safe
  # add+drop path: ADD the new column, DROP the old column.
  # Because DROP is destructive, `migrate(..., destructive=true)` is
  # required — exactly as Django would require an explicit confirmation.
  #
  # We use a CharField rename (not a DateField rename) because the
  # non-interactive path for a non-null temporal field on SQLite triggers
  # a table recreation that also removes the old column, making the
  # subsequent DROP fail — a separate known issue.
  #
  # The interactive rename path (user answers "1" at the prompt) is
  # covered by Phase 8e using a mocked stdin.
  @testset "Phase 8d: Rename column (non-interactive add+drop)" begin
    # Baseline: fullname exists from earlier phases
    @assert "fullname" in column_names(pool, "migrationtest") "Phase 8d requires 'fullname' column from earlier phases"

    # Rename fullname → display_name in the model definition.
    write_edge_models("""
    MigrationTest = Models.Model(
        id = Models.IDField(),
        display_name = Models.CharField(null=true),
        updated_at = Models.DateTimeField(),
        created_date = Models.DateField(),
        activated_at = Models.DateTimeField()
    )
    TypesTable = Models.Model(
        id = Models.IDField(),
        is_active = Models.BooleanField(default=true),
        score = Models.DecimalField(max_digits=5, decimal_places=2, null=true),
        created_at = Models.DateTimeField(null=true)
    )
    """)

    # Non-interactive: planner sees `display_name` as a new field and
    # `fullname` as a removed field → ADD + DROP (destructive).
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)

    result = Migrations.dry_run(pool, edge_settings)
    # The plan must include an ADD for the new name …
    @test any(occursin("display_name", lowercase(s)) for s in result.statements)
    # … and a DROP for the old name.
    @test any(occursin("fullname", lowercase(s)) for s in result.statements)
    # Overall the plan is destructive because of the DROP.
    @test Migrations.is_destructive(result)

    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    cols = column_names(pool, "migrationtest")
    @test "display_name" in cols
    @test !("fullname" in cols)
  end

  # ── Phase 8e: Rename column (interactive RENAME via mocked stdin) ──
  # This exercises the same code path a user hits when they answer "1"
  # at the interactive rename prompt — but fully automated by redirecting
  # stdin through a Pipe pre-loaded with the expected response.
  #
  # Unlike Phase 8d (non-interactive → ADD + DROP), the interactive path
  # produces a single RENAME COLUMN statement which is non-destructive.
  # Django's equivalent is `RenameField`.
  #
  # Both SQLite (3.25+) and PostgreSQL support ALTER TABLE … RENAME
  # COLUMN, so this test runs on both adapters.
  @testset "Phase 8e: Rename column (interactive RENAME via mocked stdin)" begin
    # After Phase 8d, MigrationTest has: id, display_name, updated_at, created_date, activated_at
    @assert "display_name" in column_names(pool, "migrationtest") "Phase 8e requires 'display_name' from Phase 8d"

    # Rename display_name → full_name in the model definition.
    # The planner will detect one addition (full_name) and one deletion
    # (display_name) and prompt the user to confirm the rename.
    write_edge_models("""
    MigrationTest = Models.Model(
        id = Models.IDField(),
        full_name = Models.CharField(null=true),
        updated_at = Models.DateTimeField(),
        created_date = Models.DateField(),
        activated_at = Models.DateTimeField()
    )
    TypesTable = Models.Model(
        id = Models.IDField(),
        is_active = Models.BooleanField(default=true),
        score = Models.DecimalField(max_digits=5, decimal_places=2, null=true),
        created_at = Models.DateTimeField(null=true)
    )
    """)

    # Mock stdin: feed "1\n" so the planner maps full_name → display_name
    # (option 1 in the numbered list of deletion candidates).
    mock_input = Pipe()
    Base.link_pipe!(mock_input)
    write(mock_input.in, "1\n")
    close(mock_input.in)
    redirect_stdin(mock_input.out) do
      makemigrations(joinpath(@__DIR__, edge_db_name), interactive=true)
    end

    # Inspect the plan via dry_run BEFORE applying.
    result = Migrations.dry_run(pool, edge_settings)

    # The plan must contain a RENAME COLUMN statement for full_name.
    @test any(s -> occursin("rename", lowercase(s)) && occursin("full_name", lowercase(s)), result.statements)

    # The RENAME COLUMN itself is non-destructive.  The overall plan may be
    # flagged destructive if the planner also regenerates other tables
    # (e.g. TypesTable schema drift), so we check just the rename statement.
    rename_stmts = filter(s -> occursin("RENAME COLUMN", uppercase(s)), result.statements)
    @test !isempty(rename_stmts) && !any(Migrations.is_destructive, rename_stmts)

    # Apply — use destructive=true because the plan may include unrelated
    # table recreations alongside the rename.
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    cols = column_names(pool, "migrationtest")
    @test "full_name" in cols
    @test !("display_name" in cols)
  end

  # ── Phase 8f: Data survival when adding NOT NULL temporal to table with rows ──
  #
  # Regression test for the bug where alter_field(conn::PormGSQLite, model::PormGModel, ...)
  # built the INSERT column list at PLANNING TIME by reading the live database's
  # columns for the table-recreation step. Reading the live DB could not see columns
  # that were queued via ADD COLUMN but had not yet executed.
  #
  # Consequently the generated SQL was:
  #   INSERT INTO "migrationtest_new" ("id", "full_name", ...) -- missing "last_seen"!
  #     SELECT "id", "full_name", ... FROM "migrationtest";
  #
  # While the new table's CREATE defined "last_seen" as NOT NULL. With even a single
  # existing row SQLite raises "NOT NULL constraint failed: migrationtest_new.last_seen"
  # and the entire migration is rolled back.
  #
  # The fix: build the INSERT column list from model.fields directly instead of reading
  # the live-DB columns. ADD COLUMN statements are always queued BEFORE the recreation in
  # the migration plan, so at execution time every model field is present in the old table.
  #
  # Assertion strategy:
  #   1. dry_run: the INSERT statement in the plan must reference "last_seen"
  #      (pure SQL-text inspection, no DB writes, adapter-neutral)
  #   2. Data-survival: a row inserted before the migration is still present after it
  #      (the migration must not blow up and not silently discard existing rows)
  @testset "Phase 8f: Data survival adding NOT NULL DateField to table with rows" begin
    @assert "full_name" in column_names(pool, "migrationtest") "Phase 8f requires 'full_name' column from Phase 8e"
    @assert "activated_at" in column_names(pool, "migrationtest") "Phase 8f requires 'activated_at' column from Phase 8c"

    # Seed one row so that a buggy INSERT SELECT (missing the new NOT NULL column)
    # will fail with a NOT NULL constraint instead of succeeding vacuously on an
    # empty table.
    PormG.ConnectionPool.fetch(pool,
      """INSERT INTO "migrationtest" ("full_name", "updated_at", "created_date", "activated_at")
         VALUES ('survivor-8f', '2024-01-01 00:00:00', '2024-01-01', '2024-01-01 00:00:00')""")

    # Add a new NOT NULL DateField. _add_new_field will:
    #   (a) queue ADD COLUMN "last_seen" DATE NOT NULL DEFAULT '<today>'
    #   (b) queue a table-recreation that must include "last_seen" in the INSERT.
    write_edge_models("""
    MigrationTest = Models.Model(
        id = Models.IDField(),
        full_name = Models.CharField(null=true),
        updated_at = Models.DateTimeField(),
        created_date = Models.DateField(),
        activated_at = Models.DateTimeField(),
        last_seen = Models.DateField()
    )
    TypesTable = Models.Model(
        id = Models.IDField(),
        is_active = Models.BooleanField(default=true),
        score = Models.DecimalField(max_digits=5, decimal_places=2, null=true),
        created_at = Models.DateTimeField(null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    @test isfile(joinpath(@__DIR__, edge_db_name, "migrations", "pending_migrations.jl"))

    result = Migrations.dry_run(pool, edge_settings)

    # ── SQL-text assertion (both adapters) ──────────────────────────────
    # The INSERT statement in the recreation block must reference "last_seen".
    # Before the fix it was generated by reading the live-DB columns at planning
    # time and would only list columns that existed before the ADD COLUMN ran.
    if adapter_name == "SQLite"
      insert_stmts = filter(
        s -> occursin("INSERT INTO", uppercase(s)) && occursin("MIGRATIONTEST_NEW", uppercase(s)),
        result.statements
      )
      @test !isempty(insert_stmts)
      # "last_seen" must appear in the INSERT column list, not just in CREATE TABLE.
      @test all(s -> occursin("last_seen", lowercase(s)), insert_stmts)
    end

    # ── Data-survival assertion ──────────────────────────────────────────
    # migrate() must not throw. If the bug is present the INSERT will violate
    # the NOT NULL constraint and the whole migration will fail.
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    # Column must exist in the live schema after migration.
    cols = column_names(pool, "migrationtest")
    @test "last_seen" in cols

    # The survivor row inserted before the migration must still be present.
    # A failed INSERT SELECT leaves the old table intact (SQLite rolls back the
    # whole recreation block), but migrate() would also have thrown above.
    survivors = PormG.ConnectionPool.fetch(pool,
      """SELECT "full_name" FROM "migrationtest" WHERE "full_name" = 'survivor-8f'""") |> DataFrame
    @test DataFrames.nrow(survivors) == 1
  end

  # ==================================================================
  # Migration Lifecycle Tests (init_migrations, status, dry_run,
  # destructive guard, repair) — isolated database.
  # ==================================================================

  # ── Phase 9: init_migrations idempotency ──────────────────────────
  @testset "Phase 9: History Table Bootstrap (init_migrations)" begin
    # pormg_migrations already exists because migrate() calls init_migrations()
    @test table_exists(pool, "pormg_migrations")

    # Second call must be idempotent
    Migrations.init_migrations(pool)
    @test table_exists(pool, "pormg_migrations")
  end

  # ── Phase 10: status() reporting ──────────────────────────────────
  @testset "Phase 10: Migration Status Reporting" begin
    st = Migrations.status(pool, edge_settings)
    @test st.has_history_table == true
    @test st.pending == false
    @test length(st.applied) > 0
    @test isempty(st.failed)
    @test st isa Migrations.MigrationStatus
  end

  # ── Phase 11: dry_run() analysis ──────────────────────────────────
  @testset "Phase 11: Dry Run Analysis" begin
    write_edge_models("""
    TypesTable = Models.Model(
        id = Models.IDField(),
        is_active = Models.BooleanField(default=true),
        score = Models.DecimalField(max_digits=5, decimal_places=2, null=true),
        created_at = Models.DateTimeField(null=true)
    )
    DryRunTable = Models.Model(
        id = Models.IDField(),
        label = Models.CharField(max_length=50)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)

    result = Migrations.dry_run(pool, edge_settings)
    @test result isa Migrations.DryRunResult
    @test Migrations.total_statements(result) > 0
    @test !isempty(result.checksum)
    @test length(result.checksum) == 64  # SHA-256 hex
    # The SQL plan must reference the new table being added
    @test any(occursin("dryruntable", lowercase(s)) for s in result.statements)

    # dry_run must not consume the pending file
    @test isfile(joinpath(@__DIR__, edge_db_name, "migrations", "pending_migrations.jl"))

    migrate(joinpath(@__DIR__, edge_db_name), interactive=false)
  end

  # ── Phase 12: Destructive guard ───────────────────────────────────
  @testset "Phase 12: Destructive Guard" begin
    # Remove DryRunTable -> triggers DROP TABLE
    write_edge_models("""
    TypesTable = Models.Model(
        id = Models.IDField(),
        is_active = Models.BooleanField(default=true),
        score = Models.DecimalField(max_digits=5, decimal_places=2, null=true),
        created_at = Models.DateTimeField(null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)

    result = Migrations.dry_run(pool, edge_settings)
    @test Migrations.is_destructive(result) == true
    @test !isempty(result.destructive_statements)

    # migrate without destructive=true must refuse
    ret = migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=false)
    @test ret === nothing
    @test isfile(joinpath(@__DIR__, edge_db_name, "migrations", "pending_migrations.jl"))

    # With destructive=true it should succeed
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    @test !table_exists(pool, "dryruntable")
  end

  # ── Phase 13: Repair operations ───────────────────────────────────
  # ─────────────────────────────────────────────────────────────────────────────
  # Migrations: repair ops must not leak pool connections
  # mark_applied/mark_failed route through _record_migration/_update_migration_status
  # with no caller-owned connection. Those helpers must release the write connection
  # they acquire (release_conn = conn === nothing); before that fix each successful
  # call returned the connection in its result and dropped it on the floor, so every
  # repair op permanently consumed a pool slot. We snapshot the pool's in-use count
  # and assert it returns to baseline after the full repair sequence.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "Phase 13: Repair Operations" begin
    pool_in_use(p) = length(p.connections) - count(p.available)
    in_use_before = pool_in_use(pool)

    # mark_applied now requires a verifiable checksum basis (issue #81): pass sql_content so the
    # recorded digest is computed from real SQL rather than fabricated.
    Migrations.mark_applied(pool, edge_settings, "99990101000001", "manual_test_migration";
                            sql_content = "-- manual reconciliation (Phase 13 repair test)")
    st = Migrations.status(pool, edge_settings)
    @test "99990101000001" in [m[:version] for m in st.applied]

    Migrations.mark_failed(pool, edge_settings, "99990101000001")
    st2 = Migrations.status(pool, edge_settings)
    @test "99990101000001" in [m[:version] for m in st2.failed]

    Migrations.remove_migration_record(pool, edge_settings, "99990101000001")
    st3 = Migrations.status(pool, edge_settings)
    all_versions = vcat([m[:version] for m in st3.applied], [m[:version] for m in st3.failed])
    @test !("99990101000001" in all_versions)

    # No connection leaked across the repair + status calls (all synchronous).
    @test pool_in_use(pool) == in_use_before
  end

  # ── Phase 14: Mixed-case columns preserve case + no churn (#57) ────
  # Declares a model with genuinely mixed-case COLUMNS, migrates it, then proves
  # (a) create_table preserved the declared case on the real backend, and
  # (b) a re-run detects NO changes — introspection reads the mixed-case columns
  # and the diff compares case-correctly, so there is no spurious add/drop churn.
  @testset "Phase 14: Mixed-case Columns + No Churn (#57)" begin
    write_edge_models("""
    MixedCaseTable = Models.Model(
        id = Models.IDField(),
        driverRef = Models.CharField(),
        foreName = Models.CharField(null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    # (a) The physical columns carry the declared case verbatim (table stays lowercase).
    cols = column_names(pool, "mixedcasetable")
    @test "driverRef" in cols
    @test "foreName" in cols
    @test !("driverref" in cols)   # no lowercased duplicate column

    # (b) Re-running makemigrations with the SAME models writes NO pending plan:
    #     introspection + diff agree on the mixed-case columns ⇒ zero churn.
    pending = joinpath(@__DIR__, edge_db_name, "migrations", "pending_migrations.jl")
    isfile(pending) && rm(pending)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    @test !isfile(pending)
  end

  # ── Phase 15: db_column drives the physical column + no churn (#50) ─
  # A field's db_column drives the PHYSICAL column name; the field name never
  # becomes a column. Proves create_table + ADD COLUMN target the db_column, and
  # that re-running makemigrations detects no churn (introspection reads the
  # db_column physical name and the diff is keyed by column, not field name).
  @testset "Phase 15: db_column Columns + No Churn (#50)" begin
    write_edge_models("""
    DbColTable = Models.Model(
        id = Models.IDField(),
        sku = Models.CharField(db_column="product_sku"),
        name = Models.CharField(null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    # (a) The physical column carries the db_column name; the field name is NOT a column.
    cols = column_names(pool, "dbcoltable")
    @test "product_sku" in cols
    @test !("sku" in cols)
    @test "name" in cols

    # (b) No churn: re-running with the SAME models writes no pending plan.
    pending = joinpath(@__DIR__, edge_db_name, "migrations", "pending_migrations.jl")
    isfile(pending) && rm(pending)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    @test !isfile(pending)

    # (c) ADD path: a new db_column field → ADD COLUMN targets the db_column name.
    write_edge_models("""
    DbColTable = Models.Model(
        id = Models.IDField(),
        sku = Models.CharField(db_column="product_sku"),
        name = Models.CharField(null=true),
        qty = Models.IntegerField(db_column="quantity_col", null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    result = Migrations.dry_run(pool, edge_settings)
    @test any(s -> occursin("quantity_col", lowercase(s)), result.statements)   # ADD COLUMN → db_column
    @test !any(s -> occursin("add column \"qty\"", lowercase(s)), result.statements)  # not the field name
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)
    cols2 = column_names(pool, "dbcoltable")
    @test "quantity_col" in cols2
    @test !("qty" in cols2)

    # (d) No churn after the ADD.
    isfile(pending) && rm(pending)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    @test !isfile(pending)

    # (d2) ADD a NOT NULL DateTimeField with db_column — exercises the temporary-default
    # path (ADD COLUMN "stamp_ts" ... DEFAULT <now>, then DROP DEFAULT). The DROP DEFAULT
    # must target the db_column; on PostgreSQL the field-name form errored before the fix.
    write_edge_models("""
    DbColTable = Models.Model(
        id = Models.IDField(),
        sku = Models.CharField(db_column="product_sku"),
        name = Models.CharField(null=true),
        qty = Models.IntegerField(db_column="quantity_col", null=true),
        stamp = Models.DateTimeField(db_column="stamp_ts")
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)  # must not error on the DROP DEFAULT
    stamp_cols = column_names(pool, "dbcoltable")
    @test "stamp_ts" in stamp_cols
    @test !("stamp" in stamp_cols)

    # (e) FK honors db_column on BOTH the local column and the referenced parent
    # column (the parent's pk field is itself renamed via db_column). The FK target
    # is a model instance, so fk_target_column resolves the parent's db_column —
    # migrate() succeeding proves the FK REFERENCES targets the real column.
    # The parent's PRIMARY KEY field is itself renamed via db_column (IDField is
    # inherently unique — satisfies PostgreSQL's FK-target requirement — and round-trips
    # cleanly through introspection, unlike a UNIQUE non-PK column).
    write_edge_models("""
    DbColParent = Models.Model("dbcolparent",
        code = Models.IDField(db_column="parent_code"),
        label = Models.CharField(null=true)
    )
    DbColChild = Models.Model("dbcolchild",
        id = Models.IDField(),
        parent = Models.ForeignKey(DbColParent, pk_field="code", db_column="parent_fk", null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)
    @test "parent_code" in column_names(pool, "dbcolparent")   # parent pk physical column
    ccols = column_names(pool, "dbcolchild")
    @test "parent_fk" in ccols                                 # local FK column = db_column
    @test !("parent" in ccols)                                 # field name is NOT a column

    # (f) No churn for the FK models either.
    isfile(pending) && rm(pending)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    @test !isfile(pending)

    # (g) #62: a STRING FK target + an OMITTED pk_field over the renamed-PK parent. The
    # migration prelude (_load_current_models) must resolve "DbColParent" → the model AND
    # default pk_field to the parent's PK ("code"), so the FK REFERENCES
    # "dbcolparent"("parent_code") — not the "id" fallback. migrate() SUCCEEDING is the
    # assertion: dbcolparent has no "id" column, so an unresolved target / "id" fallback
    # would raise. (Before #62 this churned + emitted the wrong referenced column.)
    write_edge_models("""
    DbColParent = Models.Model("dbcolparent",
        code = Models.IDField(db_column="parent_code"),
        label = Models.CharField(null=true)
    )
    DbColChild = Models.Model("dbcolchild",
        id = Models.IDField(),
        parent = Models.ForeignKey(DbColParent, pk_field="code", db_column="parent_fk", null=true)
    )
    DbColStrChild = Models.Model("dbcolstrchild",
        id = Models.IDField(),
        parent = Models.ForeignKey("DbColParent", db_column="parent_strfk", null=true)
    )
    """)
    isfile(pending) && rm(pending)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)
    scols = column_names(pool, "dbcolstrchild")
    @test "parent_strfk" in scols                              # local FK column = db_column
    @test !("parent" in scols)                                 # field name is NOT a column

    # Adapter-neutral proof of the REFERENCED column: migrate() raising is a
    # PostgreSQL-only signal (SQLite validates FK targets lazily at create time), so
    # introspect the migrated FK and confirm it points at the parent's db_column
    # ("parent_code"), not the "id" fallback an unresolved target would have produced.
    strchild_intro = nothing
    for m in PormG.Migrations.convert_schema_to_models(pool)
      lowercase(string(m.name)) == "dbcolstrchild" && (strchild_intro = m)
    end
    @test strchild_intro !== nothing
    @test any(f -> hasproperty(f, :to) && hasproperty(f, :pk_field) && f.pk_field == "parent_code",
              values(strchild_intro.fields))

    # (h) No churn for the string-target + omitted-pk_field model.
    isfile(pending) && rm(pending)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    @test !isfile(pending)
  end

  # ── Phase 16: idempotent re-apply / archive-failure landmine (#81) ─
  # Acceptance criteria 1 & 3: re-running migrate() over a pending_migrations.jl that a previous
  # apply COMMITted but then failed to archive must be a NO-OP, not a destructive re-apply.
  #
  # We reproduce the landmine deterministically. A CREATE TABLE is emitted with IF NOT EXISTS and
  # would survive a re-run harmlessly, so instead we apply an ADD COLUMN migration (a plain
  # `ALTER TABLE … ADD COLUMN`, which is NOT idempotent), then hand the engine back the exact
  # pending file a failed archive would have left and call migrate() again:
  #   • Pre-fix: the second run re-executes ADD COLUMN, errors on the duplicate column, records a
  #     spurious `failed` row, and rethrows.
  #   • Post-fix: the checksum guard recognises the content as already-applied, skips the DDL, and
  #     retries the archive so the stale pending file finally clears.
  @testset "Phase 16: Idempotent re-apply (#81)" begin
    pending_path = joinpath(@__DIR__, edge_db_name, "migrations", "pending_migrations.jl")

    # Step 1 — an isolated table to mutate. Replacing the model set drops the Phase-15 tables
    # (DROP TABLE … CASCADE on PostgreSQL), hence destructive=true.
    write_edge_models("""
    Reapply81 = Models.Model(
        id = Models.IDField(),
        alpha = Models.CharField(null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)
    @test table_exists(pool, "reapply81")
    @test !("beta" in column_names(pool, "reapply81"))

    # Step 2 — add a column: the non-idempotent ADD COLUMN whose re-apply would error.
    write_edge_models("""
    Reapply81 = Models.Model(
        id = Models.IDField(),
        alpha = Models.CharField(null=true),
        beta = Models.IntegerField(null=true)
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    @test isfile(pending_path)
    # Capture the exact pending file that a failed post-commit archive would leave behind.
    stashed_pending = read(pending_path, String)

    applied_before = length(Migrations.status(pool, edge_settings).applied)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false)
    @test "beta" in column_names(pool, "reapply81")   # applied
    @test !isfile(pending_path)                        # archived on success

    st_after = Migrations.status(pool, edge_settings)
    applied_after = length(st_after.applied)
    failed_after  = length(st_after.failed)
    @test applied_after == applied_before + 1          # exactly one new record

    # Step 3 — SIMULATE the archive-failure landmine: restore the stale pending file and re-run.
    write(pending_path, stashed_pending)
    @test isfile(pending_path)

    # The re-run must NOT throw. Pre-fix the duplicate ADD COLUMN raises → reapplied_ok = false.
    reapplied_ok = try
      migrate(joinpath(@__DIR__, edge_db_name), interactive=false)
      true
    catch
      false
    end
    @test reapplied_ok

    st_reapply = Migrations.status(pool, edge_settings)
    @test "beta" in column_names(pool, "reapply81")            # schema unchanged
    @test length(st_reapply.applied) == applied_after          # no new applied record
    @test length(st_reapply.failed) == failed_after            # no spurious 'failed' row (pre-fix bug)
    @test !isfile(pending_path)                                # archive retry cleared the stale file
  end

  # ── Phase 17: Composite unique constraint (#19) ──────────────────────
  # A model-level UniqueConstraint must materialize a real composite unique index when the table
  # is created, and the database must REJECT a duplicate (season, round) pair while allowing a
  # different pair. Uses the idiomatic no-positional-name model form (table inferred from binding).
  @testset "Phase 17: Composite unique constraint (#19)" begin
    write_edge_models("""
    Uniqtest = Models.Model(
        id = Models.IDField(),
        season = Models.IntegerField(),
        round = Models.IntegerField(),
        constraints = [Models.UniqueConstraint(fields=("season", "round"), name="uniqtest_season_round_uniq")]
    )
    """)
    makemigrations(joinpath(@__DIR__, edge_db_name), interactive=false)
    migrate(joinpath(@__DIR__, edge_db_name), interactive=false, destructive=true)

    @test table_exists(pool, "uniqtest")
    # The composite unique index exists on the freshly created table (both backends).
    @test "uniqtest_season_round_uniq" in index_names(pool, "uniqtest")

    # First (2021, 1) inserts; the duplicate must violate the composite unique index.
    PormG.ConnectionPool.fetch(pool, """INSERT INTO uniqtest ("season", "round") VALUES (2021, 1);""")
    dup_rejected = try
      PormG.ConnectionPool.fetch(pool, """INSERT INTO uniqtest ("season", "round") VALUES (2021, 1);""")
      false
    catch
      true
    end
    @test dup_rejected

    # A different pair is accepted — uniqueness is composite, not per-column.
    accepted = try
      PormG.ConnectionPool.fetch(pool, """INSERT INTO uniqtest ("season", "round") VALUES (2021, 2);""")
      true
    catch
      false
    end
    @test accepted
  end

  # ── Cleanup ─────────────────────────────────────────────────────────
  PormG.Configuration.close_pool!(joinpath(@__DIR__, edge_db_name))
  delete!(PormG.config, joinpath(@__DIR__, edge_db_name))
  if adapter_name == "SQLite"
    # SQLite: remove the entire disposable folder
    ispath(joinpath(@__DIR__, edge_db_name)) && rm(joinpath(@__DIR__, edge_db_name), recursive=true)
  else
    # Best-effort drop of the disposable DB (the edge pool was just closed above). Guarded: never
    # drop when the edge DB resolved to the shared selected DB (degraded regenerated-fixture case).
    if !edge_db_reuses_selected_db[]
      drop_postgres_database!(edge_settings, string(edge_settings.db_config_settings["database"]))
    end
    if edge_db_fixture_generated[]
      # Remove the entire temporary fixture if this test had to create it.
      ispath(joinpath(@__DIR__, edge_db_name)) && rm(joinpath(@__DIR__, edge_db_name), recursive=true)
    else
      # PostgreSQL: remove only generated artifacts, keep the committed fixture.
      mig_dir = joinpath(@__DIR__, edge_db_name, "migrations")
      ispath(mig_dir) && rm(mig_dir, recursive=true)
      models_path = joinpath(@__DIR__, edge_db_name, "models.jl")
      isfile(models_path) && rm(models_path)
    end
  end
end  # @testset "Migration Engine Edge Cases"

# ─── Final Reactivation: Selected Integration DB ────────────────────────────
# Before finishing this file, fully rebuild the selected integration DB from
# its real models so the process ends with the expected schema active again.
# This also repairs the state when the PostgreSQL edge-case config happens to
# reuse the same physical database as the selected integration environment.
@testset "Selected DB Reactivation ($(PORMG_DB_FOLDER))" begin
  settings = PormG.config[PORMG_DB_FOLDER]
  reset_database!(settings)

  settings = reload_config_and_models!()
  makemigrations(PORMG_DB_FOLDER, interactive=false)
  migrate(PORMG_DB_FOLDER, interactive=false, destructive=true)

  settings = reload_config_and_models!()
  assert_clean_state()

  # Prove that the imported integration models still resolve against the
  # selected environment after the final rebuild is complete.
  @test M.Status.objects.count() == 0
  @test M.Circuit.objects.count() == 0

  @info "Selected integration DB rebuilt after edge-case migration tests" adapter=adapter_name db=PORMG_DB_FOLDER fallback=edge_db_reuses_selected_db[]
end

# ── SQLite table-rebuild: preserve secondary indexes + FK-integrity gate (#82) ──
#
# Logic: a SQLite field ALTER rebuilds the table (CREATE new → INSERT…SELECT → DROP old → RENAME).
#        The DROP drops the table's secondary indexes; the fix re-emits their captured CREATE INDEX
#        DDL after the rename, and a `PRAGMA foreign_key_check` gates the rebuild. After altering an
#        UNRELATED field, the pre-existing db_index index must still exist, the UNIQUE constraint must
#        still be enforced, and the seeded row must survive.
# Why: before the fix the rebuild silently dropped every secondary index (lost uniqueness / slow
#      queries surfacing much later) — issue #82. PostgreSQL uses real ALTER COLUMN (no rebuild), so
#      this regression is SQLite-specific.
if adapter_name == "SQLite"
  @testset "SQLite rebuild preserves indexes + FK gate (#82)" begin
    db82 = "db_test_migration_82"
    db82_path = joinpath(@__DIR__, db82)
    write82(content::String) = open(joinpath(db82_path, "models.jl"), "w") do f
      write(f, "module models\nimport PormG.Models\n", content, "\nend")
    end
    # Only "_idx" CREATE INDEX entries are at risk; column-level UNIQUE auto-indexes
    # (sqlite_autoindex_*) are recreated by the rebuilt CREATE TABLE, so isolate the user indexes.
    user_idx(names) = sort([n for n in names if occursin("idx", lowercase(n))])

    try
      # ── setup: fresh isolated SQLite DB ──────────────────────────────────────
      try; PormG.Configuration.close_pool!(db82_path); catch; end
      try; ispath(db82_path) && rm(db82_path, recursive=true); catch; end
      PormG.Generator.create_db_folder_and_yml(path=db82_path, adapter="SQLite")
      yml = joinpath(db82_path, "connection.yml")
      yml_content = replace(read(yml, String), "database: database.sqlite" => "database: migration_82.sqlite")
      open(yml, "w") do f; write(f, yml_content); end   # read BEFORE opening "w" (which truncates)
      PormG.Configuration.load(db82_path)
      pool82 = PormG.Configuration.get_settings(db82_path).connections

      # ── create: child carries a db_index + UNIQUE field, an FK to parent, and an unrelated field ──
      write82("""
      IndexParent82 = Models.Model(
          id = Models.IDField(),
          name = Models.CharField()
      )
      IndexChild82 = Models.Model(
          id = Models.IDField(),
          code = Models.CharField(db_index=true, unique=true),
          parent_id = Models.ForeignKey(IndexParent82, pk_field="id", on_delete="CASCADE"),
          payload = Models.CharField(null=true)
      )
      """)
      makemigrations(db82_path, interactive=false)
      migrate(db82_path, interactive=false, destructive=true)

      # baseline: the db_index secondary index exists, and seed a valid parent + child.
      idx_before = user_idx(index_names(pool82, "indexchild82"))
      @test !isempty(idx_before)
      PormG.ConnectionPool.fetch(pool82, """INSERT INTO "indexparent82" ("name") VALUES ('p1')""")
      PormG.ConnectionPool.fetch(pool82, """INSERT INTO "indexchild82" ("code", "parent_id", "payload") VALUES ('c1', 1, 'keep')""")

      # ── alter an UNRELATED field (payload: null=true → NOT NULL) → forces the table rebuild ──
      write82("""
      IndexParent82 = Models.Model(
          id = Models.IDField(),
          name = Models.CharField()
      )
      IndexChild82 = Models.Model(
          id = Models.IDField(),
          code = Models.CharField(db_index=true, unique=true),
          parent_id = Models.ForeignKey(IndexParent82, pk_field="id", on_delete="CASCADE"),
          payload = Models.CharField()
      )
      """)
      makemigrations(db82_path, interactive=false)
      migrate(db82_path, interactive=false, destructive=true)   # would throw if foreign_key_check found orphans

      # (a) the user-created secondary index SURVIVED the rebuild (same name) — the core #82 fix.
      @test user_idx(index_names(pool82, "indexchild82")) == idx_before

      # (b) uniqueness is still enforced after the rebuild.
      dup_err = try
        PormG.ConnectionPool.fetch(pool82, """INSERT INTO "indexchild82" ("code", "parent_id", "payload") VALUES ('c1', 1, 'dup')""")
        nothing
      catch e; e; end
      @test dup_err !== nothing
      @test any(tok -> occursin(tok, lowercase(string(dup_err))), ["unique", "constraint"])

      # (c) the seeded row survived the rebuild.
      survivors = PormG.ConnectionPool.fetch(pool82,
        """SELECT "code" FROM "indexchild82" WHERE "code" = 'c1'""") |> DataFrame
      @test DataFrames.nrow(survivors) == 1

      # (d) the alteration applied and the migration succeeded (so foreign_key_check passed, no orphans).
      @test "payload" in column_names(pool82, "indexchild82")

      # (e) the OTHER rebuild path — adding a NOT NULL field with no explicit default forces a
      #     temp-default backfill + table recreation (planner `_add_new_field`). It must ALSO preserve
      #     the indexes. (DateField is backfilled with a temp default, mirroring Phase 8f; a plain
      #     CharField has no temp default and SQLite rejects the NOT NULL add, so it wouldn't rebuild.)
      write82("""
      IndexParent82 = Models.Model(
          id = Models.IDField(),
          name = Models.CharField()
      )
      IndexChild82 = Models.Model(
          id = Models.IDField(),
          code = Models.CharField(db_index=true, unique=true),
          parent_id = Models.ForeignKey(IndexParent82, pk_field="id", on_delete="CASCADE"),
          payload = Models.CharField(),
          added_on = Models.DateField()
      )
      """)
      makemigrations(db82_path, interactive=false)
      migrate(db82_path, interactive=false, destructive=true)
      @test "added_on" in column_names(pool82, "indexchild82")
      @test user_idx(index_names(pool82, "indexchild82")) == idx_before   # add-field rebuild kept the index

      # (f) the FK-check GATE fires: enforcement is off by default, so we can plant an orphan row, and the
      #     next rebuild's PRAGMA foreign_key_check must abort the migration (rollback) rather than commit.
      PormG.ConnectionPool.fetch(pool82,
        """INSERT INTO "indexchild82" ("code", "parent_id", "payload", "added_on") VALUES ('orphan', 999, 'x', '2024-01-01')""")
      write82("""
      IndexParent82 = Models.Model(
          id = Models.IDField(),
          name = Models.CharField()
      )
      IndexChild82 = Models.Model(
          id = Models.IDField(),
          code = Models.CharField(db_index=true, unique=true),
          parent_id = Models.ForeignKey(IndexParent82, pk_field="id", on_delete="CASCADE"),
          payload = Models.CharField(null=true),
          added_on = Models.DateField()
      )
      """)
      makemigrations(db82_path, interactive=false)
      gate_err = try
        migrate(db82_path, interactive=false, destructive=true)
        nothing
      catch e; e; end
      @test gate_err !== nothing
      @test occursin("foreign_key_check", lowercase(string(gate_err))) ||
            occursin("orphan", lowercase(string(gate_err)))
      # rollback integrity: the aborted alter (payload NOT NULL → nullable) must NOT have applied, so a
      # row omitting payload is still rejected by the surviving NOT NULL constraint.
      rollback_err = try
        PormG.ConnectionPool.fetch(pool82,
          """INSERT INTO "indexchild82" ("code", "parent_id", "added_on") VALUES ('rollbackcheck', 1, '2024-01-01')""")
        nothing
      catch e; e; end
      @test rollback_err !== nothing
    finally
      try; PormG.Configuration.close_pool!(db82_path); catch; end
      try; delete!(PormG.config, db82_path); catch; end
      try; ispath(db82_path) && rm(db82_path, recursive=true); catch; end
    end
  end
end

