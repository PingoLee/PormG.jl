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
        field_instance = getfield(Models, type_map[column_type])(null=!(nullable === nothing), default= default_value == nothing ? default_value : replace(default_value, "'" => ""))
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


# IMPORT MODELS FROM model.py
function import_models_from_django(model_str::String;
                                    db::Union{SQLite.DB, LibPQ.Connection} = connection(),
                                    force_replace::Bool=false, 
                                    ignore_table::Vector{String} = postgres_ignore_table,
                                    file::String="automatic_models.jl")
  # check if db/models/automatic_models.jl exists
  if !isfile(model_str)
    @warn("The file $(model_str) does not exists")
    return
  end

  # check if db/models/automatic_models.jl exists
  if isfile(joinpath(MODEL_PATH, file)) && !force_replace
      @warn("The file 'db/models/automatic_models.jl' already exists, use force_replace=true to replace it")
      return
  elseif !ispath(joinpath(MODEL_PATH))
      mkdir(joinpath(MODEL_PATH))
  end

  # Read the file
  model_py_string = read(model_str, String)

  # Get all schema
  model_regex = r"class\s+(\w+)\(models\.Model\):\n((?:\s*#[^\n]*\n|\s*[^\n]+\n)*?)(?=(\n+)?class\s|\Z)" 
  field_regex = r"\s*(\w+)\s*=\s*models\.(\w+)\(([^)]*)\)"
  
 
  for match in eachmatch(model_regex, model_py_string, overlap = true)
    println(match)
    
    class_content = match.captures[2]  # Extract the class content

    # Further process class_content:
    #   - Use regex to extract field names, types, and options
    #   - Translate Python types to corresponding Julia types
    #   - Generate Julia structs or types to represent the models
    
    println(class_name)
    println("oooo")
    println(class_content)

    # Extract table name
    class_name = match.captures[1]  # Extract the class name

    # Define a dictionary to map SQL types to Models.jl field types
    check_pk::Bool = false
    fk_map::Dict{String, Any} = Dict{String, Any}()
    pk_map::Dict{String, Any} = Dict{String, Any}()

    # Iterate over the fields in the class content
    fields_dict = Dict{Symbol, Any}()
    for match in eachmatch(field_regex, class_content)
      field_name = match.captures[1]
      field_type = match.captures[2]
      field_options = match.captures[3]      

      
                  
      # Parse field options
      options = Dict{String, Any}()
      capture::Bool = true
      for option in split(field_options, ",")
        key_value = split(option, "=")
        if length(key_value) == 2
          key = strip(key_value[1])
          value = strip(key_value[2])
          # primary key are not suported yeat
          if key == "primary_key"
            @warn("Primary key is not supported yet, the field $field_name will be ignored in model $class_name")
            capture = false
          end
          options[key] = value
        end
      end

      # Check if the field is a primary key

      # # Generate the field instance
      if capture
        fields_dict[Symbol(field_name)] = getfield(Models, field_type)(options...)
      end
          
    end
    
  end

end

end # module Migrations