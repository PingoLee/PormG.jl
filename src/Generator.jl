module Generator

import PormG: MODEL_PATH, SQLConn
using SQLite, LibPQ

# I want generate files with db models, can you help me?
# example:
# users = Models.PormGModel("users", 
#   name = Models.CharField(), 
#   email = Models.CharField(), 
#   age = Models.IntegerField()
# )

# cars = Models.PormGModel("cars", 
#   user = Models.ForeignKey(users, "CASCADE"),
#   name = Models.CharField(), 
#   brand = Models.CharField(), 
#   year = Models.IntegerField()
# )
# I Need open a sqlight db and get all tables and columns to generate the models.jl file


"""
  generate_models_from_db(db::SQLite.DB, file::String, Instructions::Vector{Any}) :: Nothing

Generate models from a database and write them to a file.

# Arguments
- `db::SQLite.DB`: The SQLite database object.
- `file::String`: The name of the file to write the generated models to.
- `Instructions::Vector{Any}`: A vector of instructions for generating the models.
"""
function generate_models_from_db(db::Union{SQLite.DB, LibPQ.LibPQ.Connection }, file::String, Instructions::Vector{Any}) :: Nothing 

  open(joinpath(MODEL_PATH, file), "w") do f
    write(f, """module $(basename(file) |> x -> replace(x, ".jl" => ""))\n
    import PormG.Models
    """)
    for table in Instructions
      write(f, "$(table)\n\n")      
    end
    write(f, "Models.set_models(@__MODULE__, @__DIR__)\n\n")
    write(f, "end\n")
  end

  nothing
end

function dict_to_jl_str(d::Dict{String,Any})::String
  entries = String[]
  for (k, v) in d
      # Escape any internal quotes in keys
      key_str = replace(string(k), "\"" => "\\\"")

      # If the value is a string, we might wrap it in triple quotes if it has newlines
      if v isa String
          val_str = string(v)
          if occursin('\n', val_str)
              # Use triple-quoted string to preserve newlines nicely
              val_str = "\"\"\"$(val_str))\"\"\""
          else
              # Escape quotes for simpler single-line strings
              val_str = "\"" * replace(val_str, "\"" => "\\\"") * "\""
          end
          push!(entries, "\"$key_str\" => $val_str")
      else
          # For non-string values, just string-ify them
          val_str = replace(string(v), "\"" => "\\\"")
          push!(entries, "\"$key_str\" => $val_str")
      end
  end
  
  # Join the key-value pairs into a Dict( ... )
  return "Dict{String, Any}(" * join(entries, ",\n ") * ")"
end

# function generate_migration_plan(file::String, migration_plan::Dict{Any,Any}, path::String) :: Nothing
#   println(path)
#   open(joinpath(path, file), "w") do f
#     write(f, """module $(basename(file) |> x -> replace(x, ".jl" => ""))\n
#     import PormG.Migrations
#     """)
#     for (key, value) in migration_plan
#       write(f, 
#       """# table: $(key)
#       $(value)
#       \n""")            
#     end
#     write(f, "\n\nend\n")
#   end

#   nothing
# end

function generate_migration_plan(file::String, migration_plan::Dict{Any,Any}, path::String) :: Nothing
  open(joinpath(path, file), "w") do f
      module_name = replace(basename(file), ".jl" => "")
      write(f, """
          module $module_name

          import PormG.Migrations

          """)
      for (key, value) in migration_plan
          write(f, "# table: $key\n")

          if value isa Dict{String,Any}
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