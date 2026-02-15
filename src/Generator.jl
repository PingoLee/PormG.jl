module Generator

import PormG: MODEL_PATH, SQLConn, DB_PATH
using SQLite, LibPQ
import OrderedCollections: OrderedDict

"""
  create_db_folder_and_yml(; path::String = DB_PATH, adapter::String = "PostgreSQL", database::String = "", host::String = "", username::String = "", password::String = "", port::Union{Int, String} = 5432, time_zone::String = "UTC")::Nothing

Creates a folder named "db" at the given path (if it doesn't exist) and an empty ".yml" file inside it with the specified connection details.
"""
function create_db_folder_and_yml(;
    path::String = DB_PATH, 
    adapter::String = "PostgreSQL", 
    database::String = "",
    host::String = "",
    username::String = "",
    password::String = "",
    port::Union{Int, String} = 5432,
    time_zone::String = "UTC"
)::Nothing
    db_folder = joinpath(path)
    if !isdir(db_folder)
        mkpath(db_folder)
    end
    yml_file = joinpath(db_folder, "connection.yml")
    
    # We overwrite if we are specifically calling this with details, 
    # but the fail-forward in Configuration.jl checks if it exists first.
    open(yml_file, "w") do f
        if lowercase(adapter) == "sqlite"
            db_name = isempty(database) ? "database.sqlite" : database
            write(f, """
env: dev

dev:
  adapter: SQLite
  database: $db_name
  config:
    change_db: true
    change_data: true
    time_zone: '$time_zone'
""")
        else
            write(f, """
env: dev

dev:
  adapter: $adapter
  database: $database
  host: $host
  username: $username
  password: $password
  port: $port
  config:
    change_db: true
    change_data: true
    time_zone: '$time_zone'

prod:
  adapter: $adapter
  database: $database
  host: $host
  username: $username
  password: $password
  port: $port
  config:
    change_db: true
    change_data: true
    time_zone: '$time_zone'

test:
  adapter: $adapter
  database: $database
  host: $host
  username: $username
  password: $password
  port: $port
  config:
    change_db: true
    change_data: true
    time_zone: '$time_zone'
""")
        end
    end
    nothing
end

function generate_models_from_db(file::String, Instructions::Vector{Any}, settings::SQLConn; path::String = MODEL_PATH) :: Nothing 

  open(joinpath(path, file), "w") do f
    write(f, """module $(basename(file) |> x -> replace(x, ".jl" => ""))\n
    import PormG.Models
    import PormG.Models: RESTRICT, CASCADE, SET_NULL, SET_DEFAULT, DO_NOTHING, PROTECT

    """)
    for table in Instructions
      write(f, "$(table)\n\n")      
    end
    write(f, "end\n")
  end

  nothing
end

function dict_to_jl_str(d::OrderedDict{String, String})::String
  entries = String[]
  for (k, v) in d
      # Escape any internal quotes in keys
      key_str = replace(string(k), "\"" => "\\\"")

      # If the value is a string, we might wrap it in triple quotes if it has newlines
      if v isa String
          val_str = string(v)
          val_str = "\"\"\"$(val_str)\"\"\""          
          push!(entries, "\n\"$key_str\" =>\n $val_str")
      else
          # For non-string values, just string-ify them
          val_str = replace(string(v), "\"" => "\\\"")
          push!(entries, "\"$key_str\" => $val_str")
      end
  end
  
  # Join the key-value pairs into a Dict( ... )
  return "OrderedDict{String, String}(" * join(entries, ",\n ") * ")"
end

function generate_migration_plan(file::String, migration_plan::OrderedDict{Symbol,OrderedDict{String,String}}, path::String) :: Nothing
  open(joinpath(path, file), "w") do f
      module_name = replace(basename(file), ".jl" => "")
      write(f, """
          module $module_name

          import PormG.Migrations
          import OrderedCollections: OrderedDict

          """)
      for (key, value) in migration_plan
        write(f, "# table: $key\n")
        if value isa OrderedDict{String, String}
          # Convert this dictionary into parseable Julia code
          jl_code_str = dict_to_jl_str(value)
          write(f, "$key = $jl_code_str\n\n")
        else
          # If it's not a Dict, just write it plainly (or handle differently)
          write(f, "# (Not a Dict) $value\n\n")
        end
      end

      write(f, "end\n")
  end

  nothing
end

  
end