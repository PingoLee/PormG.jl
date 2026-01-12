module AdvisoryLock

using Logging
import LibPQ

import PormG
import PormG: SQLConn, PormGPostgres, PormGSQLite
import PormG.Configuration: acquire_connection, release_connection, reconnect_db, is_connection_error

import Infiltrator: @infiltrate
export with_advisory_lock


const ADVISORY_KEY_EXPR = "(( 'x' || substr(md5(\$1), 1, 16))::bit(64))::bigint"
const TRY_SQL = "SELECT pg_try_advisory_lock($(ADVISORY_KEY_EXPR)) AS ok"
# Workaround for pg_advisory_lock returning void: select true from the void function call
const BLOCK_SQL = "SELECT true AS ok FROM (SELECT pg_advisory_lock($(ADVISORY_KEY_EXPR))) AS _"
const UNLOCK_SQL = "SELECT pg_advisory_unlock($(ADVISORY_KEY_EXPR)) AS ok"

"""
Execute a lock/unlock query on a held connection and return boolean result.
"""
function _exec_lock_query(conn::LibPQ.Connection, sql::String, key::AbstractString)::Bool
  # async_execute yields to the scheduler, allowing other Tasks to run
  async_res = LibPQ.async_execute(conn, sql, Any[key])
  
  # CORREÇÃO: fetch() espera a task terminar e retorna o LibPQ.Result
  res = fetch(async_res)
  
  rows = collect(res)
  return !isempty(rows) && rows[1][1] == true
end

"""
with_advisory_lock(f::Function, pool::PormGPostgres, key::AbstractString; ...)
...
"""
function with_advisory_lock(f::Function, pool::PormGPostgres, key::AbstractString; 
                            wait::Bool = false, 
                            timeout_ms::Int = 5_000, 
                            interval_ms::Int = 100, 
                            strategy::Symbol = :poll)
  conn = acquire_connection(pool)
  got_lock = false
  old_timeout = nothing
  
  try
    # Attempt to acquire lock
    if !wait
      # Non-blocking: single try
      got_lock = _exec_lock_query(conn, TRY_SQL, key)
    elseif strategy == :block
      # Server-side blocking with timeout
      try
        prev = LibPQ.execute(conn, "SHOW statement_timeout")
        rows = collect(prev)
        !isempty(rows) && (old_timeout = rows[1][1])
      catch
        old_timeout = nothing
      end
      
      # CORREÇÃO: fetch() ao invés de collect() para comandos sem retorno de linhas
      async_res = LibPQ.async_execute(conn, "SET statement_timeout = $(timeout_ms)")
      fetch(async_res) 
      
      try
        got_lock = _exec_lock_query(conn, BLOCK_SQL, key)
      catch e
        msg = lowercase(string(e))
        if occursin("canceling statement due to statement timeout", msg)
          @warn "Advisory lock timed out on server-side statement_timeout" key=key timeout_ms=timeout_ms
          got_lock = false
        else
          throw(e)
        end
      end
    else # :poll
      # Client-side polling with retry
      deadline = time() * 1_000 + timeout_ms
      while true
        got_lock = _exec_lock_query(conn, TRY_SQL, key)
        got_lock && break
        (time() * 1_000) >= deadline && break
        sleep(interval_ms / 1_000)
      end
    end
    
    if !got_lock
      throw(ErrorException("Failed to acquire advisory lock for '$key'"))
    end
    
    # Execute user function while holding lock
    return f()
    
  finally
    # Release lock if acquired (on same connection)
    if got_lock
      try
        _exec_lock_query(conn, UNLOCK_SQL, key)
      catch e
        @warn "Failed to release advisory lock; connection may have been dropped" key=key exception=(e, catch_backtrace())
      end
    end
    
    # Restore statement_timeout if we changed it
    if old_timeout !== nothing
      try
        # wait() é suficiente para AsyncResult quando não precisamos do output
        wait(LibPQ.async_execute(conn, "SET statement_timeout = '$(old_timeout)'"))
      catch
      end
    elseif strategy == :block
      try
        wait(LibPQ.async_execute(conn, "SET statement_timeout TO DEFAULT"))
      catch
      end
    end
    
    # Safely reset connection state before returning to pool.
    try
      wait(LibPQ.async_execute(conn, "ROLLBACK"))
    catch
      # Already outside transaction or connection error; that's OK.
    end
    
    # Return connection to pool
    release_connection(pool, conn)
  end
end

# Convenience wrappers for Settings/SQLConn objects
with_advisory_lock(f::Function, settings::SQLConn, key::AbstractString; kwargs...) =
  with_advisory_lock(f, settings.connections, key; kwargs...)

# SQLite no-op (advisory locks not supported)
with_advisory_lock(f::Function, conn::PormGSQLite, key::AbstractString; kwargs...) = f()

# Wrapper to use by database name string
function with_advisory_lock(f::Function, db::String, key::AbstractString; kwargs...)
  @infiltrate false
  haskey(PormG.config, db) || throw(ErrorException("Database '$db' not found in configuration"))
  settings = PormG.config[db]
  return with_advisory_lock(f, settings, key; kwargs...)
end

end # module