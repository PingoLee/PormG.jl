module ConnectionPool

import Logging
import PormG: SQLConn, PormGPostgres, PormGPostgresParam, PormGSQLite, config, PormGModel
import PormG.Infiltrator: @infiltrate

import SQLite
import LibPQ

export fetch, fetch_async, await_result, FetchTask, fetch_copy
export with_transaction, with_transaction_async, run_in_transaction
export acquire_connection, release_connection, close_pool!
export is_connection_alive, reconnect_db, is_connection_error
export libpq_execute, libpq_execute_async

# Import transaction context helpers from Configuration
import PormG.Configuration: get_tx_connection, get_tx_pool, with_tx_context, transaction_connection_for

const _REDACT_CONNECTION_STRING_RE = Regex("(?i)(password|user)=[^\\s]+")

"""
    redact_secret(conn_str::String)

Replace sensitive connection string fields such as `password` or `user` with masked values before logging.
"""
function redact_secret(conn_str::String)::String
  return replace(conn_str, _REDACT_CONNECTION_STRING_RE => s"\1=****")
end

#
# Connection Pool Implementation
#

mutable struct PostgresConnectionPool <: PormGPostgres
  connections::Vector{Union{Nothing, LibPQ.Connection}}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock  # For thread safety  
end

mutable struct SQLiteConnectionPool <: PormGSQLite
  connections::Vector{Union{Nothing, SQLite.DB}}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock  # For thread safety
end

function PostgresConnectionPool(connection_string::String; pool_size::Int = 3)
  connections = Vector{Union{Nothing, LibPQ.Connection}}(nothing, pool_size)
  available = fill(true, pool_size) 
  lock = ReentrantLock()
  PostgresConnectionPool(connections, available, connection_string, pool_size, lock)
end

function SQLiteConnectionPool(connection_string::String; pool_size::Int = 3)
  connections = Vector{Union{Nothing, SQLite.DB}}(nothing, pool_size)
  available = fill(true, pool_size)
  lock = ReentrantLock()
  SQLiteConnectionPool(connections, available, connection_string, pool_size, lock)
end

function close_pool!(pool::PormGPostgres)
  Base.lock(pool.lock) do
    for i in 1:length(pool.connections)
      if pool.connections[i] !== nothing
        try
          close(pool.connections[i])
        catch e
          @warn "Error closing connection $i: $e"
        end
      end
      pool.available[i] = true
    end
  end
end

function acquire_connection(pool::PormGPostgres; timeout_seconds::Int = 5, max_retries::Int = 20)
  start_time = time()
  retry_count = 0
  
  while retry_count < max_retries && (time() - start_time) < timeout_seconds
    connection = Base.lock(pool.lock) do
      # Look for an available connection
      for i in 1:length(pool.connections)
        if pool.available[i]
          # Check if existing connection is still alive
          if pool.connections[i] !== nothing && is_connection_alive(pool.connections[i])
            pool.available[i] = false
            return pool.connections[i]
          end
          
          # Create new connection if slot is empty or dead
          try
            new_conn = LibPQ.Connection(pool.connection_string)
            pool.connections[i] = new_conn
            pool.available[i] = false
            return new_conn
          catch e
            @error "Failed to create connection $i: $e" connection_string=redact_secret(pool.connection_string)
            pool.available[i] = true
            continue
          end
        end
      end
      
      # If we reach here, no available connections found
      # Try to expand the pool if we haven't reached the limit
      if length(pool.connections) < max_retries
        try
          new_conn = LibPQ.Connection(pool.connection_string)
          push!(pool.connections, new_conn)
          push!(pool.available, false)
          return new_conn
        catch e
          @error "Failed to expand pool: $e"
        end
      end
      
      # Return nothing if no connection could be acquired
      return nothing
    end
    
    # If we got a connection, return it
    if connection !== nothing
      return connection
    end
    
    # No connection available, wait and retry
    retry_count += 1
    @info "No available connections, retrying ($retry_count/$max_retries) in 100ms..." pool_size=pool.pool_size
    sleep(0.1)  # Wait 100ms before retrying
  end
  
  # If we've exhausted all retries
  if retry_count >= max_retries
    @error "Exceeded maximum retry attempts ($max_retries) to acquire connection" pool_size=pool.pool_size connection_string=redact_secret(pool.connection_string)
    throw("No available connections in the pool after $max_retries attempts")
  else
    @error "Timeout after $(timeout_seconds) seconds waiting for available connection" pool_size=pool.pool_size connection_string=redact_secret(pool.connection_string)
    throw("No available connections in the pool after $(timeout_seconds) seconds")
  end
