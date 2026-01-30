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
  
  # FIX: fetch() waits for the task to complete and returns the LibPQ.Result
  res = fetch(async_res)
  
  rows = collect(res)
  return !isempty(rows) && rows[1][1] == true
end

"""
    with_advisory_lock(f::Function, pool::PormGPostgres, key::AbstractString; wait::Bool=false, timeout_ms::Int=5_000, strategy::Symbol=:poll)

Execute a function `f` while holding a PostgreSQL session-level advisory lock identified by `key`.

Advisory locks are an application-level locking mechanism provided by PostgreSQL. They are useful for ensuring exclusivity for tasks that don't map directly to a database row, such as synchronizing external API calls or preventing concurrent expensive calculations.

# Arguments
- `f::Function`: The function to execute while holding the lock.
- `pool::PormGPostgres`: The PostgreSQL connection pool.
- `key::AbstractString`: A unique string identifying the lock. It will be hashed to a 64-bit integer.

# Keywords
- `wait::Bool=false`: If `true`, the function will wait until the lock becomes available or the timeout is reached. If `false`, it throws an error immediately if the lock is already held.
- `timeout_ms::Int=5_000`: Maximum time to wait for the lock (in milliseconds).
- `strategy::Symbol=:poll`: The waiting strategy:
    - `:poll`: (Default) Periodically retries lock acquisition from the Julia client. Safe and recommended for most cases.
    - `:block`: Uses PostgreSQL's server-side blocking mechanism. Efficient but holds a connection and uses `statement_timeout`.
- `interval_ms::Int=100`: Retry interval for the `:poll` strategy.

# Examples
```julia
# Lock around a critical update for a specific constructor
PormG.with_advisory_lock(M.Constructor.objects.object.model.connect_key, "update_constructor_1") do
    # This block is protected by the lock "update_constructor_1"
    # Perform complex logic here...
    @info "Exclusive access granted"
end
```
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
      
      # FIX: use fetch() instead of collect() for commands without returned rows
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