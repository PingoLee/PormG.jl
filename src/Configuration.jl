module Configuration

import YAML, Logging
import PormG: SQLConn, PormGPostgres, PormGPostgresParam, PormGSQLite, config
import PormG: PORMG_DB_CONFIG_FILE_NAME, DB_PATH, MODEL_FILE, DATETIME_FORMAT
import PormG: Generator
import PormG.Infiltrator: @infiltrate

import SQLite
import LibPQ
using Base.ScopedValues: ScopedValue, with

export env, Settings, connection, close_pool!, fetch_async, await_result, FetchTask
export with_tx_context, get_tx_connection, in_transaction_context

# app environments
const DEV   = "dev"
const PROD  = "prod"
const TEST  = "test"

#
# Thread-Local Transaction Context
# This ensures that fetch() calls within a transaction use the same connection
#

"""
    TransactionContext

Holds the current transaction connection for a task/thread.
Used to ensure that nested fetch() calls within a transaction
use the same database connection.
"""
mutable struct TransactionContext
  conn::Union{Nothing, LibPQ.Connection}
  pool::Union{Nothing, PormGPostgres}
  depth::Int  # Track nested transaction contexts
  
  TransactionContext() = new(nothing, nothing, 0)
end

# Task-local storage for transaction context
const _tx_context = ScopedValue(TransactionContext())

"""
    get_tx_connection() -> Union{Nothing, LibPQ.Connection}

Get the current transaction connection if we're inside a transaction context.
Returns `nothing` if not in a transaction.
"""
function get_tx_connection()
  ctx = _tx_context[]
  return ctx.depth > 0 ? ctx.conn : nothing
end

"""
    get_tx_pool() -> Union{Nothing, PormGPostgres}

Get the connection pool associated with the current transaction context.
"""
function get_tx_pool()
  ctx = _tx_context[]
  return ctx.depth > 0 ? ctx.pool : nothing
end

"""
    in_transaction_context() -> Bool

Check if we're currently inside a transaction context.
"""
function in_transaction_context()
  return _tx_context[].depth > 0
end

"""
    with_tx_context(f::Function, pool::PormGPostgres, conn::LibPQ.Connection)

Execute a function within a transaction context. All `fetch()` calls
within this context will use the provided connection instead of
acquiring a new one from the pool.

This is essential for transaction isolation - ensures BEGIN/COMMIT/ROLLBACK
and all intermediate queries use the same connection.

# Example
```julia
conn = acquire_connection(pool)
try
  LibPQ.execute(conn, "BEGIN")
  with_tx_context(pool, conn) do
    # All these fetches use the same connection
    fetch(pool, "INSERT INTO users (name) VALUES ('Alice')")
    fetch(pool, "INSERT INTO orders (user_id) VALUES (1)")
  end
  LibPQ.execute(conn, "COMMIT")
catch e
  LibPQ.execute(conn, "ROLLBACK")
  rethrow(e)
finally
  release_connection(pool, conn)
end
```
"""
function with_tx_context(f::Function, pool::PormGPostgres, conn::LibPQ.Connection)
  old_ctx = _tx_context[]
  new_ctx = TransactionContext()
  new_ctx.conn = conn
  new_ctx.pool = pool
  new_ctx.depth = old_ctx.depth + 1
  
  return with(_tx_context => new_ctx) do
    f()
  end
end

"""
    env() :: String

Returns the current environment.

# Examples
```julia
julia> Configuration.env()
"dev"
```
"""
function env(;path::String=DB_PATH)::String 
  haskey(config, path) || throw("$(path) not found")
  return config[path].app_env
end
env(x::String) = env(path=x)

