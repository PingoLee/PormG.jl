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

# Conditional imports: SQLite.jl is only needed for the SQLite adapter path
if adapter_name == "SQLite"
  using SQLite
end

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
    # PostgreSQL: use the committed connection.yml when available, otherwise
    # generate a blank fixture and hydrate it from the selected DB settings.
    selected_settings = PormG.Configuration.get_settings(PORMG_DB_FOLDER)
    edge_db_fixture_generated[] = ensure_postgres_test_config!(joinpath(@__DIR__, edge_db_name))
    hydrate_postgres_test_config!(joinpath(@__DIR__, edge_db_name), selected_settings)

    # Detect whether the edge-case database actually points at the same
    # PostgreSQL instance/database as the selected integration environment.
    # That is not ideal, but the final reactivation block below will rebuild
    # the selected schema from its real models as a fallback.
    PormG.Configuration.load(joinpath(@__DIR__, edge_db_name))
    pg_edge_settings = PormG.Configuration.get_settings(joinpath(@__DIR__, edge_db_name))
    edge_db_reuses_selected_db[] = postgres_connection_identity(selected_settings) == postgres_connection_identity(pg_edge_settings)
    if edge_db_reuses_selected_db[]
      @warn "db_test_migration_pg/connection.yml points to the same PostgreSQL database as the selected integration DB; the final bootstrap step will rebuild $(PORMG_DB_FOLDER) as a fallback." db=PORMG_DB_FOLDER edge_db=edge_db_name
    end

    # Reset the public schema to start clean
    try; PormG.Configuration.close_pool!(joinpath(@__DIR__, edge_db_name)); catch; end
    delete!(PormG.config, joinpath(@__DIR__, edge_db_name))

    PormG.Configuration.load(joinpath(@__DIR__, edge_db_name))
    pg_edge_settings = PormG.Configuration.get_settings(joinpath(@__DIR__, edge_db_name))
    _reset_postgres!(pg_edge_settings.connections)
    PormG.Configuration.close_pool!(joinpath(@__DIR__, edge_db_name))
    delete!(PormG.config, joinpath(@__DIR__, edge_db_name))

    # Clean up any leftover migration artifacts
    mig_dir = joinpath(@__DIR__, edge_db_name, "migrations")
    ispath(mig_dir) && rm(mig_dir, recursive=true)
  end

  PormG.Configuration.load(joinpath(@__DIR__, edge_db_name))
  edge_settings = PormG.Configuration.get_settings(joinpath(@__DIR__, edge_db_name))
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
  @testset "Phase 13: Repair Operations" begin
    Migrations.mark_applied(pool, edge_settings, "99990101000001", "manual_test_migration")
    st = Migrations.status(pool, edge_settings)
    @test "99990101000001" in [m[:version] for m in st.applied]

    Migrations.mark_failed(pool, edge_settings, "99990101000001")
    st2 = Migrations.status(pool, edge_settings)
    @test "99990101000001" in [m[:version] for m in st2.failed]

    Migrations.remove_migration_record(pool, edge_settings, "99990101000001")
    st3 = Migrations.status(pool, edge_settings)
    all_versions = vcat([m[:version] for m in st3.applied], [m[:version] for m in st3.failed])
    @test !("99990101000001" in all_versions)
  end

  # ── Cleanup ─────────────────────────────────────────────────────────
  PormG.Configuration.close_pool!(joinpath(@__DIR__, edge_db_name))
  delete!(PormG.config, joinpath(@__DIR__, edge_db_name))
  if adapter_name == "SQLite"
    # SQLite: remove the entire disposable folder
    ispath(joinpath(@__DIR__, edge_db_name)) && rm(joinpath(@__DIR__, edge_db_name), recursive=true)
  else
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

