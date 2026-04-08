module ConnectionPool

import Logging
import PormG: SQLConn, PormGPostgres, PormGPostgresParam, PormGSQLite, PormGSQLiteParam, AbstractPormGParam, config, PormGModel
import PormG: @pormg_debug

import SQLite
import LibPQ

export fetch, fetch_async, await_result, FetchTask, fetch_copy
export with_transaction, with_transaction_async, run_in_transaction
export acquire_connection, release_connection, close_pool!
export is_connection_alive, reconnect_db, is_connection_error
export libpq_execute, libpq_execute_async

# Import transaction context helpers from Configuration
import PormG.Configuration: get_tx_connection, get_tx_pool, with_tx_context, transaction_connection_for, get_settings

const _REDACT_CONNECTION_STRING_RE = Regex("(?i)(password|user)=[^\\s]+")
const _SQLITE_LOCK_RETRY_MAX_ATTEMPTS = 20
const _SQLITE_LOCK_RETRY_BASE_DELAY = 0.005
const _SQLITE_LOCK_RETRY_MAX_DELAY = 0.25

"""
    redact_secret(conn_str::String)

Replace sensitive connection string fields such as `password` or `user` with masked values before logging.
"""
function redact_secret(conn_str::String)::String
  return replace(conn_str, _REDACT_CONNECTION_STRING_RE => s"\1=****")
end

function _is_sqlite_locked_error(e)::Bool
  msg = lowercase(string(e))
  return occursin("database is locked", msg) || occursin("database table is locked", msg)
end

function _sqlite_with_retry(op::Function)
  attempt = 1
  while true
    try
      return op()
    catch e
      if !_is_sqlite_locked_error(e) || attempt >= _SQLITE_LOCK_RETRY_MAX_ATTEMPTS
        rethrow(e)
      end

      sleep_seconds = min(_SQLITE_LOCK_RETRY_BASE_DELAY * (1.4^(attempt - 1)), _SQLITE_LOCK_RETRY_MAX_DELAY)
      sleep(sleep_seconds)
      attempt += 1
    end
  end
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
  split_read_write::Bool
  writer_slot::Int
  reader_cursor::Int
  lock::ReentrantLock  # For thread safety
end

function PostgresConnectionPool(connection_string::String; pool_size::Int = 3)
  connections = Vector{Union{Nothing, LibPQ.Connection}}(nothing, pool_size)
  available = fill(true, pool_size) 
  lock = ReentrantLock()
  PostgresConnectionPool(connections, available, connection_string, pool_size, lock)
end

function SQLiteConnectionPool(connection_string::String; pool_size::Int = 3, split_read_write::Bool = false)
  connections = Vector{Union{Nothing, SQLite.DB}}(nothing, pool_size)
  available = fill(true, pool_size)
  lock = ReentrantLock()
  effective_split = split_read_write && pool_size > 1
  if split_read_write && !effective_split
    @warn "SQLite split read/write mode requires pool_size > 1; falling back to shared pool" pool_size=pool_size
  end
  SQLiteConnectionPool(connections, available, connection_string, pool_size, effective_split, 1, 0, lock)
end

function _create_sqlite_connection(connection_string::String; read_only::Bool = false)
  new_conn = SQLite.DB(connection_string)
  SQLite.execute(new_conn, "PRAGMA journal_mode = WAL;")
  SQLite.execute(new_conn, "PRAGMA synchronous = NORMAL;")
  SQLite.execute(new_conn, "PRAGMA busy_timeout = 30000;")
  SQLite.execute(new_conn, "PRAGMA case_sensitive_like = ON;")
  if read_only
    SQLite.execute(new_conn, "PRAGMA query_only = ON;")
  end
  return new_conn
end

function _sqlite_is_read_query(sql::String)::Bool
  cleaned = strip(sql)
  isempty(cleaned) && return true
  token = uppercase(split(cleaned)[1])
  if token in ("SELECT", "PRAGMA", "EXPLAIN")
    return true
  end
  if token == "WITH"
    upper_sql = uppercase(cleaned)
    has_write_keyword = occursin(r"\b(INSERT|UPDATE|DELETE|REPLACE|CREATE|DROP|ALTER|VACUUM|ANALYZE|ATTACH|DETACH|REINDEX|BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)\b", upper_sql)
    return !has_write_keyword
  end
  return false
end