end

function release_connection(pool::PormGPostgres, conn::LibPQ.Connection)
  released = Base.lock(pool.lock) do
    for i in 1:length(pool.connections)
      if pool.connections[i] === conn
        pool.available[i] = true
        return true
      end
    end
  end
  released !== nothing && return released
  @warn "Connection not found in the pool - connection may have been replaced due to failure"
  return false
end

function is_connection_alive(conn::LibPQ.Connection)
  @infiltrate false
  try
    return LibPQ.status(conn) == LibPQ.libpq_c.CONNECTION_OK
  catch
    return false
  end
end

function reconnect_db(pool::PormGPostgres, conn::LibPQ.Connection)
  reconnect = Base.lock(pool.lock) do
    for i in 1:length(pool.connections)
      if pool.connections[i] === conn
        try
          # Try to reset the connection
          reset = LibPQ.reset(conn)
          return reset
        catch e
          @error "Failed to reset connection $i: $e"
        end
        # If reset fails, create a new connection
        try
          new_conn = LibPQ.Connection(pool.connection_string)
          pool.connections[i] = new_conn
          return pool.connections[i]
        catch e
          @error "Failed to recreate connection $i: $e"
        end
      end
    end
  end
  reconnect !== nothing && return reconnect
  @error "Connection not found in the pool for reconnection"
  return nothing
end

#
# Connection Execution Functions
#

function is_connection_error(e, connection::PormGPostgres)
    msg = lowercase(string(e))
    return (e isa LibPQ.Errors.UnknownError && string(e) == "LibPQ.Errors.UnknownError(\"\")") ||
           occursin("server closed the connection", msg) ||
           occursin("connection not open", msg)
end

#
# Synchronous execution (legacy)
#
function libpq_execute(conn::LibPQ.Connection, sql::String, params::Nothing)
  return LibPQ.execute(conn, sql)  
end
function libpq_execute(conn::LibPQ.Connection, sql::String, params::Vector{Any})
  return LibPQ.execute(conn, sql, params) 
end
libpq_execute(conn::LibPQ.Connection, sql::String, params::PormGPostgresParam) = libpq_execute(conn, sql, params.parameters)

#
# Async execution (yields to Julia scheduler)
#
function libpq_execute_async(conn::LibPQ.Connection, sql::String, params::Nothing)
  return LibPQ.async_execute(conn, sql)
end
function libpq_execute_async(conn::LibPQ.Connection, sql::String, params::Vector{Any})
  return LibPQ.async_execute(conn, sql, params)
end
libpq_execute_async(conn::LibPQ.Connection, sql::String, params::PormGPostgresParam) = libpq_execute_async(conn, sql, params.parameters)

