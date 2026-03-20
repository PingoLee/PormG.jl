module Configuration

import YAML, Logging
import PormG: SQLConn, PormGPostgres, PormGPostgresParam, PormGSQLite, config, PormGModel
import PormG: PORMG_DB_CONFIG_FILE_NAME, DB_PATH, MODEL_FILE, DATETIME_FORMAT, UTC_TIMEZONE
import PormG: Generator
import PormG.Infiltrator: @infiltrate

import SQLite
import LibPQ
using Base.ScopedValues: ScopedValue, with

export env, Settings, connection, close_pool!, get_settings
export with_tx_context, register_connection, unregister_connection, set_connection_resolver

const _REDACT_CONNECTION_STRING_RE = Regex("(?i)(password|user)=[^\\s]+")

# Dynamic connection resolver hook
const _CONNECTION_RESOLVER = Ref{Union{Nothing, Function}}(nothing)

"""
    set_connection_resolver(f::Function)

Register a callback function to lazily resolve unknown connection keys.
The function `f` should accept a `key::String` and return:
- `nothing` if the key cannot be resolved.
- A `Tuple` of `(url, adapter, pool_size)` or a `Dict` with those keys.
"""
function set_connection_resolver(f::Function)
  _CONNECTION_RESOLVER[] = f
end

"""
    redact_secret(conn_str::String)

Replace sensitive connection string fields such as `password` or `user` with masked values before logging.
"""
function redact_secret(conn_str::String)::String
  return replace(conn_str, _REDACT_CONNECTION_STRING_RE => s"\1=****")
end

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
  conn::Union{Nothing, LibPQ.Connection, SQLite.DB}
  pool::Union{Nothing, PormGPostgres, PormGSQLite}
  depth::Int  # Track nested transaction contexts
  
  TransactionContext() = new(nothing, nothing, 0)
end

# Task-local storage for transaction context; TODO i need study this more
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

function with_tx_context(f::Function, pool::Union{PormGPostgres, PormGSQLite}, conn::Union{LibPQ.Connection, SQLite.DB})
  old_ctx = _tx_context[]
  new_ctx = TransactionContext()
  new_ctx.conn = conn
  new_ctx.pool = pool
  new_ctx.depth = old_ctx.depth + 1
  
  return with(_tx_context => new_ctx) do
    f()
  end
end

function connection_key_for_pool(pool::Union{PormGPostgres, PormGSQLite})::Union{String, Nothing}
  for (key, settings) in config
    if settings.connections === pool
      return key
    end
  end
  return nothing
end

function ensure_model_transaction_scope(model::PormGModel)
  tx_pool = get_tx_pool()
  tx_pool === nothing && return
  model.connect_key === nothing && throw(ArgumentError("Model $(model.name) is not bound to a database connection key"))
  settings = get_settings(model.connect_key)
  if tx_pool === settings.connections
    return
  end
  active_key = connection_key_for_pool(tx_pool)
  active_desc = active_key === nothing ? "unknown transaction" : active_key
  throw(ArgumentError("Active transaction on connection $(active_desc) cannot include model $(model.name) bound to $(model.connect_key). Run run_in_transaction(\"$(model.connect_key)\") or move this operation outside the current transaction."))
end

function transaction_connection_for(settings::SQLConn)
  tx_pool = get_tx_pool()
  tx_conn = get_tx_connection()
  return tx_conn !== nothing && tx_pool === settings.connections ? tx_conn : nothing
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
  return get_settings(path).app_env
end
env(x::String) = env(path=x)

function _effective_env(env::Union{Nothing, String})::String
  return env === nothing ? (haskey(ENV, "PORMG_ENV") ? ENV["PORMG_ENV"] : DEV) : env
end

function _resolve_loaded_key(path_or_key::String)::Union{Nothing, String}
  haskey(config, path_or_key) && return path_or_key

  target_path = abspath(path_or_key)
  for (key, settings) in config
    settings.db_def_folder == "dynamic_connection" && continue
    if abspath(settings.db_def_folder) == target_path
      return key
    end
  end

  return nothing
