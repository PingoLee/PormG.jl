# ==============================================================================
# PormG PostgreSQL Migration Debug Script
# ==============================================================================
# This script demonstrates the migration workflow for PostgreSQL.
# It uses the models defined in test/integration/db_2/models.jl
# and the configuration in test/integration/db_2/connection.yml.
# ==============================================================================

using Pkg
Pkg.activate(".")

using PormG
using PormG.Migrations

# 1. Setup the environment
# We point to the folder containing the PostgreSQL connection.yml.
# db_2 is the PostgreSQL integration environment used by the migration tests.
# The connection.yml is expected to exist already because PostgreSQL requires
# host/user/password/database details that should be reviewed explicitly.
DB_KEY = "test/integration/db_2"

# These flags make the script easier to use during debugging.
# - INTERACTIVE_MIGRATE=true will ask for confirmation in the terminal.
# - ALLOW_DESTRUCTIVE=false keeps DROP-like operations blocked by default.
#   Flip it to true only after reviewing the dry-run output carefully.
INTERACTIVE_MIGRATE = true
ALLOW_DESTRUCTIVE = false

# PostgreSQL debug scripts should use the committed connection.yml instead of
# auto-generating one. That keeps the host/database settings explicit.
conn_yml = joinpath(DB_KEY, "connection.yml")
if !isfile(conn_yml)
    error("Missing PostgreSQL connection file at $(conn_yml). Create test/integration/db_2/connection.yml before running this script.")
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
# This generates a 'migrations/pending_migrations.jl' file by comparing the
# current 'models.jl' with the live PostgreSQL schema.
@info "Step 1: Generating migration plan (makemigrations)..."
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
# This applies the 'pending_migrations.jl' to the PostgreSQL database.
# PostgreSQL-specific notes:
# - tables/indexes/constraints are introspected from the live server,
# - destructive SQL is still blocked unless destructive=true,
# - the migration history is recorded in pormg_migrations.
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
# You can now use the PostgreSQL-backed models to query the database.
# PormG.@import_models "test/integration/db_2/models.jl" PG_Models
# ...

# Notes for future migration features:
# - `migrate_to(version)` is not implemented for the current single
#   pending_migrations.jl workflow, so this script intentionally does not call it.
# - For manual intervention workflows, also see:
#   PormG.Migrations.mark_applied(...)
#   PormG.Migrations.mark_failed(...)
#   PormG.Migrations.remove_migration_record(...)
