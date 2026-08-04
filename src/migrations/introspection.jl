# ==============================================================================
# INTROSPECTION LOGIC
# Functions for reading database schemas and converting them to PormG models.
# Handles both SQLite and PostgreSQL.
# ==============================================================================

# ---
# Shared FK helpers (both backends)
# ---

# A foreign key's column default, coerced to what `ForeignKey`/`OneToOneField` accept, or `nothing`.
#
# FAILURE POLICY (#292): introspection NEVER throws over a default it cannot represent. The field
# constructors run `validate_default(default, Union{Int64, Nothing}, …, format2int64)`, which raises
# `FieldValidationError` on anything non-numeric — a text default on a text FK column, a PostgreSQL
# expression default like `nextval(...)`. Letting that escape would abort an entire
# `convert_schema_to_models` run over one odd column, with no way to skip past it. So: warn, naming
# the table, column and raw value, and emit the FK without a `default=`.
#
# THE RESIDUAL, stated rather than hidden. This policy covers the *default*, not a self-contradictory
# *action*, so `set_models` still rejects two shapes — deliberately, because the database really is
# in a state PormG cannot express and silently dropping the action would hide it:
#
#   1. `SET_DEFAULT` on a column with no default (or an unrepresentable one) — #287's guard.
#   2. `SET_NULL` on a NOT NULL column — #287's other guard.
#
# Both are legal DDL on both backends (the action is only enforced at delete time), and PostgreSQL
# reaches them for the first time as of #292, because before it the PostgreSQL path never emitted
# `on_delete` at all and so could not contradict anything. The `@warn` above is what names the
# column for case 1; case 2 surfaces at registration with the model and field named. See the
# `## Unreleased` entry in UPGRADING.md.
#
# Shared by all three FK branches — the two SQLite ones and the PostgreSQL one. Before #292 the
# SQLite branches dropped the default silently and PostgreSQL passed it through unguarded, so this
# closes an existing PostgreSQL exposure as well as the SQLite gap it was written for.
function _fk_default_or_warn(default_val, table_name, column_name)
  default_val === nothing && return nothing
  ismissing(default_val) && return nothing

  try
    # `Bool <: Integer`, so a SQLite 0/1 boolean default converts to 0/1 — which is what the
    # column actually stores. Inside the `try` on purpose: `Int64(::UInt64)` past `typemax(Int64)`
    # raises `InexactError`, and the whole point of this helper is that no input escapes as a throw.
    default_val isa Integer && return Int64(default_val)
    return Models.format2int64(default_val)
  catch e
    # Program-state failures are not "this default is unrepresentable" — same carve-out the
    # `Model_to_str` render-failure path uses (Models.jl), so Ctrl-C during a large
    # `convert_schema_to_models` run aborts instead of being reported as a bad default.
    (e isa InterruptException || e isa StackOverflowError) && rethrow()
    # The value is shown as introspection received it. On PostgreSQL that is the column regex's
    # already-cleaned form, so an expression default can appear truncated at a `::` cast — enough
    # to identify the column, not a faithful reproduction of the DDL.
    @warn "Foreign key default could not be represented as a field default; emitting the relation without it." table = string(table_name) column = string(column_name) default = string(default_val)
    return nothing
  end
end

# PormG's `on_delete === nothing` and `DO_NOTHING` both render as SQL `ON DELETE NO ACTION`
# (`_foreign_key_on_delete_sql`, Dialect.jl), so a "NO ACTION" read back out of a database is
# ambiguous — and `NO ACTION` is also what a backend stores when no action was declared at all.
# Introspecting it as `DO_NOTHING` would therefore stamp an explicit `on_delete=DO_NOTHING` onto
# EVERY plain foreign key in every generated model. Mapping it to `nothing` is lossless (the
# re-emitted DDL is identical either way) and keeps the two backends agreeing: PostgreSQL stores
# `confdeltype = 'a'` for the same two cases.
#
# `PROTECT` is not recoverable — it renders as SQL `RESTRICT`, so a round trip can only ever return
# `RESTRICT`. One-way by construction, not an oversight.
#
# PostgreSQL stores the action as a single char in `pg_constraint.confdeltype`. `'a'` (NO ACTION)
# maps to `nothing` for the reason above; an empty/unknown code does too, so a schema-query result
# predating #292 degrades to today's behaviour instead of erroring.
function _pg_confdeltype_to_on_delete(code)
  code === nothing && return nothing
  ismissing(code) && return nothing
  c = strip(string(code))
  c == "c" && return "CASCADE"
  c == "r" && return "RESTRICT"
  c == "n" && return "SET NULL"
  c == "d" && return "SET DEFAULT"
  return nothing   # 'a' (NO ACTION) and anything unrecognised