function _sqlite_candidate_slots!(pool::PormGSQLite, mode::Symbol)::Vector{Int}
  total = length(pool.connections)
  writer = pool.writer_slot
  if !pool.split_read_write || mode == :any
    return collect(1:total)
  end
  if mode == :write
    return [writer]
  end

  reader_slots = [i for i in 1:total if i != writer]
  isempty(reader_slots) && return [writer]

  start = mod(pool.reader_cursor, length(reader_slots)) + 1
  ordered = vcat(reader_slots[start:end], reader_slots[1:start - 1], [writer])
  pool.reader_cursor = mod(start, length(reader_slots))
  return ordered
end

function close_pool!(pool::PormGPostgres)
  Base.lock(pool.lock) do
    for i in 1:length(pool.connections)
      conn = pool.connections[i]
      if conn !== nothing
        try
          close(conn)
        catch e
          @warn "Error closing PG connection $i: $e"
        finally
          pool.connections[i] = nothing
        end
      end
      pool.available[i] = true
    end
  end
end

function close_pool!(pool::PormGSQLite)
  Base.lock(pool.lock) do
    for i in 1:length(pool.connections)
      conn = pool.connections[i]
      if conn !== nothing
        try
          close(conn)
        catch e
          @warn "Error closing SQLite connection $i: $e"
        finally
          pool.connections[i] = nothing
        end
      end
      pool.available[i] = true
    end
  end
end

function acquire_connection(pool::PormGPostgres; timeout_seconds::Int = 30, max_retries::Int = 300)
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
            @error "Failed to create PG connection $i: $e" connection_string=redact_secret(pool.connection_string)
            pool.available[i] = true
            continue
          end
        end
      end
      
      # If we reach here, no available connections found
      # Try to expand the pool if we haven't reached the limit
      if length(pool.connections) < (pool.pool_size * 5)
        try
          new_conn = LibPQ.Connection(pool.connection_string)
          push!(pool.connections, new_conn)
          push!(pool.available, false)
          @warn "PG pool expanded beyond initial size" current_size=length(pool.connections) initial_size=pool.pool_size connection_string=redact_secret(pool.connection_string)
          return new_conn
        catch e
          @error "Failed to expand PG pool: $e"
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
    @info "No available PG connections, retrying ($retry_count/$max_retries) in 100ms..." pool_size=pool.pool_size
    sleep(0.1)  # Wait 100ms before retrying
  end
  
  # If we've exhausted all retries
  if retry_count >= max_retries
    @error "Exceeded maximum retry attempts ($max_retries) to acquire PG connection" pool_size=pool.pool_size connection_string=redact_secret(pool.connection_string)
    throw("No available PG connections in the pool after $max_retries attempts")
  else
    @error "Timeout after $(timeout_seconds) seconds waiting for available PG connection" pool_size=pool.pool_size connection_string=redact_secret(pool.connection_string)
    throw("No available PG connections in the pool after $(timeout_seconds) seconds")
  end
end

function acquire_connection(pool::PormGSQLite; timeout_seconds::Int = 30, max_retries::Int = 300, mode::Symbol = :any)
  start_time = time()
  retry_count = 0

  mode in (:any, :read, :write) || throw(ArgumentError("Invalid SQLite acquire mode: $(mode). Expected :any, :read or :write."))
  
  while retry_count < max_retries && (time() - start_time) < timeout_seconds
    connection = Base.lock(pool.lock) do
      slot_order = _sqlite_candidate_slots!(pool, mode)

      # Look for an available connection
      for i in slot_order
        if pool.available[i]
          # Check if existing connection is still alive
          if pool.connections[i] !== nothing && is_connection_alive(pool.connections[i])
            pool.available[i] = false
            return pool.connections[i]
          end
          
          # Create new connection if slot is empty or dead
          try
            is_reader_slot = pool.split_read_write && i != pool.writer_slot
            new_conn = _create_sqlite_connection(pool.connection_string; read_only = is_reader_slot)
            pool.connections[i] = new_conn
            pool.available[i] = false
            return new_conn
          catch e
            @error "Failed to create SQLite connection $i: $e" connection_string=pool.connection_string
            pool.available[i] = true
            continue
          end
        end
      end
      
      # Expand pool logic
      can_expand = !pool.split_read_write && length(pool.connections) < (pool.pool_size * 5)
      if can_expand
        try
          new_conn = _create_sqlite_connection(pool.connection_string)
          push!(pool.connections, new_conn)
          push!(pool.available, false)
          @warn "SQLite pool expanded beyond initial size" current_size=length(pool.connections) initial_size=pool.pool_size connection_string=pool.connection_string
          return new_conn
        catch e
          @error "Failed to expand SQLite pool: $e"
        end
      end
      
      return nothing
    end
    
    if connection !== nothing
      return connection
    end
    
    retry_count += 1
    @info "No available SQLite connections, retrying ($retry_count/$max_retries) in 100ms..." pool_size=pool.pool_size
    sleep(0.1)
  end
  
  error_msg = retry_count >= max_retries ? 
    "No available SQLite connections in the pool after $max_retries attempts" :
    "Timeout after $(timeout_seconds) seconds waiting for available SQLite connection"
    
  @error error_msg pool_size=pool.pool_size connection_string=pool.connection_string
  throw(error_msg)
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
  @warn "PG Connection not found in the pool - connection may have been replaced due to failure"
  return false
