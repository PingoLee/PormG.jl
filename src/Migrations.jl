# I want creater a django like orm in julia, can you help me?
# Implement a system for database migrations to manage schema changes over time.
# This could involve creating a separate set of scripts or modules that can apply versioned schema changes to the database.
module Migrations
  using DataFrames
  using CSV
  using Dates
  using JSON
  using SQLite

  import PormG: Models, connection, sqlite_type_map, PormGModel

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

  function import_models_from_sql(;db::SQLite.DB = connection(), force_replace::Bool=false, ignore_schema::Vector{String} = [])

    # check if db/models/automatic_models.jl exists
    if isfile("db/models/automatic_models.jl") && !force_replace
      @warn("The file 'db/models/automatic_models.jl' already exists, use force_replace=true to replace it")
      return
    elseif !ispath("db/models")
      mkdir("db/models")
    end
    
    # Get all schema
    schemas = get_database_schema(db=db)

    # Colect all create instructions
    Instructions::Vector{Any} = []
    for schema in schemas
      schema[2]["type"] == "index" && continue    
      println(schema[2]["sql"])
      # push!(Instructions, convertSQLToModel(schema[2]["sql"]))
    end


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
    # Example usage (to depure)
    # sql = """CREATE TABLE \"rel_avan\" (
    #   \"id\"    INTEGER  NOT NULL,
    #   \"nome\" TEXT,
    #   \"function\"    TEXT,
    #   \"ordem\"    INTEGER,
    #   \"rel_id\"    INTEGER,
    #   \"definition\"    TEXT,
    #   PRIMARY KEY(\"id\" AUTOINCREMENT),
    #   FOREIGN KEY(\"rel_id\") REFERENCES \"opc_cruz_rel\"(\"id\")
    # )"""
    
    # sql = """CREATE TABLE \"example3\" (
    #   \"first_name\" TEXT,
    #   \"last_name\" TEXT,
    #   \"cpf\" NUMERIC,
    #   PRIMARY KEY (\"first_name\", \"last_name\", \"cpf\")
    # );"""
    # sql = """CREATE TABLE \"example4\" (
    #   \"id\" INTEGER NOT NULL,
    #   \"name\" TEXT,
    #   PRIMARY KEY (\"id\")
    # );"""

    sql = "CREATE TABLE \"defs_prob\" (\n\t\"id\"\tINTEGER NOT NULL UNIQUE,\n\t\"npm\"\tNUMERIC NOT NULL,\n\t\"npu\"\tNUMERIC NOT NULL,\n\t\"mpm\"\tNUMERIC NOT NULL,\n\t\"mpu\"\tNUMERIC NOT NULL,\n\t\"dnpm\"\tNUMERIC NOT NULL,\n\t\"dnpu\"\tNUMERIC NOT NULL,\n\t\"lim_n\"\tNUMERIC NOT NULL,\n\t\"lim_m\"\tNUMERIC NOT NULL,\n\t\"lim_dn\"\tNUMERIC NOT NULL,\n\t\"desc\"\tTEXT NOT NULL DEFAULT 'Novo',\n\tPRIMARY KEY(\"id\" AUTOINCREMENT)\n)"


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
      if haskey(pk_map, "primary_keys")
        if column_name in pk_map["primary_keys"]
          field_instance = Models.IDField(null=!(nullable === nothing), auto_increment=pk_map["auto_increment"])
          # str_fields_dict[column_name] = "IDField(null=$(!(nullable === nothing)), auto_increment=$(pk_map["auto_increment"]))"
        else
          field_instance = getfield(Models, type_map[column_type])(null=!(nullable === nothing), default=default_value)
          # str_fields_dict[column_name] = "$(type_map[column_type] |> string)(null=$(!(nullable === nothing)), default=$default_value)"
        end
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