"""
    FetchTask

A wrapper around an async database query result that manages connection lifecycle.
Use `await_result(task)` to get the result and properly release the connection.

# Fields
- `async_result::LibPQ.AsyncResult`: The underlying async result from LibPQ.async_execute
- `pool::PormGPostgres`: The connection pool to release the connection to
- `conn::LibPQ.Connection`: The connection being used for this query
- `completed::Bool`: Whether the async result has been awaited

# Example
```julia
# Start async query (non-blocking)
fetch_task = fetch_async(pool, "SELECT * FROM users")

# Do other work while query runs...

# Await result (blocks until complete, then releases connection)
result = await_result(fetch_task)
```
"""
mutable struct FetchTask
  async_result::Union{LibPQ.AsyncResult, Task}  # Accept both AsyncResult and Task
  pool::PormGPostgres
  conn::LibPQ.Connection
  completed::Bool
  result_cache::Union{Nothing, Any}
  in_transaction::Bool  # Whether this task is part of a transaction context
  
  # Constructor for transaction-aware fetch
  FetchTask(async_result::Union{LibPQ.AsyncResult, Task}, pool::PormGPostgres, conn::LibPQ.Connection, in_transaction::Bool) = 
    new(async_result, pool, conn, false, nothing, in_transaction)
  
  # Legacy constructor (defaults to not in transaction)
  FetchTask(async_result::Union{LibPQ.AsyncResult, Task}, pool::PormGPostgres, conn::LibPQ.Connection) = 
    new(async_result, pool, conn, false, nothing, false)
end

"""
    await_result(ft::FetchTask) -> LibPQ.Result

Await the completion of an async fetch task and return the result.
Automatically releases the connection back to the pool.

This function is idempotent - calling it multiple times returns the same result
without re-releasing the connection.
"""
function await_result(ft::FetchTask)
  if ft.completed
    # Already completed, just return the cached result
    return ft.result_cache
  end
  
  try
    # Await the async result (works for both LibPQ.AsyncResult and Task)
    result = Base.fetch(ft.async_result)
    ft.result_cache = result
    ft.completed = true
    return result
  catch e
    ft.completed = true
    # Unwrap TaskFailedException so callers see the real SQL/LibPQ error
    if e isa TaskFailedException
      root = e.task.exception
      throw(root)
    end
    rethrow(e)
  finally
    # Only release connection if we're not in a transaction context
    # Transaction context manages its own connection lifecycle
    if ft.completed && !ft.in_transaction
      release_connection(ft.pool, ft.conn)
    end
  end
end

"""
    fetch_async(connection::PormGPostgres, sql::String; params=nothing) -> FetchTask

Start an async database query that yields to the Julia scheduler.
Returns a `FetchTask` that can be awaited with `await_result()`.

This is useful in Genie.jl async handlers where you want to run multiple
queries in parallel or allow other tasks to run while waiting for the database.

# Example
```julia
# Start multiple queries in parallel
task1 = fetch_async(pool, "SELECT * FROM users")
task2 = fetch_async(pool, "SELECT * FROM orders")

# Both queries run concurrently, await results
users = await_result(task1)
orders = await_result(task2)
```
"""
function fetch_async(connection::PormGPostgres, sql::String; 
  conn::Union{Nothing, LibPQ.Connection} = nothing, 
  params::Union{Nothing, PormGPostgresParam} = nothing,
  ignore_tx::Bool = false)
  
  # Check for transaction context first
  tx_conn = ignore_tx ? nothing : get_tx_connection()
  use_tx_context = conn === nothing && tx_conn !== nothing
  
  if use_tx_context
    # Use transaction context connection - don't acquire a new one
    conn = tx_conn
    try
      task = libpq_execute_async(conn, sql, params)
      # Return a special FetchTask that won't release the connection
      return FetchTask(task, connection, conn, true)  # true = in_transaction
    catch e
      # Don't release - transaction context manages the connection
      throw(e)
    end
  else
    # Normal path: acquire connection from pool
    conn === nothing && (conn = acquire_connection(connection))
    try
      task = libpq_execute_async(conn, sql, params)
      return FetchTask(task, connection, conn, false)  # false = not in transaction
    catch e
      # If async_execute fails immediately, release connection
      release_connection(connection, conn)
      throw(e)
    end
  end
end
fetch_async(settings::SQLConn, sql::String; conn::Union{Nothing, LibPQ.Connection} = nothing, params::Union{Nothing, PormGPostgresParam} = nothing, ignore_tx::Bool = false) = fetch_async(settings.connections, sql; conn=conn, params=params, ignore_tx=ignore_tx)
fetch_async(settings::SQLConn, sql::String, params::PormGPostgresParam; conn::Union{Nothing, LibPQ.Connection} = nothing, ignore_tx::Bool = false) = fetch_async(settings.connections, sql; conn=conn, params=params, ignore_tx=ignore_tx)
fetch_async(settings::PormGPostgres, sql::String, params::PormGPostgresParam; conn::Union{Nothing, LibPQ.Connection} = nothing, ignore_tx::Bool = false) = fetch_async(settings, sql; conn=conn, params=params, ignore_tx=ignore_tx)