end

function _build_connection_pool!(settings::SQLConn, path::String)
  # Extract pool size from config (defaults to 3)
  pool_size = haskey(settings.db_config_settings, "pool_size") ?
              parse(Int, string(settings.db_config_settings["pool_size"])) : 3

  sqlite_split_read_write = false
  if haskey(settings.db_config_settings, "sqlite_split_read_write")
    raw_value = settings.db_config_settings["sqlite_split_read_write"]
    sqlite_split_read_write = raw_value isa Bool ? raw_value : lowercase(strip(string(raw_value))) in ("1", "true", "yes", "on")
  elseif haskey(settings.db_config_settings, "options") && isa(settings.db_config_settings["options"], Dict)
    options = settings.db_config_settings["options"]
    if haskey(options, "sqlite_split_read_write")
      raw_value = options["sqlite_split_read_write"]
      sqlite_split_read_write = raw_value isa Bool ? raw_value : lowercase(strip(string(raw_value))) in ("1", "true", "yes", "on")
    end
  end

  if settings.db_config_settings["adapter"] == "SQLite"
    dbname =  if haskey(settings.db_config_settings, "host") && settings.db_config_settings["host"] !== nothing
      settings.db_config_settings["host"]
        elseif haskey(settings.db_config_settings, "database") && settings.db_config_settings["database"] !== nothing
          settings.db_config_settings["database"]
        else
          nothing
        end

    db_path = if dbname !== nothing
      # Ensure path is absolute if it's not relative to memory
      full_path = isabspath(dbname) ? dbname : joinpath(path, dbname)
      isempty(dirname(full_path)) || mkpath(dirname(full_path))
      full_path
    else # in-memory
      ":memory:"
    end

    @infiltrate false
    CP = getfield(parentmodule(@__MODULE__), :ConnectionPool)
    settings.connections = CP.SQLiteConnectionPool(db_path; pool_size=pool_size, split_read_write=sqlite_split_read_write)

  elseif settings.db_config_settings["adapter"] == "PostgreSQL"
    dns = String[]

    # Check for direct URL/Connection String support
    if haskey(settings.db_config_settings, "url") && settings.db_config_settings["url"] !== nothing
      dns_str = settings.db_config_settings["url"]
    else
      # Standard parameters loop
      for key in ["host", "hostaddr", "port", "password", "passfile", "connect_timeout", "client_encoding", "sslmode", "sslrootcert", "sslcert", "sslkey"]
        get!(settings.db_config_settings, key, nothing)
        settings.db_config_settings[key] !== nothing && push!(dns, string("$key=", settings.db_config_settings[key]))
      end

      get!(settings.db_config_settings, "database", nothing)
      settings.db_config_settings["database"] !== nothing && push!(dns, string("dbname=", settings.db_config_settings["database"]))

      get!(settings.db_config_settings, "username", nothing)
      settings.db_config_settings["username"] !== nothing && push!(dns, string("user=", settings.db_config_settings["username"]))

      dns_str = join(dns, " ")
    end

    # Use parent module reference to avoid circular dependency during module loading
    CP = getfield(parentmodule(@__MODULE__), :ConnectionPool)
    settings.connections = CP.PostgresConnectionPool(dns_str; pool_size=pool_size)

  else
    adapter = settings.db_config_settings["adapter"]
    throw(ArgumentError("Unsupported adapter: $(adapter)"))
  end

  return settings
end

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
          # Safely apply settings that exist in the Settings struct
          if hasfield(Settings, Symbol(k))
            if k == "log_level"
              for dl in Dict("debug" => Logging.Debug, "error" => Logging.Error, "info" => Logging.Info, "warn" => Logging.Warn)
                occursin(dl[1], lowercase(string(v))) && setfield!(settings, Symbol(k), dl[2])
              end
            else
              setfield!(settings, Symbol(k), ((isa(v, String) && startswith(v, ":")) ? Symbol(v[2:end]) : v) )
            end
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


