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
import PormG.ConnectionPool: fetch, with_transaction
import PormG.Configuration
import PormG.Configuration: get_settings
using Logging

import PormG.Infiltrator: @infiltrate

import PormG: Models, Migration, Dialect
import PormG.Models: format_model_name
import PormG: connection, config, get_constraints_pk, get_constraints_unique
import PormG: PormGModel, PormGField, SQLConn, PormGPostgres, PormGSQLite
import PormG: sqlite_type_map, postgres_type_map, sqlite_ignore_schema, postgres_ignore_table
import PormG: MODEL_PATH, SQLConn, DB_PATH

import PormG.Generator: generate_models_from_db, generate_migration_plan

# Include submodules logic
include("migrations/introspection.jl")
include("migrations/importers.jl")
include("migrations/planner.jl")
include("migrations/runner.jl")

# Exports
export makemigrations, migrate
export import_models_from_postgres, import_models_from_sqlite, import_models_from_django
export django_to_string
export convertSQLToModel, convert_schema_to_models, get_database_schema
export get_migration_plan, get_all_models, get_all_dicts
export get_constraints_fk, get_constraints_index, get_constraints_pk, get_constraints_unique, get_sequence_name

end # module Migrations
