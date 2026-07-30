# ==============================================================================
# IMPORTER UTILITIES
# High-level functions to import existing database schemas or Django models 
# into PormG model definitions.
# ==============================================================================

# ---
# Dialect Importers (SQLite / Postgres)
# ---

"""
    import_models_from_sqlite(db::String="db"; force_replace::Bool=false, ignore_schema::Vector{String}=sqlite_ignore_schema, include_table=nothing, file::String="automatic_models.jl")

Import models from a SQLite database and generate a Julia file with model definitions.

# Arguments
- `db::String="db"`: The database key from the configuration (must resolve to a registered SQLite connection).
- `force_replace::Bool=false`: Whether to overwrite the file if it already exists.
- `ignore_schema::Vector{String}=sqlite_ignore_schema`: Table name patterns to ignore.
- `include_table::Union{Vector{String},Nothing}=nothing`: When set, only these tables are imported.
- `file::String="automatic_models.jl"`: The output filename for the generated models.

# Description
Symmetric with [`import_models_from_postgres`](@ref): the database **key** resolves to its settings
via `Configuration.get_settings`, the output directory comes from that connection's `db_def_folder`,
and the connection object is taken from the same settings — so the key and its settings can never
drift apart. A missing/unregistered key raises a clear `ArgumentError` from `get_settings` (no silent
`MODEL_PATH` fallback); a key bound to a non-SQLite connection is rejected explicitly.

# Example
```julia
using PormG

# Load the SQLite configuration
PormG.Configuration.load("db_sl")

# Import models from the database
PormG.Migrations.import_models_from_sqlite("db_sl")
```
"""
function import_models_from_sqlite(db::String = "db";
                                  force_replace::Bool=false,
                                  ignore_schema::Vector{String} = sqlite_ignore_schema,
                                  include_table::Union{Vector{String}, Nothing} = nothing,
                                  file::String="automatic_models.jl")

  # Resolve the connection from its config key (mirrors import_models_from_postgres):
  # a missing/unregistered key throws a clear ArgumentError from get_settings, and the
  # output folder comes from the resolved connection's settings — never a hardcoded path.
  settings = Configuration.get_settings(db)
  conn = settings.connections
  conn isa PormGSQLite || throw(BackendCapabilityError(
    "Connection '$(db)' is not a SQLite connection (got $(typeof(conn))). Use import_models_from_postgres for PostgreSQL."))
  model_path = settings.db_def_folder

  # check if file already exists
  if isfile(joinpath(model_path, file)) && !force_replace
    @warn("The file '$(joinpath(model_path, file))' already exists, use force_replace=true to replace it")
    return nothing
  elseif !ispath(model_path)
    mkpath(model_path)
  end

  # Convert the database schema to models
  models_array = convert_schema_to_models(conn, ignore_table=ignore_schema, include_table=include_table)

  if isempty(models_array)
    @warn("No tables found in the database to import.")
    return nothing
  end

  # Collect all create instructions
  Instructions::Vector{Any} = []
  for model in models_array
    push!(Instructions, Models.Model_to_str(model, settings))
  end

  generate_models_from_db(file, Instructions, settings; path=model_path)

  @info(_emsg("\e[32mSuccessfully imported $(length(models_array)) models from the database.\e[0m"))
  @info("The models have been saved to '$(joinpath(model_path, file))'.")

  return nothing
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
  config::Dict{String,PormGSettings} = config)
  
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
  
  @info(_emsg("\e[32mSuccessfully imported $(length(models_array)) models from the database.\e[0m"))
  @info("The models have been saved to '$(joinpath(model_path, file))'.")
  
  return nothing
end

