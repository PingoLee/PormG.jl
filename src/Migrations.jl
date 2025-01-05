# I want creater a django like orm in julia, can you help me?
# Implement a system for database migrations to manage schema changes over time.
# This could involve creating a separate set of scripts or modules that can apply versioned schema changes to the database.
module Migrations
using DataFrames
using CSV
using Dates
using JSON
using SQLite
using LibPQ
using OrderedCollections

import ..PormG: Models, connection, config, sqlite_type_map, postgres_type_map, PormGModel, SQLConn, MODEL_PATH, sqlite_ignore_schema, postgres_ignore_table, Migration, Dialect
import ..PormG.Generator: generate_models_from_db, generate_migration_plan


# ---
# Define the migration types
#

# Moved to Models.jl to impruve loading code


# ---
# Functions to apply migrations
#

# Moved to Models.jl to Dialect.jl to impruve loading code

# ---
# Functions to import models from a SQLite database
#

function import_models_from_sqlite(;db::SQLite.DB = connection(), 
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
    println(schema[2]["sql"])
    push!(Instructions, convertSQLToModel(schema[2]["sql"]) |> Models.Model_to_str)
  end

  generate_models_from_db(db, file, Instructions)


end

function get_database_schema(db::SQLite.DB)
  # Query the sqlite_master table to get the schema information
  schema_query = "SELECT type, name, sql FROM sqlite_master WHERE type='table' OR type='index';"
  schema_info = SQLite.DBInterface.execute(db, schema_query)

  # Initialize a dictionary to hold the schema data
  schema_data = Dict{String, Any}()

  for row in schema_info
      # For each row, store the type, name, and SQL in the schema_data dictionary
      table_name = row[:name]
      schema_data[table_name] = Dict(
          "type" => row[:type],
          "sql" => row[:sql]
      )
  end

  return schema_data
end

"""
  convertSQLToModel(sql::String)

Converts a SQL CREATE TABLE statement into a model definition in PormGModel.

# Arguments
- `sql::String`: The SQL CREATE TABLE statement.

# Returns
- `PormGModel`: The model definition.

# Example"""
function convertSQLToModel(sql::String; type_map::Dict{String, Any} = sqlite_type_map)   

  # Extract table name
  table_name_match = match(r"CREATE TABLE \"(.+?)\"", sql)
  table_name = table_name_match !== nothing ? table_name_match.captures[1] : error("Table name not found")

  # Define a dictionary to map SQL types to Models.jl field types
  fk_map::Dict{String, Any} = Dict{String, Any}()
  pk_map::Dict{String, Any} = Dict{String, Any}()

  # Extract any primary key constraints
  # primary_key_regex = eachmatch(r"PRIMARY KEY\s*\((.+?)\)", sql)
  primary_key_regex = eachmatch(r"PRIMARY KEY\s*\((.+?)\)?\s*(AUTOINCREMENT)?\)", sql)
  for match in primary_key_regex
    primary_keys = match.captures[1]
    primary_keys = replace(primary_keys, r"\"" => "") 
    primary_keys = split(primary_keys, ",")
    auto_increment = isnothing(match.captures[2]) ? false : true
    println(primary_keys)
    for key in primary_keys
      key = strip(key) |> String
      pk_map[key] = Dict("primary_keys" => key, "auto_increment" => auto_increment)
    end
  end

  # Extract any foreign key constraints
  foreign_key_matches = eachmatch(r"FOREIGN KEY\(\"(\w+)\"\) REFERENCES \"(\w+)\"\(\"(\w+)\"\)(?: ON DELETE (CASCADE|SET NULL|NO ACTION|RESTRICT|SET DEFAULT))?(?: ON UPDATE (CASCADE|SET NULL|NO ACTION|RESTRICT|SET DEFAULT))?(?: DEFERRABLE INITIALLY (DEFERRED|IMMEDIATE))?", sql)
  for match in foreign_key_matches
    column_name, fk_table, fk_column, on_delete, on_update, on_deferable = match.captures
    println(match.captures)
    typeof(column_name |> String) |> println
    fk_map[column_name |> String] = Dict("column_name" => column_name, "fk_table" => fk_table, "fk_column" => fk_column, "on_delete" => on_delete, "on_update" => on_update, "on_deferable" => on_deferable)
  end

  
  # Extend regex to capture PRIMARY KEY and FOREIGN KEY constraints
  column_matches = eachmatch(r"[^(]\"(\w+)\"\s+([A-Z]+)\s*(NOT NULL)?\s*(?:DEFAULT\s+('[^']*'|[^,]*))?", sql)
  # Initialize fields dictionary
  fields_dict = Dict{Symbol, Any}()
  str_fields_dict = Dict{String, Any}()
  for match in column_matches
    # println(match.captures)
    column_name, column_type, nullable, default_value = match.captures
    # check if column_name is a primary key
    if haskey(pk_map, column_name)
      field_instance = Models.IDField(null=!(nullable === nothing), auto_increment=pk_map[column_name]["auto_increment"])
    elseif haskey(fk_map, column_name)
      field_instance = Models.ForeignKey(fk_map[column_name]["fk_table"] |> string; pk_field=fk_map[column_name]["fk_column"] |> string, on_delete=fk_map[column_name]["on_delete"], 
      on_update=fk_map[column_name]["on_update"], deferrable=!(fk_map[column_name]["on_deferable"] === nothing), null=!(nullable === nothing))
    else
      field_instance = getfield(Models, type_map[column_type])(null=!(nullable === nothing), default= default_value === nothing ? default_value : replace(default_value, "'" => ""))
    end
            
    fields_dict[Symbol(column_name)] = field_instance
  end

  # Construct and return the model
  # Dict(:models => Models.Model(table_name, fields_dict), :str_models => Models.Model(table_name, str_fields_dict))
  println(fields_dict)
  println(typeof(table_name))
  return Models.Model(table_name, fields_dict)
end

#
# Makemigrations -- Do instructions to create a migration plan
#

function _configure_order_dict_migration_plan(migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, key::String, value::String)
  if !haskey(migration_plan, model_name)
    migration_plan[model_name] = OrderedDict{String, String}(key => value)
  else
    migration_plan[model_name][key] = value
  end
end

# Compare model definitions to the current database schema
function get_migration_plan(models, current_schema, conn)
  migration_plan = OrderedDict{Symbol, OrderedDict{String, String}}()
  # models is empty set all models to migration_plan
  if isempty(models)
    for (model_name, model) in current_schema
      _configure_order_dict_migration_plan(migration_plan, model_name, "New model", apply_migration(conn, Dialect.create_table(conn, model)))
      for (field_name, field) in model.fields       
        _hash = randstring(8)
        name = "$(model_name)_$field_name"
        if length(name) + length(_hash) > 63
          name = name[1:63 - length(_hash)]
        end
        

        # If new field is a foreign key
        if hasfield(field |> typeof, :to) && !field.db_constraint
          constraint_name = name * "_$_hash" * "_fk"
          _configure_order_dict_migration_plan(migration_plan, model_name, "New foreign key: $field_name", 
          apply_migration(conn, Dialect.add_foreign_key(conn, model, "\"$field_name\"", "\"$constraint_name\"", "\"$(field.to)\"", "\"$(field.pk_field)\"")))
        end

        # If new field is also indexed
        if field.db_index 
          index_name = name * "_$_hash"
          _configure_order_dict_migration_plan(migration_plan, model_name, "Create index on $field_name", 
          apply_migration(conn, Dialect.add_index(conn, model, "\"$index_name\"", "\"$model_name\"", ["\"$field_name\""])))
        end
      
        
      end

    end
    return migration_plan
  end

  for model in models
    model_name = model.name
    if haskey(current_schema, model_name)
      # Compare fields
      for (field_name, field_type) in model.fields
        if !haskey(current_schema[model_name], field_name)     
          migration_plan[model_name] = Dict{String, Any}(
            "Plan" => "New field: $field_name",
            "Column" => field_type,
            "SQL" => Dialect.add_column(connection, model_name, field_name, field_type)
          )
        end
        # check if just a name of the field changed
        
        # Additional comparisons for field changes
      end
    else
      migration_plan[model_name] = "New model"
    end
  end

  # Check for models in the current schema that are not in the models
  for (model_name, model) in current_schema
    if !haskey(models, model_name)
      migration_plan[model_name] = "Delete table"
    end
  end

  # how detect changes in name of the models?


  return migration_plan
end

# Main function to simulate makemigrations
function makemigrations(connection::LibPQ.Connection, settings::SQLConn; path::String = "db/models/models.jl")
  models_array::Vector{Any} = []
  try
    models_array = convert_schema_to_models(connection)
  catch e
    error_message = sprint(showerror, e)
    if occursin("Table definition not found", error_message)
      @info("The database is empty, that is migrate all tables") # TODO, impruve this message
    else
      println("Error: ", e)
      @error("Error: ", e)
      return
    end
  end
  # get module from the path
  println(models_array)
  current_models = get_current_models(include(path))
  println(current_models |> length)
  
  println("compare")
  migration_plan = get_migration_plan(models_array, current_models, connection)

  # store migration_plan as pending_migrations.jl file
  path = joinpath(settings.db_def_folder, "migrations")
  if !ispath(path)
    mkdir(path)
  end
  generate_migration_plan("pending_migrations.jl", migration_plan, path)


  # migration_plan = generate_migration_plan(differences)
  # # Here you would write the migration_plan to a file or directly apply it
  # println("Migration plan: ", migration_plan)
end
function makemigrations(db::String; config::Dict{String,SQLConn} = config)
  settings = config[db]
  path = joinpath(db, settings.model_file)
  isfile(path) || error("The file $(path) does not exists")
  makemigrations(settings.connections, settings, path=path)
end

# Get all models from a module
function get_current_models(mod::Module)
  models = Dict{Symbol, Any}()
  for name in names(mod, all = true)
      if isdefined(mod, name)
          obj = getfield(mod, name)
          if isa(obj, PormGModel)
              models[name] = obj
          end
      end
  end
  return models
end

# ---
# Functions to apply migrations
#

function get_current_dicts(mod::Module)
  ordered_dicts = []
  for name in names(mod, all = true)
      if isdefined(mod, name)
          obj = getfield(mod, name)
          if isa(obj, OrderedDict)
            push!(ordered_dicts, obj)
          end
      end
  end
  return ordered_dicts
end

function migrate(connection::LibPQ.Connection, settings::SQLConn; path::String = "db/models/models.jl")
  # Load the migration plan
  migration_plan = include(joinpath(settings.db_def_folder, "migrations", "pending_migrations.jl")) |> get_current_dicts

  # build the transaction to apply the migration plan
  fisrt_execution::Vector{String} = []
  last_execution::Vector{String} = []

  for dict_instructs in migration_plan
    println("Executing: $dict_instructs")
    for (key, value) in dict_instructs
      if value == "New model"
        push!(fisrt_execution, key)
      else
        push!(last_execution, key)
      end
    end
  
  end

  return migration_plan
  

  # Begin a transaction
  LibPQ.execute(connection, "BEGIN;")

  try
      # Iterate over the migration plan and execute each SQL statement
      for (model_name, actions) in migration_plan
          for (action, sql) in actions
              println("Executing: $sql")
              LibPQ.execute(connection, sql)
          end
      end

      # Commit the transaction
      LibPQ.execute(connection, "COMMIT;")
      println("Migrations applied successfully.")
  catch e
      # Rollback the transaction in case of an error
      LibPQ.execute(connection, "ROLLBACK;")
      println("Error applying migrations: ", e)
      @error("Error applying migrations: ", e)
  end

  
end
function migrate(db::String; config::Dict{String,SQLConn} = config)
  settings = config[db]
  migrate(settings.connections, settings)
end
  


#
# IMPORT MODELS FROM DATABASE POSTGRESQL
#

"""
  convert_schema_to_models(db::LibPQ.Connection; ignore_table::Vector{String} = postgres_ignore_table)

Convert the database schema to models.

# Arguments
- `db::LibPQ.Connection`: The database connection.
- `ignore_table::Vector{String}`: A vector of table names to ignore. Defaults to `postgres_ignore_table`.

# Returns
- `models_array::Vector{Any}`: A vector containing the converted models.

# Description
This function retrieves the database schema and converts it to models. It collects all create instructions and skips tables specified in the `ignore_table` vector. The function prints the type of each schema and returns the schema for debugging purposes. It stops processing after the fifth schema.
"""
function convert_schema_to_models(db::LibPQ.Connection; ignore_table::Vector{String} = postgres_ignore_table)
  # Get all schema
  schemas = get_database_schema(db)
  # Colect all create instructions
  models_array::Vector{Any} = []
  for (index, schema) in enumerate(eachrow(schemas))
    # check if each ignore_table value is contained in the schema.table_name
    any(ignored -> occursin(ignored, schema.table_name), ignore_table) && continue
    println(typeof(schema))
    return schema
    convertSQLToModel(schema) |> println
    # push!(Instructions, convertSQLToModel(schema) |> Models.Model_to_str)
    index > 4 && break
  end  
  return models_array
end

  
function import_models_from_postgres(;db::LibPQ.Connection = connection(), 
                                  force_replace::Bool=false, 
                                  ignore_table::Vector{String} = postgres_ignore_table,
                                  file::String="automatic_models.jl")

  # check if db/models/automatic_models.jl exists
  if isfile(joinpath(MODEL_PATH, file)) && !force_replace
      @warn("The file 'db/models/automatic_models.jl' already exists, use force_replace=true to replace it")
      return
  elseif !ispath(joinpath(MODEL_PATH))
      mkdir(joinpath(MODEL_PATH))
  end
  
  models_array = convert_schema_to_models(db, ignore_table=ignore_table)

  println(models_array)

  # generate_models_from_db(db, file, Instructions)
end
function import_models_from_postgres(db::String;
  force_replace::Bool=false, 
  ignore_table::Vector{String} = postgres_ignore_table,
  file::String="automatic_models.jl")
  import_models_from_postgres(db=connection(key=db), force_replace=force_replace, ignore_table=ignore_table, file=file)
end

function get_database_schema(db::LibPQ.Connection; schema::Union{String, Nothing} = "public", table::Union{String, Nothing} = nothing)
  query = """
  SELECT
      n.nspname AS table_schema,
      c.relname AS table_name,
      array_to_string(array_agg(quote_ident(a.attname) || ' ' || format_type(a.atttypid, a.atttypmod) ||
                                CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END ||
                                CASE WHEN ad.adbin IS NOT NULL THEN ' DEFAULT ' || pg_get_expr(ad.adbin, ad.adrelid) ELSE '' END), ', ') AS columns,
      pk.pk_cols AS primary_keys,
      fk.fk_cols AS foreign_keys,
      fk.fk_tables AS foreign_tables,
      ix.indexes AS indexes
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = c.oid
  LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
  LEFT JOIN (
      SELECT i.indrelid, array_to_string(array_agg(quote_ident(a.attname)), ', ') AS pk_cols
      FROM pg_index i
      JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
      WHERE i.indisprimary
      GROUP BY i.indrelid
  ) pk ON pk.indrelid = c.oid
  LEFT JOIN (
      SELECT con.conrelid, 
             array_to_string(array_agg(quote_ident(att2.attname)), ', ') AS fk_cols,
             array_to_string(array_agg(quote_ident(nf.nspname) || '.' || quote_ident(cf.relname)), ', ') AS fk_tables
      FROM pg_constraint con
      JOIN pg_attribute att2 ON att2.attnum = ANY(con.conkey) AND att2.attrelid = con.conrelid
      JOIN pg_class cf ON cf.oid = con.confrelid
      JOIN pg_namespace nf ON nf.oid = cf.relnamespace
      WHERE con.contype = 'f'
      GROUP BY con.conrelid
  ) fk ON fk.conrelid = c.oid
  LEFT JOIN (
      SELECT i.indexrelid, array_to_string(array_agg(quote_ident(att2.attname)), ', ') AS indexes
      FROM pg_index i
      JOIN pg_class idx ON idx.oid = i.indexrelid
      JOIN pg_attribute att2 ON att2.attnum = ANY(i.indkey) AND att2.attrelid = i.indrelid
      GROUP BY i.indexrelid
  ) ix ON ix.indexrelid = c.oid
  WHERE c.relkind = 'r'
    $(schema === nothing ? "" : "AND n.nspname = '" * schema * "'" )
    $(table === nothing ? "" : "AND c.relname = '" * table * "'" )
    AND a.attnum > 0
    AND NOT a.attisdropped
  GROUP BY n.nspname, c.relname, pk.pk_cols, fk.fk_cols, fk.fk_tables, ix.indexes;
  """
  result = LibPQ.execute(db, query) |> DataFrame
  if nrow(result) == 0
      error("Table definition not found")
  end
  println(result)
  return result
end

function convertSQLToModel(row::DataFrameRow)
    # Implement the conversion logic here

    table_name = row[:table_name]
    columns = split(row[:columns], ", ")
    # SubString{String}["denominador numeric(5,1)", "meta numeric(5,1)", "perc numeric(5,1)", "perc_cat boolean NOT NULL", "apto_id bigint", "cat_cbo_id bigint", "ibge_id bigint NOT NULL", "tipologia_id bigint NOT NULL", "vinculo_id bigint NOT NULL", "encer boolean NOT NULL", "recalc boolean NOT NULL", "nu_cnes_id bigint", "mat_rh_id bigint", "tipo_id bigint NOT NULL", "metac numeric(5,1)", "dias_n_c integer", "id bigint NOT NULL DEFAULT nextval('dash_aval_avaliacao_mensal_id_seq'::regclass)", "periodo_id bigint", "mes integer", "ano integer", "n_apt_mot character varying(250)", "numerador numeric(5,1)", "resultado numeric(5,1)", "indicador_id bigint", "nu_ine_id bigint", "prof_id bigint"]
    println(columns)
    
    # Define a dictionary to map SQL types to Models.jl field types
    fk_map::Dict{String, Any} = Dict{String, Any}()
    pk_map::Dict{String, Any} = Dict{String, Any}()

    # Extract any primary key constraints


    return row
end

# function generate_models_from_db(db::LibPQ.Connection, file::String, instructions::Vector{Any})
#     # Implement the model generation logic here
#     open(joinpath(MODEL_PATH, file), "w") do f
#         for instruction in instructions
#             println(f, instruction)
#         end
#     end
# end

  
function get_database_schema(;pickup::Union{SQLite.DB, LibPQ.Connection} = connection())  
  return get_database_schema(pickup)
end

#
# IMPORT MODELS FROM model.py
#

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
  import_models_from_django(model_py_string::String; db::Union{SQLite.DB, LibPQ.Connection} = connection(), force_replace::Bool = false, ignore_table::Vector{String} = postgres_ignore_table, file::String = "automatic_models.jl", autofields_ignore::Vector{String} = ["Manager"], parameters_ignore::Vector{String} = ["help_text"])

Imports Django models from a given `model.py` file content string and generates corresponding Julia models.

# Arguments
- `model_py_string::String`: The content of the `model.py` file as a string; user django_to_string(path) to read the file; or insert the file path.
- `db::Union{SQLite.DB, LibPQ.Connection}`: The database connection object. Defaults to `connection()`.
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
  db::Union{SQLite.DB, LibPQ.Connection} = connection(),
  force_replace::Bool = false,
  ignore_table::Vector{String} = postgres_ignore_table,
  file::String = "automatic_models.jl",
  autofields_ignore::Vector{String} = ["Manager"],
  parameters_ignore::Vector{String} = ["help_text"]
)
  # Check if db/models/automatic_models.jl exists
  if isfile(joinpath(MODEL_PATH, file)) && !force_replace
      @warn(
          "The file 'db/models/automatic_models.jl' already exists, use force_replace=true to replace it"
      )
      return
  elseif !ispath(joinpath(MODEL_PATH))
      mkdir(joinpath(MODEL_PATH))
  end

  # check if model_py_string is a path to file and if yes, call django_to_string
  if isfile(model_py_string)
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

    println("Processing class: ", class_name)
    println(class["original_class"])

    # Initialize fields_dict
    fields_dict = Dict{Symbol, Any}()
    has_primary_key = false  # Flag to check if a primary key exists

    # Process fields separately
    process_class_fields!(fields_dict, class_content, class_name, base_class, has_primary_key, autofields_ignore, parameters_ignore) && continue

    # Insert IDField if no primary key is defined
    if !has_primary_key
        println("No primary key found in class '$class_name'. Adding an IDField named 'id'.")
        fields_dict[:id] = Models.IDField()
    end

    # Collect all create instructions
    if !isempty(fields_dict)
        push!(Instructions, Models.Model(class_name, fields_dict) |> Models.Model_to_str)
    end
    
  end

  generate_models_from_db(db, file, Instructions)
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
        class_name = match_class.captures[1]
        class_type = match_class.captures[2]           
        push!(class_colector, Dict("class_name" => class_name, "class_type" => class_type, "original_class" => "", "class_content" => []))
        inside_class = true
      end

      # Append the line to the class content if inside a class
      # revome comments from the line      
      if inside_class
        class_colector[end]["original_class"] = class_colector[end]["original_class"] * "\n" * line
        line = match(r"^(.*?)(#.*)?$", line).captures[1]
        push!(class_colector[end]["class_content"], line)
      end
  end 
  return class_colector
