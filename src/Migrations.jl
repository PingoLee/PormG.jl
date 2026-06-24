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
using SQLite
using LibPQ
import OrderedCollections: OrderedDict
import Random: randstring
import SHA
import PormG.ConnectionPool: fetch, with_transaction, with_sqlite_write_lock
import PormG.Configuration
import PormG.Configuration: get_settings
using Logging

import PormG: @pormg_debug
import PormG: _emsg  # shared TTY-aware error/log-message strip helper (tools.jl)

import PormG: Models, Migration, Dialect
import PormG.Models: format_model_name
import PormG: connection, config, get_constraints_pk, get_constraints_unique, get_constraints_check
import PormG: PormGModel, PormGField, SQLConn, PormGPostgres, PormGSQLite
import PormG: sqlite_type_map, postgres_type_map, sqlite_ignore_schema, postgres_ignore_table, _EXTRA_IGNORE_TABLES
import PormG: MODEL_PATH, SQLConn, DB_PATH
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
export convertSQLToModel, convert_schema_to_models, get_database_schema
export get_migration_plan, get_all_models, get_all_dicts
export get_constraints_fk, get_constraints_index, get_constraints_pk, get_constraints_unique, get_constraints_check, get_sequence_name

# Exports — new migration lifecycle APIs (Phases 1–7)
export init_migrations, status, dry_run
export migrate_to, mark_applied, mark_failed, remove_migration_record, discard_pending_migration
export MigrationStatus, DryRunResult
export compute_checksum, is_destructive, total_statements, detect_destructive_actions

end # module Migrations