"""
    read_db_connection_data(db_settings_file::String) :: Dict{Any,Any}

Attempts to read the database configuration file and returns the part corresponding to the current environment as a `Dict`.
Does not check if `db_settings_file` actually exists so it can throw errors.
If the database connection information for the current environment does not exist, it returns an empty `Dict`.

# Examples
```julia
julia> Configuration.read_db_connection_data(...)
Dict{Any,Any} with 6 entries:
  "host"     => "localhost"
  "password" => "..."
  "username" => "..."
  "port"     => 5432
  "database" => "..."
  "adapter"  => "PostgreSQL"
```
"""
function read_db_connection_data(path::String, settings::SQLConn) :: Dict{String,Any}
  db_settings_file = joinpath(path, PORMG_DB_CONFIG_FILE_NAME) 

  endswith(db_settings_file, ".yml") || throw("Unknow configuration file type - expecting .yml")
  db_conn_data::Dict =  YAML.load(open(db_settings_file))

  # println(db_conn_data)

  # if  haskey(db_conn_data, "env") && db_conn_data["env"] !== nothing
  #   Base.ENV["PORMG_ENV"] =  if strip(uppercase(string(db_conn_data["env"]))) == """ENV["GENIE_ENV"]"""
  #                               haskey(ENV, "GENIE_ENV") ? ENV["GENIE_ENV"] : DEV
  #                             else
  #                               db_conn_data["env"]
  #                             end

  #   settings.app_env = Base.ENV["PORMG_ENV"]
  # end

  if  haskey(db_conn_data, settings.app_env)
      if haskey(db_conn_data[settings.app_env], "config") && isa(db_conn_data[settings.app_env]["config"], Dict)
        for (k, v) in db_conn_data[settings.app_env]["config"]
          # println(k, " => ", v)
          if k == "log_level"
            for dl in Dict("debug" => Logging.Debug, "error" => Logging.Error, "info" => Logging.Info, "warn" => Logging.Warn)
              occursin(dl[1], v) && setfield!(settings, Symbol(k), dl[2])
            end
          else
            setfield!(settings, Symbol(k), ((isa(v, String) && startswith(v, ":")) ? Symbol(v[2:end]) : v) )
          end
        end
      end

      if ! haskey(db_conn_data[settings.app_env], "options") || ! isa(db_conn_data[settings.app_env]["options"], Dict)
        db_conn_data[settings.app_env]["options"] = Dict{String,String}()
      end
  end

  haskey(db_conn_data, settings.app_env) ?
    db_conn_data[settings.app_env] :
    throw(MissingDatabaseConfigurationException("DB configuration for $(settings.app_env) not found"))
end


function load(path::Union{String,Nothing} = nothing; context::Union{Module,Nothing} = nothing, config::Dict{String,SQLConn} = config)
  # create settings if does not exists
  path === nothing && (path = DB_PATH )

  @infiltrate false

  # check if the path exists
  if !isdir(path)
    Generator.create_db_folder_and_yml(path=path)
    @error("The database $(path) does not exist. A new folder and configuration file have been created. Please edit the file and run again.")
    return nothing
  end

  # check if the yml file exists
  db_settings_file = joinpath(path, PORMG_DB_CONFIG_FILE_NAME)
  if !isfile(db_settings_file)
    Generator.create_db_folder_and_yml(path=path)
    @error("The database $(db_settings_file) does not exist. A new configuration file have been created. Please edit the configuration.yml file and run again.")
    return nothing
  end

  if !haskey(config, path)
    env = haskey(ENV, "PORMG_ENV") ? ENV["PORMG_ENV"] : DEV
    config[path] = Settings(app_env = env, db_def_folder=path)
  end
  settings::SQLConn = config[path]

  settings.db_config_settings = read_db_connection_data(path, settings)

  if settings.db_config_settings["adapter"] == "SQLite"
    dbname =  if haskey(settings.db_config_settings, "host") && settings.db_config_settings["host"] !== nothing
      settings.db_config_settings["host"]
        elseif haskey(settings.db_config_settings, "database") && settings.db_config_settings["database"] !== nothing
          settings.db_config_settings["database"]
        else
          nothing
        end

    db = if dbname !== nothing
      isempty(dirname(dbname)) || mkpath(dirname(dbname))
      SQLite.DB(dbname)
    else # in-memory
      SQLite.DB()
    end

    settings.connections = db

  elseif settings.db_config_settings["adapter"] == "PostgreSQL"
    dns = String[]

    for key in ["host", "hostaddr", "port", "password", "passfile", "connect_timeout", "client_encoding"]
      # get!(settings.db_config_settings, key, get(ENV, "SEARCHLIGHT_$(uppercase(key))", nothing))
      get!(settings.db_config_settings, key, nothing)
      # println(key, " => ", settings.db_config_settings[key])
      settings.db_config_settings[key] !== nothing && push!(dns, string("$key=", settings.db_config_settings[key]))
    end

    # @infiltrate

    # get!(settings.db_config_settings, "database", get(ENV, "SEARCHLIGHT_DATABASE", nothing))
    get!(settings.db_config_settings, "database", nothing)
    settings.db_config_settings["database"] !== nothing && push!(dns, string("dbname=", settings.db_config_settings["database"]))

    # get!(settings.db_config_settings, "username", get(ENV, "SEARCHLIGHT_USERNAME", nothing))
    get!(settings.db_config_settings, "username", nothing)
    settings.db_config_settings["username"] !== nothing && push!(dns, string("user=", settings.db_config_settings["username"]))

    # settings.connections = LibPQ.Connection(join(dns, " "))
    @infiltrate false
    settings.connections = PostgresConnectionPool(join(dns, " "))

  end
  return nothing
