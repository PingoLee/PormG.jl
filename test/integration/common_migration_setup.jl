if !isdefined(Main, :PormG)
  include("common_setup.jl")
end

import PormG.Migrations
import PormG.Migrations: init_migrations, makemigrations, migrate, status
import PormG.Migrations: MigrationStatus
import YAML

"""
    reset_database!(settings)

Destructive reset of the selected integration database.
- SQLite: drops every user table (from sqlite_master).
- PostgreSQL: drops and recreates the public schema.

After calling this, the database is completely empty — no user tables,
no pormg_migrations history.
"""
function reset_database!(settings::PormG.PormGSettings)
  conn_pool = settings.connections
  if conn_pool isa PormG.PormGSQLite
    _reset_sqlite!(conn_pool)
  elseif conn_pool isa PormG.PormGPostgres
    _reset_postgres!(conn_pool)
  else
    error("Unsupported adapter for reset_database!: $(typeof(conn_pool))")
  end
  nothing
end

function _reset_sqlite!(pool::PormG.PormGSQLite)
  rows = PormG.ConnectionPool.fetch(pool,
    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
  df = DataFrame(rows)
  if nrow(df) > 0
    # #276: dropping tables in `sqlite_master` order means dropping parents before children, which
    # enforcement refuses (or, for a CASCADE child, silently empties). Suspend it for the block.
    #
    # This used to bracket the loop with two bare `fetch(pool, "PRAGMA …")` calls — which never
    # worked: every `fetch` acquires its OWN pooled connection, `PRAGMA foreign_keys` is
    # per-connection, and `_sqlite_is_read_query` even classifies PRAGMA as a *read*, so under
    # split_read_write it routed to a reader while the DROPs went to the writer. The trailing
    # `= ON` then stuck permanently on whichever slot ran it. Inert while enforcement was off
    # everywhere; a live corruption of pool state the moment it is not. `without_foreign_keys`
    # pins one connection for the whole block and renews it afterwards.
    #
    # check_on_exit = false: we are deleting every table, so a mid-teardown FK check is meaningless.
    PormG.without_foreign_keys(pool; check_on_exit = false) do
      for tbl in df.name
        PormG.ConnectionPool.fetch(pool, "DROP TABLE IF EXISTS \"$(tbl)\";")
      end
    end
  end
end

function _reset_postgres!(pool::PormG.PormGPostgres)
  # Drop all user tables in the public schema individually (with CASCADE)
  # instead of DROP SCHEMA public CASCADE, which requires schema ownership.
  rows = PormG.ConnectionPool.fetch(pool,
    "SELECT tablename FROM pg_tables WHERE schemaname = 'public';")
  df = DataFrame(rows)
  if nrow(df) > 0
    for tbl in df.tablename
      PormG.ConnectionPool.fetch(pool, "DROP TABLE IF EXISTS \"$tbl\" CASCADE;")
    end
  end
end

"""
    ensure_postgres_test_config!(edge_db_path::String) -> Bool

Ensure the PostgreSQL edge-case migration fixture folder contains a
`connection.yml`. Returns `true` when the fixture had to be created on demand.
"""
function ensure_postgres_test_config!(edge_db_path::String)::Bool
  config_path = joinpath(edge_db_path, "connection.yml")
  if isdir(edge_db_path) && isfile(config_path)
    return false
  end

  PormG.Generator.create_db_folder_and_yml(path=edge_db_path, adapter="PostgreSQL")
  return true
end

"""
    hydrate_postgres_settings!(edge_settings, source_settings, folder::String)

Fill blank connection values (host/username/password/etc.) on an already-loaded edge-case
`Settings` from the currently selected integration DB — entirely IN-MEMORY, then rebuild the
connection pool. The committed `connection.yml` is never rewritten, so no credentials ever land
in git (issue #36).

Why rebuild the pool: `Configuration.load` builds the pool eagerly, freezing host/user/pass into
`pool.connection_string`, so mutating `db_config_settings` after load has no effect until the pool
is rebuilt via `_build_connection_pool!`.

`database` is preserved (non-blank in the committed fixture → the loop below skips it), which is
exactly what keeps the edge DB isolated from the selected integration DB.
"""
function hydrate_postgres_settings!(edge_settings::PormG.PormGSettings,
                                    source_settings::PormG.PormGSettings, folder::String)
  edge_cfg = edge_settings.db_config_settings
  source_cfg = source_settings.db_config_settings

  changed = false
  for key in ("database", "host", "username", "password", "port", "url")
    current_value = get(edge_cfg, key, nothing)
    source_value = get(source_cfg, key, nothing)
    if (current_value === nothing || isempty(strip(string(current_value)))) &&
       !(source_value === nothing || isempty(strip(string(source_value))))
      edge_cfg[key] = source_value
      changed = true
    end
  end

  if changed
    # The pool built at load time used the blank credentials but was never dialed (connections
    # open lazily on first fetch); close it and rebuild from the hydrated dict.
    try; PormG.Configuration.close_pool!(folder); catch; end
    PormG.Configuration._build_connection_pool!(edge_settings, folder)
  end

  return nothing
end

# ── Auto-provisioning of the disposable PostgreSQL DB (Django/Rails/Prisma style) ──────────────
# The edge-case suite creates its dedicated throwaway DB if absent and drops it at teardown, so
# there is no manual pre-create step. The connecting role needs the CREATEDB privilege.

# The disposable DB name must be a validated, hardcoded identifier: DDL cannot bind identifiers,
# so CREATE/DROP DATABASE must interpolate it — this allowlist makes that injection-safe. (Same
# principle as _reset_postgres! interpolating pg_tables names into `DROP TABLE "$tbl"` above.)
_is_safe_pg_ident(name::AbstractString) = occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", name)

# Build an ad-hoc pool to the `postgres` maintenance DB using the (already-hydrated) host/port/
# user/password from the edge settings, so we can CREATE/DROP the disposable DB from outside it.
function _maintenance_pool(edge_settings::PormG.PormGSettings)
  cfg = copy(edge_settings.db_config_settings)
  cfg["database"] = "postgres"     # connect to the always-present maintenance DB
  delete!(cfg, "url")              # force param-based DNS so the `database` override takes effect
  maint = PormG.Configuration.Settings(app_env = edge_settings.app_env,
                                       db_config_settings = cfg)
  PormG.Configuration._build_connection_pool!(maint, "db_test_migration_pg::maint")
  return maint
end

"""
    ensure_postgres_database!(edge_settings, dbname::String)

Create the disposable `dbname` database if it does not already exist, connecting to the `postgres`
maintenance DB with the hydrated edge credentials. No-op when the DB is already present.
"""
function ensure_postgres_database!(edge_settings::PormG.PormGSettings, dbname::String)
  _is_safe_pg_ident(dbname) || error("Refusing unsafe database identifier: $(repr(dbname))")
  maint = _maintenance_pool(edge_settings)
  try
    # The lookup VALUE is bindable, so parameterize it ($1). Only the CREATE identifier below must
    # be interpolated (validated + quoted) — DDL cannot bind identifiers.
    lookup = PormG.QueryBuilder.PgParameterizedQuery("", Any[], 0)
    placeholder = PormG.QueryBuilder.add_parameter!(lookup, dbname)
    rows = PormG.ConnectionPool.fetch(maint.connections,
      "SELECT 1 AS present FROM pg_database WHERE datname = $(placeholder);"; params=lookup)
    if nrow(DataFrame(rows)) == 0
      PormG.ConnectionPool.fetch(maint.connections, "CREATE DATABASE \"$(dbname)\";")  # not txn-able
    end
  finally
    try; PormG.Configuration.close_pool!(maint.connections); catch; end
  end
  return nothing
end

"""
    drop_postgres_database!(edge_settings, dbname::String)

Best-effort drop of the disposable `dbname` database at teardown (`WITH (FORCE)` terminates any
straggler connections; requires PostgreSQL 13+). Failure only warns — the next run re-creates it.
Close the edge pool for `dbname` before calling this.
"""
function drop_postgres_database!(edge_settings::PormG.PormGSettings, dbname::String)
  _is_safe_pg_ident(dbname) || return nothing
  maint = _maintenance_pool(edge_settings)
  try
    PormG.ConnectionPool.fetch(maint.connections, "DROP DATABASE IF EXISTS \"$(dbname)\" WITH (FORCE);")
  catch e
    # Log a scrubbed message only — attaching the raw exception could echo the maintenance DSN
    # (which carries the password) if the failure happens at connection time.
    @warn "best-effort drop of disposable migration DB failed" db=dbname reason=sprint(showerror, e)
  finally
    try; PormG.Configuration.close_pool!(maint.connections); catch; end
  end
  return nothing
end

"""
    reload_config_and_models!()

Full cleanup → reload cycle for the selected integration database.
Call this after any destructive reset or migration that changes schema:
1. Close existing connection pool for PORMG_DB_FOLDER
2. Re-run Configuration.load to create fresh pool
3. Re-register models so M.*.objects point at the rebuilt schema

Returns the settings for the reloaded DB.
"""
function reload_config_and_models!()
  try
    PormG.Configuration.close_pool!(PORMG_DB_FOLDER)
  catch e
    @debug "close_pool! during reload" exception=e
  end

  delete!(PormG.config, PORMG_DB_FOLDER)
  PormG.Configuration.load(PORMG_DB_FOLDER)

  models_dir = joinpath(@__DIR__, PORMG_DB_FOLDER)
  Models.set_models(models, models_dir)

  return PormG.config[PORMG_DB_FOLDER]
end

"""
    assert_clean_state()

Smoke test: verifies the imported M module can reach the rebuilt schema.
Call after reload_config_and_models!() and before fixture seeding.

Also asserts the schema has **no drift**: every declared model compares equal to its own live
table. That half was impossible until #325 — introspection lost each field's type, `max_length`
and `db_index`, so `makemigrations` proposed the same no-op alteration forever and no point in the
suite could be asserted schema-clean. Note that `st.pending` alone would NOT have caught it: it
only tests whether a `pending_migrations.jl` file exists on disk, so it reports whatever some
earlier call happened to leave behind and never re-diffs anything.
"""
function assert_clean_state()
  settings = PormG.config[PORMG_DB_FOLDER]
  st = status(settings.connections, settings)
  @assert st.has_history_table "Expected pormg_migrations table after bootstrap"
  @assert isempty(st.failed)   "Expected no failed migrations after bootstrap"
  @assert !st.pending          "Expected no pending migration file after bootstrap"
  assert_no_schema_drift()
  nothing
end

"""
    assert_no_schema_drift()

Re-diff the LIVE schema against the DECLARED models and assert the plan is empty (#325).

In memory on purpose: `get_migration_plan` writes no `pending_migrations.jl`, so calling this
never disturbs the `st.pending` check above or a later `makemigrations`. The failure message names
every model that drifted and the plan steps proposed for it, because "the schema drifted" on its
own is not enough to act on.

This is the GLOBAL assertion #318 wanted and could not have: it was blocked on the type/length
round-trip, which is why `test/integration/test_db_table_db.jl` carried a per-table workaround
until #325 landed.
"""
function assert_no_schema_drift()
  settings = PormG.config[PORMG_DB_FOLDER]
  conn = settings.connections
  live = PormG.Migrations.convert_schema_to_models(conn)
  declared = PormG.Migrations.get_all_models(models)
  plan = PormG.Migrations.get_migration_plan(live, declared, conn, settings; interactive = false)
  if !isempty(plan)
    lines = String[]
    for (name, steps) in plan
      push!(lines, string(name, ": ", join(collect(keys(steps)), "; ")))
    end
    error("Schema drift after bootstrap — makemigrations would propose:\n  " * join(lines, "\n  "))
  end
  nothing
end

# ==============================================================================
# Adapter-Neutral Introspection Helpers
#
# These functions abstract away SQLite-specific PRAGMA / SQLite.jl calls and
# PostgreSQL information_schema queries so that migration edge-case tests
# (Phase C) can run against both adapters with the same assertion code.
# ==============================================================================

"""
    table_exists(pool, table_name::String) → Bool

Check whether `table_name` exists in the database.
"""
function table_exists(pool::PormG.PormGSQLite, table_name::String)::Bool
  conn = PormG.ConnectionPool.acquire_connection(pool)
  try
    tables = SQLite.tables(conn) |> DataFrame
    return table_name in tables.name
  finally
    PormG.ConnectionPool.release_connection(pool, conn)
  end
end

function table_exists(pool::PormG.PormGPostgres, table_name::String)::Bool
  rows = PormG.ConnectionPool.fetch(pool,
    "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '$table_name');")
  df = DataFrame(rows)
  return nrow(df) > 0 && df[1, 1] == true
end

"""
    column_names(pool, table_name::String) → Vector{String}

Return the list of column names for `table_name`.
"""
function column_names(pool::PormG.PormGSQLite, table_name::String)::Vector{String}
  conn = PormG.ConnectionPool.acquire_connection(pool)
  try
    columns = SQLite.columns(conn, table_name) |> DataFrame
    return String.(columns.name)
  finally
    PormG.ConnectionPool.release_connection(pool, conn)
  end
end

function column_names(pool::PormG.PormGPostgres, table_name::String)::Vector{String}
  rows = PormG.ConnectionPool.fetch(pool,
    "SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '$table_name' ORDER BY ordinal_position;")
  df = DataFrame(rows)
  return nrow(df) > 0 ? String.(df[!, 1]) : String[]
end

"""
    column_nullable(pool, table_name::String, col_name::String) → Bool

Return `true` if the column allows NULL values.
"""
function column_nullable(pool::PormG.PormGSQLite, table_name::String, col_name::String)::Bool
  conn = PormG.ConnectionPool.acquire_connection(pool)
  try
    columns = SQLite.columns(conn, table_name) |> DataFrame
    row = filter(r -> r.name == col_name, columns)
    isempty(row) && error("Column '$col_name' not found in '$table_name'")
    # SQLite: notnull=0 means NULL is allowed
    return row[1, :notnull] == 0
  finally
    PormG.ConnectionPool.release_connection(pool, conn)
  end
end

function column_nullable(pool::PormG.PormGPostgres, table_name::String, col_name::String)::Bool
  rows = PormG.ConnectionPool.fetch(pool,
    "SELECT is_nullable FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '$table_name' AND column_name = '$col_name';")
  df = DataFrame(rows)
  isempty(df) && error("Column '$col_name' not found in '$table_name'")
  return df[1, 1] == "YES"
end

"""
    column_has_nonneg_check(pool, table_name::String, col_name::String) → Bool

Return `true` if the column is guarded by a non-negative (`>= 0`) CHECK constraint.
Used to assert PositiveSmallIntegerField's CHECK is added/dropped as a column's type
transitions into or out of the field across migrations.
"""
function column_has_nonneg_check(pool::PormG.PormGSQLite, table_name::String, col_name::String)::Bool
  # SQLite keeps the full CREATE TABLE text in sqlite_master; the CHECK is re-derived
  # on every table recreation, so a substring match on the stored DDL is sufficient.
  rows = PormG.ConnectionPool.fetch(pool,
    "SELECT sql FROM sqlite_master WHERE type='table' AND name='$table_name';") |> DataFrame
  isempty(rows) && return false
  ddl = rows[1, 1]
  return ddl !== missing && occursin("CHECK (\"$col_name\" >= 0)", ddl)
end

function column_has_nonneg_check(pool::PormG.PormGPostgres, table_name::String, col_name::String)::Bool
  # Reuse the production introspection path so the test exercises the same query the
  # migration engine uses to locate the constraint for dropping it.
  return PormG.get_constraints_check(pool, table_name, col_name) !== nothing
end

"""
    index_names(pool, table_name::String) → Vector{String}

Return the names of all indexes on `table_name`.
"""
function index_names(pool::PormG.PormGSQLite, table_name::String)::Vector{String}
  conn = PormG.ConnectionPool.acquire_connection(pool)
  try
    indices = PormG.ConnectionPool.fetch(pool, "PRAGMA index_list('$table_name')", conn=conn) |> DataFrame
    return nrow(indices) > 0 ? String.(indices[!, :name]) : String[]
  finally
    PormG.ConnectionPool.release_connection(pool, conn)
  end
end

function index_names(pool::PormG.PormGPostgres, table_name::String)::Vector{String}
  rows = PormG.ConnectionPool.fetch(pool,
    "SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND tablename = '$table_name';")
  df = DataFrame(rows)
  return nrow(df) > 0 ? String.(df[!, 1]) : String[]
end

"""
    foreign_key_count(pool, table_name::String) → Int

Return the number of FOREIGN KEY constraints on `table_name`. Used to assert that a migration
removed an FK (#83): after the constraint is dropped the count must be 0.
"""
function foreign_key_count(pool::PormG.PormGSQLite, table_name::String)::Int
  conn = PormG.ConnectionPool.acquire_connection(pool)
  try
    # PRAGMA foreign_key_list returns one row per (constraint, column) pair; distinct `id` = distinct FK.
    fks = PormG.ConnectionPool.fetch(pool, "PRAGMA foreign_key_list('$table_name')", conn=conn) |> DataFrame
    return nrow(fks) == 0 ? 0 : length(unique(fks[!, :id]))
  finally
    PormG.ConnectionPool.release_connection(pool, conn)
  end
end

function foreign_key_count(pool::PormG.PormGPostgres, table_name::String)::Int
  rows = PormG.ConnectionPool.fetch(pool,
    "SELECT count(*) FROM information_schema.table_constraints WHERE table_schema = 'public' AND table_name = '$table_name' AND constraint_type = 'FOREIGN KEY';")
  df = DataFrame(rows)
  return nrow(df) > 0 ? Int(df[1, 1]) : 0
end

"""
    all_table_names(pool) → Vector{String}

Return the names of all user tables in the database.
"""
function all_table_names(pool::PormG.PormGSQLite)::Vector{String}
  conn = PormG.ConnectionPool.acquire_connection(pool)
  try
    tables = SQLite.tables(conn) |> DataFrame
    return String.(tables.name)
  finally
    PormG.ConnectionPool.release_connection(pool, conn)
  end
end

function all_table_names(pool::PormG.PormGPostgres)::Vector{String}
  rows = PormG.ConnectionPool.fetch(pool,
    "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY table_name;")
  df = DataFrame(rows)
  return nrow(df) > 0 ? String.(df[!, 1]) : String[]
end