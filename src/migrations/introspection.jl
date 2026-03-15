# ==============================================================================
# INTROSPECTION LOGIC
# Functions for reading database schemas and converting them to PormG models.
# Handles both SQLite and PostgreSQL.
# ==============================================================================

# ---
# SQLite Introspection
# ---

function _strip_sqlite_default_wrapper(default_val)
  default_val === nothing && return nothing
  ismissing(default_val) && return nothing

  stripped = strip(String(default_val))
  while length(stripped) >= 2 && startswith(stripped, "(") && endswith(stripped, ")")
    inner = strip(stripped[2:end-1])
    inner == stripped && break
    stripped = inner
  end

  return stripped
end

function _normalize_sqlite_default(default_val, type_sym::Symbol)
  stripped = _strip_sqlite_default_wrapper(default_val)
  stripped === nothing && return nothing

  uppercase(stripped) == "NULL" && return nothing

  if type_sym == :BooleanField
    lowered = lowercase(replace(stripped, "'" => "", "\"" => ""))
    lowered in ["1", "true", "t"] && return true
    lowered in ["0", "false", "f"] && return false
  end

  if length(stripped) >= 2 && startswith(stripped, "'") && endswith(stripped, "'")
    return replace(stripped[2:end-1], "''" => "'")
  end

  return stripped
end

function get_database_schema(db::PormGSQLite)
  # Query the sqlite_master table to get the schema information
  schema_query = "SELECT type, name, sql FROM sqlite_master WHERE type='table' OR type='index';"
  schema_info = fetch(db, schema_query)

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
function convertSQLToModel(sql::String; type_map::Dict{String, Symbol} = sqlite_type_map)   

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
    # println(primary_keys)
    for key in primary_keys
      key = strip(key) |> String
      pk_map[key] = Dict("primary_keys" => key, "auto_increment" => auto_increment)
    end
  end

  # Extract any foreign key constraints
  foreign_key_matches = eachmatch(r"FOREIGN KEY\(\"(\w+)\"\) REFERENCES \"(\w+)\"\(\"(\w+)\"\)(?: ON DELETE (CASCADE|SET NULL|NO ACTION|RESTRICT|SET DEFAULT))?(?: ON UPDATE (CASCADE|SET NULL|NO ACTION|RESTRICT|SET DEFAULT))?(?: DEFERRABLE INITIALLY (DEFERRED|IMMEDIATE))?", sql)
  for match in foreign_key_matches
    column_name, fk_table, fk_column, on_delete, on_update, on_deferable = match.captures
    # println(match.captures)
    # typeof(column_name |> String) |> println
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
    type_sym = get(type_map, column_type, :TextField)
    normalized_default = _normalize_sqlite_default(default_value, type_sym)
    # check if column_name is a primary key
    if haskey(pk_map, column_name)
      field_instance = Models.IDField(null=!(nullable === nothing), auto_increment=pk_map[column_name]["auto_increment"])
    elseif haskey(fk_map, column_name)
      field_instance = Models.ForeignKey(fk_map[column_name]["fk_table"] |> string; pk_field=fk_map[column_name]["fk_column"] |> string, on_delete=fk_map[column_name]["on_delete"], 
      on_update=fk_map[column_name]["on_update"], deferrable=!(fk_map[column_name]["on_deferable"] === nothing), null=!(nullable === nothing))
    else
      field_instance = getfield(Models, type_sym)(null=!(nullable === nothing), default=normalized_default)
    end
            
    fields_dict[Symbol(column_name)] = field_instance
  end

  # Construct and return the model
  # Dict(:models => Models.Model(table_name, fields_dict), :str_models => Models.Model(table_name, str_fields_dict))
  # println(fields_dict)
  # println(typeof(table_name))
  return Models.Model(table_name, fields_dict)
end