end

function _normalize_introspected_on_delete(action)
  action === nothing && return nothing
  ismissing(action) && return nothing
  normalized = uppercase(replace(strip(string(action)), r"\s+" => "_"))
  (isempty(normalized) || normalized == "NO_ACTION") && return nothing
  return normalized
end

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
  elseif length(stripped) >= 2 && startswith(stripped, "\"") && endswith(stripped, "\"")
    return replace(stripped[2:end-1], "\"\"" => "\"")
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
  table_name = table_name_match !== nothing ? table_name_match.captures[1] :
    throw(InvalidMigrationError("Cannot introspect: CREATE TABLE statement has no double-quoted table name (table created outside PormG?): $(first(sql, 120))"))

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

  
  # Extend regex to capture PRIMARY KEY and FOREIGN KEY constraints.
  # The type group allows a trailing UNSIGNED so the two-word declared type of
  # PositiveIntegerField ("INTEGER UNSIGNED") round-trips instead of degrading
  # to IntegerField.
  column_matches = eachmatch(r"[^(]\"(\w+)\"\s+([A-Z]+(?: UNSIGNED)?)\s*(NOT NULL)?\s*(?:DEFAULT\s+('[^']*'|[^,]*))?", sql)
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
      # `default=` was computed above but never reached this branch before #292, so an FK declared
      # ON DELETE SET DEFAULT introspected to `SET_DEFAULT` with no default — which since #287
      # throws `ModelDefinitionError` at `set_models`, and regenerating produced the identical
      # broken file. Routed through `_fk_default_or_warn` so an unrepresentable default warns
      # rather than throwing from inside introspection.
      field_instance = Models.ForeignKey(uppercasefirst(fk_map[column_name]["fk_table"] |> string); pk_field=fk_map[column_name]["fk_column"] |> string,
      on_delete=_normalize_introspected_on_delete(fk_map[column_name]["on_delete"]),
      on_update=fk_map[column_name]["on_update"], deferrable=!(fk_map[column_name]["on_deferable"] === nothing), null=!(nullable === nothing),
      default=_fk_default_or_warn(normalized_default, table_name, column_name))
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
        # Same #292 gap as the DDL-regex path above: `default_val` was in scope and used two
        # branches down, but never passed to the FK. This is the path the live
        # `convert_schema_to_models(::PormGSQLite)` actually reaches. The FK column's declared type
        # drives normalization the same way a non-FK column's does.
        fk_type_sym = get(type_map, base_type, :TextField)
        field = Models.ForeignKey(uppercasefirst(fk_info.table); pk_field=fk_info.to,
            on_delete=_normalize_introspected_on_delete(fk_info.on_delete), null=nullable,
            default=_fk_default_or_warn(_normalize_sqlite_default(default_val, fk_type_sym), table_name, col_name))
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
  # Always skip consumer-registered framework tables (e.g. Nitro's), on top of the caller's list.
  ignore_table = unique(vcat(ignore_table, _EXTRA_IGNORE_TABLES[]))
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
  # Always skip consumer-registered framework tables (e.g. Nitro's), on top of the caller's list.
  ignore_table = unique(vcat(ignore_table, _EXTRA_IGNORE_TABLES[]))
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
  # @pormg_debug 
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
            array_to_string(array_agg(con.condeferred::text), ', ') AS initially_deferred,
            -- #292: the referential action was never selected, so every introspected PostgreSQL FK
            -- came back claiming no ON DELETE. Single-char codes: a=NO ACTION, r=RESTRICT,
            -- c=CASCADE, n=SET NULL, d=SET DEFAULT. Aggregated in the same order as fk_cols so the
            -- zip in convertSQLToModel stays aligned.
            array_to_string(array_agg(con.confdeltype::text), ', ') AS delete_rules
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
    ),
    non_negative_checks AS (
        SELECT
            con.conrelid AS table_oid,
            array_agg(a.attname) AS check_cols
        FROM pg_constraint con
        JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = ANY(con.conkey)
        WHERE con.contype = 'c'
          AND array_length(con.conkey, 1) = 1
          AND pg_get_constraintdef(con.oid) LIKE '%>= 0%'
        GROUP BY con.conrelid
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
            || CASE
                WHEN nn.check_cols IS NOT NULL
                     AND a.attname = ANY(nn.check_cols) THEN ' NON_NEGATIVE_CHECK'
                ELSE ''
               END
        ), ', ') AS columns,
        pk.pk_cols AS primary_keys,
        fk.fk_cols AS foreign_keys,
        fk.fk_tables AS foreign_tables,
        fk.referenced_primary_keys AS referenced_primary_keys,
        fk.deferrable AS deferrable,
        fk.initially_deferred AS initially_deferred,
        fk.delete_rules AS delete_rules,
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
    LEFT JOIN non_negative_checks nn ON nn.table_oid = c.oid
    WHERE c.relkind = 'r'
      $(schema === nothing ? "" : "AND n.nspname = '$(schema)'")
      $(table === nothing ? "" : "AND c.relname = '$(table)'")
      AND a.attnum > 0
      AND NOT a.attisdropped
    GROUP BY n.nspname, c.relname, pk.pk_cols, fk.fk_cols, fk.fk_tables, fk.referenced_primary_keys, fk.deferrable, fk.initially_deferred, fk.delete_rules, ix.index_columns, ix.index_names, u.unique_cols, nn.check_cols
    ORDER BY table_schema, table_name;
    """

  df = DataFrame(fetch(db, query))
  # @pormg_debug false
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

# #151: SQLite introspection does not populate `field.unique` (see convertSQLToModel(::PormGSQLite)), so the
# deletion path can't trust the old field's attribute — probe the live schema for a UNIQUE index covering
# `field_name`. That covers the column-level UNIQUE auto-index (`sqlite_autoindex_…`, which `DROP INDEX`
# can't remove) as well as any `CREATE UNIQUE INDEX`. Such a column is refused by `ALTER TABLE DROP COLUMN`,
# so its deletion must route through a table rebuild (same remedy #116 uses for FK columns).
function _sqlite_column_is_unique(conn::PormGSQLite, table_name, field_name::String)::Bool
  idx_list = fetch(conn, "PRAGMA index_list(\"$(string(table_name))\")") |> DataFrame
  isempty(idx_list) && return false
  for row in eachrow(idx_list)
    row.unique == 1 || continue
    idx_info = fetch(conn, "PRAGMA index_info(\"$(row.name)\")") |> DataFrame
    (!isempty(idx_info) && field_name in idx_info.name) && return true
  end
  return false
end

"""
    get_secondary_index_ddls(conn::PormGSQLite, table_name) -> Vector{String}

