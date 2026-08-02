# ==============================================================================
# PormG MIGRATIONS MODULE
# Developed for PormG.jl ORM (Julia)
# This module handles database schema introspection, migration planning,
# and execution (makemigrations & migrate).
# ==============================================================================

module Migrations

using DataFrames
using CSV
using Dates
using JSON
import OrderedCollections: OrderedDict
import Random: randstring
import SHA
import PormG.ConnectionPool: fetch, with_transaction, with_sqlite_write_lock, finalize_transaction_connection!
# #276: the SQLite lifecycle acquires its connection explicitly so it can suspend FK enforcement
# before BEGIN, and asserts the suspension took. Both must be on this list — an export from
# ConnectionPool alone is an UndefVarError here, and only the migration path would hit it.
import PormG.ConnectionPool: acquire_connection, _assert_foreign_keys_suspended
import PormG.Configuration
import PormG.Configuration: get_settings
using Logging

import PormG: @pormg_debug
import PormG: _emsg  # shared TTY-aware error/log-message strip helper (Kernel)
import PormG: PormGError, MigrationError, InvalidMigrationError  # semantic error taxonomy (#239); defined in Kernel
# importers.jl reports a wrong-backend connection with the precise type rather than folding it
# into MigrationError — an unknown key already fails earlier as InvalidConfigurationError.
import PormG: BackendCapabilityError
# MissingConfigurationError lives in Configuration (its umbrella ConfigurationError is in Kernel);
# it is NOT a PormG-level binding, so it must be imported from the owning module.
import PormG.Configuration: MissingConfigurationError

import PormG: Models, Migration, Dialect
import PormG.Models: format_model_name
import PormG: connection, config, get_constraints_pk, get_constraints_unique, get_constraints_check
import PormG: PormGModel, PormGField, PormGSettings, PormGBackend, PormGPostgres, PormGSQLite
import PormG: sqlite_type_map, postgres_type_map, sqlite_ignore_schema, postgres_ignore_table, _EXTRA_IGNORE_TABLES
import PormG: MODEL_PATH, PormGSettings, DB_PATH
import PormG.AdvisoryLock

import PormG.Generator: generate_models_from_db, generate_migration_plan

# Include submodules logic
include("migrations/introspection.jl")
include("migrations/importers.jl")
include("migrations/planner.jl")
include("migrations/runner.jl")

# Exports — existing
export makemigrations, migrate
export import_models_from_postgres, import_models_from_sqlite, import_models_from_django
export django_to_string
export convertSQLToModel, convert_schema_to_models
export get_migration_plan

# NOT exported, on purpose (#274) — schema-introspection and module-scanning plumbing whose only
# callers live inside src/migrations/. They were exported by accident, which made them read as
# public API and put them on the docstring-coverage guard for a surface nobody consumes. Reach
# them qualified (`PormG.Migrations.get_database_schema(...)`) if you are extending PormG itself:
#
#   get_database_schema, get_all_models, get_all_dicts,
#   get_constraints_fk, get_constraints_index, get_sequence_name
#
# get_constraints_pk / get_constraints_unique / get_constraints_check are NOT re-exported here
# either — they are Kernel generics (Kernel.jl) that Kernel already exports, so `PormG.get_*`
# keeps resolving; re-exporting them from Migrations only duplicated the name.

# Exports — new migration lifecycle APIs (Phases 1–7)
export init_migrations, status, dry_run
export migrate_to, mark_applied, mark_failed, remove_migration_record, discard_pending_migration
export MigrationStatus, DryRunResult

# `public` (Julia 1.11+) — user-facing but not exported (#289). `docs/src/migrations/stability.md`
# tells users to read `PormG.Migrations.MIGRATION_FORMAT_VERSION` to check plan compatibility.
# Required for it to survive `Private = false`; see the note in QueryBuilder.jl. Note this is a
# `const`, so `api.md`'s `@autodocs` `Order` must also include `:constant` or it is filtered out
# of the page while `checkdocs` still demands it.
public MIGRATION_FORMAT_VERSION
export compute_checksum, is_destructive, total_statements, detect_destructive_actions
export DestructiveMigrationError

end # module Migrations