function convertSQLToModel(db::PormGSQLite, table_name::String; type_map::Dict{String, Symbol} = sqlite_type_map)
  # Use PRAGMA instead of Regex for more reliable introspection
  cols = fetch(db, "PRAGMA table_info(\"$table_name\")") |> DataFrame
  fks = fetch(db, "PRAGMA foreign_key_list(\"$table_name\")") |> DataFrame
  
  fields_dict = Dict{Symbol, Any}()
  fk_map = Dict{String, Any}()
  if !isempty(fks)
    for fk_row in eachrow(fks)
      fk_map[fk_row.from] = fk_row
    end
  end
  
  for col_row in eachrow(cols)
    col_name = col_row.name
    col_type = col_row.type |> uppercase
    # Handle types with length/precision like VARCHAR(255)
    base_type = split(col_type, '(')[1] |> strip
    
    nullable = col_row.notnull == 0
    default_val = ismissing(col_row.dflt_value) ? nothing : col_row.dflt_value
    is_pk = col_row.pk > 0
    
    if is_pk
        # In SQLite, INTEGER PRIMARY KEY often implies AUTOINCREMENT behavior
        field = Models.IDField(null=false, primary_key=true, auto_increment=(base_type == "INTEGER"))
    elseif haskey(fk_map, col_name)
        fk_info = fk_map[col_name]
        field = Models.ForeignKey(fk_info.table; pk_field=fk_info.to, on_delete=fk_info.on_delete, null=nullable)
    else
        type_sym = get(type_map, base_type, :TextField)
        # Handle decimal precision if present
      field = getfield(Models, type_sym)(null=nullable, default=_normalize_sqlite_default(default_val, type_sym))
        if type_sym == :CharField && occursin("(", col_type)
            m = match(r"\((\d+)\)", col_type)
            if m !== nothing
                field.max_length = parse(Int, m.captures[1])
            end
        end
    end
    fields_dict[Symbol(col_name)] = field
  end
  
  return Models.Model(table_name, fields_dict)
end

function convert_schema_to_models(db::PormGSQLite; ignore_table::Vector{String} = sqlite_ignore_schema, include_table::Union{Vector{String}, Nothing} = nothing)
  # Query the sqlite_master table to get the table names
  tables_query = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"
  tables = fetch(db, tables_query) |> DataFrame
  
  models_array::Vector{PormGModel} = []
  for row in eachrow(tables)
    table_name = row.name
    # If include_table is specified, only include those tables
    if include_table !== nothing
      !any(included -> table_name == included, include_table) && continue
    end
    # check if each ignore_table value is contained in the table_name
    any(ignored -> table_name == ignored, ignore_table) && continue
    
    push!(models_array, convertSQLToModel(db, table_name))
  end  
  return models_array
end

# ---
# PostgreSQL Introspection
# ---

"""
  convert_schema_to_models(db::PormGPostgres; ignore_table::Vector{String} = postgres_ignore_table)

Convert the database schema to models.

# Arguments
- `db::PormGPostgres`: The database connection.
- `ignore_table::Vector{String}`: A vector of table names to ignore. Defaults to `postgres_ignore_table`.

# Returns
- `models_array::Vector{Any}`: A vector containing the converted models.

# Description
This function retrieves the database schema and converts it to models. It collects all create instructions and skips tables specified in the `ignore_table` vector. The function prints the type of each schema and returns the schema for debugging purposes. It stops processing after the fifth schema.
"""
function convert_schema_to_models(db::PormGPostgres; ignore_table::Vector{String} = postgres_ignore_table, include_table::Union{Vector{String}, Nothing} = nothing)
  # Get all schema
  schemas = get_database_schema(db)
  # Colect all create instructions

  # println("-----------------------------------------")
  
  models_array::Vector{PormGModel} = []
  for (index, schema) in enumerate(eachrow(schemas))
    # println(schema |> typeof)
    # println(schema)
    # If include_table is specified, only include those tables
    if include_table !== nothing
      !any(included -> schema.table_name == included, include_table) && continue
    end
    # check if each ignore_table value is contained in the schema.table_name
    any(ignored -> occursin(ignored, schema.table_name), ignore_table) && continue
    # println(typeof(schema), " ", convertSQLToModel(schema) |> println)
    
    push!(models_array, convertSQLToModel(schema))
    # index > 4 && break
  end  
  # println(models_array)
  # @infiltrate 
  return models_array
end

