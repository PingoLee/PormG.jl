if !isdefined(Main, :PormG)
  include("common_setup.jl")
end

import PormG.Migrations
import PormG.Migrations: init_migrations, makemigrations, migrate, status
import PormG.Migrations: MigrationStatus

"""
    reset_database!(settings)

Destructive reset of the selected integration database.
- SQLite: drops every user table (from sqlite_master).
- PostgreSQL: drops and recreates the public schema.

After calling this, the database is completely empty — no user tables,
no pormg_migrations history.
"""
function reset_database!(settings::PormG.SQLConn)
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
    PormG.ConnectionPool.fetch(pool, "PRAGMA foreign_keys = OFF;")
    for tbl in df.name
      PormG.ConnectionPool.fetch(pool, "DROP TABLE IF EXISTS \"$(tbl)\";")
    end
    PormG.ConnectionPool.fetch(pool, "PRAGMA foreign_keys = ON;")
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
"""
function assert_clean_state()
  settings = PormG.config[PORMG_DB_FOLDER]
  st = status(settings.connections, settings)
  @assert st.has_history_table "Expected pormg_migrations table after bootstrap"
  @assert isempty(st.failed)   "Expected no failed migrations after bootstrap"
  @assert !st.pending          "Expected no pending migration file after bootstrap"
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