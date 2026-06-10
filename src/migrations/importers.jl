# ==============================================================================
# IMPORTER UTILITIES
# High-level functions to import existing database schemas or Django models 
# into PormG model definitions.
# ==============================================================================

# ---
# Dialect Importers (SQLite / Postgres)
# ---

function import_models_from_sqlite(;db::PormGSQLite = connection(), 
                                  force_replace::Bool=false, 
                                  ignore_schema::Vector{String} = sqlite_ignore_schema,
                                  file::String="automatic_models.jl")

  # check if db/models/automatic_models.jl exists
  if isfile(joinpath(MODEL_PATH, file)) && !force_replace
    @warn("The file 'db/models/automatic_models.jl' already exists, use force_replace=true to replace it")
    return
  elseif !ispath(joinpath(MODEL_PATH))
    mkdir(joinpath(MODEL_PATH))
  end
  
  # Get all schema
  schemas = get_database_schema(db)

  # Colect all create instructions
  Instructions::Vector{Any} = []
  for schema in schemas
    schema[2]["type"] == "index" && continue    
    schema[1] in ignore_schema && continue
    # println(schema[2]["sql"])
    push!(Instructions, convertSQLToModel(schema[2]["sql"]) |> Models.Model_to_str)
  end

  generate_models_from_db(db, file, Instructions)


end

"""
    import_models_from_postgres(db::String; force_replace::Bool=false, ignore_table::Vector{String}=postgres_ignore_table, file::String="automatic_models.jl")

Import models from a PostgreSQL database and generate a Julia file with model definitions.

# Arguments
- `db::String`: The database key from the configuration.
- `force_replace::Bool=false`: Whether to overwrite the file if it already exists.
- `ignore_table::Vector{String}=postgres_ignore_table`: A vector of table name patterns to ignore.
- `file::String="automatic_models.jl"`: The output filename for the generated models.

# Description
This function retrieves the database schema from PostgreSQL, converts each table to a PormG model,
and generates a Julia module file containing all the model definitions. The generated file can be
directly included in your project to work with the database tables.

# Example
```julia
using PormG

# Load the database configuration
PormG.Configuration.load("db")

# Import models from the database
PormG.Migrations.import_models_from_postgres("db")

# Or with options
PormG.Migrations.import_models_from_postgres("db", force_replace=true, file="my_models.jl")
```
"""
function import_models_from_postgres(db::String;
  force_replace::Bool=false, 
  ignore_table::Vector{String} = postgres_ignore_table,
  include_table::Union{Vector{String}, Nothing} = nothing,
  file::String="automatic_models.jl",
  config::Dict{String,SQLConn} = config)
  
  settings = Configuration.get_settings(db)
  conn = settings.connections
  model_path = settings.db_def_folder
  
  # Check if the models file already exists
  if isfile(joinpath(model_path, file)) && !force_replace
      @warn("The file '$(joinpath(model_path, file))' already exists, use force_replace=true to replace it")
      return nothing
  end
  
  
  # Convert the database schema to models
  models_array = convert_schema_to_models(conn, ignore_table=ignore_table, include_table=include_table)
  
  if isempty(models_array)
      @warn("No tables found in the database to import.")
      return nothing
  end
  
  # Convert each model to string representation
  Instructions::Vector{Any} = []
  for model in models_array
      push!(Instructions, Models.Model_to_str(model, settings))
  end
  
  # Generate the models file
  generate_models_from_db(file, Instructions, settings, path=model_path)
  
  @info("\e[32mSuccessfully imported $(length(models_array)) models from the database.\e[0m")
  @info("The models have been saved to '$(joinpath(model_path, file))'.")
  
  return nothing
end

function import_models_from_postgres(;db::PormGPostgres = connection(), 
                                  settings::SQLConn,
                                  force_replace::Bool=false, 
                                  ignore_table::Vector{String} = postgres_ignore_table,
                                  include_table::Union{Vector{String}, Nothing} = nothing,
                                  file::String="automatic_models.jl")
  
  model_path = settings.db_def_folder
  
  # Check if the models file already exists
  if isfile(joinpath(model_path, file)) && !force_replace
      @warn("The file '$(joinpath(model_path, file))' already exists, use force_replace=true to replace it")
      return nothing
  end
    
  # Convert the database schema to models
  models_array = convert_schema_to_models(db, ignore_table=ignore_table, include_table=include_table)
  
  if isempty(models_array)
      @warn("No tables found in the database to import.")
      return nothing
  end
  
  # Convert each model to string representation
  Instructions::Vector{Any} = []
  for model in models_array
      push!(Instructions, Models.Model_to_str(model, settings))
  end
  
  # Generate the models file
  generate_models_from_db(file, Instructions, settings, path=model_path)
  
  @info("\e[32mSuccessfully imported $(length(models_array)) models from the database.\e[0m")
  @info("The models have been saved to '$(joinpath(model_path, file))'.")
  
  return nothing
