module AdvisoryLock

using Logging
import LibPQ

import PormG: SQLConn, PormGPostgres, PormGSQLite
import PormG.Configuration: acquire_connection, release_connection, reconnect_db, is_connection_error

# Internal helper to run a boolean-returning query with reconnection handling.
function _exec_bool(pool::PormGPostgres, sql::String, key::AbstractString)
  conn = acquire_connection(pool)
  try
    return _exec_bool_with_conn(pool, conn, sql, key)
  catch e
    if is_connection_error(e, pool)
      @warn "Lost connection while running advisory lock query; reconnecting" key=key
      conn = reconnect_db(pool, conn)
      conn === nothing && throw(e)
      return _exec_bool_with_conn(pool, conn, sql, key)
    end
    @error "Failed to run advisory lock query" key=key exception=(e, catch_backtrace())
    throw(e)
  finally
    release_connection(pool, conn)
  end
end

function _exec_bool_with_conn(::PormGPostgres, conn::LibPQ.Connection, sql::String, key::AbstractString)
  res = LibPQ.execute(conn, sql, Any[key])
  rows = collect(res)
  return !isempty(rows) && rows[1][1] == true
end

# Acquire (non-blocking or timed-wait) advisory lock for PostgreSQL pools.
function try_advisory_lock(pool::PormGPostgres, key::AbstractString; wait::Bool = false, timeout_ms::Int = 5_000, interval_ms::Int = 100)::Bool
  sql = """SELECT pg_try_advisory_lock(hashtext($1)) AS ok"""
  if !wait
    return _exec_bool(pool, sql, key)
  end

  deadline = time() * 1_000 + timeout_ms
  while true
    ok = _exec_bool(pool, sql, key)
    ok && return true
    (time() * 1_000) >= deadline && return false
    sleep(interval_ms / 1_000)
  end
end

# Release advisory lock for PostgreSQL pools.
function release_advisory_lock(pool::PormGPostgres, key::AbstractString)::Bool
  sql = "SELECT pg_advisory_unlock(hashtext($1)) AS ok"
  return _exec_bool(pool, sql, key)
end

# Convenience wrappers for Settings/SQLConn objects.
try_advisory_lock(settings::SQLConn, key::AbstractString; kwargs...) = try_advisory_lock(settings.connections, key; kwargs...)
release_advisory_lock(settings::SQLConn, key::AbstractString) = release_advisory_lock(settings.connections, key)

# SQLite fallback: advisory locks are not available, so we simply warn once.
function try_advisory_lock(::PormGSQLite, key::AbstractString; wait::Bool = false, timeout_ms::Int = 0, interval_ms::Int = 0)::Bool
  @warn "Advisory locks are only supported on PostgreSQL; skipping" key=key
  return true
end
release_advisory_lock(::PormGSQLite, key::AbstractString)::Bool = true

# with_advisory_lock helper to ensure release even on failure.
function with_advisory_lock(f::Function, pool::PormGPostgres, key::AbstractString; wait::Bool = false, timeout_ms::Int = 5_000, interval_ms::Int = 100)
  ok = try_advisory_lock(pool, key; wait=wait, timeout_ms=timeout_ms, interval_ms=interval_ms)
  ok || throw(ErrorException("Failed to acquire advisory lock for '$key'"))
  try
    return f()
  finally
    release_advisory_lock(pool, key)
  end
end

with_advisory_lock(f::Function, settings::SQLConn, key::AbstractString; wait::Bool = false, timeout_ms::Int = 5_000, interval_ms::Int = 100) =
  with_advisory_lock(f, settings.connections, key; wait=wait, timeout_ms=timeout_ms, interval_ms=interval_ms)

with_advisory_lock(f::Function, conn::PormGSQLite, key::AbstractString; wait::Bool = false, timeout_ms::Int = 0, interval_ms::Int = 0) = f()

function with_advisory_lock(db::String, key::AbstractString; wait::Bool = false, timeout_ms::Int = 5_000, interval_ms::Int = 100, f::Function)
  haskey(PormG.config, db) || throw(ErrorException("Database '$db' not found in configuration"))
  settings = PormG.config[db]
  return with_advisory_lock(f, settings.connections, key; wait=wait, timeout_ms=timeout_ms, interval_ms=interval_ms)
end

end # module