Return the `CREATE INDEX` DDL for every *user-created* secondary index on `table_name`, verbatim from
`sqlite_master`. Auto-indexes backing column-level `UNIQUE` constraints have a NULL `sql` and are excluded —
they are recreated automatically by the rebuilt `CREATE TABLE`. Used by the SQLite table-rebuild path to
re-create the indexes that the rebuild's `DROP TABLE` would otherwise silently lose (#82).

`column_renames` (old ⇒ new physical name) supports the rename-with-FK-change rebuild (#150): the DDL is
snapshotted from the LIVE schema at planning time (old column name), but the rebuilt table carries the new
name, so each renamed column is mapped through this dict both when testing `surviving_columns` membership
(else the renamed column's index would be wrongly filtered out and lost) and when rewriting the emitted DDL.
Default empty ⇒ no rewriting, so every existing #82/#116 call site is unaffected.
"""
function get_secondary_index_ddls(conn::PormGSQLite, table_name::Union{String,Symbol};
                                  surviving_columns::Union{Nothing,Set{String}} = nothing,
                                  column_renames::Dict{String,String} = Dict{String,String}())::Vector{String}
  tname = replace(string(table_name), "'" => "''")
  # `name` is fetched alongside `sql` so we can probe each index's columns via pragma_index_info
  # when filtering (#116). Auto-created indexes (UNIQUE/PK) carry a NULL `sql` and are excluded here,
  # exactly as before — they belong to the CREATE TABLE the rebuild already re-emits.
  rows = fetch(conn, "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = '$(tname)' AND sql IS NOT NULL") |> DataFrame
  isempty(rows) && return String[]
  ddls = String[]
  for r in eachrow(rows)
    s = r.sql
    s === missing && continue
    stmt = strip(string(s))
    isempty(stmt) && continue
    # #116: when the caller is rebuilding a table with columns removed (FK-field deletion), an index on a
    # dropped column must NOT be re-created — SQLite would raise "no such column". `pragma_index_info`
    # gives the index's exact indexed-column membership (robust vs. substring-matching the DDL text); drop
    # the index if any of its columns is no longer present in the rebuilt table. No filtering when the
    # kwarg is `nothing`, so every existing rebuild call site keeps its current behavior.
    #
    # Known limitation: `pragma_index_info` reports NULL for an *expression* column and does not list a
    # *partial* index's WHERE-clause columns, so a user-created expression/partial index over a dropped
    # column would slip through and fail the rebuild. Accepted for #116: PormG only ever emits plain
    # single/multi-column indexes (create_index in Dialect.jl), which pragma_index_info covers exactly.
    if surviving_columns !== nothing
      idxname = replace(string(r.name), "'" => "''")
      cols = fetch(conn, "SELECT name FROM pragma_index_info('$(idxname)')") |> DataFrame
      # #150: the live index references the OLD column name; map it to the rebuilt table's new name
      # before the membership test so a renamed-but-surviving column keeps its index.
      referenced = String[get(column_renames, string(c), string(c)) for c in cols.name if c !== missing]
      any(c -> !(c in surviving_columns), referenced) && continue
    end
    # #150: rewrite renamed columns in the snapshotted DDL. PormG emits quoted identifiers
    # (create_index in Dialect.jl), so replacing the quoted `"old"` token is precise — it can't
    # touch the index name or table name. Empty dict ⇒ no-op for the #82/#116 call sites.
    for (oldc, newc) in column_renames
      stmt = replace(stmt, "\"$oldc\"" => "\"$newc\"")
    end
    push!(ddls, endswith(stmt, ";") ? stmt : stmt * ";")
  end
  return ddls
end

# `table_name::String` — NOT Symbol. This was the odd one out of the four `get_constraints_*`
# helpers, and since `alter_field`'s model-based overload always resolves the table to
# `model.name |> lowercase` (a String), a Symbol signature could never be dispatched to (#283).
function get_constraints_pk(conn::PormGPostgres, table_name::String, field_name::String)
  # Joins carry `table_schema` as well as `constraint_name`: constraint names are unique per
  # SCHEMA, not per database, so joining on the name alone can splice rows from a same-named
  # table in another schema and return a constraint that does not exist on the table the DDL
  # targets. Same shape as get_constraints_check below, which is the exercised sibling. This
  # query was unreachable until #283 (its only caller passed the wrong arity), so it had never
  # run to expose the defect.
  # Filters on `tc.table_name` rather than `ccu.table_name` — `tc` IS the constrained table.
  query = """
  SELECT tc.constraint_name
  FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
  WHERE tc.table_name = '$table_name'
    AND tc.constraint_type = 'PRIMARY KEY'
    AND kcu.column_name = '$field_name';
  """
  result = fetch(conn, query) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :constraint_name]
end

# Returns `nothing` when no UNIQUE constraint matches — the annotation must admit it, or Julia
# converts the `return nothing` below and raises instead of letting callers test it (#284).
function get_constraints_unique(conn::PormGPostgres, table_name::String, field_name::String)::Union{String, Nothing}
  # `AND tc.table_schema = ccu.table_schema` for the same reason as get_constraints_pk above:
  # constraint names are unique per schema, so a name-only join can cross schemas (#283 review).
  query = """
  SELECT tc.constraint_name
  FROM information_schema.table_constraints tc
  JOIN information_schema.constraint_column_usage ccu
    ON tc.constraint_name = ccu.constraint_name AND tc.table_schema = ccu.table_schema
  WHERE tc.table_name = '$table_name' AND tc.constraint_type = 'UNIQUE' AND ccu.column_name = '$field_name';
  """
  result = fetch(conn, query) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :constraint_name]
end

# Find the non-negative CHECK constraint backing a positive integer column.
# PostgreSQL has no unsigned integer type, so PormG enforces `col >= 0` with a
# CHECK constraint; on a type transition away from a positive integer field the
# migration engine needs the constraint's auto-generated name to drop it. We
# match by column and the `>= 0` clause rather than assuming a name, so it works
# even for constraints PormG created anonymously at CREATE TABLE time. Returns
# `nothing` when no such constraint exists.
function get_constraints_check(conn::PormGPostgres, table_name::String, field_name::String)
  query = """
  SELECT tc.constraint_name
  FROM information_schema.table_constraints tc
  JOIN information_schema.constraint_column_usage ccu
    ON tc.constraint_name = ccu.constraint_name AND tc.table_schema = ccu.table_schema
  JOIN information_schema.check_constraints cc
    ON cc.constraint_name = tc.constraint_name AND cc.constraint_schema = tc.constraint_schema
  WHERE tc.table_name = '$table_name'
    AND tc.constraint_type = 'CHECK'
    AND ccu.column_name = '$field_name'
    AND cc.check_clause ILIKE '%>= 0%';
  """
  result = fetch(conn, query) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :constraint_name]
end

# Same empty-result contract as `get_constraints_unique` above (#284).
function get_sequence_name(conn::PormGPostgres, table_name::String, field_name::String)::Union{String, Nothing}
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
  # Widened past `(table, pk)` for #292 to carry the referential action, which the schema query
  # never selected — so every introspected FK claimed no ON DELETE and a migration generated from
  # it silently dropped the action from the schema.
  fk_map = Dict{String, NamedTuple{(:table, :pk, :on_delete), Tuple{String, String, Union{String, Nothing}}}}()
  if row[:foreign_keys] |> !ismissing
    fk_columns = split(row[:foreign_keys], ", ")
    fk_tables = split(row[:foreign_tables], ", ")
    fk_pk_columns = split(row[:referenced_primary_keys], ", ")
    # `delete_rules` is absent on a schema-query result produced before #292 (and on the synthetic
    # rows some unit tests build), so degrade to "no action recorded" rather than throwing.
    delete_rules = (:delete_rules in propertynames(row) && !ismissing(row[:delete_rules])) ?
      split(row[:delete_rules], ", ") : fill("", length(fk_columns))
    for (i, (fk_col, fk_table, fk_pk)) in enumerate(zip(fk_columns, fk_tables, fk_pk_columns))
        rule = i <= length(delete_rules) ? delete_rules[i] : ""
        fk_map[fk_col] = (table = String(fk_table), pk = String(fk_pk),
                          on_delete = _pg_confdeltype_to_on_delete(rule))
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

      @pormg_debug false

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
      
      # Determine field type. format_type() reports a PositiveIntegerField column as
      # plain "integer", so the schema query appends a NON_NEGATIVE_CHECK marker when
      # the column carries a `>= 0` CHECK constraint — that marker is what tells a
      # PositiveIntegerField apart from an IntegerField on round-trip.
      field_type = getfield(Models, haskey(type_map, col_type) ? type_map[col_type] : :TextField)
      if col_type == "integer" && occursin("NON_NEGATIVE_CHECK", col)
        field_type = Models.PositiveIntegerField
      end
      
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

      # @pormg_debug col == "qt_referencia bigint DEFAULT (0)::numeric"

      # println(col)
      
      # Create field instance      
      field = if primary_key
          Models.IDField(generated=generated, generated_always=generated_always, unique=true, null=false, db_index=true)
      elseif haskey(fk_map, col_name)
        fk_info = fk_map[col_name]
        fk_table = uppercasefirst(fk_info.table)
        fk_column = fk_info.pk
        # #292: `on_delete` is now carried (it was never even queried), and `default_value` goes
        # through the shared failure policy — this branch passed it unguarded, so a column default
        # that cannot be an Int64 raised FieldValidationError from inside introspection.
        # `OneToOneField` had the identical omission and is fixed with `ForeignKey`.
        fk_default = _fk_default_or_warn(default_value, table_name, col_name)
        fk_on_delete = _normalize_introspected_on_delete(fk_info.on_delete)
        if unique
          Models.OneToOneField(fk_table, pk_field=fk_column, null=!not_null, default=fk_default, on_delete=fk_on_delete, db_index=true)
        else
          Models.ForeignKey(fk_table, pk_field=fk_column, null=!not_null, default=fk_default, on_delete=fk_on_delete, db_index=true)
        end
      else
        field_type(unique=unique, null=!not_null, default=default_value, db_index=db_index)
      end

      # Only fields that actually carry these attributes get them. A primary-key column
      # is mapped to an IDField (above), which has no max_length/max_digits — guard the
      # assignments so such columns don't raise FieldError during introspection.
      if max_length !== nothing && hasfield(typeof(field), :max_length)
        if max_length > 255
          # CharField only supports max_length <= 255, use TextField for longer strings
          field = Models.TextField(unique=unique, null=!not_null, default=default_value, db_index=db_index)
        else
          field.max_length = max_length
        end
      end

      if max_digits !== nothing && hasfield(typeof(field), :max_digits)
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
  @pormg_debug false
  return model_resp

end