end

# ---
# Django Importer
# ---

"""
  django_to_string(path::String)

Reads the content of a Django model file and returns it as a string.

# Description
This function reads the content of a Django model file and returns it as a string. The file path is provided as an argument.

# Example
django_to_string("/home/user/models.py") |> import_models_from_django
""" 

function django_to_string(path::String)
  # check if db/models/automatic_models.jl exists
  if !isfile(path)
    @warn("The file $(path) does not exists")
    return
  end

  # Read the file  
  return replace(read(path, String), "'" => "\"")
end
  

"""
  import_models_from_django(model_py_string::String; db::Union{PormGSQLite, PormGPostgres} = connection(), force_replace::Bool = false, ignore_table::Vector{String} = postgres_ignore_table, file::String = "automatic_models.jl", autofields_ignore::Vector{String} = ["Manager"], parameters_ignore::Vector{String} = ["help_text"])

Imports Django models from a given `model.py` file content string and generates corresponding Julia models.

# Arguments
- `model_py_string::String`: The content of the `model.py` file as a string; user django_to_string(path) to read the file; or insert the file path.
- `db::String`: The configuration key used to resolve settings (usually the db folder path). The generated file is written to that configuration's `db_def_folder`. Defaults to `DB_PATH`.
- `force_replace::Bool`: If `true`, forces replacement of the existing models file. Defaults to `false`.
- `ignore_table::Vector{String}`: Tables to ignore during the import process. Defaults to `postgres_ignore_table`.
- `file::String`: The name of the file to save the generated models. Defaults to `"automatic_models.jl"`.
- `autofields_ignore::Vector{String}`: Fields to ignore automatically. Defaults to `["Manager"]`.
- `parameters_ignore::Vector{String}`: Parameters to ignore during field processing. Defaults to `["help_text"]`.

# Description
This function checks if the specified models file already exists and creates it if necessary. It parses the provided `model.py` content string to extract Django model classes and their fields. For each class, it processes the fields, adds a primary key if none exists, and generates the corresponding Julia model code. The generated models are then saved to the specified file.

# Example
import_models_from_django(django_to_string("/home/user/models.py"))
"""
function import_models_from_django(
    model_py_string::String;
    db::String = DB_PATH,
    force_replace::Bool = false,
    ignore_table::Vector{String} = postgres_ignore_table,
    file::String = "automatic_models.jl",
    autofields_ignore::Vector{String} = ["Manager"],
    parameters_ignore::Vector{String} = ["help_text"]
  )

  settings::Union{Nothing, SQLConn} = nothing
  try
    settings = Configuration.get_settings(db)
  catch e
    @error("The database $(db) does not exists in the config")
    return
  end

  # `db` is the config key; the output directory comes from the resolved settings,
  # matching import_models_from_postgres. Key and folder usually coincide, but
  # manually registered Settings may point elsewhere.
  model_path = settings.db_def_folder
  model_output_path = joinpath(model_path, file)

  # Check if the generated models file already exists.
  if isfile(model_output_path) && !force_replace
      @warn(
          "The file '$(model_output_path)' already exists, use force_replace=true to replace it"
      )
      return
  elseif !ispath(model_path)
      mkpath(model_path)
  end

  # check if model_py_string is a path to file and if yes, call django_to_string
  if !occursin('\n', model_py_string) && isfile(model_py_string)
    model_py_string = django_to_string(model_py_string)
  end

  # check if model_py_string is a model.py file content and not a path
  if !occursin(r"class\s+\w+\(models\.(Model|AbstractUser)\)", model_py_string)
    @warn("The string does not contain a valid model.py content")
    return
  end

  # create a vector{String} with the a string for each 20 classes 
  class_colector = parse_class(model_py_string) 

  Instructions = Vector{Any}()
  for class in class_colector
    class_name = class["class_name"]  # Extract the class name
    base_class = class["class_type"]  # Extract the base class (models.Model or AbstractUser)
    class_content = class["class_content"]  # Extract the class content

    # println("Processing class: ", class_name)
    # println(class["original_class"])

    # Initialize fields_dict
    fields_dict = Dict{Symbol, Any}()
    has_primary_key = Ref(false)  # Flag to check if a primary key exists

    # Process fields separately
    process_class_fields!(fields_dict, class_content, class_name, base_class, has_primary_key, autofields_ignore, parameters_ignore)

    # Insert IDField if no primary key is defined
    if !has_primary_key[]
        # println("No primary key found in class '$class_name'. Adding an IDField named 'id'.")
        fields_dict[:id] = Models.IDField()
    end

    # Collect all create instructions
    if !isempty(fields_dict)
        push!(Instructions, Models.Model_to_str(Models.Model(class_name, fields_dict), settings))
    end
    
  end

  generate_models_from_db(file, Instructions, settings, path=model_path)