function load(path::Union{String,Nothing} = nothing; context::Union{Module,Nothing} = nothing, env::Union{Nothing,String} = nothing, config::Dict{String,SQLConn} = config)
  # create settings if does not exists
  path === nothing && (path = DB_PATH )
  selected_env = _effective_env(env)

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

  if haskey(config, path) && config[path].connections !== nothing
    close_pool!(config[path].connections)
  end

  config[path] = Settings(app_env = selected_env, db_def_folder=path)
  settings::SQLConn = config[path]

  settings.db_config_settings = read_db_connection_data(path, settings)

  _build_connection_pool!(settings, path)
  return nothing
end

"""
    load_many(paths::AbstractVector{<:AbstractString}; env::Union{Nothing,String} = nothing)

Load several static configuration folders using the same environment override.
Returns the list of connection keys that were loaded.
"""
function load_many(paths::AbstractVector{<:AbstractString}; env::Union{Nothing,String} = nothing, config::Dict{String,SQLConn} = config)
  loaded_keys = String[]
  for path in paths
    key = String(path)
    load(key; env=env, config=config)
    push!(loaded_keys, key)
  end
  return loaded_keys
end

"""
    is_loaded(path_or_key::String) -> Bool

Return `true` when a static configuration folder or dynamic connection key has
already been registered in the in-memory configuration cache.
"""
function is_loaded(path_or_key::String)::Bool
  return _resolve_loaded_key(path_or_key) !== nothing
end

function connection(; key::String = "db") 
  settings = config[key]
  return settings.connections
end

function get_settings(key::String)
  if !haskey(config, key) && _CONNECTION_RESOLVER[] !== nothing
    # Attempt lazy resolution
    try
      res = _CONNECTION_RESOLVER[](key)
      if res !== nothing
        if res isa Tuple
          url, adapter, pool_size = res
          register_connection(key, url; adapter=adapter, pool_size=pool_size)
        elseif res isa Dict
          url = get(res, "url", nothing)
          adapter = get(res, "adapter", "PostgreSQL")
          pool_size = get(res, "pool_size", 3)
          url !== nothing && register_connection(key, url; adapter=adapter, pool_size=pool_size)
        end
      end
    catch e
      @error "Error in lazy connection resolver for key '$key'" exception=(e, catch_backtrace())
    end
  end

  haskey(config, key) || throw(ArgumentError("Settings for key '$(key)' not found. Ensure it is loaded via 'load()' or registered via 'register_connection()'."))
  return config[key]  
end

"""
    register_connection(key::String, url::String; adapter::String = "PostgreSQL", pool_size::Int = 3)

Register a new database connection pool dynamically using a connection URL.
Useful for multi-tenant applications or connecting to dynamic data sources.
"""
function register_connection(key::String, url::String; adapter::String = "PostgreSQL", pool_size::Int = 3, sqlite_split_read_write::Bool = false)
  # SAFETY: Deny using folder paths as dynamic keys to avoid hijacking static configs
  if isdir(key)
    throw(ArgumentError("Cannot register dynamic connection using key '$(key)'. Folder paths are reserved for static configurations loaded via 'load()'."))
  end

  if haskey(config, key)
    existing = config[key]
    if existing.db_def_folder != "dynamic_connection"
      throw(ArgumentError("Cannot overwrite static connection '$(key)'. This key is bound to folder '$(existing.db_def_folder)'."))
    end
    
    @warn "Dynamic connection '$(key)' already exists. Closing old pool before re-registering."
    close_pool!(key)
  end

  # Create a minimal Settings object
  settings = Settings(
    app_env = haskey(ENV, "PORMG_ENV") ? ENV["PORMG_ENV"] : DEV,
    db_def_folder = "dynamic_connection"
  )
  
  settings.db_config_settings = Dict{String, Any}(
    "adapter" => adapter,
    "url" => url,
    "pool_size" => pool_size,
    "sqlite_split_read_write" => sqlite_split_read_write
  )

  CP = getfield(parentmodule(@__MODULE__), :ConnectionPool)
  
  if adapter == "PostgreSQL"
    settings.connections = CP.PostgresConnectionPool(url; pool_size=pool_size)
  elseif adapter == "SQLite"
    settings.connections = CP.SQLiteConnectionPool(url; pool_size=pool_size, split_read_write=sqlite_split_read_write)
  else
    throw(ArgumentError("Unsupported adapter: $adapter"))
  end

  config[key] = settings
  return key