function get_database_schema(db::PormGPostgres; schema::Union{String, Nothing} = "public", table::Union{String, Nothing} = nothing)
  # Get PostgreSQL version to check for attidentity support
  version_df = DataFrame(fetch(db, "SELECT split_part(version(), ' ', 2) AS version"))
  pg_version = version_df[1, :version]
  major_version = parse(Int, split(pg_version, ".")[1])
  
  # Build the identity case conditionally
  identity_case = if major_version >= 10
    """
            || CASE
                WHEN a.attidentity = 'a' THEN ' GENE_ALWAYS_IDENTITY'
                WHEN a.attidentity = 'd' THEN ' GENE_BY_DEF_IDENTITY'
                ELSE ''
               END
    """
  else
    ""
  end
  
  # Modified query that adds identity info (if supported) and checks single-column UNIQUE constraints
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
            $(identity_case)
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

  df = DataFrame(fetch(db, query))
  # @infiltrate false
  if nrow(df) == 0
      @warn("No tables found in the database.")
  end

  # println(df)

  return df
end

function get_database_schema(;pickup::Union{PormGSQLite, PormGPostgres} = connection())  
  return get_database_schema(pickup)
end

function get_constraints_fk(conn::PormGPostgres, table_name::Symbol, field_name::String )
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
  WHERE tc.table_name = '$table_name' AND tc.constraint_type = 'FOREIGN KEY' AND kcu.column_name = '$field_name';
  """
  result = fetch(conn, query) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :constraint_name]
end

function get_constraints_index(conn::PormGPostgres, table_name::Symbol, field_name::String)
  query = """
  SELECT indexname
  FROM pg_indexes
  WHERE tablename = '$table_name' AND indexdef LIKE '%$field_name%';
  """
  result = fetch(conn, query) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :indexname]
end

function get_constraints_index(conn::PormGSQLite, table_name::Symbol, field_name::String)
  # table_name is Symbol like :migrationtest
  tname = string(table_name)
  idx_list = fetch(conn, "PRAGMA index_list(\"$tname\")") |> DataFrame
  if isempty(idx_list)
    return nothing
  end
  
  for row in eachrow(idx_list)
    idx_name = row.name
    idx_info = fetch(conn, "PRAGMA index_info(\"$idx_name\")") |> DataFrame
    if !isempty(idx_info) && field_name in idx_info.name
      return idx_name
    end
  end
  return nothing
end

function get_constraints_pk(conn::PormGPostgres, table_name::Symbol, field_name::String )
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
  WHERE tc.constraint_type = 'PRIMARY KEY' AND kcu.column_name = '$field_name' AND ccu.table_name = '$table_name';
  """
  result = fetch(conn, query) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :constraint_name]
end

function get_constraints_unique(conn::PormGPostgres, table_name::String, field_name::String)::String
  query = """
  SELECT tc.constraint_name
  FROM information_schema.table_constraints tc
  JOIN information_schema.constraint_column_usage ccu
  ON tc.constraint_name = ccu.constraint_name
  WHERE tc.table_name = '$table_name' AND tc.constraint_type = 'UNIQUE' AND ccu.column_name = '$field_name';
  """
  result = fetch(conn, query) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :constraint_name]
end

function get_sequence_name(conn::PormGPostgres, table_name::String, field_name::String)::String
  query = """
  SELECT pg_get_serial_sequence('$table_name', '$field_name');
  """
  result = fetch(conn, query) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :pg_get_serial_sequence]
end

