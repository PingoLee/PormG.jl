module AdvisoryLock

using Logging

import PormG
import PormG: SQLConn, PormGPostgres, PormGSQLite, backend_execute_async
import PormG.Configuration: get_settings
import PormG.ConnectionPool: acquire_connection, release_connection

import PormG: @pormg_debug
export with_advisory_lock


const ADVISORY_KEY_EXPR = "(( 'x' || substr(md5(\$1), 1, 16))::bit(64))::bigint"
const TRY_SQL = "SELECT pg_try_advisory_lock($(ADVISORY_KEY_EXPR)) AS ok"
# Workaround for pg_advisory_lock returning void: select true from the void function call
const BLOCK_SQL = "SELECT true AS ok FROM (SELECT pg_advisory_lock($(ADVISORY_KEY_EXPR))) AS _"
const UNLOCK_SQL = "SELECT pg_advisory_unlock($(ADVISORY_KEY_EXPR)) AS ok"

"""
Execute a lock/unlock query on a held connection and return boolean result.
"""
function _exec_lock_query(pool::PormGPostgres, conn, sql::String, key::AbstractString)::Bool
  # backend_execute_async yields to the scheduler, allowing other Tasks to run.
  # It runs on the held connection without releasing it back to the pool, so the
  # session-level lock stays bound to this connection.
  async_res = backend_execute_async(pool, conn, sql, Any[key])

  # Base.fetch awaits the LibPQ AsyncResult and returns the driver result.
  # Qualified deliberately: this module imports no `fetch`, so a bare call would
  # resolve to Base only by absence — qualifying keeps it immune to import shadowing.
  res = Base.fetch(async_res)

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
      got_lock = _exec_lock_query(pool, conn, TRY_SQL, key)
    elseif strategy == :block
      # Server-side blocking with timeout
      try
        prev = Base.fetch(backend_execute_async(pool, conn, "SHOW statement_timeout", nothing))
        rows = collect(prev)
        !isempty(rows) && (old_timeout = rows[1][1])
      catch
        old_timeout = nothing
      end

      # use Base.fetch() for commands without returned rows
      Base.fetch(backend_execute_async(pool, conn, "SET statement_timeout = $(timeout_ms)", nothing))
      
      try
        got_lock = _exec_lock_query(pool, conn, BLOCK_SQL, key)
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
        got_lock = _exec_lock_query(pool, conn, TRY_SQL, key)
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
        _exec_lock_query(pool, conn, UNLOCK_SQL, key)
      catch e
        @warn "Failed to release advisory lock; connection may have been dropped" key=key exception=(e, catch_backtrace())
      end
    end
    
    # Restore statement_timeout if we changed it
    if old_timeout !== nothing
      try
        # wait() is enough for the async result when we don't need the output
        wait(backend_execute_async(pool, conn, "SET statement_timeout = '$(old_timeout)'", nothing))
      catch
      end
    elseif strategy == :block
      try
        wait(backend_execute_async(pool, conn, "SET statement_timeout TO DEFAULT", nothing))
      catch
      end
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
  @pormg_debug false
  settings = get_settings(db)
  return with_advisory_lock(f, settings, key; kwargs...)
end

end # module