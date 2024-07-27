module Generator

import PormG: MODEL_PATH
using SQLite

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
function generate_models_from_db(db::SQLite.DB, file::String, Instructions::Vector{Any}) :: Nothing 

  open(joinpath(MODEL_PATH, file), "w") do f
    write(f, """module Models
    using PormG.Models""")
    for table in Instructions
      write(f, "$(table)\n\n")      
    end
    write(f, "end\n")
  end

  nothing
end

  
end