end

function parse_class(model_py_string::String)
  # Initialize state variables
  inside_class = false
  original_class = ""
  class_colector::Vector{Dict{String,Any}} = []

  # Iterate over lines
  for line in split(model_py_string, '\n')
      # Trim leading and trailing whitespace
      stripped_line = strip(line)

      # check if the line is a class
      # Detect the start of a class definition
      if startswith(stripped_line, "class ")
        match_class = match(r"class\s+(\w+)\((models\.Model|AbstractUser)\).?", stripped_line)
        if match_class !== nothing
          class_name = match_class.captures[1]
          class_type = match_class.captures[2]           
          push!(class_colector, Dict("class_name" => class_name, "class_type" => class_type, "original_class" => "", "class_content" => []))
          inside_class = true
        end
      end

      # Append the line to the class content if inside a class
      # revome comments from the line      
      if inside_class
        class_colector[end]["original_class"] = class_colector[end]["original_class"] * "\n" * line
        comment_match = match(r"^(.*?)(#.*)?$", line)
        if comment_match !== nothing
          line = comment_match.captures[1]
        end
        push!(class_colector[end]["class_content"], line)
      end
  end 
  return class_colector
end

function process_class_fields!(fields_dict::Dict{Symbol, Any}, class_content::Vector{Any}, class_name::AbstractString, base_class::AbstractString, has_primary_key::Base.RefValue{Bool}, autofields_ignore::Vector{String}, parameters_ignore::Vector{String})
  # Initialize fields for AbstractUser
  if base_class == "AbstractUser"
      has_primary_key[] = true
      fields_dict[:id] = Models.IDField()
      fields_dict[:password] = Models.CharField()
      fields_dict[:last_login] = Models.DateTimeField()
      fields_dict[:is_superuser] = Models.BooleanField()
      fields_dict[:username] = Models.CharField()
      fields_dict[:first_name] = Models.CharField()
      fields_dict[:last_name] = Models.CharField()
      fields_dict[:email] = Models.CharField()
      fields_dict[:is_staff] = Models.BooleanField()
      fields_dict[:is_active] = Models.BooleanField()
      fields_dict[:date_joined] = Models.DateTimeField()
  end

  # Regex to capture field definitions
  # field_regex = r"^\s*(\w+)\s*=\s*models\.(\w+)\((.*)\)"
  field_regex = r"^\s*(\w+)\s*=\s*models\.(\w+)\(([^#]*)\)"


  # Iterate over the fields in the class content
  for field_line in class_content
    field_match = match(field_regex, field_line)
    if field_match !== nothing
      field_name = field_match.captures[1]
      field_type = django_field_type(field_match.captures[2])
      field_args_str = field_match.captures[3]

      # Parse field arguments
      options, related_model = parse_field_args(field_args_str, field_type, parameters_ignore)
      
      # Check for primary key
      if haskey(options, :primary_key) && options[:primary_key] == true
          has_primary_key[] = true
      end         

      # Instantiate the field
      try
        # println(field_type)
        if field_type in autofields_ignore
          continue
        elseif field_type in ["ForeignKey", "OneToOneField"]
          # Add "_id" suffix for foreign keys
          field_key = Symbol("$(field_name)_id")              
          # println(related_model, " ", related_model |> typeof)
          fields_dict[field_key] = getfield(Models, Symbol(field_type))(related_model; options...)
        elseif field_type == "ManyToManyField"
          fields_dict[Symbol(field_name)] = Models.ManyToManyField(related_model; options...)
        else
          fields_dict[Symbol(field_name)] = getfield(Models, Symbol(field_type))(; options...)
        end
      catch e
        @pormg_debug
        error_msg = "Error processing field '$field_name' in class '$class_name': $(e)"
        throw(ErrorException(error_msg))
      end
    end
  end

  return nothing

