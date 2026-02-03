module Configuration

import YAML, Logging
import PormG: SQLConn, PormGPostgres, PormGPostgresParam, PormGSQLite, config, PormGModel
import PormG: PORMG_DB_CONFIG_FILE_NAME, DB_PATH, MODEL_FILE, DATETIME_FORMAT
import PormG: Generator
import PormG.Infiltrator: @infiltrate

import SQLite
import LibPQ
using Base.ScopedValues: ScopedValue, with

export env, Settings, connection, close_pool!, get_settings
export with_tx_context

const _REDACT_CONNECTION_STRING_RE = Regex("(?i)(password|user)=[^\\s]+")

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
  conn::Union{Nothing, LibPQ.Connection}
  pool::Union{Nothing, PormGPostgres}
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

function connection_key_for_pool(pool::PormGPostgres)::Union{String, Nothing}
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
  settings = config[model.connect_key]
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
    # Use parent module reference to avoid circular dependency during module loading
    CP = getfield(parentmodule(@__MODULE__), :ConnectionPool)
    settings.connections = CP.PostgresConnectionPool(join(dns, " "))

  end
  return nothing
end

function connection(; key::String = "db") 
  settings = config[key]
  return settings.connections
end

function get_settings(key::String)
  haskey(config, key) || throw("Settings for key '$(key)' not found")
  return config[key]  
end

function close_pool!(pool::PormGPostgres)
  CP = getfield(parentmodule(@__MODULE__), :ConnectionPool)
  CP.close_pool!(pool)
end

function close_pool!(db::String)
  haskey(config, db) || throw("$(db) not found")
  settings::SQLConn = config[db]
  if settings.connections isa PormGPostgres
    close_pool!(settings.connections)
  end
end

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