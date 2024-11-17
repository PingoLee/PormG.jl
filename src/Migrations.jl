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

  import PormG: Models, connection, sqlite_type_map, PormGModel, MODEL_PATH, sqlite_ignore_schema, postgres_ignore_table
  import PormG.Generator: generate_models_from_db

  abstract type Migration end

  struct CreateTable <: Migration
    table_name::String
    columns::Vector{Tuple{String, String}}
  end

  struct DropTable <: Migration
    table_name::String
  end

  struct AddColumn <: Migration
    table_name::String
    column_name::String
    column_type::String
  end

  struct DropColumn <: Migration
    table_name::String
    column_name::String
  end

  struct RenameColumn <: Migration
    table_name::String
    old_column_name::String
    new_column_name::String
  end

  struct AlterColumn <: Migration
    table_name::String
    column_name::String
    new_column_name::String
    new_column_type::String
  end

  struct AddForeignKey <: Migration
    table_name::String
    column_name::String
    foreign_table_name::String
    foreign_column_name::String
  end

  struct DropForeignKey <: Migration
    table_name::String
    column_name::String
  end

  struct AddIndex <: Migration
    table_name::String
    column_name::String
  end

  struct DropIndex <: Migration
    table_name::String
    column_name::String
  end

  function apply_migration(db::SQLite.DB, migration::CreateTable)
    query = "CREATE TABLE IF NOT EXISTS $(migration.table_name) ($(join([col[1] * " " * col[2] for col in migration.columns], ", ")))"
    SQLite.execute(db, query)
  end

  function apply_migration(db::SQLite.DB, migration::DropTable)
    query = "DROP TABLE IF EXISTS $(migration.table_name)"
    SQLite.execute(db, query)
  end

  function apply_migration(db::SQLite.DB, migration::AddColumn)
    query = "ALTER TABLE $(migration.table_name) ADD COLUMN $(migration.column_name) $(migration.column_type)"
    SQLite.execute(db, query)
  end

  function apply_migration(db::SQLite.DB, migration::DropColumn)
    query = "ALTER TABLE $(migration.table_name) DROP COLUMN $(migration.column_name)"
    SQLite.execute(db, query)
  end

  function apply_migration(db::SQLite.DB, migration::RenameColumn)
    query = "ALTER TABLE $(migration.table_name) RENAME COLUMN $(migration.old_column_name) TO $(migration.new_column_name)"
    SQLite.execute(db, query)
  end

  function apply_migration(db::SQLite.DB, migration::AlterColumn)
    query = "ALTER TABLE $(migration.table_name) RENAME COLUMN $(migration.column_name) TO $(migration.new_column_name); ALTER TABLE $(migration.table_name) ALTER COLUMN $(migration.new_column_name) TYPE $(migration.new_column_type)"
    SQLite.execute(db, query)
  end

  function apply_migration(db::SQLite.DB, migration::AddForeignKey)
    query = "ALTER TABLE $(migration.table_name) ADD FOREIGN KEY ($(migration.column_name)) REFERENCES $(migration.foreign_table_name)($(migration.foreign_column_name))"
    SQLite.execute(db, query)
  end

  function apply_migration(db::SQLite.DB, migration::DropForeignKey)
    query = "ALTER TABLE $(migration.table_name) DROP FOREIGN KEY $(migration.column_name)"
    SQLite.execute(db, query)
  end

  function apply_migration(db::SQLite.DB, migration::AddIndex)
    query = "CREATE INDEX IF NOT EXISTS $(migration.table_name)_$(migration.column_name)_index ON $(migration.table_name) ($(migration.column_name))"
    SQLite.execute(db, query)
  end

  function apply_migration(db::SQLite.DB, migration::DropIndex)
    query = "DROP INDEX IF EXISTS $(migration.table_name)_$(migration.column_name)_index"
    SQLite.execute(db, query)
  end

  function apply_migration(db::SQLite.DB, migration::Migration)
    @warn "Migration type not recognized"
  end

  function apply_migrations(db::SQLite.DB, migrations::Vector{Migration})
    for migration in migrations
      apply_migration(db, migration)
    end
  end

  # functions to repreoduce the makemigrations from django
  

  

  function import_models_from_sql(;db::SQLite.DB = connection(), 
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

  # Compare model definitions to the current database schema
  function compare_schemas(models, current_schema)
    differences = Dict()
    for model in models
        model_name = model.name
        if haskey(current_schema, model_name)
            # Compare fields
            for (field_name, field_type) in model.fields
                if !haskey(current_schema[model_name], field_name)
                    differences[model_name] = "New field: $field_name"
                end
                # Additional comparisons for field changes
            end
        else
            differences[model_name] = "New model"
        end
    end
    return differences
  end

  # Generate migration plan based on differences
  function generate_migration_plan(differences)
    plan = []
    for (model_name, change) in differences
        push!(plan, "Apply change to $model_name: $change")
    end
    return plan
  end

  # # Main function to simulate makemigrations
  # function makemigrations()
  #   models = get_all_models()
  #   current_schema = get_current_db_schema()
  #   differences = compare_schemas(models, current_schema)
  #   migration_plan = generate_migration_plan(differences)
  #   # Here you would write the migration_plan to a file or directly apply it
  #   println("Migration plan: ", migration_plan)
  # end

  # # Example usage
  # makemigrations()


#   # sugestion to PostgreSQL

#
# IMPORT MODELS FROM DATABASE POSTGRESQL
#

  
function import_models_from_sql(;db::LibPQ.Connection = connection(), 
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
  
  # Get all schema
  schemas = get_database_schema(db)

  # Collect all create instructions
  Instructions::Vector{Any} = []
  # schemas is a DataFrame
  #   Row │ table_schema  table_name                         columns                            primary_keys  foreign_keys              foreign_tables                     indexes 
  #       │ String?       String?                            String?                            String?       String?                   String?                            String? 
  #  ─────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  #     1 │ public        auth_group                         id integer NOT NULL DEFAULT next…  id            missing                   missing                            missing 
  #     2 │ public        auth_group_permissions             id bigint NOT NULL DEFAULT nextv…  id            group_id, permission_id   public.auth_group, public.auth_p…  missing 
  for (index, schema) in enumerate(eachrow(schemas))
    # check if each ignore_table value is contained in the schema.table_name
    any(ignored -> occursin(ignored, schema.table_name), ignore_table) && continue
    println(typeof(schema))
    return schema
    convertSQLToModel(schema) |> println
    # push!(Instructions, convertSQLToModel(schema) |> Models.Model_to_str)
    index > 4 && break
  end

  # generate_models_from_db(db, file, Instructions)
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
  return replace(read(Loc, String), "'" => "\"")
end

"""
  import_models_from_django(model_py_string::String; db::Union{SQLite.DB, LibPQ.Connection} = connection(), force_replace::Bool = false, ignore_table::Vector{String} = postgres_ignore_table, file::String = "automatic_models.jl", autofields_ignore::Vector{String} = ["Manager"], parameters_ignore::Vector{String} = ["help_text"])

Imports Django models from a given `model.py` file content string and generates corresponding Julia models.

# Arguments
- `model_py_string::String`: The content of the `model.py` file as a string; user django_to_string(path) to read the file.
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
              fields_dict[Symbol(string(field_name, "_id"))] = getfield(Models, Symbol(field_type))(related_model; options...)
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