end

#
# mode to handle multiple connections (connection pool)
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
          LibPQ.close(pool.connections[i])
        catch e
          @error "Failed to close connection $i: $e"
        end
        pool.connections[i] = nothing        
      end
      pool.available[i] = true
    end
  end
end
function close_pool!(db::String)
  haskey(config, db) || throw("$(db) not found")
  settings::SQLConn = config[db]
  if settings.connections isa PormGPostgres
    close_pool!(settings.connections)
  end
end

function acquire_connection(pool::PormGPostgres; timeout_seconds::Int = 5, max_retries::Int = 20)
  start_time = time()
  retry_count = 0
  
  while retry_count < max_retries && (time() - start_time) < timeout_seconds
    connection = Base.lock(pool.lock) do
      # First, try to find an available connection
      for i in 1:length(pool.connections)
        if pool.available[i]
          if pool.connections[i] !== nothing
            # Check if connection is still alive
            if is_connection_alive(pool.connections[i])
              pool.available[i] = false
              # @info "Acquired existing connection $i from pool"
              return pool.connections[i]
            else
              try
                pool.connections[i] = LibPQ.Connection(pool.connection_string)
                pool.available[i] = false
                # @info "Reconnected and acquired connection $i"
                return pool.connections[i]
              catch e
                @error "Failed to reconnect connection $i: $e" connection_string=pool.connection_string
                pool.connections[i] = nothing
                pool.available[i] = true
              end
            end
          else            
            # Create new connection in empty slot
            try
              pool.connections[i] = LibPQ.Connection(pool.connection_string)
              pool.available[i] = false
              # @info "Created new connection in slot $i"
              return pool.connections[i]
            catch e
              
              pool.connections[i] = nothing
              pool.available[i] = true
              @error "Failed to create new connection in slot $i: $e" connection_string=pool.connection_string
              throw("Failed to create new connection in pool")
            end
          end
        end
      end
      
      # If we reach here, no available connections found
      # Try to expand the pool if we haven't reached the limit
      if length(pool.connections) < max_retries
        try
          new_connection = LibPQ.Connection(pool.connection_string)
          push!(pool.connections, new_connection)
          push!(pool.available, false)
          pool.pool_size += 1
          @info "Expanded connection pool to $(pool.pool_size) connections"
          return new_connection
        catch e
          @error "Failed to create new connection for pool expansion: $e" connection_string=pool.connection_string
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
    @error "Exceeded maximum retry attempts ($max_retries) to acquire connection" pool_size=pool.pool_size connection_string=pool.connection_string
    throw("No available connections in the pool after $max_retries attempts")
  else
    @error "Timeout after $(timeout_seconds) seconds waiting for available connection" pool_size=pool.pool_size connection_string=pool.connection_string
    throw("No available connections in the pool after $(timeout_seconds) seconds")
  end
end