function convertSQLToModel(row::DataFrameRow{DataFrame, DataFrames.Index}; type_map::Dict{String, Symbol} = postgres_type_map)
  table_name = row[:table_name]
  columns = split(row[:columns], ", ")
  # println("Table Name: ", table_name)
  # println("Columns: ", columns)
  # println("Row", row)
    
  # Initialize fields dictionary
  fields_dict = Dict{String, PormGField}()

  # Extract primary key constraints
  # row[:primary_keys] is missing for keyless tables (e.g., Lap_times, Pit_stops that have no IDField)
  pk_set = ismissing(row[:primary_keys]) ? Set{String}() : Set(split(row[:primary_keys], ", "))
    
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

  # Extract index information
  index_map = Dict{String, String}()
  if !ismissing(row[:index_columns])
    indexes = split(row[:index_columns], ", ")
    index_names = split(row[:index_names], ", ")
    for (index, index_name) in zip(indexes, index_names)
      index_map[index] = index_name
    end      
  end
   
  # Parse each column definition
  for col in columns    
      col_parts = split(replace(col, "double precision" => "double_precision")
      , " ")
      col_name = col_parts[1]
      col_type = lowercase(col_parts[2])
      generated::Bool = false
      max_length = nothing
      max_digits = nothing
      decimal_places = nothing

      # Detect if the column is indexed
      db_index = haskey(index_map, col_name |> Symbol)

      @infiltrate false

      # Extract max_length if it exists
      if occursin(r"varchar\((\d+)\)", col_type) || occursin(r"char\((\d+)\)", col_type) 
        max_length_match = match(r"\((\d+)\)", col_type)
        if max_length_match !== nothing
          max_length = parse(Int, max_length_match.captures[1])
          col_type = "varchar"
        end
      elseif occursin(r"character varying\((\d+)\)", col)
        max_length_match = match(r"character varying\((\d+)\)", col)
        if max_length_match !== nothing
          max_length = parse(Int, max_length_match.captures[1])
          col_type = "varchar"
        end
      end

      # Extract max_digits and decimal_places if it exists
      if occursin(r"decimal\((\d+),(\d+)\)", col_type) || occursin(r"numeric\((\d+),(\d+)\)", col_type)
        decimal_match = match(r"\((\d+),(\d+)\)", col_type)
        if decimal_match !== nothing
          max_digits = parse(Int, decimal_match.captures[1])
          decimal_places = parse(Int, decimal_match.captures[2])
          col_type = "decimal"
        end
      end
      
      # Determine field type
      field_type = getfield(Models, haskey(type_map, col_type) ? type_map[col_type] : :TextField)
      
      # Determine field constraints
      primary_key::Bool = col_name in pk_set
      unique::Bool = occursin("UNIQUE", col)
      not_null::Bool = occursin("NOT NULL", col)
      default_value = nothing
      if occursin("DEFAULT", col)
        # Match DEFAULT followed by value, handling type casts like ::numeric
        default_match = match(r"DEFAULT\s+((?:\([^)]+\)|[^:\s]+)(?:::[a-zA-Z_]+)?)", col)
        if default_match !== nothing
          raw_default = default_match.captures[1]
          # Clean up the default value: remove type casts and parentheses for simple values
          # e.g., "(0)::numeric" -> "0", "'value'::text" -> "value"
          # TODO: store the type cast if necessary
          cleaned_default = replace(raw_default, r"::[a-zA-Z_]+" => "")  # Remove type cast
          cleaned_default = replace(cleaned_default, r"^\((.+)\)$" => s"\1")  # Remove outer parentheses
          cleaned_default = replace(cleaned_default, r"^'(.+)'$" => s"\1")  # Remove quotes
          default_value = cleaned_default
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

      # @infiltrate col == "qt_referencia bigint DEFAULT (0)::numeric"

      # println(col)
      
      # Create field instance      
      field = if primary_key
          Models.IDField(generated=generated, generated_always=generated_always, unique=true, null=false, db_index=true)
      elseif haskey(fk_map, col_name)
        fk_table, fk_column = fk_map[col_name]
        fk_table = uppercasefirst(fk_table)
        if unique
          Models.OneToOneField(fk_table, pk_field=fk_column, null=!not_null, default=default_value, db_index=true)
        else
          Models.ForeignKey(fk_table, pk_field=fk_column, null=!not_null, default=default_value, db_index=true)
        end
      else
        field_type(unique=unique, null=!not_null, default=default_value, db_index=db_index)
      end

      if max_length !== nothing
        if max_length > 255
          # CharField only supports max_length <= 255, use TextField for longer strings
          field = Models.TextField(unique=unique, null=!not_null, default=default_value, db_index=db_index)
        else
          field.max_length = max_length
        end
      end

      if max_digits !== nothing
        field.max_digits = max_digits
        field.decimal_places = decimal_places
      end
      
      # Add field to fields dictionary
      fields_dict[replace(col_name, "\"" => "")] = field
  end

  # Construct and return the model
  # check if index_map is empty
  model_resp = Models.Model(table_name, fields_dict)
  if !isempty(index_map)   
    model_resp.cache = Dict("index" => index_map)
  end
  @infiltrate false
  return model_resp

end