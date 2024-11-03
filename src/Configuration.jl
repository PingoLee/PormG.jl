"""
Core PormG configuration / settings functionality.
"""
module Configuration

import YAML, Logging
import PormG
import DataFrames
using DataFrames, Tables, XLSX

import SQLite
import LibPQ

export env, Settings, connection
# app environments
const DEV   = "dev"
const PROD  = "prod"
const TEST  = "test"

haskey(ENV, "PORMG_ENV") || (ENV["PORMG_ENV"] = DEV)


"""
    env() :: String

Returns the current environment.

# Examples
```julia
julia> Configuration.env()
"dev"
```
"""
env() :: String = PormG.config.app_env


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
function read_db_connection_data(db_settings_file::String) :: Dict{String,Any}
  endswith(db_settings_file, ".yml") || throw("Unknow configuration file type - expecting .yml")
  db_conn_data::Dict =  YAML.load(open(db_settings_file))

  if  haskey(db_conn_data, "env") && db_conn_data["env"] !== nothing
    ENV["PORMG_ENV"] =  if strip(uppercase(string(db_conn_data["env"]))) == """ENV["GENIE_ENV"]"""
                                haskey(ENV, "GENIE_ENV") ? ENV["GENIE_ENV"] : DEV
                              else
                                db_conn_data["env"]
                              end

    PormG.config.app_env = ENV["PORMG_ENV"]
  end

  if  haskey(db_conn_data, PormG.config.app_env)
      if haskey(db_conn_data[PormG.config.app_env], "config") && isa(db_conn_data[PormG.config.app_env]["config"], Dict)
        for (k, v) in db_conn_data[PormG.config.app_env]["config"]
          if k == "log_level"
            for dl in Dict("debug" => Logging.Debug, "error" => Logging.Error, "info" => Logging.Info, "warn" => Logging.Warn)
              occursin(dl[1], v) && setfield!(PormG.config, Symbol(k), dl[2])
            end
          else
            setfield!(PormG.config, Symbol(k), ((isa(v, String) && startswith(v, ":")) ? Symbol(v[2:end]) : v) )
          end
        end
      end

      if ! haskey(db_conn_data[PormG.config.app_env], "options") || ! isa(db_conn_data[PormG.config.app_env]["options"], Dict)
        db_conn_data[PormG.config.app_env]["options"] = Dict{String,String}()
      end
  end

  haskey(db_conn_data, PormG.config.app_env) ?
    db_conn_data[PormG.config.app_env] :
    throw(PormG.MissingDatabaseConfigurationException("DB configuration for $(PormG.config.app_env) not found"))
end


function load(path::Union{String,Nothing} = nothing; context::Union{Module,Nothing} = nothing)
  path === nothing && (path = PormG.DB_PATH )
  db_config_file = joinpath(path, PormG.PORMG_DB_CONFIG_FILE_NAME) 
  PormG.config.db_config_settings = read_db_connection_data(db_config_file)

  # PormG.config.db_config_settings

  if PormG.config.db_config_settings["adapter"] == "SQLite"
    dbname =  if haskey(PormG.config.db_config_settings, "host") && PormG.config.db_config_settings["host"] !== nothing
      PormG.config.db_config_settings["host"]
        elseif haskey(PormG.config.db_config_settings, "database") && PormG.config.db_config_settings["database"] !== nothing
          PormG.config.db_config_settings["database"]
        else
          nothing
        end

    db = if dbname !== nothing
      isempty(dirname(dbname)) || mkpath(dirname(dbname))
      SQLite.DB(dbname)
    else # in-memory
      SQLite.DB()
    end

    if PormG.CONNECTIONS === nothing 
      (PormG.CONNECTIONS = [db]) 
    else
      (push!(PormG.CONNECTIONS, db)[end])
    end

  elseif PormG.config.db_config_settings["adapter"] == "PostgreSQL"
    dns = String[]

    for key in ["host", "hostaddr", "port", "password", "passfile", "connect_timeout", "client_encoding"]
      get!(PormG.config.db_config_settings, key, get(ENV, "SEARCHLIGHT_$(uppercase(key))", nothing))
      PormG.config.db_config_settings[key] !== nothing && push!(dns, string("$key=", PormG.config.db_config_settings[key]))
    end

    get!(PormG.config.db_config_settings, "database", get(ENV, "SEARCHLIGHT_DATABASE", nothing))
    PormG.config.db_config_settings["database"] !== nothing && push!(dns, string("dbname=", PormG.config.db_config_settings["database"]))

    get!(PormG.config.db_config_settings, "username", get(ENV, "SEARCHLIGHT_USERNAME", nothing))
    PormG.config.db_config_settings["username"] !== nothing && push!(dns, string("user=", PormG.config.db_config_settings["username"]))

    println(join(dns, " "))
    PormG.CONNECTIONS[path] = LibPQ.Connection(join(dns, " "))

  end
end

# Function to get a connection from the pool
function get_connection(name::String)::Union{SQLite.DB, Nothing}
  return get(PormG.CONNECTIONS, name, nothing)
end

# Function to remove a connection from the pool
function remove_connection(name::String)
  if haskey(PormG.CONNECTIONS, name)
      close(PormG.CONNECTIONS[name])
      delete!(PormG.CONNECTIONS, name)
  end
end

function connection(;key::String = "db") 
  haskey(PormG.CONNECTIONS, key) || throw("PormG is not connected to the database")  
    return PormG.CONNECTIONS[key]
end
"""
    mutable struct Settings

App configuration - sets up the app's defaults. Individual options are overwritten in the corresponding environment file.
"""
mutable struct Settings <: PormG.SQLConn
  app_env::String
  
  db_def_folder::String
  db_config_settings::Dict{String,Any}

  log_queries::Bool
  log_level::Logging.LogLevel
  log_to_file::Bool
  columns::Union{DataFrames.DataFrame, Nothing}
  pk::Union{DataFrames.DataFrame, Nothing}


  Settings(;
            app_env             = ENV["PORMG_ENV"],           
            db_def_folder       = PormG.DB_PATH,
            db_config_settings  = Dict{String,Any}(),
            log_queries         = true,
            log_level           = Logging.Debug,
            log_to_file         = true,
            columns             = nothing,
            pk                  = nothing

        ) =
              new(
                  app_env,
                  db_def_folder, db_config_settings,
                  log_queries, log_level, log_to_file,
                  columns, pk
                )
end

end