"""
    fetch(connection::PormGPostgres, sql::String; params=nothing, ignore_tx=false) -> LibPQ.Result

Execute a database query synchronously (blocking).
Internally uses async execution but immediately awaits the result.

This is the standard API for most use cases. For async/parallel queries,
use `fetch_async()` instead.

# Example
```julia
result = fetch(pool, "SELECT * FROM users WHERE id = \$1", params)
df = DataFrame(result)
```
"""
function fetch(connection::PormGPostgres, sql::String; 
  conn::Union{Nothing, LibPQ.Connection} = nothing, 
  params::Union{Nothing, PormGPostgresParam} = nothing,
  ignore_tx::Bool = false)
  @infiltrate false
  
  # Use async-first approach: start async query then await
  fetch_task = fetch_async(connection, sql; conn=conn, params=params, ignore_tx=ignore_tx)
  
  try
    return await_result(fetch_task)
  catch e    
    if is_connection_error(e, connection)
      @warn "Lost connection to database. Attempting to reconnect..."
      # Get a fresh connection and retry
      new_conn = reconnect_db(connection, fetch_task.conn)
      if new_conn !== nothing
        retry_task = fetch_async(connection, sql; conn=new_conn, params=params, ignore_tx=ignore_tx)
        return await_result(retry_task)
      end
    end
    # Short-circuit composite errors to the underlying DB cause when present
    if e isa CompositeException && length(e.exceptions) == 1
      throw(e.exceptions[1])
    end
    throw(e)
  end
end
fetch(settings::SQLConn, sql::String; conn::Union{Nothing, LibPQ.Connection} = nothing, params::Union{Nothing, PormGPostgresParam} = nothing, ignore_tx::Bool = false) = fetch(settings.connections, sql; conn=conn, params=params, ignore_tx=ignore_tx)
fetch(settings::SQLConn, sql::String, params::PormGPostgresParam; conn::Union{Nothing, LibPQ.Connection} = nothing, ignore_tx::Bool = false) = fetch(settings.connections, sql; conn=conn, params=params, ignore_tx=ignore_tx)
fetch(settings::PormGPostgres, sql::String, params::PormGPostgresParam; conn::Union{Nothing, LibPQ.Connection} = nothing, ignore_tx::Bool = false) = fetch(settings, sql; conn=conn, params=params, ignore_tx=ignore_tx)

"""
    fetch_copy(connection::PormGPostgres, sql::String, data_itr)

Execute a PostgreSQL `COPY FROM STDIN` operation using an iterable of data chunks.
Uses `LibPQ.execute` with `LibPQ.CopyIn` for high-performance data transfer.
"""
function fetch_copy(connection::PormGPostgres, sql::String, data_itr)
  # Check for transaction context
  tx_conn = get_tx_connection()
  use_tx_context = tx_conn !== nothing
  
  if use_tx_context
    conn = tx_conn
    try
        res = LibPQ.execute(conn, LibPQ.CopyIn(sql, data_itr))
        close(res)
    catch e
        throw(e)
    end
  else
    # TEMPORARY TEST: Use fresh connection and close it
    conn = LibPQ.Connection(connection.connection_string)
    try
        res = LibPQ.execute(conn, LibPQ.CopyIn(sql, data_itr))
        close(res)
    catch e
      rethrow(e)
    finally
      close(conn)
    end
  end
end
fetch_copy(settings::SQLConn, sql::String, data_itr) = fetch_copy(settings.connections, sql, data_itr)

