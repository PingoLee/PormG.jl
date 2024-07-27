# I want creater a django like orm in julia, can you help me?
# Implement a system for database migrations to manage schema changes over time.
# This could involve creating a separate set of scripts or modules that can apply versioned schema changes to the database.
module Migrations
  using DataFrames
  using CSV
  using Dates
  using JSON
  using SQLite

  import PormG: Models, connection, sqlite_type_map, PormGModel, MODEL_PATH, sqlite_ignore_schema
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
  

  # Assuming a function that can return all defined models
  function get_all_models(modules::Module)
    model_names = []
    for name in names(modules; all=true, imported=true)
        # Check if the attribute is an instance of Model_Type
        attr = getfield(modules, name)
        if isa(attr, Models.Model_Type)
            push!(model_names, attr)
        end
    end
    return model_names
  end

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
    schemas = get_database_schema(db=db)

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

  function get_database_schema(;db::SQLite.DB = connection())
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
    fk_map::Union{Dict{String, Any},Nothing} = nothing
    pk_map::Union{Dict{String, Any},Nothing} = nothing

    # Extract any primary key constraints
    # primary_key_regex = eachmatch(r"PRIMARY KEY\s*\((.+?)\)", sql)
    primary_key_regex = eachmatch(r"PRIMARY KEY\s*\((.+?)\)?\s*(AUTOINCREMENT)?\)", sql)
    for match in primary_key_regex
      primary_keys = match.captures[1]
      primary_keys = replace(primary_keys, r"\"" => "") 
      primary_keys = split(primary_keys, ",")
      auto_increment = isnothing(match.captures[2]) ? false : true
      pk_map = Dict("primary_keys" => primary_keys, "auto_increment" => auto_increment)
    end

    # Extract any foreign key constraints
    foreign_key_matches = eachmatch(r"FOREIGN KEY\(\"(\w+)\"\) REFERENCES \"(\w+)\"\(\"(\w+)\"\)(?: ON DELETE (CASCADE|SET NULL|NO ACTION|RESTRICT|SET DEFAULT))?(?: ON UPDATE (CASCADE|SET NULL|NO ACTION|RESTRICT|SET DEFAULT))?(?: DEFERRABLE INITIALLY (DEFERRED|IMMEDIATE))?", sql)
    for match in foreign_key_matches
      column_name, fk_table, fk_column, on_delete, on_update, on_deferable = match.captures
      println(match.captures)
      fk_map = Dict("column_name" => column_name, "fk_table" => fk_table, "fk_column" => fk_column, "on_delete" => on_delete, "on_update" => on_update, "on_deferable" => on_deferable)
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
        if pk_map !== nothing && haskey(pk_map, "primary_keys") && column_name in pk_map["primary_keys"]
          field_instance = Models.IDField(null=!(nullable === nothing), auto_increment=pk_map["auto_increment"])
        elseif fk_map !== nothing && haskey(fk_map, "column_name") && column_name == fk_map["column_name"]
          field_instance = Models.ForeignKey(fk_map["fk_table"] |> string; pk_field=fk_map["fk_column"] |> string, on_delete=fk_map["on_delete"], on_update=fk_map["on_update"], deferrable=!(fk_map["on_deferable"] === nothing), null=!(nullable === nothing))
        else
          field_instance = getfield(Models, type_map[column_type])(null=!(nullable === nothing), default= default_value == nothing ? default_value : replace(default_value, "'" => ""))
        end
              
      fields_dict[Symbol(column_name)] = field_instance
    end

    # Construct and return the model
    # Dict(:models => Models.Model(table_name, fields_dict), :str_models => Models.Model(table_name, str_fields_dict))
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

  

end # module Migrations