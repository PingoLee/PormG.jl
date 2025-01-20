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
import OrderedCollections: OrderedDict
import Random: randstring

import ..PormG.Infiltrator: @infiltrate

import ..PormG: Models, connection, config, sqlite_type_map, postgres_type_map, PormGModel, SQLConn, PormGField, MODEL_PATH, sqlite_ignore_schema, postgres_ignore_table, Migration, Dialect
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

function _drop_fk_constraint(conn::LibPQ.Connection, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, field_name::String, new_field::PormGField, old_field::PormGField)::Nothing
  if hasfield(old_field |> typeof, :to) && old_field.db_constraint && (!hasfield(new_field |> typeof, :to) || !new_field.db_constraint)
    constraint_name = get_constraints(conn, model_name)
    _configure_order_dict_migration_plan(migration_plan, model_name, "Remove foreign key: $field_name", 
    Dialect.drop_foreign_key(conn, model_name, "\"$(constraint_name[1][1])\""))
  end
  return nothing
end

function _add_fk_constraint(conn::LibPQ.Connection, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, field_name::String, new_field::PormGField, old_field::PormGField)::Nothing
  if hasfield(new_field |> typeof, :to) && new_field.db_constraint && (!hasfield(old_field |> typeof, :to) || !old_field.db_constraint)
    constraint_name = "$(model_name)_$(field_name)_fk" |> lowercase
    _configure_order_dict_migration_plan(migration_plan, model_name, "New foreign key: $field_name", 
    Dialect.add_foreign_key(conn, model_name, "\"$constraint_name\"", "\"$field_name\"",  "\"$(new_field.to |> lowercase)\"", "\"$(new_field.pk_field)\""))
  end
  return nothing
end

# Compare model definitions to the current database schema
function get_migration_plan(models::Vector{PormGModel}, current_schema::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}, conn)
  # models is olds models

  migration_plan = OrderedDict{Symbol, OrderedDict{String, String}}()
  futher_processing = Dict{Symbol, Dict{Symbol, Any}}()

  # models is empty set all models to migration_plan
  if isempty(models)
    for (model_name, model) in current_schema
      _configure_order_dict_migration_plan(migration_plan, model_name, "New model", Dialect.create_table(conn, model))
      for (field_name, field) in model.fields       
        _hash = randstring(8) 
        name = "$(model_name)_$field_name"
        if length(name) + length(_hash) > 63
          name = name[1:63 - length(_hash)]
        end
        

        # If new field is a foreign key
        if hasfield(field |> typeof, :to) && !field.db_constraint
          constraint_name = name * "_$_hash" * "_fk" |> lowercase
          _configure_order_dict_migration_plan(migration_plan, model_name, "New foreign key: $field_name", 
          Dialect.add_foreign_key(conn, model.name, "\"$constraint_name\"", "\"$field_name\"",  "\"$(field.to |> lowercase)\"", "\"$(field.pk_field)\""))
        end

        # If new field is also indexed
        if field.db_index 
          index_name = name * "_$_hash" |> lowercase
          _configure_order_dict_migration_plan(migration_plan, model_name, "Create index on $field_name", 
          Dialect.create_index(conn, "\"$index_name\"", "\"$(model.name |> lowercase)\"", ["\"$field_name\""]))
        end
      
        
      end

    end
    return migration_plan
  
  end

  println("-------------------------------------")
  @infiltrate false

  for model in models # models is olds models
    model_name = model.name |> Symbol
    println("Model: ", model_name)
    @infiltrate false 
    if haskey(current_schema, model_name)
      current_schema[model_name][:exist] = true
      if Models.are_model_fields_equal(model, current_schema[model_name][:model])
        println("Model $model_name are equal")
      else        
        # Compare fields
        @infiltrate false
        for (field_name, field) in  current_schema[model_name][:model].fields
          if haskey(model.fields, field_name)
            println("Fields $field_name")
            @infiltrate false
           
            if model.fields[field_name] |> typeof == field |> typeof && Models._compare_model_field(field, model.fields[field_name])


            else              
              @infiltrate false
              # check if the field is diferent
              colect_not_equal::Vector{Symbol} = []
              if model.fields[field_name] |> typeof == field |> typeof                          
                # Check if all attributes are equal                
                for attr in fieldnames(typeof(field))
                  new_var = getfield(field, attr)
                  old_var = getfield(model.fields[field_name], attr)
                  if new_var != old_var
                    (attr == :to && new_var |> lowercase == old_var |> lowercase) && continue
                    attr == :on_delete && continue # TODO: on_delete does managede by application ?
                    push!(colect_not_equal, attr)
                  end
                end
              end

              # Check if is needed remove the foreign key
              _drop_fk_constraint(conn, migration_plan, model_name, field_name, field, model.fields[field_name])
              
              _configure_order_dict_migration_plan(migration_plan, model_name, "Alter field: $field_name",
              Dialect.alter_field(conn, model_name |> string, field_name, field))

              # Check if the field is a foreign key
              _add_fk_constraint(conn, migration_plan, model_name, field_name, field, model.fields[field_name])

              # Check if the field is also indexed
              if field.db_index && !model.fields[field_name].db_index
                index_name = model_name * "_$field_name" |> lowercase
                _configure_order_dict_migration_plan(migration_plan, model_name, "Create index on $field_name", 
                Dialect.create_index(conn, "\"$index_name\"", "\"$(model.name |> lowercase)\"", ["\"$field_name\""]))
              end

              # Check if is need to remove the index
              if model.fields[field_name].db_index && !field.db_index
                index_name = model_name * "_$field_name" |> lowercase
                _configure_order_dict_migration_plan(migration_plan, model_name, "Remove index on $field_name", 
                Dialect.drop_index(conn, "\"$index_name\""))
              end

            end 
          else
          end
        end

      
      end      
    else
      
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
  # models_array::Vector{Any} = []
  models_array = convert_schema_to_models(connection)
  # println(models_array |> typeof)

  # try
  #   models_array = convert_schema_to_models(connection)
  # catch e
  #   error_message = sprint(showerror, e)
  #   if occursin("Table definition not found", error_message)
  #     @info("The database is empty, that is migrate all tables") # TODO, impruve this message
  #   else
  #     println("Error: ", e)
  #     @error("Error: ", e)
  #     return
  #   end
  # end
  # get module from the path
  # println(models_array)
  current_models = get_all_models(include(path))
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