end

"""
    unregister_connection(key::String)

Close the connection pool and remove the configuration for the specified key.
"""
function unregister_connection(key::String)
  if haskey(config, key)
    close_pool!(key)
    delete!(config, key)
    return true
  end
  return false
end

"""
    close_pool!(pool::Union{PormGPostgres, PormGSQLite})
    close_pool!(db::String)

Close all connections in the database pool.
"""
function close_pool!(pool::Union{PormGPostgres, PormGSQLite})
  CP = getfield(parentmodule(@__MODULE__), :ConnectionPool)
  CP.close_pool!(pool)
end

function close_pool!(db::String)
  settings::SQLConn = get_settings(db)
  if settings.connections !== nothing
    close_pool!(settings.connections)
  end
end

"""
    ping(path_or_key::String) -> Bool

Check whether a loaded database configuration is reachable right now.
This performs a real connection acquisition and liveness check instead of only
verifying that settings exist in memory.
"""
function ping(path_or_key::String)::Bool
  key = _resolve_loaded_key(path_or_key)
  key === nothing && return false

  settings::SQLConn = config[key]
  pool = settings.connections
  pool === nothing && return false

  CP = getfield(parentmodule(@__MODULE__), :ConnectionPool)
  conn = nothing

  try
    if pool isa PormGSQLite
      conn = CP.acquire_connection(pool; timeout_seconds=5, max_retries=1, mode=:read)
    else
      conn = CP.acquire_connection(pool; timeout_seconds=5, max_retries=1)
    end
    return CP.is_connection_alive(conn)
  catch e
    @warn "Database ping failed" key=key db_def_folder=settings.db_def_folder adapter=get(settings.db_config_settings, "adapter", nothing) exception=(e, catch_backtrace())
    return false
  finally
    if conn !== nothing
      try
        CP.release_connection(pool, conn)
      catch
        # Releasing a failed health-check connection should not mask the original probe result.
      end
    end
  end
end

"""
    status(path_or_key::String) -> NamedTuple

Return a compact server-oriented status payload describing whether a
configuration is loaded and reachable.
"""
function status(path_or_key::String)
  key = _resolve_loaded_key(path_or_key)
  if key === nothing
    return (
      key = path_or_key,
      loaded = false,
      reachable = false,
      adapter = nothing,
      app_env = nothing,
      db_def_folder = nothing,
      dynamic = false,
    )
  end

  settings::SQLConn = config[key]
  return (
    key = key,
    loaded = true,
    reachable = ping(key),
    adapter = get(settings.db_config_settings, "adapter", nothing),
    app_env = settings.app_env,
    db_def_folder = settings.db_def_folder,
    dynamic = settings.db_def_folder == "dynamic_connection",
  )
end

# Reconnection is now handled automatically by the ConnectionPool via acquire_connection()
# and reconnect_db() inside the fetch() cycle. Old direct handle logic removed.

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
      app_env             = haskey(ENV, "PORMG_ENV") ? ENV["PORMG_ENV"] : "dev",           
      db_def_folder       = DB_PATH,
      model_file          = MODEL_FILE,
      db_config_settings  = Dict{String,Any}(),
      log_queries         = true,
      log_level           = Logging.Debug,
      log_to_file         = true,
      change_db           = false,
      change_data         = false,
      connections         = nothing,
          time_zone           = UTC_TIMEZONE,
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