end

function django_field_type(field_type::AbstractString)::String
  return String(field_type)
end

function parse_field_args(args_str::AbstractString, field_type::AbstractString, parameters_ignore::Vector{String})
  # This function parses field arguments handling nested parentheses and commas
  # and returns a dictionary of options.
  options = Dict{Symbol, Any}()
  options_list = split_field_options(args_str)
  # println(options_list)
  related_model = missing
  for option_str in options_list
      key_value = split(option_str, "=", limit=2)
      if length(key_value) == 2
          key = strip(key_value[1])
          value = strip(key_value[2])
          value_parsed = parse_value(value)
          # println(value_parsed)
          field_type == "ManyToManyField" && key == "blank" && continue
          key in parameters_ignore && continue
          # Django callable datetime defaults (e.g. default=timezone.now) have no
          # literal equivalent in PormG. Map them to auto_now_add, which sets the
          # column to the current timestamp on creation — the closest semantics.
          if key == "default" && field_type in DATETIME_FIELD_TYPES && is_current_time_default(value)
              options[:auto_now_add] = true
              continue
          end
          options[Symbol(key)] = value_parsed
      else
        if field_type in ["ForeignKey", "OneToOneField", "ManyToManyField"]
          related_model = replace(key_value[1], "\"" => "", "'" => "") |> string
          field_type in ["ForeignKey", "OneToOneField"] && (options[:pk_field] = "id")
        end
      end
  end
  return options, related_model
end

# Django field types that map to PormG date/time fields carrying auto_now_add.
const DATETIME_FIELD_TYPES = ["DateTimeField", "DateField", "TimeField"]

# Django callables that resolve to "the current moment" at row creation. Used as
# field defaults (e.g. default=timezone.now); they have no literal value to import.
const CURRENT_TIME_CALLABLES = Set([
  "timezone.now",
  "django.utils.timezone.now",
  "datetime.now",
  "datetime.datetime.now",
  "now",
])

function is_current_time_default(value::AbstractString)::Bool
  # Accept both `timezone.now` (callable reference) and `timezone.now()` (call).
  normalized = replace(strip(value), r"\(\s*\)$" => "")
  return normalized in CURRENT_TIME_CALLABLES
end

function parse_value(value::AbstractString)
  value = strip(value)
  if value == "True"
      return true
  elseif value == "False"
      return false
  elseif value == "list"
      return "[]"
  elseif value == "dict"
      return "{}"
  elseif occursin(r"^\d+$", value)
      return parse(Int, value)
  elseif (startswith(value, "\"") && endswith(value, "\"")) || (startswith(value, "'") && endswith(value, "'"))
      return String(value[2:end-1])  # Remove surrounding quotes
  elseif startswith(value, "(") && endswith(value, ")")
      # Handle nested tuples (e.g., choices)
      return parse_choices(value)
  else
      return String(value)  # Return as string or handle other types as needed
  end
end

function parse_choices(choices_str::AbstractString)
  # Parse a string into a tuple of tuples
  choices = ()
  pattern = r"\(([^()]+)\)"
  for m in eachmatch(pattern, choices_str)
      inner = m.captures[1]
      values = split(inner, ",")
      if length(values) == 2
          key = strip(values[1])
          value = strip(values[2])
          choices = (choices..., (key, value))
      else
          throw(ArgumentError("Invalid choices format"))
      end
  end
  return choices
end

function split_field_options(field_options::AbstractString)
  tokens = String[]
  buffer = IOBuffer()
  parens = 0
  in_quotes = false
  quote_char::Union{Char, Nothing} = nothing  # Proper initialization
  
  for c in field_options
      if c == '"' || c == '\''
          if in_quotes
              if c == quote_char
                  in_quotes = false
                  quote_char = nothing  # Reset quote_char when exiting quotes
              end
          else
              in_quotes = true
              quote_char = c  # Set quote_char to the current quote
          end
          print(buffer, c)
      elseif in_quotes
          print(buffer, c)
      else
          if c == '('
              parens += 1
              print(buffer, c)
          elseif c == ')'
              parens -= 1
              print(buffer, c)
          elseif c == ',' && parens == 0
              push!(tokens, String(take!(buffer)) |> strip)
          else
              print(buffer, c)
          end
      end
  end
  
  if position(buffer) > 0
      push!(tokens, String(take!(buffer)) |> strip)
  end
  
  return tokens
end