function get_all_models(mod::Module)::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}
  # Get all models from a module
  models = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}()
  for name in names(mod, all = true)
    if isdefined(mod, name)
      obj = getfield(mod, name)
      if isa(obj, PormGModel)
        models[name |> string |> lowercase |> Symbol] = Dict{Symbol, Union{Bool, PormGModel}}(:model => obj, :exist => false) # TODO: change model.name to lowercase in all project
      end
    end
  end
  return models
end

# ---
# Functions to apply migrations
#

function get_all_dicts(mod::Module)
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
  migration_plan = include(joinpath(settings.db_def_folder, "migrations", "pending_migrations.jl")) |> get_all_dicts

  # build the transaction to apply the migration plan
  fisrt_execution::Vector{String} = []
  last_execution::Vector{String} = []

  for dict_instructs in migration_plan
    println("Executing: $dict_instructs")
    for (key, value) in dict_instructs
      if key == "New model"
        push!(fisrt_execution, value)
      else
        push!(last_execution, value)
      end
    end
  
  end

  # Begin a transaction
  LibPQ.execute(connection, "BEGIN;")

  try
    # Iterate over the migration plan and execute each SQL statement
    for action in fisrt_execution
      println("Executing: $action")
      LibPQ.execute(connection, action)
    end
    for action in last_execution
      println("Executing: $action")
      LibPQ.execute(connection, action)
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

  # println("-----------------------------------------")
  
  models_array::Vector{PormGModel} = []
  for (index, schema) in enumerate(eachrow(schemas))
    # println(schema |> typeof)
    # println(schema)
    # check if each ignore_table value is contained in the schema.table_name
    any(ignored -> occursin(ignored, schema.table_name), ignore_table) && continue
    # println(typeof(schema), " ", convertSQLToModel(schema) |> println)
    
    push!(models_array, convertSQLToModel(schema))
    # index > 4 && break
  end  
  # println(models_array)
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
  # Modified query that adds identity info and checks single-column UNIQUE constraints
  query = """
    WITH unique_constraints AS (
        SELECT
            con.conrelid AS table_oid,
            array_agg(a.attname) AS unique_cols
        FROM pg_constraint con
        JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = ANY(con.conkey)
        WHERE con.contype = 'u'
        GROUP BY con.conrelid
    ),
    foreign_keys AS (
        SELECT
            con.conrelid,
            array_to_string(array_agg(quote_ident(att2.attname)), ', ') AS fk_cols,
            array_to_string(array_agg(quote_ident(cf.relname)), ', ') AS fk_tables,
            array_to_string(array_agg(quote_ident(pk_att.attname)), ', ') AS referenced_primary_keys,
            array_to_string(array_agg(con.condeferrable::text), ', ') AS deferrable,
            array_to_string(array_agg(con.condeferred::text), ', ') AS initially_deferred
        FROM pg_constraint con
        JOIN pg_attribute att2 ON att2.attnum = ANY(con.conkey) AND att2.attrelid = con.conrelid
        JOIN pg_class cf ON cf.oid = con.confrelid
        JOIN pg_namespace nf ON nf.oid = cf.relnamespace
        JOIN pg_index pk_idx ON pk_idx.indrelid = cf.oid AND pk_idx.indisprimary
        JOIN pg_attribute pk_att ON pk_att.attrelid = pk_idx.indrelid AND pk_att.attnum = ANY(pk_idx.indkey)
        WHERE con.contype = 'f'
        GROUP BY con.conrelid
    ),
    indexes AS (
        SELECT
            i.indrelid AS table_oid,
            array_to_string(array_agg(quote_ident(a.attname)), ', ') AS index_columns,
            array_to_string(array_agg(quote_ident(c.relname)), ', ') AS index_names
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE NOT i.indisprimary
        GROUP BY i.indrelid
    )
    SELECT
        n.nspname AS table_schema,
        c.relname AS table_name,
        array_to_string(array_agg(
            quote_ident(a.attname)
            || ' ' || format_type(a.atttypid, a.atttypmod)
            || CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END
            || CASE WHEN ad.adbin IS NOT NULL THEN ' DEFAULT ' || pg_get_expr(ad.adbin, ad.adrelid) ELSE '' END
            || CASE
                WHEN a.attidentity = 'a' THEN ' GENE_ALWAYS_IDENTITY'
                WHEN a.attidentity = 'd' THEN ' GENE_BY_DEF_IDENTITY'
                ELSE ''
               END
            || CASE
                WHEN array_length(u.unique_cols, 1) = 1
                     AND a.attname = ANY(u.unique_cols) THEN ' UNIQUE'
                ELSE ''
               END
        ), ', ') AS columns,
        pk.pk_cols AS primary_keys,
        fk.fk_cols AS foreign_keys,
        fk.fk_tables AS foreign_tables,
        fk.referenced_primary_keys AS referenced_primary_keys,
        fk.deferrable AS deferrable,
        fk.initially_deferred AS initially_deferred,
        ix.index_columns AS index_columns,
        ix.index_names AS index_names
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
    LEFT JOIN foreign_keys fk ON fk.conrelid = c.oid
    LEFT JOIN indexes ix ON ix.table_oid = c.oid
    LEFT JOIN unique_constraints u ON u.table_oid = c.oid
    WHERE c.relkind = 'r'
      $(schema === nothing ? "" : "AND n.nspname = '$(schema)'")
      $(table === nothing ? "" : "AND c.relname = '$(table)'")
      AND a.attnum > 0
      AND NOT a.attisdropped
    GROUP BY n.nspname, c.relname, pk.pk_cols, fk.fk_cols, fk.fk_tables, fk.referenced_primary_keys, fk.deferrable, fk.initially_deferred, ix.index_columns, ix.index_names, u.unique_cols
    ORDER BY table_schema, table_name;
    """

  df = DataFrame(LibPQ.execute(db, query))
  if nrow(df) == 0
      error("No matching table definitions found.")
  end

  println(df)

  return df
