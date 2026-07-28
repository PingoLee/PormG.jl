# ==============================================================================
# PormG SQLite Migration Debug Script
# ==============================================================================
# This script demonstrates the migration workflow for SQLite.
# It uses the models defined in test/integration/db_sl/models.jl
# and the configuration in test/integration/db_sl/connection.yml.
# ==============================================================================

using Pkg
Pkg.activate(".")

using PormG
using PormG.Migrations

# 1. Setup the environment
# We point to the folder containing connection.yml
DB_KEY = "test/integration/db_sl"

# These flags make the script easier to use during debugging.
# - INTERACTIVE_MIGRATE=true will ask for confirmation in the terminal.
# - ALLOW_DESTRUCTIVE=false keeps DROP-like operations blocked by default.
#   Flip it to true only after reviewing the dry-run output carefully.
INTERACTIVE_MIGRATE = true
ALLOW_DESTRUCTIVE = false

# If connection.yml does not exist yet, create it configured for SQLite.
# This is where you choose adapter/database for this debug workflow.
conn_yml = joinpath(DB_KEY, "connection.yml")
if !isfile(conn_yml)
    @info "Creating SQLite connection file at $conn_yml..."
    PormG.Generator.create_db_folder_and_yml(
        path=DB_KEY,
        adapter="SQLite",
        database="f1.sqlite",
        time_zone="America/Sao_Paulo"
    )
end

@info "Loading configuration from $DB_KEY..."
PormG.Configuration.load(DB_KEY)

# 1b. Bootstrap the migration history table and inspect the starting state.
#
# The new migration runner stores applied/failed migrations in the database
# itself via the `pormg_migrations` table. `init_migrations()` is idempotent,
# so it is safe to call every time in a debug script.
@info "Step 0: Bootstrapping migration history table (init_migrations)..."
PormG.Migrations.init_migrations(DB_KEY)

@info "Current migration status before planning:"
println(PormG.Migrations.status(DB_KEY))

# 2. Makemigrations
# This generates a 'migrations/pending_migrations.jl' file 
# by comparing the current 'models.jl' with the 'f1.sqlite' schema.
# If the database file doesn't exist, it will be created.
@info "Step 1: Generating migration plan (makemigrations)..."
if !isfile(joinpath(DB_KEY, "f1.sqlite"))
    @info "Database file f1.sqlite does not exist. It will be created during migration."
end
PormG.Migrations.makemigrations(DB_KEY)

# 2b. Dry-run / plan review
#
# dry_run() is the safest way to understand what the runner is about to do.
# It does NOT modify the database and does NOT archive the pending file.
# Instead, it returns a structured summary with:
# - the generated version id,
# - the checksum of the SQL plan,
# - the ordered SQL statements,
# - whether destructive actions were detected.
@info "Step 1b: Reviewing the generated plan (dry_run)..."
dry_run_result = PormG.Migrations.dry_run(DB_KEY)
println(dry_run_result)

# This explicit branch is intentionally didactic:
# destructive migrations are blocked unless `destructive=true` is passed.
if PormG.Migrations.is_destructive(dry_run_result) && !ALLOW_DESTRUCTIVE
    @warn "The pending migration contains destructive operations and ALLOW_DESTRUCTIVE=false."
    @warn "Review the dry-run output above. If the DROP operations are intentional, set ALLOW_DESTRUCTIVE=true and run again."
end

# 3. Migrate
# This applies the 'pending_migrations.jl' to the database.
# The runner now supports:
# - interactive confirmation,
# - destructive guards,
# - migration history recording,
# - status reporting.
@info "Step 2: Applying migrations (migrate)..."
if INTERACTIVE_MIGRATE
    @info "Wait for the prompt and type 'yes' to proceed."
else
    @info "Running in non-interactive mode."
end

try
    PormG.Migrations.migrate(
        DB_KEY,
        interactive=INTERACTIVE_MIGRATE,
        destructive=ALLOW_DESTRUCTIVE,
    )
    @info "Migration process finished."
catch e
    @error "Error during migration" exception=e
end

# 3b. Inspect the state after apply.
#
# This is useful for checking whether the migration was recorded as applied,
# whether a pending file still exists, and whether any drift/failure signals
# were detected by the status API.
@info "Step 3: Migration status after execution:"
println(PormG.Migrations.status(DB_KEY))

# 4. Verify (Optional)
# You can now use the models to query the database.
# PormG.@import_models "test/integration/db_sl/models.jl" SL_Models
# ...

# Notes for future migration features:
# - `migrate_to(version)` is not implemented for the current single
#   pending_migrations.jl workflow, so this script intentionally does not call it.
# - For manual intervention workflows, also see:
#   PormG.Migrations.mark_applied(...)
#   PormG.Migrations.mark_failed(...)
#   PormG.Migrations.remove_migration_record(...)