function import_models_from_postgres(;db::PormGPostgres = connection(), 
                                  settings::PormGSettings,
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
  
  @info(_emsg("\e[32mSuccessfully imported $(length(models_array)) models from the database.\e[0m"))
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
  import_models_from_django(model_py_string::String; db::String = DB_PATH, force_replace::Bool = false, ignore_table::Vector{String} = postgres_ignore_table, file::String = "automatic_models.jl", output_path::Union{Nothing, String} = nothing, django_prefix::Union{Nothing, String, Missing} = missing, autofields_ignore::Vector{String} = ["Manager"], parameters_ignore::Vector{String} = ["help_text"])

Imports Django models from a given `model.py` file content string and generates corresponding Julia models.

# Arguments
- `model_py_string::String`: The content of the `model.py` file as a string; user django_to_string(path) to read the file; or insert the file path.
- `db::String`: The configuration key used to resolve settings (usually the db folder path). The generated file is written to that configuration's `db_def_folder` unless `output_path` overrides it, and the table-name prefix comes from that configuration's `django_prefix` unless `django_prefix` overrides it. Defaults to `DB_PATH`.
- `force_replace::Bool`: If `true`, forces replacement of the existing models file. Defaults to `false`.
- `ignore_table::Vector{String}`: Tables to ignore during the import process. Defaults to `postgres_ignore_table`.
- `file::String`: The name of the file to save the generated models. Defaults to `"automatic_models.jl"`.
- `output_path::Union{Nothing, String}`: Directory to write the generated file into, overriding the resolved config's `db_def_folder`. Use this to stage a *foreign* Django app's models next to their copied `model.py` (e.g. `"db_gal"`) while still resolving `db` for its Settings. Defaults to `nothing` (use `db_def_folder`).
- `django_prefix::Union{Nothing, String, Missing}`: Overrides the generated table-name prefix. `missing` inherits the resolved config's `django_prefix`; `nothing` emits unprefixed table names; a `String` (e.g. `"estoque"`) forces `<prefix>_<table>`. Use this when the imported app uses a different Django `app_label` than the `db` config's. Defaults to `missing` (inherit).
- `autofields_ignore::Vector{String}`: Fields to ignore automatically. Defaults to `["Manager"]`.
- `parameters_ignore::Vector{String}`: Parameters to ignore during field processing. Defaults to `["help_text"]`.

# Description
This function checks if the specified models file already exists and creates it if necessary. It parses the provided `model.py` content string to extract Django model classes and their fields. For each class, it processes the fields, adds a primary key if none exists, and generates the corresponding Julia model code. The generated models are then saved to the specified file.

`output_path` and `django_prefix` never mutate the shared `db` config: when either is set, a
throwaway render-only `Settings` (no database connection) drives the output directory and prefix.

# Example
import_models_from_django(django_to_string("/home/user/models.py"))

# Stage a foreign Django app (its models.py copied into db_gal/) with its own folder and prefix:
import_models_from_django("db_gal/models.py"; db="db", file="gal_models.jl",
                          output_path="db_gal", django_prefix="estoque", force_replace=true)
"""
function import_models_from_django(
    model_py_string::String;
    db::String = DB_PATH,
    force_replace::Bool = false,
    ignore_table::Vector{String} = postgres_ignore_table,
    file::String = "automatic_models.jl",
    output_path::Union{Nothing, String} = nothing,
    django_prefix::Union{Nothing, String, Missing} = missing,
    autofields_ignore::Vector{String} = ["Manager"],
    parameters_ignore::Vector{String} = ["help_text"]
  )

  settings::Union{Nothing, PormGSettings} = nothing
  try
    settings = Configuration.get_settings(db)
  catch e
    @error("The database $(db) does not exists in the config")
    return
  end

  # `db` is the config key used to resolve Settings; by default the output directory
  # and table-name prefix come from that config (matching import_models_from_postgres).
  # When importing a *foreign* Django app staged elsewhere, `output_path`/`django_prefix`
  # override those without mutating the shared config — a throwaway render-only Settings
  # (no DB connection) carries the overrides. `django_prefix === missing` inherits the
  # config's prefix; `nothing` emits unprefixed tables; a String forces that prefix.
  render_settings = if output_path === nothing && django_prefix === missing
    settings
  else
    Configuration.Settings(
      db_def_folder = output_path === nothing ? settings.db_def_folder : output_path,
      django_prefix = django_prefix === missing ? settings.django_prefix : django_prefix,
    )
  end
  model_path = render_settings.db_def_folder
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
        model = Models.Model(class_name, fields_dict)
        # Recover Django `Meta.unique_together` → composite UniqueConstraints (#19). Lenient:
        # BOTH parsing and validation are wrapped — a malformed `unique_together` (e.g. duplicate
        # fields) is warned and skipped, never aborting the whole multi-class import.
        try
          constraints = parse_meta_unique_together(class_content, fields_dict, class_name)
          isempty(constraints) || Models._apply_unique_constraints!(model, constraints)
        catch e
          @warn "import: could not parse/apply unique_together; skipping" class=class_name exception=e
        end
        push!(Instructions, Models.Model_to_str(model, render_settings))
    end

  end

  generate_models_from_db(file, Instructions, render_settings, path=model_path)
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
        # A FieldValidationError/InvalidValueError from field construction is already the right
        # type — stringifying it into an ErrorException would eject it from the taxonomy (audit).
        e isa PormGError && rethrow()
        throw(InvalidMigrationError("Error processing field '$field_name' in class '$class_name': $(e)"))
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
  elseif value == "None"
      # Python's None literal (e.g. default=None) is a null value; map it to
      # Julia's `nothing`. Passing "None" verbatim would crash typed converters
      # such as ForeignKey's default (parse(Int64, "None")).
      return nothing
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
          throw(InvalidMigrationError("Invalid choices format"))
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

# ── Django `Meta.unique_together` → PormG `UniqueConstraint` (#19) ────────────────────────
# The field regex above silently drops any non-`models.X(...)` line, so `class Meta:` options
# never reached the model. These helpers recover `unique_together` and map it to PormG's
# composite-uniqueness declaration. Django `Meta.constraints=[UniqueConstraint(...)]` (the newer
# named form) is not parsed here yet — `unique_together` is the concrete #19 need.

# Return the text inside the FIRST balanced (...) or [...] group in `s` (Django allows tuples
# or lists), or nothing. Quote-aware so a paren inside a string literal is ignored.
function _balanced_group(s::AbstractString)::Union{String, Nothing}
  chars = collect(s)
  start = findfirst(c -> c == '(' || c == '[', chars)
  start === nothing && return nothing
  depth = 0
  buf = IOBuffer()
  in_quotes = false
  quote_char = ' '
  for idx in start:length(chars)
    c = chars[idx]
    if in_quotes
      c == quote_char && (in_quotes = false)
      print(buf, c)
    elseif c == '"' || c == '\''
      in_quotes = true
      quote_char = c
      print(buf, c)
    elseif c == '(' || c == '['
      depth += 1
      depth > 1 && print(buf, c)
    elseif c == ')' || c == ']'
      depth -= 1
      depth == 0 && return String(take!(buf))
      print(buf, c)
    else
      print(buf, c)
    end
  end
  return nothing
end

# Strip surrounding quotes/whitespace off each token, dropping empties (e.g. trailing-comma
# artifacts). `django_to_string` already normalizes `'`→`"` for file input; handle both anyway.
function _clean_constraint_field_names(tokens)::Vector{String}
  out = String[]
  for t in tokens
    n = strip(replace(String(t), "\"" => "", "'" => ""))
    isempty(n) || push!(out, String(n))
  end
  return out
end

# Split the inner text of a `unique_together` value into column groups. Handles both a flat
# single group `('a','b')` and a tuple/list of groups `(('a','b'),('c','d'))`.
function _parse_unique_together_groups(inner::AbstractString)::Vector{Vector{String}}
  tokens = split_field_options(inner)
  isempty(tokens) && return Vector{String}[]
  if any(t -> (st = strip(t); startswith(st, "(") || startswith(st, "[")), tokens)
    groups = Vector{String}[]
    for t in tokens
      st = strip(t)
      (startswith(st, "(") || startswith(st, "[")) || continue
      innerg = _balanced_group(st)
      innerg === nothing && continue
      names = _clean_constraint_field_names(split_field_options(innerg))
      isempty(names) || push!(groups, names)
    end
    return groups
  else
    names = _clean_constraint_field_names(tokens)
    return isempty(names) ? Vector{String}[] : [names]
  end
end

# Map a Django field name to the imported PormG field name: FK/OneToOne fields gain an `_id`
# suffix at import (see process_class_fields!), so `item` in Django is `item_id` in PormG.
function _resolve_django_constraint_field(name::AbstractString, fields_dict::Dict{Symbol, Any})::Union{String, Nothing}
  haskey(fields_dict, Symbol(name)) && return String(name)
  haskey(fields_dict, Symbol("$(name)_id")) && return "$(name)_id"
  return nothing
end

# Build PormG UniqueConstraints from a class's `Meta.unique_together`, resolving each declared
# Django field to its imported PormG field name. Unresolvable groups are warned and skipped
# (lenient, matching the importer's philosophy) rather than aborting the whole import.
function parse_meta_unique_together(class_content, fields_dict::Dict{Symbol, Any}, class_name::AbstractString)
  content = join(string.(class_content), "\n")
  occursin("unique_together", content) || return Models.UniqueConstraint[]
  # `\b` anchors to a word boundary so a longer identifier ending in `unique_together`
  # (e.g. `not_unique_together = ...`) is not mis-parsed as the Meta option.
  m = match(r"\bunique_together\s*=\s*(.*)"s, content)
  m === nothing && return Models.UniqueConstraint[]
  inner = _balanced_group(m.captures[1])
  inner === nothing && return Models.UniqueConstraint[]
  constraints = Models.UniqueConstraint[]
  for group in _parse_unique_together_groups(inner)
    resolved = String[]
    ok = true
    for name in group
      r = _resolve_django_constraint_field(name, fields_dict)
      if r === nothing
        @warn "import: unique_together field matches no imported field; skipping constraint" field=name class=class_name
        ok = false
        break
      end
      push!(resolved, r)
    end
    ok && !isempty(resolved) && push!(constraints, Models.UniqueConstraint(fields = resolved))
  end
  return constraints
end