end

function process_class_fields!(fields_dict::Dict{Symbol, Any}, class_content::Vector{Any}, class_name::AbstractString, base_class::AbstractString, has_primary_key::Bool, autofields_ignore::Vector{String}, parameters_ignore::Vector{String})  
  # Initialize fields for AbstractUser
  if base_class == "AbstractUser"
      has_primary_key = true
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
  pass = false
  for field_line in class_content
      field_match = match(field_regex, field_line)
      if field_match !== nothing
          field_name = field_match.captures[1]
          field_type = field_match.captures[2]
          field_args_str = field_match.captures[3]

          # Parse field arguments
          options, related_model = parse_field_args(field_args_str, field_type, parameters_ignore)
          
          # Check for primary key
          if haskey(options, :primary_key) && options[:primary_key] == true
              has_primary_key = true
          end         

          # Instantiate the field
          try
            # println(field_type)
            if field_type in autofields_ignore
              pass = true
              continue
            elseif field_type in ["ForeignKey", "OneToOneField" ]              
              # println(related_model, " ", related_model |> typeof)
              fields_dict[Symbol(field_name)] = getfield(Models, Symbol(field_type))(related_model; options...)
            else
              fields_dict[Symbol(field_name)] = getfield(Models, Symbol(field_type))(; options...)
            end
          catch e
              error_msg = "Error processing field '$field_name' in class '$class_name': $(e)"
              throw(ErrorException(error_msg))
          end
      end
  end

  return pass

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
          key in parameters_ignore && continue          
          options[Symbol(key)] = value_parsed
      else
        if field_type in ["ForeignKey", "OneToOneField" ]
          related_model = replace(key_value[1], "\"" => "") |> string
          options[:pk_field] = "id"
        end
      end
  end
  return options, related_model
end

function parse_value(value::AbstractString)
  value = strip(value)
  if value == "True"
      return true
  elseif value == "False"
      return false
  elseif occursin(r"^\d+$", value)
      return parse(Int, value)
  elseif startswith(value, "\"") && endswith(value, "\"")
      return value[2:end-1]  # Remove surrounding quotes
  elseif startswith(value, "(") && endswith(value, ")")
      # Handle nested tuples (e.g., choices)
      return parse_choices(value)
  else
      return value  # Return as string or handle other types as needed
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


end # module Migrations