module Generator

import PormG
import PormG: MODEL_PATH, PormGSettings, DB_PATH, GENERATED_MODULE_RESERVED_BINDINGS
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
default_env: dev

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
default_env: dev

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

function generate_models_from_db(file::String, Instructions::Vector{Any}, settings::PormGSettings; path::String = MODEL_PATH) :: Nothing

  # #338: built from the same list Model_to_str's caller seeds its binding-collision `taken` set
  # with, so the boilerplate this file actually imports and the collision guard can never drift.
  reserved_import = join(filter(!=("Models"), GENERATED_MODULE_RESERVED_BINDINGS), ", ")

  open(joinpath(path, file), "w") do f
    write(f, """module $(basename(file) |> x -> replace(x, ".jl" => ""))\n
    import PormG.Models
    import PormG.Models: $(reserved_import)

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

# A migration-plan key rendered as a Julia binding (#394). Plain when the physical table name is
# already a legal identifier — which keeps every existing plan file byte-identical — and Julia's
# `var"..."` raw-identifier form otherwise. Both escapes are needed inside `var"..."`: it follows
# normal string rules, so a backslash or a quote in the table name would terminate it early.
# Can this name be written as a BARE Julia binding? `Base.isidentifier` is necessary but not
# sufficient: it accepts reserved words (`end`, `function`) that are a `ParseError` in assignment
# position, and all-underscore names that parse and then discard. Parsing the assignment itself is
# the only exact test, and it runs once per table during `makemigrations` (#394).
function _plan_binds_bare(name::AbstractString)::Bool
  Base.isidentifier(name) || return false
  all(==('_'), name) && return false
  ex = Meta.parse(string(name, " = 1"); raise = false)
  return ex isa Expr && ex.head === :(=) && ex.args[1] === Symbol(name)
end

function _plan_binding(key)::String
  name = String(key)
  _plan_binds_bare(name) && return name
  # An ALL-UNDERSCORE name (`_`, `___`) is the one case `var"..."` cannot rescue: Julia treats it as
  # a DISCARD at any spelling, so the entry would parse and then hold nothing, and `get_all_dicts`
  # would silently skip that table's migration. Prefixing is safe because the binding NAME is never
  # read back — `get_all_dicts` collects every `OrderedDict` in the module regardless of what it is
  # called, and the `# table:` comment written above each entry is what carries the real name for a
  # human reading the plan.
  stem = all(==('_'), name) ? "pormg_plan_" * name : name
  return "var\"" * replace(replace(stem, "\\" => "\\\\"), "\"" => "\\\"") * "\""
end

function generate_migration_plan(file::String, migration_plan::OrderedDict{Symbol,OrderedDict{String,String}}, path::String) :: Nothing
  open(joinpath(path, file), "w") do f
      module_name = replace(basename(file), ".jl" => "")
      # Stamp the frozen on-disk format version (issue #32) as an inert comment header rather than a
      # `const`: generated files are re-included across runs, and a const would warn on redefinition
      # and conflict once files of different format versions coexist. The header is read by line-scan
      # (`^# pormg-migration-format: (\\d+)\\r?$`, CRLF-tolerant) *before* the module is executed — see docs:
      # Migrations → Format Stability. The authoritative record is the pormg_migrations.format_version
      # column; this comment is the on-disk annotation.
      fmt_version = PormG.Migrations.MIGRATION_FORMAT_VERSION
      write(f, """
          module $module_name
          # pormg-migration-format: $fmt_version

          import PormG.Migrations
          import OrderedCollections: OrderedDict

          """)
      for (key, value) in migration_plan
        write(f, "# table: $key\n")
        if value isa OrderedDict{String, String}
          # Convert this dictionary into parseable Julia code
          jl_code_str = dict_to_jl_str(value)
          # #394: `key` is a PHYSICAL table name and is written here as a Julia BINDING, so a name
          # that is not a legal Julia identifier — a space, a leading digit, a quote: exactly the
          # spellings `db_table` exists to carry — produced a plan file that could not be PARSED.
          # `makemigrations` succeeded and `migrate` then died on its own output. `var"..."` is
          # Julia's raw-identifier syntax and accepts any string; the reader walks `names(mod)`
          # and `getfield` (`Migrations.get_all_dicts`), so it never sees which spelling was used.
          write(f, "$(_plan_binding(key)) = $jl_code_str\n\n")
        else
          # If it's not a Dict, just write it plainly (or handle differently)
          write(f, "# (Not a Dict) $value\n\n")
        end
      end

      write(f, "end\n")
  end

  nothing
end

"""
    create_models_jl(path::String, filename::String = "models.jl")::Nothing

Creates a boilerplate models file in the specified configuration folder with a matching module name.
"""
function create_models_jl(path::String, filename::String = "models.jl")::Nothing
    models_file = joinpath(path, filename)
    module_name = replace(filename, ".jl" => "")
    
    # Don't overwrite if it already exists
    if isfile(models_file)
        return nothing
    end

    reserved_import = join(filter(!=("Models"), GENERATED_MODULE_RESERVED_BINDINGS), ", ")

    open(models_file, "w") do f
        write(f, """
module $module_name

import PormG.Models
import PormG.Models: $(reserved_import)

# Define your models here
# Example:
# Driver = Models.Model("drivers",
#     id        = Models.IDField(),
#     forename  = Models.CharField(max_length=255),
#     surname   = Models.CharField(max_length=255),
# )

end
""")
    end
    nothing
end


  
end