end

function release_connection(pool::PormGSQLite, conn::SQLite.DB)
  released = Base.lock(pool.lock) do
    for i in 1:length(pool.connections)
      if pool.connections[i] === conn
        pool.available[i] = true
        return true
      end
    end
  end
  released !== nothing && return released
  @warn "SQLite Connection not found in the pool"
  return false
end

function is_connection_alive(conn::LibPQ.Connection)
  @pormg_debug false
  try
    return LibPQ.status(conn) == LibPQ.libpq_c.CONNECTION_OK
  catch
    return false
  end
end

function is_connection_alive(conn::SQLite.DB)
  try
    # Simple query to check if the database is accessible
    SQLite.execute(conn, "SELECT 1")
    return true
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
          @error "Failed to reset PG connection $i: $e"
        end
        # If reset fails, create a new connection
        try
          new_conn = LibPQ.Connection(pool.connection_string)
          pool.connections[i] = new_conn
          return pool.connections[i]
        catch e
          @error "Failed to recreate PG connection $i: $e"
        end
      end
    end
  end
  reconnect !== nothing && return reconnect
  @error "PG Connection not found in the pool for reconnection"
  return nothing
end

function reconnect_db(pool::PormGSQLite, conn::SQLite.DB)
  reconnect = Base.lock(pool.lock) do
    for i in 1:length(pool.connections)
      if pool.connections[i] === conn
        try
          # For SQLite, we just create a new DB handle
          is_reader_slot = pool.split_read_write && i != pool.writer_slot
          new_conn = _create_sqlite_connection(pool.connection_string; read_only = is_reader_slot)
          pool.connections[i] = new_conn
          return pool.connections[i]
        catch e
          @error "Failed to recreate SQLite connection $i: $e"
        end
      end
    end
  end
  reconnect !== nothing && return reconnect
  @error "SQLite Connection not found in the pool for reconnection"
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

function is_connection_error(e, connection::PormGSQLite)
    msg = lowercase(string(e))
    return occursin("database is closed", msg) || 
           occursin("database connection is closed", msg) ||
           occursin("disk i/o error", msg)
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

function sqlite_execute(conn::SQLite.DB, sql::String, params::Nothing)
  return _sqlite_with_retry(() -> SQLite.DBInterface.execute(conn, sql))
end
function sqlite_execute(conn::SQLite.DB, sql::String, params::Vector{Any})
  return _sqlite_with_retry(() -> SQLite.DBInterface.execute(conn, sql, params))
end
function sqlite_execute(conn::SQLite.DB, sql::String, params::PormGSQLiteParam)
  return _sqlite_with_retry(() -> SQLite.DBInterface.execute(conn, sql, params.parameters))
end

mutable struct SQLiteAsyncWorkItem
  conn::SQLite.DB
  sql::String
  params::Any
  response::Channel{Any}
end

struct SQLiteAsyncResponse
  success::Bool
  payload::Any
end

# A single global worker serializes all SQLite async operations across all pool instances.
# This is intentional: SQLite supports only one concurrent writer per file, and even for
# reads, WAL mode only provides limited concurrency at the file level. A shared queue
# prevents connection pool instances from racing on the same file and avoids the
# "database is locked" errors that arise from concurrent writers on different Julia tasks.
# The queue capacity (2048) is intentionally large so that producers never block.
const _sqlite_async_worker_lock = ReentrantLock()
const _sqlite_async_worker_started = Ref(false)
const _sqlite_async_work_queue = Channel{SQLiteAsyncWorkItem}(2048)

