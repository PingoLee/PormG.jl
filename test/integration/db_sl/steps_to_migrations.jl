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

@info "Loading configuration from $DB_KEY..."
PormG.Configuration.load(DB_KEY)

# 2. Makemigrations
# This generates a 'migrations/pending_migrations.jl' file 
# by comparing the current 'models.jl' with the 'f1.sqlite' schema.
# If the database file doesn't exist, it will be created.
@info "Step 1: Generating migration plan (makemigrations)..."
if !isfile(joinpath(DB_KEY, "f1.sqlite"))
    @info "Database file f1.sqlite does not exist. It will be created during migration."
end
PormG.Migrations.makemigrations(DB_KEY)

# 3. Migrate
# This applies the 'pending_migrations.jl' to the database.
# WARNING: This step is interactive and will ask for 'yes' in the terminal.
@info "Step 2: Applying migrations (migrate)..."
@info "Wait for the prompt and type 'yes' to proceed."

try
    PormG.Migrations.migrate(DB_KEY)
    @info "Migration process finished."
catch e
    @error "Error during migration" exception=e
end

# 4. Verify (Optional)
# You can now use the models to query the database.
# PormG.@import_models "test/integration/db_sl/models.jl" SL_Models
# ...
