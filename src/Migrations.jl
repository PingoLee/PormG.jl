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
import OrderedCollections: OrderedDict, OrderedSet
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
import PormG: PormGError, MigrationError, InvalidMigrationError, ModelDefinitionError  # semantic error taxonomy (#239); defined in Kernel
# importers.jl reports a wrong-backend connection with the precise type rather than folding it
# into MigrationError — an unknown key already fails earlier as InvalidConfigurationError.
import PormG: BackendCapabilityError
# #472: introspection catches this NARROWLY to drop a column default it cannot represent
# (`_field_or_drop_default`, migrations/introspection.jl). Naming an unimported binding inside a
# `catch` body is not a precompile error — it would surface as an `UndefVarError` raised INSTEAD
# of the original, at the first bad default in a live import.
import PormG: FieldValidationError
# MissingConfigurationError lives in Configuration (its umbrella ConfigurationError is in Kernel);
# it is NOT a PormG-level binding, so it must be imported from the owning module.
import PormG.Configuration: MissingConfigurationError

import PormG: Models, Migration, Dialect
import PormG.Models: format_model_name, model_table_name, fk_target_table
import PormG: connection, config, get_constraints_pk, get_constraints_unique, get_constraints_check, get_constraints_byte_length_check
import PormG: PormGModel, PormGField, PormGSettings, PormGBackend, PormGPostgres, PormGSQLite
# The canonical column IR (#507). The NOUNS live in `Kernel` (`src/column_ir.jl`) because `Dialect`
# renders an ALTER from a `ColumnDelta` and is included before this module; the COMPILER that turns a
# `PormGField` into a `ColumnSpec` is `migrations/column_spec.jl`, here, where `Models` and `Dialect`
# are reachable. `column_delta` is imported rather than merely reachable because the compiler adds
# the `(field, field, conn)` method to it.
import PormG: CanonicalType, CInt16, CInt32, CInt64, CFloat64, CBool, CText, CDate, CTime,
              CInterval, CUUID, CJSON, CBytes, CVarChar, CDecimal, CDateTime, CUnsupported,
              ColumnDefault, NoDefault, LiteralDefault, ExpressionDefault,
              CheckKind, NonNegativeCheck, ByteLengthCheck,
              ColumnIdentity, ForeignKeyRef, ColumnSpec, ColumnDelta,
              reference_delta, column_delta, COLUMN_DELTA_COMPARATORS, COLUMN_DELTA_SLOTS
# The two forward type maps (`sqlite_type_map` / `postgres_type_map`) were imported here until #522
# retired them: the readers compile a catalog type through `parse_canonical_type` now, and nothing
# maps a rendered type back to a field struct any more.
import PormG: sqlite_ignore_schema, postgres_ignore_table, _EXTRA_IGNORE_TABLES
# #522: `convertSQLToModel(::String)` executes its statement in a throwaway SQLite file and reads it
# back through the live reader, so the pool constructor and its close are needed here — and, per the
# #276 note above, must be on an explicit import list to be visible in this module.
import PormG.ConnectionPool: SQLiteConnectionPool, close_pool!
# #522: `_literal_default` folds a `DateTimeField` default to a UTC `ZonedDateTime` on both sides
# of the diff, and the readers coerce a catalog datetime with the same vocabulary.
import TimeZones: ZonedDateTime, TimeZone, astimezone, @tz_str
import PormG: GENERATED_MODULE_RESERVED_BINDINGS
import PormG: MODEL_PATH, PormGSettings, DB_PATH
import PormG.AdvisoryLock

import PormG.Generator: generate_models_from_db, generate_migration_plan

# Include submodules logic
# column_spec.jl first: it defines the canonical column IR the planner's field diff runs on (#507),
# and it depends only on Models/Dialect, both of which PormG has already included by this point.
include("migrations/column_spec.jl")
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
#   get_constraints_fk, get_constraints_index, get_sequence_name,
#   read_live_schema, LiveTable, live_table, model_from_live, field_from_spec  (#522)
#
# get_constraints_pk / get_constraints_unique / get_constraints_check are NOT re-exported here
# either — they are Kernel generics (Kernel.jl) that Kernel already exports, so `PormG.get_*`
# keeps resolving; re-exporting them from Migrations only duplicated the name.

# Exports — new migration lifecycle APIs (Phases 1–7)
export init_migrations, status, dry_run, check
export migrate_to, mark_applied, mark_failed, remove_migration_record, discard_pending_migration
export MigrationStatus, DryRunResult, SchemaCheckResult, SchemaCheckFinding

# `public` (Julia 1.11+) — user-facing but not exported (#289). `docs/src/migrations/stability.md`
# tells users to read `PormG.Migrations.MIGRATION_FORMAT_VERSION` to check plan compatibility.
# Required for it to survive `Private = false`; see the note in QueryBuilder.jl. Note this is a
# `const`, so `api.md`'s `@autodocs` `Order` must also include `:constant` or it is filtered out
# of the page while `checkdocs` still demands it.
public MIGRATION_FORMAT_VERSION
export compute_checksum, is_destructive, total_statements, detect_destructive_actions
export DestructiveMigrationError

end # module Migrations