function _ensure_sqlite_async_worker!()
  _sqlite_async_worker_started[] && return

  Base.lock(_sqlite_async_worker_lock) do
    _sqlite_async_worker_started[] && return

    Threads.@spawn begin
      while true
        item = take!(_sqlite_async_work_queue)
        try
          result = sqlite_execute(item.conn, item.sql, item.params)
          put!(item.response, SQLiteAsyncResponse(true, result))
        catch e
          put!(item.response, SQLiteAsyncResponse(false, e))
        end
      end
    end

    _sqlite_async_worker_started[] = true
  end
end

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
    sqlite_execute_async(conn::SQLite.DB, sql::String, params)

Internal helper to execute a SQLite query on a separate thread using `Threads.@spawn`.
This allows the main event loop to remain responsive while waiting for the database.
"""
function sqlite_execute_async(conn::SQLite.DB, sql::String, params)
  _ensure_sqlite_async_worker!()

  response = Channel{Any}(1)
  work_item = SQLiteAsyncWorkItem(conn, sql, params, response)

  return @async begin
    put!(_sqlite_async_work_queue, work_item)
    result = take!(response)
    if result isa SQLiteAsyncResponse
      result.success && return result.payload
      throw(result.payload)
    end
    throw(ErrorException("SQLite async worker returned an invalid response payload"))
  end
end

"""
    FetchTask

A wrapper around an async database query result that manages connection lifecycle.
Use `await_result(task)` to get the result and properly release the connection.