function release_connection(pool::PormGPostgres, conn::LibPQ.Connection)
  released = Base.lock(pool.lock) do
    for i in 1:length(pool.connections)
      if pool.connections[i] === conn
        pool.available[i] = true
        # @info "Released connection $i back to pool"
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
          LibPQ.reset!(conn)
          if is_connection_alive(conn)
            pool.available[i] = false
            @info "Successfully reset connection $i"
            return conn
          end
        catch e
          @error "Failed to reset connection $i: $e"
        end
        # If reset fails, create a new connection
        try
          pool.connections[i] = LibPQ.Connection(pool.connection_string)
          pool.available[i] = false
          @info "Recreated connection $i"
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
# fetch Function with Pool Support
#

export fetch

function is_connection_error(e, connection::PormGPostgres)
    msg = lowercase(string(e))
    return (e isa LibPQ.Errors.UnknownError && string(e) == "LibPQ.Errors.UnknownError(\"\")") ||
           occursin("server closed the connection", msg) ||
           occursin("connection not open", msg)
           # occursin("connection refused", msg) ||
           # occursin("connection timeout", msg)
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
  params::Union{Nothing, PormGPostgresParam} = nothing)
  
  # Check for transaction context first
  tx_conn = get_tx_connection()
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
fetch_async(settings::SQLConn, sql::String; conn::Union{Nothing, LibPQ.Connection} = nothing, params::Union{Nothing, PormGPostgresParam} = nothing) = fetch_async(settings.connections, sql; conn=conn, params=params)
fetch_async(settings::SQLConn, sql::String, params::PormGPostgresParam; conn::Union{Nothing, LibPQ.Connection} = nothing) = fetch_async(settings.connections, sql; conn=conn, params=params)
fetch_async(settings::PormGPostgres, sql::String, params::PormGPostgresParam; conn::Union{Nothing, LibPQ.Connection} = nothing) = fetch_async(settings, sql; conn=conn, params=params)


"""
    fetch(connection::PormGPostgres, sql::String; params=nothing) -> LibPQ.Result

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
  params::Union{Nothing, PormGPostgresParam} = nothing)
  @infiltrate false
  
  # Use async-first approach: start async query then await
  fetch_task = fetch_async(connection, sql; conn=conn, params=params)
  
  try
    return await_result(fetch_task)
  catch e    
    if is_connection_error(e, connection)
      @warn "Lost connection to database. Attempting to reconnect..."
      # Get a fresh connection and retry
      new_conn = reconnect_db(connection, fetch_task.conn)
      if new_conn !== nothing
        retry_task = fetch_async(connection, sql; conn=new_conn, params=params)
        return await_result(retry_task)
      end
    end
    @infiltrate 
    @error "Failed to execute SQL query: $e"
    throw(e)
  end
end
fetch(settings::SQLConn, sql::String; conn::Union{Nothing, LibPQ.Connection} = nothing, params::Union{Nothing, PormGPostgresParam} = nothing) = fetch(settings.connections, sql; conn=conn, params=params)
fetch(settings::SQLConn, sql::String, params::PormGPostgresParam; conn::Union{Nothing, LibPQ.Connection} = nothing) = fetch(settings.connections, sql; conn=conn, params=params)
fetch(settings::PormGPostgres, sql::String, params::PormGPostgresParam; conn::Union{Nothing, LibPQ.Connection} = nothing) = fetch(settings, sql; conn=conn, params=params)

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

export run_in_transaction

"""
    run_in_transaction(f::Function, pool::PormGPostgres) -> result

Execute a function within a database transaction with proper connection context.
All `fetch()` calls within the function will automatically use the same connection.

This is the recommended way to run transactions as it ensures:
1. All queries use the same connection (transaction isolation)
2. Automatic COMMIT on success
3. Automatic ROLLBACK on error
4. Connection is properly released back to the pool