"""
    with_transaction_async(pool::PormGPostgres, sql::String; ...) -> (FetchTask, LibPQ.Connection)

Start an async transaction query. Returns the FetchTask and connection.
The connection is NOT released - caller must manage it for transaction continuation.

For transactions, you typically want to keep the connection for multiple queries.
"""
function with_transaction_async(pool::PormGPostgres, sql::String; 
  conn::Union{Nothing, LibPQ.Connection} = nothing, 
  params::Union{Nothing, PormGPostgresParam} = nothing)
  
  conn === nothing && (conn = acquire_connection(pool))
  try
    task = libpq_execute_async(conn, sql, params)
    # Don't wrap in FetchTask since we don't want auto-release
    return task, conn
  catch e
    release_connection(pool, conn)
    throw(e)
  end
end

function with_transaction(pool::PormGPostgres, sql::String; 
  conn::Union{Nothing, LibPQ.Connection} = nothing, 
  release_conn::Bool = false, 
  params::Union{Nothing, PormGPostgresParam} = nothing)
  
  conn === nothing && (conn = acquire_connection(pool))
  try
    # Use async execution but await immediately
    task = libpq_execute_async(conn, sql, params)
    result = Base.fetch(task)
    return result, conn
  catch e
    @infiltrate   
    @error "Failed to execute SQL transaction, rolling back: $e"
    throw(e)
  finally
    if release_conn
      release_connection(pool, conn)
    end
  end
end
with_transaction(pool::SQLConn, sql::String; conn::Union{Nothing, LibPQ.Connection} = nothing, release_conn::Bool = false, params::Union{Nothing, PormGPostgresParam} = nothing) = with_transaction(pool.connections, sql; conn=conn, release_conn=release_conn, params=params)
with_transaction_async(pool::SQLConn, sql::String; conn::Union{Nothing, LibPQ.Connection} = nothing, params::Union{Nothing, PormGPostgresParam} = nothing) = with_transaction_async(pool.connections, sql; conn=conn, params=params)

"""
    run_in_transaction(f::Function, pool::PormGPostgres) -> result

Execute a function within a database transaction with proper connection context.
All `fetch()` calls within the function will automatically use the same connection.

This is the recommended way to run transactions as it ensures:
1. All queries use the same connection (transaction isolation)
2. Automatic COMMIT on success
3. Automatic ROLLBACK on error
4. Connection is properly released back to the pool

# Example using PormG objects
```julia
include("db/models.jl")
import .models as M

result = run_in_transaction(pool) do
  driver_query = M.Driver |> object
  new_driver = driver_query.create(
    "forename" => "Alice",
    "surname" => "Lane",
    "nationality" => "British",
    "driverref" => "alice_lane"
  )

  race_query = M.Race |> object
  race_query.create(
    "year" => 2025,
    "round" => 1,
    "name" => "Gran Turismo",
    "circuitid" => 1
  )

  # Keep counting or aggregate inside the transaction if needed
  driver_count = driver_query |> do_count
  return (new_driver[:driverid], driver_count)
end
```
"""
function run_in_transaction(f::Function, pool::PormGPostgres)
  conn = acquire_connection(pool)
  try
    # Begin transaction
    task = libpq_execute_async(conn, "BEGIN;", nothing)
    Base.fetch(task)
    
    # Execute the function within transaction context
    result = with_tx_context(pool, conn) do
      f()
    end
    
    # Commit on success
    task = libpq_execute_async(conn, "COMMIT;", nothing)
    Base.fetch(task)
    
    return result
  catch e
    # Rollback on error
    try
      task = libpq_execute_async(conn, "ROLLBACK;", nothing)
      Base.fetch(task)
    catch rollback_error
      @error "Failed to rollback transaction: $rollback_error"
    end
    rethrow(e)
  finally
    release_connection(pool, conn)
  end
end

function run_in_transaction(f::Function, db::String)
  haskey(config, db) || throw("$(db) not found")
  settings::SQLConn = config[db]
  return run_in_transaction(f, settings.connections)
end

run_in_transaction(f::Function, settings::SQLConn) = run_in_transaction(f, settings.connections)

end # module
