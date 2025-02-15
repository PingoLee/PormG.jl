module Configuration

import YAML, Logging
import PormG: SQLConn, config
import PormG: PORMG_DB_CONFIG_FILE_NAME, DB_PATH, MODEL_FILE, DATETIME_FORMAT

import PormG.Infiltrator: @infiltrate

import SQLite
import LibPQ

export env, Settings, connection
# app environments
const DEV   = "dev"
const PROD  = "prod"
const TEST  = "test"

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
          println(k, " => ", v)
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
  if !haskey(config, path)
    config[path] = Settings(app_env = ENV["PORMG_ENV"], db_def_folder=path)
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
      println(key, " => ", settings.db_config_settings[key])
      settings.db_config_settings[key] !== nothing && push!(dns, string("$key=", settings.db_config_settings[key]))
    end

    # @infiltrate

    # get!(settings.db_config_settings, "database", get(ENV, "SEARCHLIGHT_DATABASE", nothing))
    get!(settings.db_config_settings, "database", nothing)
    settings.db_config_settings["database"] !== nothing && push!(dns, string("dbname=", settings.db_config_settings["database"]))

    # get!(settings.db_config_settings, "username", get(ENV, "SEARCHLIGHT_USERNAME", nothing))
    get!(settings.db_config_settings, "username", nothing)
    settings.db_config_settings["username"] !== nothing && push!(dns, string("user=", settings.db_config_settings["username"]))

    settings.connections = LibPQ.Connection(join(dns, " "))

  end
end

#
# TODO: create a mode to handle multiple connections
#

# mutable struct ConnectionPool
#   connections::Vector{Union{Nothing, LibPQ.Connection}}
#   available::Vector{Bool}
# end

# function create_pg_pool(connection_string::String; pool_size::Int = 10)
#   connections = Vector{Union{Nothing, LibPQ.Connection}}(undef, pool_size)
#   available = fill(true, pool_size)
#   for i in 1:pool_size
#       connections[i] = LibPQ.Connection(connection_string)
#   end
#   return ConnectionPool(connections, available)
# end

# function acquire_connection(pool::ConnectionPool)
#   for i in 1:length(pool.connections)
#       if pool.available[i]
#           pool.available[i] = false
#           return pool.connections[i]
#       end
#   end
#   throw(ArgumentError("No available connections in the pool."))
# end

# function release_connection(pool::ConnectionPool, conn::LibPQ.Connection)
#   for i in 1:length(pool.connections)
#       if pool.connections[i] === conn
#           pool.available[i] = true
#           return
#       end
#   end
#   throw(ArgumentError("Connection not found in the pool."))
# end

# OLD

# # Function to get a connection from the pool
# function get_connection(name::String)::Union{SQLite.DB, Nothing}
#   return get(PormG.CONNECTIONS, name, nothing)
# end

# # Function to remove a connection from the pool
# function remove_connection(settings::Settings, name::String)
#   if haskey(settings.connections, name)
#       close(settings.connections[name])
#       delete!(settings.connections, name)
#   end
# end

function connection(; key::String = "db") 
  settings = config[key]
  return settings.connections
end
"""
    mutable struct Settings

App configuration - sets up the app's defaults. Individual options are overwritten in the corresponding environment file.
"""
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
  connections::Union{Nothing, SQLite.DB, LibPQ.Connection} # Store multiple database connections
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

end