# Example
```julia
result = run_in_transaction(pool) do
  # All these operations use the same connection
  fetch(pool, "INSERT INTO users (name) VALUES ('Alice')")
  user_id = fetch(pool, "SELECT currval('users_id_seq')") |> DataFrame
  fetch(pool, "INSERT INTO orders (user_id) VALUES (\$(user_id[1,1]))")
  return user_id[1,1]
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

run_in_transaction(f::Function, settings::SQLConn) = run_in_transaction(f, settings.connections)

function connection(; key::String = "db") 
  settings = config[key]
  return settings.connections
end
"""
    mutable struct Settings

App configuration - sets up the app's defaults. Individual options are overwritten in the corresponding environment file.
"""



function reconnect_to_db(settings::SQLConn)
  # Check if the connection is closed
 
  # Reconnect to the database
  db_settings_file = joinpath(settings.db_def_folder, PORMG_DB_CONFIG_FILE_NAME) 
  db_conn_data::Dict =  YAML.load(open(db_settings_file))
  db_conn_data = read_db_connection_data(settings.db_def_folder, settings)

  if db_conn_data["adapter"] == "SQLite"
    dbname =  if haskey(db_conn_data, "host") && db_conn_data["host"] !== nothing
      db_conn_data["host"]
        elseif haskey(db_conn_data, "database") && db_conn_data["database"] !== nothing
          db_conn_data["database"]
        else
          nothing
        end

    db = if dbname !== nothing
      isempty(dirname(dbname)) || mkpath(dirname(dbname))
      SQLite.DB(dbname)
    else # in-memory
      SQLite.DB()
    end

    settings.connections = db

  elseif db_conn_data["adapter"] == "PostgreSQL"
    dns = String[]

    for key in ["host", "hostaddr", "port", "password", "passfile", "connect_timeout", "client_encoding"]
      get!(db_conn_data, key, nothing)
      # println(key, " => ", db_conn_data[key])
      db_conn_data[key] !== nothing && push!(dns, string("$key=", db_conn_data[key]))
    end

    get!(db_conn_data, "database", nothing)
    db_conn_data["database"] !== nothing && push!(dns, string("dbname=", db_conn_data["database"]))

    get!(db_conn_data, "username", nothing)
    db_conn_data["username"] !== nothing && push!(dns, string("user=", db_conn_data["username"]))

    settings.connections = LibPQ.Connection(join(dns, " "))
  end
  
end
  
  

# # old fetch function
# function fetch(settings::SQLConn, sql::String)
#   try
#     return fetch(settings.connections, sql)
#   catch e    
#     @infiltrate false
#     if e == LibPQ.Errors.UnknownError("") || occursin("server closed the connection" , string(e)) || occursin("connection not open", string(e))
#       @warn "Lost connection to database. Attempting to reconnect..."
#       reconnect_to_db(settings);
#       @infiltrate false
#       try
#         return fetch(settings.connections, sql)
#       catch e
#         @error "Failed to reconnect to the database: $(e)"
#         throw(e)
#       end
#     else
#       rethrow(e)
#     end
#   end
# end
# function fetch(connection::LibPQ.Connection, sql::String)
#   return LibPQ.execute(connection, sql) 
# end

#
# Settings struct
#

mutable struct Settings <: SQLConn
  app_env::String
  db_def_folder::String # same then key
  model_file::String
  db_config_settings::Dict{String,Any}
  log_queries::Bool
  log_level::Logging.LogLevel
  log_to_file::Bool
  change_db::Bool # Enable makemigrations and migrations functionality in the app
  change_data::Bool # Enable the change of the database (upgrade, delete) in the app
  connections::Union{Nothing, PormGPostgres, PormGSQLite}
  time_zone::String
  django_prefix::Union{Nothing, String}

  Settings(;
      app_env             = ENV["PORMG_ENV"],           
      db_def_folder       = DB_PATH,
      model_file          = MODEL_FILE,
      db_config_settings  = Dict{String,Any}(),
      log_queries         = true,
      log_level           = Logging.Debug,
      log_to_file         = true,
      change_db           = false,
      change_data         = false,
      connections         = nothing,
      time_zone           = DATETIME_FORMAT,
      django_prefix       = nothing
  ) =
  new(
      app_env,
      db_def_folder,
      model_file,
      db_config_settings,
      log_queries,
      log_level,
      log_to_file,
      change_db,
      change_data,
      connections,
      time_zone,
      django_prefix
  )
end

# Add this to your module cleanup if needed
function __cleanup__()
  for (path, settings) in config
    if settings.connections isa SQLConn
      close_pool!(settings.connections)
    end
  end
end

end