# Fields
- `async_result::Union{LibPQ.AsyncResult, Task}`: The underlying async result (LibPQ.AsyncResult for PG, Task for SQLite)
- `pool::Union{PormGPostgres, PormGSQLite}`: The connection pool to release the connection to
- `conn::Union{LibPQ.Connection, SQLite.DB}`: The connection being used for this query
- `completed::Bool`: Whether the async result has been awaited
- `result_cache::Union{Nothing, Any}`: Cached result for multiple `await_result` calls
- `in_transaction::Bool`: Whether this task is part of a transaction (don't release connection)
"""
mutable struct FetchTask
  async_result::Union{LibPQ.AsyncResult, Task}  # Accept both AsyncResult and Task
  pool::Union{PormGPostgres, PormGSQLite}
  conn::Union{LibPQ.Connection, SQLite.DB}
  completed::Bool
  result_cache::Union{Nothing, Any}
  in_transaction::Bool  # Whether this task is part of a transaction context
  
  # Constructor for transaction-aware fetch
  FetchTask(async_result::Union{LibPQ.AsyncResult, Task}, pool::Union{PormGPostgres, PormGSQLite}, conn::Union{LibPQ.Connection, SQLite.DB}, in_transaction::Bool) = 
    new(async_result, pool, conn, false, nothing, in_transaction)
  
  # Legacy constructor (defaults to not in transaction)
  FetchTask(async_result::Union{LibPQ.AsyncResult, Task}, pool::Union{PormGPostgres, PormGSQLite}, conn::Union{LibPQ.Connection, SQLite.DB}) = 
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
function fetch_async(connection::Union{PormGPostgres, PormGSQLite}, sql::String; 
  conn::Union{Nothing, LibPQ.Connection, SQLite.DB} = nothing, 
  params::Union{Nothing, AbstractPormGParam} = nothing,
  ignore_tx::Bool = false)
  
  # Check for transaction context first
  tx_conn = ignore_tx ? nothing : get_tx_connection()
  use_tx_context = conn === nothing && tx_conn !== nothing
  
  if use_tx_context
    # Use transaction context connection - don't acquire a new one
    conn = tx_conn
    try
      task = if connection isa PormGPostgres
        libpq_execute_async(conn, sql, params)
      else
        sqlite_execute_async(conn, sql, params)
      end
      # Return a special FetchTask that won't release the connection
      return FetchTask(task, connection, conn, true)  # true = in_transaction
    catch e
      # Don't release - transaction context manages the connection
      throw(e)
    end
  else
    # Normal path: acquire connection from pool
    if conn === nothing
      if connection isa PormGSQLite
        sqlite_mode = _sqlite_is_read_query(sql) ? :read : :write
        conn = acquire_connection(connection; mode=sqlite_mode)
      else
        conn = acquire_connection(connection)
      end
    end
    try
      task = if connection isa PormGPostgres
        libpq_execute_async(conn, sql, params)
      else
        sqlite_execute_async(conn, sql, params)
      end
      return FetchTask(task, connection, conn, false)  # false = not in transaction
    catch e
      # If EXEC fails immediately, release connection
      release_connection(connection, conn)
      throw(e)
    end
  end
end
fetch_async(settings::SQLConn, sql::String; conn::Union{Nothing, LibPQ.Connection, SQLite.DB} = nothing, params::Union{Nothing, AbstractPormGParam} = nothing, ignore_tx::Bool = false) = fetch_async(settings.connections, sql; conn=conn, params=params, ignore_tx=ignore_tx)
fetch_async(settings::SQLConn, sql::String, params::AbstractPormGParam; conn::Union{Nothing, LibPQ.Connection, SQLite.DB} = nothing, ignore_tx::Bool = false) = fetch_async(settings.connections, sql; conn=conn, params=params, ignore_tx=ignore_tx)
fetch_async(settings::Union{PormGPostgres, PormGSQLite}, sql::String, params::AbstractPormGParam; conn::Union{Nothing, LibPQ.Connection, SQLite.DB} = nothing, ignore_tx::Bool = false) = fetch_async(settings, sql; conn=conn, params=params, ignore_tx=ignore_tx)

"""
    fetch(connection::Union{PormGPostgres, PormGSQLite}, sql::String; params=nothing, ignore_tx=false) -> Tables.rowtable

Execute a database query synchronously (blocking).
Internally uses async execution but immediately awaits the result.
"""
function fetch(connection::Union{PormGPostgres, PormGSQLite}, sql::String; 
  conn::Union{Nothing, LibPQ.Connection, SQLite.DB} = nothing, 
  params::Union{Nothing, AbstractPormGParam} = nothing,
  ignore_tx::Bool = false)
  @pormg_debug false
  
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
fetch(settings::SQLConn, sql::String; conn::Union{Nothing, LibPQ.Connection, SQLite.DB} = nothing, params::Union{Nothing, AbstractPormGParam} = nothing, ignore_tx::Bool = false) = fetch(settings.connections, sql; conn=conn, params=params, ignore_tx=ignore_tx)
fetch(settings::SQLConn, sql::String, params::AbstractPormGParam; conn::Union{Nothing, LibPQ.Connection, SQLite.DB} = nothing, ignore_tx::Bool = false) = fetch(settings.connections, sql; conn=conn, params=params, ignore_tx=ignore_tx)
fetch(settings::Union{PormGPostgres, PormGSQLite}, sql::String, params::AbstractPormGParam; conn::Union{Nothing, LibPQ.Connection, SQLite.DB} = nothing, ignore_tx::Bool = false) = fetch(settings, sql; conn=conn, params=params, ignore_tx=ignore_tx)

function _drain_postgres_connection!(conn::LibPQ.Connection)
  LibPQ.lock(conn) do
    while true
      # COPY can leave a trailing PGresult pending on the connection even after
      # the main Result is closed. Drain it before the connection returns to the pool.
      LibPQ.libpq_c.PQconsumeInput(conn.conn) == 1 || error(LOGGER, LibPQ.Errors.PQConnectionError(conn))

      if LibPQ.libpq_c.PQisBusy(conn.conn) == 1
        yield()
        continue
      end

      result_ptr = LibPQ.libpq_c.PQgetResult(conn.conn)
      result_ptr == C_NULL && return nothing
      LibPQ.libpq_c.PQclear(result_ptr)
    end
  end
end

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
    # Reuse the transaction connection — COPY is part of the open transaction
    try
      res = LibPQ.execute(tx_conn, LibPQ.CopyIn(sql, data_itr))
      try
        close(res)
      finally
        _drain_postgres_connection!(tx_conn)
      end
    catch e
      try
        _drain_postgres_connection!(tx_conn)
      catch
      end
      rethrow(e)
    end
  else
    # Acquire a pool connection for the duration of the COPY stream.
    # LibPQ.CopyIn owns the connection until the stream is fully consumed,
    # so we must not release it until execute() returns.
    conn = acquire_connection(connection)
    try
      try
        res = LibPQ.execute(conn, LibPQ.CopyIn(sql, data_itr))
        try
          close(res)
        finally
          _drain_postgres_connection!(conn)
        end
      catch e
        try
          _drain_postgres_connection!(conn)
        catch
        end
        rethrow(e)
      end
    finally
      release_connection(connection, conn)
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
function with_transaction_async(pool::Union{PormGPostgres, PormGSQLite}, sql::String; 
  conn::Union{Nothing, LibPQ.Connection, SQLite.DB} = nothing, 
  params::Union{Nothing, AbstractPormGParam} = nothing)
  
  if conn === nothing
    if pool isa PormGSQLite
      conn = acquire_connection(pool; mode=:write)
    else
      conn = acquire_connection(pool)
    end
  end
  try
    task = if pool isa PormGPostgres
      libpq_execute_async(conn, sql, params)
    else
      sqlite_execute_async(conn, sql, params)
    end
    # Don't wrap in FetchTask since we don't want auto-release
    return task, conn
  catch e
    release_connection(pool, conn)
    throw(e)
  end
end

function with_transaction(pool::Union{PormGPostgres, PormGSQLite}, sql::String; 
  conn::Union{Nothing, LibPQ.Connection, SQLite.DB} = nothing, 
  release_conn::Bool = false, 
  params::Union{Nothing, AbstractPormGParam} = nothing)
  
  conn_acquired = false
  if conn === nothing
    if pool isa PormGSQLite
      conn = acquire_connection(pool; mode=:write)
    else
      conn = acquire_connection(pool)
    end
    conn_acquired = true
  end

  try
    # Use async execution but await immediately
    task = if pool isa PormGPostgres
      libpq_execute_async(conn, sql, params)
    else
      sqlite_execute_async(conn, sql, params)
    end
    result = Base.fetch(task)
    return result, conn
  catch e
    # If we acquired the connection here and the command failed (like BEGIN),
    # and we were not asked to release it (which means the caller expected it back),
    # we MUST release it now because the caller won't receive it in the return.
    if conn_acquired && !release_conn
      release_connection(pool, conn)
    end
    @error "Failed to execute SQL transaction, rolling back: $e"
    throw(e)
  finally
    if release_conn
      release_connection(pool, conn)
    end
  end
end
with_transaction(pool::SQLConn, sql::AbstractString; conn::Union{Nothing, LibPQ.Connection, SQLite.DB} = nothing, release_conn::Bool = false, params::Union{Nothing, AbstractPormGParam} = nothing) = with_transaction(pool.connections, sql; conn=conn, release_conn=release_conn, params=params)
with_transaction_async(pool::SQLConn, sql::String; conn::Union{Nothing, LibPQ.Connection, SQLite.DB} = nothing, params::Union{Nothing, AbstractPormGParam} = nothing) = with_transaction_async(pool.connections, sql; conn=conn, params=params)

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
function run_in_transaction(f::Function, pool::Union{PormGPostgres, PormGSQLite})
  conn = if pool isa PormGSQLite
    acquire_connection(pool; mode=:write)
  else
    acquire_connection(pool)
  end
  tx_started = false
  try
    # Begin transaction
    if pool isa PormGPostgres
        task = libpq_execute_async(conn, "BEGIN;", nothing)
        Base.fetch(task)
    else
        # Use BEGIN IMMEDIATE for SQLite to prevent deadlocks and ensure 
        # write lock is acquired early for multi-threaded scenarios.
      task = sqlite_execute_async(conn, "BEGIN IMMEDIATE TRANSACTION;", nothing)
      Base.fetch(task)
    end
    tx_started = true
    
    # Execute the function within transaction context
    result = with_tx_context(pool, conn) do
      f()
    end
    
    # Commit on success
    if pool isa PormGPostgres
        task = libpq_execute_async(conn, "COMMIT;", nothing)
        Base.fetch(task)
    else
      task = sqlite_execute_async(conn, "COMMIT;", nothing)
      Base.fetch(task)
    end
    
    return result
  catch e
    # Rollback on error if transaction actually started
    if tx_started
      try
        if pool isa PormGPostgres
            task = libpq_execute_async(conn, "ROLLBACK;", nothing)
            Base.fetch(task)
        else
          task = sqlite_execute_async(conn, "ROLLBACK;", nothing)
          Base.fetch(task)
        end
      catch rollback_error
        # Only log if it's not a "no transaction active" error in SQLite
        if !(pool isa PormGSQLite && occursin("no transaction is active", string(rollback_error)))
            @error "Failed to rollback transaction: $rollback_error"
        end
      end
    end
    rethrow(e)
  finally
    release_connection(pool, conn)
  end
end

function run_in_transaction(f::Function, db::String)
  settings::SQLConn = get_settings(db)
  return run_in_transaction(f, settings.connections)
end

run_in_transaction(f::Function, settings::SQLConn) = run_in_transaction(f, settings.connections)

end # module