end

function get_constraints(conn::LibPQ.Connection, table_name::Symbol)::Vector{Tuple{String, String, String}}
  query = """
  SELECT
      tc.constraint_name, kcu.column_name,
      ccu.table_name AS foreign_table_name,
      ccu.column_name AS foreign_column_name
  FROM 
      information_schema.table_constraints AS tc 
      JOIN information_schema.key_column_usage AS kcu
        ON tc.constraint_name = kcu.constraint_name
      JOIN information_schema.constraint_column_usage AS ccu
        ON ccu.constraint_name = tc.constraint_name
  WHERE tc.table_name = '$table_name' AND tc.constraint_type = 'FOREIGN KEY';
  """
  result = LibPQ.execute(conn, query) |> DataFrame
  return [(row[1], row[2], row[3]) for row in eachrow(result)]
end


function convertSQLToModel(row::DataFrameRow{DataFrame, DataFrames.Index}; type_map::Dict{String, Symbol} = postgres_type_map)
  table_name = row[:table_name]
  columns = split(row[:columns], ", ")
  # println("Table Name: ", table_name)
  # println("Columns: ", columns)
  
  # Initialize fields dictionary
  fields_dict = Dict{String, PormGField}()

  # Extract primary key constraints
  pk_set = Set(split(row[:primary_keys], ", "))
    
  # Extract foreign key constraints
  fk_map = Dict{String, Tuple{String, String}}()
  if row[:foreign_keys] |> !ismissing
    fk_columns = split(row[:foreign_keys], ", ")
    fk_tables = split(row[:foreign_tables], ", ")
    fk_pk_columns = split(row[:referenced_primary_keys], ", ")  
    for (fk_col, fk_table, fk_pk) in zip(fk_columns, fk_tables, fk_pk_columns)
        fk_map[fk_col] = (fk_table, fk_pk) 
    end
  end
   
  # Parse each column definition
  for col in columns
      col_parts = split(col, " ")
      col_name = col_parts[1]
      col_type = lowercase(col_parts[2])
      generated::Bool = false
      
      # Determine field type
      field_type = getfield(Models, haskey(type_map, col_type) ? type_map[col_type] : :TextField)
      
      # Determine field constraints
      primary_key::Bool = col_name in pk_set
      unique::Bool = occursin("UNIQUE", col)
      not_null::Bool = occursin("NOT NULL", col)
      default_value = nothing
      default_value = nothing
      if occursin("DEFAULT", col)
          default_match = match(r"DEFAULT\s+([^ ]+)", col)
          if default_match !== nothing
              default_value = default_match.captures[1]
          end
      end
      if primary_key
        if occursin("GENE_BY_DEF_IDENTITY", col)
          generated = true
          generated_always = false
        elseif occursin("GENE_ALWAYS_IDENTITY", col)
          generated = true
          generated_always = true
        else 
          generated = false
          generated_always = false
        end
      end

      # println("Col", col)
      # println("Column Name: ", col_name)
      # println("Column Type: ", col_type)
      # println("Primary Key: ", primary_key)
      # println("Unique: ", unique)
      # println("Not Null: ", not_null)
      # println("Default Value: ", default_value)
      # println("Generated: ", generated)
      
      # Create field instance
      @infiltrate false
      field = if primary_key
        @infiltrate false
        Models.IDField(generated=generated, generated_always=generated_always)
      elseif haskey(fk_map, col_name)
        fk_table, fk_column = fk_map[col_name]
        if unique
          Models.OneToOneField(fk_table, pk_field=fk_column, null=!not_null, default=default_value)
        else
          Models.ForeignKey(fk_table, pk_field=fk_column, null=!not_null, default=default_value)
        end
      else
        field_type(unique=unique, null=!not_null, default=default_value)
      end
      
      # Add field to fields dictionary
      fields_dict[col_name |> string] = field
  end

  # Construct and return the model
  return Models.Model(table_name, fields_dict)
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