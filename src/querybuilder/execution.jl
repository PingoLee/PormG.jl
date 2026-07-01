
function _show_query_result(mode::Symbol, sql::String, connection::Union{Nothing, PormGPostgres, PormGSQLite}, model::Union{PormGModel, String}, operation::Symbol;
                          parameters::Union{Nothing, AbstractPormGParam} = nothing)
  
  if mode === :none
    return nothing # Zero-allocation mode for benchmarking the builder
  elseif mode === :sql
    return sql # Simplicity: just the SQL string (fast benchmarking)
  elseif mode === :execute
    # Safety check: this function shouldn't be called with :execute,
    # but we return SQL just in case to avoid a crash.
    return sql
  end

  # Resolve model name
  model_name = model isa PormGModel ? model.name : String(model)

  # For formats requiring parameters, prepare the list
  params_list = if parameters === nothing
    []
  elseif hasproperty(parameters, :parameters)
    parameters.parameters
  else
    # Fallback for AbstractPormGParam if it doesn't have .parameters field
    []
  end
  
  if mode === :params
    return params_list
  elseif mode === :dict || mode === :inspection
    # Rich metadata format used by inspect_query() or advanced debugging
    dialect = connection isa PormGPostgres ? :postgresql : :sqlite
    bucketing = connection isa PormGPostgres ? :numbered : :positional
    
    bucket_breakdown = Dict{Symbol, Vector{Any}}()
    if parameters isa PormGSQLiteParam
       bucket_breakdown = Dict(
        :cte => parameters.cte_params,
        :select => parameters.select_params,
        :update => parameters.update_params,
        :join => parameters.join_params,
        :where => parameters.where_params,
        :having => parameters.having_params
      )
    end

    return Dict(
        :sql_text => sql, 
        :parameters => params_list,
        :dialect => dialect,
        :model => model_name,
        :operation => operation,
        :bucketing => bucketing,
        :parameter_count => length(params_list),
        :parameter_buckets => bucket_breakdown
    )
  else
    throw(ArgumentError("Invalid show_query mode: $mode. Must be one of: :sql, :dict, :inspection, :params, :none"))
  end
end

"""
    inspect_query(q::SQLObjectHandler) -> Dict

Comprehensive query inspection API that provides full metadata about a query without executing it.
Returns a rich dictionary with SQL, parameters, dialect information, and structural metadata.

This is the explicit API for query inspection - use this when you want to examine a query's structure
and generated SQL without ambiguity.

# Arguments
- `q::SQLObjectHandler`: The query object to inspect
- `operation::Union{Nothing, Symbol} = nothing`: Optional operation override (:select, :insert, :update, :delete).
  If not provided, the operation is detected automatically based on the query structure.

# Returns
- `Dict`: A dictionary containing:
  - `:sql_text` (String): The generated SQL query
  - `:parameters` (Vector): The parameterized values in bucket order
  - `:dialect` (Symbol): The database dialect (`:postgresql` or `:sqlite`)
  - `:model` (String): The model/table name
  - `:operation` (Symbol): The query operation type (`:select`, `:insert`, `:update`, `:delete`)
  - `:bucketing` (Symbol): The parameter bucketing strategy (`:numbered` for PostgreSQL, `:positional` for SQLite)
  - `:parameter_count` (Int): Number of parameters
  - `:parameter_buckets` (Dict): Breakdown of parameters by bucket (for positional strategies)

# Example
```julia
q = M.Driver.objects
q.filter("nationality" => "British")
q.order_by("surname")

inspection = q |> inspect_query()
# Dict with:
# :sql_text => "SELECT ... WHERE drivers.nationality = \$1 ORDER BY ..."
# :parameters => ["British"]
# :dialect => :postgresql
# :model => "drivers"
# :operation => :select
# :bucketing => :numbered
```
"""
function inspect_query(q::SQLObjectHandler; connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing, operation::Union{Nothing, Symbol} = nothing)
  # Force builder to run without execution
  # We reuse the internal query building logic
  settings, conn, conn_key = get_settings(q, connection=connection)
  
  # 1. Operation detection heuristic
  if operation === nothing
    if !isempty(q.object.insert)
      # If it has data in the 'insert' field, it's either an INSERT or an UPDATE.
      # UPDATE typically has filters (WHERE), INSERT typically does not.
      operation = isempty(q.object.filter) ? :insert : :update
    else
      # Default to :select (safe, most common)
      # Note: :delete is ambiguous with :select if only filters are present,
      # so it must be explicitly requested via inspect_query(operation=:delete)
      operation = :select
    end
  end
  
  # 2. Delegate to appropriate dry-run
  if operation === :select
      return query(q, show_query=:inspection, connection=conn)
  elseif operation === :insert
      return insert(q.object, show_query=:inspection, connection=conn)
  elseif operation === :update
      return update(q.object, show_query=:inspection, connection=conn)
  elseif operation === :delete
      res = delete(q, show_query=:inspection, connection=conn)
      # delete() returns (total_deleted, counter_dict) when executing.
      # In inspection mode it returns a single Dict (simple delete) or a
      # Vector of Dicts (cascaded delete with SET_NULL / SET_DEFAULT / CASCADE
      # steps).  Return the result as-is so callers can inspect every step.
      return res isa Tuple ? res[2] : res
  else
      throw(ArgumentError("Unsupported or unknown operation for inspection: $operation"))
  end
end
inspect_query(; kwargs...) = (objct) -> inspect_query(objct; kwargs...)

function query(q::SQLObjectHandler; 
  table_alias::Union{Nothing, SQLTableAlias} = nothing,
  connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing,
  parameters::Union{Nothing, AbstractPormGParam} = nothing,
  cte::Union{Nothing, CTEDict} = nothing,
  outer::Union{Nothing, SQLInstruction} = nothing,
  show_query::Symbol = :execute
  )

  @pormg_debug false

  # Create a shared table alias counter for both CTEs and main query
  table_alias === nothing && (table_alias = SQLTbAlias())
  
  settings, connection, conn_key = get_settings(q, connection=connection)

  # Track if this is a subquery
  is_subquery = parameters !== nothing

  # IMPORTANT: Create the shared parameters object BEFORE building CTEs
  # This ensures all CTEs and the main query use sequential parameter numbering
  if parameters === nothing
    parameters = get_parameter(connection)
  end

  # Save current context for backends that use positional buckets (SQLite)
  # This is crucial for nested subqueries to avoid clobbering the parent's bucket.
  old_context = parameters isa PormGSQLiteParam ? parameters.current_context : nothing

  # Build WITH clause - passes the SAME parameters object
  # CTE context is set inside build_cte_clause
  !is_subquery && set_context!(parameters, :cte)
  with_clause = build_cte_clause(q.object.ctes, connection, parameters, table_alias)  

  @pormg_debug false

  # Main query uses the SAME parameters object (will continue numbering from where CTEs left off)
  # Context switching for select/where/join happens inside build()
  # Subqueries skip context switching to inherit the parent's current bucket.
  instruction = build(q.object, table_alias=table_alias, connection=connection, parameters=parameters, set_contexts=!is_subquery, outer=outer)
  
  # Prevent SELECT * across JOINs which causes DataFrame column collisions downstream.
  # Only enforce during actual execution (:execute) — inspection/dry-run modes (:dict, :sql,
  # :inspection, etc.) must be allowed to build joined queries without .values() so that
  # inspect_query() and show_query=:dict work on un-projected joined queries.
  if isempty(q.object.values) && !isempty(instruction.join) && show_query === :execute
    throw(ArgumentError("PormG: Joined queries must explicitly select fields using .values(...) to prevent duplicate column names. Tip: Use .values(\"*\", \"joined_model__field_name\") to select all main table fields alongside specific joined fields."))
  end

  # Restore the context for parent query if this was a subquery
  if is_subquery && old_context !== nothing
    set_context!(parameters, old_context)
  end
  if cte !== nothing
    @pormg_debug false
    _build_cte_custom_model(cte, instruction)
  end
  
  # Quote table name and alias to prevent SQL injection
  safe_table_name = safe_table_identifier(q.object.model.name, instruction.connection)
  safe_alias = quote_identifier(instruction.alias, instruction.connection)  
  
  io = IOBuffer()
  print(io, with_clause)
  print(io, "SELECT\n    ")
  if q.object.distinct
    print(io, "DISTINCT ")
  end
  print(io, _query_select(instruction.select, instruction.connection))
  print(io, "\nFROM ", safe_table_name, " as ", safe_alias, "\n")
  
  for j in instruction.join
    print(io, j, "\n")
  end

  if !isempty(instruction._where)
    print(io, "WHERE ")
    for (i, w) in enumerate(instruction._where)
      i > 1 && print(io, " AND \n   ")
      print(io, w)
    end
    print(io, "\n")
  end
  
  if instruction.agregate && !isempty(instruction.group)
    print(io, "GROUP BY ")
    for (i, g) in enumerate(instruction.group)
      i > 1 && print(io, ", ")
      print(io, g)
    end
    print(io, " \n")
  end
  
  if !isempty(instruction.having)
    print(io, "HAVING ")
    for (i, h) in enumerate(instruction.having)
      i > 1 && print(io, " AND \n   ")
      print(io, h)
    end
    print(io, "\n")
  end
  
  if !isempty(instruction.order)
    print(io, "ORDER BY ")
    for (i, o) in enumerate(instruction.order)
      i > 1 && print(io, ", \n  ")
      print(io, o)
    end
    print(io, "\n")
  end
  
  if q.object.limit !== 0
    print(io, "LIMIT ", q.object.limit, " \n")
  end
  
  if q.object.offset !== 0
    print(io, "OFFSET ", q.object.offset, " \n")
  end
  
  resposta = String(take!(io))
  
  # Store the final parameters object with all CTEs + main query parameters
  q.object.parameters = instruction.parameters
  
  if show_query !== :execute
    return _show_query_result(show_query, resposta, instruction.connection, q.object.model.name, :select; 
                            parameters=instruction.parameters)
  end
  return resposta
end
show_query(q::SQLObjectHandler, mode::Symbol = :sql) = query(q; show_query=mode)

# ---
# Count or check if exists
#

function do_count(oq::SQLObjectHandler; column::Union{Nothing, AbstractString} = nothing, distinct::Bool = false,
                  table_alias::Union{Nothing, SQLTableAlias} = nothing, show_query::Symbol = :execute)
  # Column form: COUNT([DISTINCT] column). Reuse the Count() aggregate so column
  # resolution, joins and dialect rendering are shared with values(Count(...)); we
  # return the scalar rather than a row. COUNT(DISTINCT col) is valid SQL (unlike
  # COUNT(DISTINCT *)), so no subquery is needed for this form.
  if column !== nothing
    cq = deepcopy(oq)
    cq.object.order = []
    cq.object.distinct = false      # DISTINCT belongs to COUNT(col), not the row set
    cq.object.limit = 0
    cq.object.offset = 0
    up_values!(cq.object, Any["__pormg_count" => Count(String(column); distinct = distinct)])
    show_query !== :execute && return query(cq; table_alias = table_alias, show_query = show_query)
    rows = list(cq, Val(:dict))
    return isempty(rows) ? 0 : Base.first(values(Base.first(rows)))
  end

  # Resolve settings
  settings, connection, conn_key = get_settings(oq)
  
  q = deepcopy(oq) # Create a copy of the SQLObjectHandler to avoid modifying the original object  
  q.object.order = []# clear order_by
  q.object.values = [] # clear values

  # Create shared table alias and parameters BEFORE building CTEs
  # so CTE parameters are numbered first (critical for positional backends).
  table_alias === nothing && (table_alias = SQLTbAlias())
  parameters = get_parameter(connection)

  # Build WITH clause first — CTE params land in :cte bucket before main params.
  set_context!(parameters, :cte)
  with_clause = build_cte_clause(q.object.ctes, connection, parameters, table_alias)

  # Main query continues from where CTE numbering left off.
  instruction = build(q.object, table_alias=table_alias, connection=connection, parameters=parameters)
  
  # Quote table name and alias to prevent SQL injection
  safe_table_name = safe_table_identifier(q.object.model.name, instruction.connection)
  safe_alias = quote_identifier(instruction.alias, instruction.connection)
  
  # Shared FROM / JOIN / WHERE / GROUP BY body for both count forms.
  body = """FROM $safe_table_name as $safe_alias
    $(join(instruction.join, "\n"))
    $(instruction._where |> length > 0 ? "WHERE" : "") $(join(instruction._where, " AND \n   "))
    $(instruction.agregate ? "GROUP BY $(join(instruction.group, ", ")) \n" : "")
    """
  if distinct || q.object.distinct
    # COUNT(DISTINCT *) is invalid SQL in both PostgreSQL and SQLite. To count the rows a
    # DISTINCT select would return, wrap `SELECT DISTINCT *` in an outer COUNT(*) so that
    # count() == length(distinct list()). Any CTEs stay at the top level and remain in
    # scope for the subquery; parameter order/count is unchanged by the wrapping.
    resposta = """$(with_clause)SELECT COUNT(*) FROM (
    SELECT DISTINCT *
    $body) as "__pormg_distinct_count"
    """
  else
    resposta = """$(with_clause)SELECT
      COUNT(*)
    $body"""
  end
  # Inspection short-circuit: return SQL/metadata without hitting the database.
  if show_query !== :execute
    return _show_query_result(show_query, resposta, instruction.connection, q.object.model.name, :select;
                            parameters=instruction.parameters)
  end
  query_result = fetch(settings, resposta, instruction.parameters)
  # PostgreSQL returns a LibPQ.Result that supports scalar [row, col] indexing.
  # SQLite returns a materialized rowtable (Vector{<:NamedTuple}); a Vector *also* has a
  # (Int, Int) getindex method (trailing-singleton dimension), so exclude vectors explicitly
  # and take the Tables path, which extracts the scalar from the single COUNT row.
  if !(query_result isa AbstractVector) &&
     (query_result isa AbstractMatrix || hasmethod(getindex, Tuple{typeof(query_result), Int, Int}))
    return query_result[1, 1]
  else
    row = Tables.rowtable(query_result) |> Base.first
    return Base.first(values(row))
  end
end

function do_exists(oq::SQLObjectHandler; table_alias::Union{Nothing, SQLTableAlias} = nothing, show_query::Symbol = :execute)
  try
    # Resolve settings
    settings, connection, conn_key = get_settings(oq)
    
    q = deepcopy(oq) # Create a copy of the SQLObjectHandler to avoid modifying the original object
    q.object.order = [] # clear order_by
    q.object.values = [] # clear values

    # Create shared table alias and parameters BEFORE building CTEs
    # so CTE parameters are numbered first (critical for positional backends).
    table_alias === nothing && (table_alias = SQLTbAlias())
    parameters = get_parameter(connection)

    # Build WITH clause first — CTE params land in :cte bucket before main params.
    set_context!(parameters, :cte)
    with_clause = build_cte_clause(q.object.ctes, connection, parameters, table_alias)

    # Main query continues from where CTE numbering left off.
    instruction = build(q.object, table_alias=table_alias, connection=connection, parameters=parameters)
    limit_clause = "LIMIT 1"
    offset_clause = q.object.offset > 0 ? "OFFSET $(q.object.offset)" : ""
    
    # Quote table name and alias to prevent SQL injection
    safe_table_name = safe_table_identifier(q.object.model.name, instruction.connection)
    safe_alias = quote_identifier(instruction.alias, instruction.connection)
    
    sql = """
    $(with_clause)SELECT 1
    FROM $safe_table_name as $safe_alias
    $(join(instruction.join, "\n"))
    $(isempty(instruction._where) ? "" : "WHERE " * join(instruction._where, " AND \n   "))
    $(instruction.agregate && !isempty(instruction.group) ? "GROUP BY $(join(instruction.group, ", "))" : "")
    $limit_clause
    $offset_clause
    """
    # Inspection short-circuit: return SQL/metadata without hitting the database.
    if show_query !== :execute
      return _show_query_result(show_query, sql, instruction.connection, q.object.model.name, :select;
                              parameters=instruction.parameters)
    end
    @pormg_debug false
    result = fetch(settings, sql, instruction.parameters) |> Tables.rowtable
    @pormg_debug false
    return length(result) > 0
  catch e
    @pormg_debug false
    # Log for observability, then rethrow unconditionally.
    # Silently returning false would mask connection failures, SQL errors, and
    # permission errors as "does not exist", which is incorrect and dangerous.
    # The only legitimate false return is from `length(result) > 0` above.
    @error "Error in do_exists for model $(oq.object.model.name): $e"
    rethrow(e)
  end
end

# Build a Dict{Symbol,Any} from a result row, mapping physical column names back to the
# declared field names so callers always see field-name keys even when a field maps to a
# differently-named column via db_column (#50). No-op shape on the common path.
function _row_to_field_keyed_dict(row, model::PormGModel)::Dict{Symbol,Any}
  if !Models.model_has_db_column(model)
    return Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs(row))
  end
  rev = Dict{String,Symbol}(Models.field_db_column(f, string(k)) => Symbol(k) for (k, f) in model.fields)
  return Dict{Symbol,Any}(get(rev, string(k), Symbol(k)) => v for (k, v) in pairs(row))
end

function insert(objct::SQLObject; table_alias::Union{Nothing, SQLTableAlias} = nothing, connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing, show_query::Symbol = :execute)
real_obj = objct isa SQLObjectHandler ? objct.object : objct
  model = real_obj.model
  ensure_model_transaction_scope(model)
  
  # Resolve settings
  settings, connection, conn_key = get_settings(objct, connection=connection)
  
  # colect name of the fields
  fields = model.field_names

  # Collect column names and parameter values
  quoted_field_columns = []
  param_values = []
  parameters = get_parameter(connection)
  # For INSERT, all params go into :select bucket (VALUES clause is the only positioned section)
  set_context!(parameters, :select)
  
  # check if is allowed to insert
  !settings.change_data && throw(_argerr("Error in insert, the connection \e[4m\e[31m$conn_key\e[0m not allowed to insert"))
  
  # check if the fields are in objct.insert
  for field in fields
    if !haskey(real_obj.insert, field)
      # check if field allow null or if exist a default value
      if model.fields[field].default !== nothing
        real_obj.insert[field] = model.fields[field].default
      elseif model.fields[field].type == "TIMESTAMPTZ" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        real_obj.insert[field] = model.fields[field].formater(now(TimeZone(settings.time_zone)))
      elseif model.fields[field].type == "DATE" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        real_obj.insert[field] = model.fields[field].formater(today())
      elseif model.fields[field].type == "UUID" && model.fields[field].auto_add
        real_obj.insert[field] = model.fields[field].formater(UUIDs.uuid4())
      elseif model.fields[field].null || model.fields[field].primary_key
        continue
      else
        throw(_argerr("Error in insert, the field \e[4m\e[31m$(field)\e[0m not allow null"))
      end
    end
  end

  # SQLite reservation handling: if this transaction already pre-allocated ids for the
  # table, consume the next id explicitly instead of relying on AUTOINCREMENT.
  if connection isa PormGSQLite
    auto_pk_fields = [field for field in fields if _is_auto_generated_bulk_primary_key(model.fields[field])]
    if length(auto_pk_fields) == 1
      pk_name = auto_pk_fields[1]
      reserved_max = get_sqlite_reserved_primary_key_max(model, pk_name)
      if reserved_max !== nothing && !haskey(real_obj.insert, pk_name)
        reserved_id = _allocate_sqlite_ids(model, connection, pk_name, 1, settings)[1]
        real_obj.insert[pk_name] = reserved_id
      end
    end
  end

  pk_exist::Bool = false
  pk_field::Vector{String} = []
  for field in keys(real_obj.insert)
    # Validation checks
    validate_field_data(model, field, real_obj.insert[field], "insert"; allow_primary_key = true)
    Models.is_many_to_many_field(model.fields[field]) && throw(ArgumentError("ManyToManyField $(model.name).$(field) cannot be written in create(); use $(model.name).$(field)(source_id).add!(target_id) after creating the source row"))

    # check if the field is a primary key
    model.fields[field].primary_key && (pk_exist = true; push!(pk_field, field))

     # Add safely quoted physical column (db_column when set) to columns list (#50)
    push!(quoted_field_columns, quote_identifier(Models.field_db_column(model.fields[field], field), connection))

    # Format and add value to parameters
    push!(param_values, add_parameter!(parameters, real_obj.insert[field] |> model.fields[field].formater))

  end
 
  # TODO: insert a function to handle with the different types of connection and modulate the code

  # construct the SQL statement
  safe_table_name = safe_table_identifier(string(model.name), connection)
  sql = """
  INSERT INTO $(safe_table_name) (
    $(join(quoted_field_columns, ", "))
  ) VALUES (
    $(join(param_values, ", "))
  )
  """

  if show_query !== :execute
    return _show_query_result(show_query, sql, connection, model.name, :insert; 
                            parameters=parameters)
  end

  # Execute safely
  if connection isa PormGPostgres
    result = fetch(settings, sql * " RETURNING *;", parameters)
    pk_exist && _update_sequence(model, connection, pk_field, settings)
    return _row_to_field_keyed_dict(Tables.rowtable(result) |> Base.first, model)
  elseif connection isa PormGSQLite
    # SQLite: deliberately avoid `INSERT ... RETURNING *`. RETURNING can hang
    # indefinitely inside SQLite/libsqlite3 for some table shapes (observed: an
    # AUTOINCREMENT primary key that migrations left in a non-first column
    # position). The previous broad `catch` masked that hang/error by re-running a
    # plain INSERT, which then tripped a spurious UNIQUE violation because the
    # first INSERT had already written the row. Instead: run a plain INSERT, then
    # read the full inserted row back with a SELECT on the SAME connection
    # (last_insert_rowid() is per-connection session state). Reading the whole row
    # keeps the returned Dict consistent with the Postgres `RETURNING *` path —
    # all columns present, including nullable ones the caller did not set.
    do_insert = () -> begin
      fetch(settings, sql, parameters)
      rows = fetch(settings,
        "SELECT * FROM $(safe_table_name) WHERE rowid = last_insert_rowid();") |> Tables.rowtable
      isempty(rows) ?
        Dict{Symbol, Any}(Symbol(k) => v for (k, v) in pairs(real_obj.insert)) :
        _row_to_field_keyed_dict(rows[1], model)
    end

    # INSERT and the row read-back must run on one connection (last_insert_rowid()
    # is per-connection). Reuse the active transaction if there is one; otherwise
    # pin a connection for the pair.
    result_dict = transaction_connection_for(settings) !== nothing ?
      do_insert() : run_in_transaction(do_insert, settings)

    pk_exist && _update_sequence(model, connection, pk_field, settings)
    return result_dict
  else
    throw("Unsupported connection type")
  end

end

function _get_owned_sequence_name(connection::PormGPostgres, model::PormGModel, field::String; ignore_tx::Bool = false)
  sequence_df = fetch(
    connection,
    "SELECT pg_get_serial_sequence('$(string(model.name))', '$(field)');";
    ignore_tx=ignore_tx,
  ) |> DataFrames.DataFrame

  if size(sequence_df, 1) == 0 || !("pg_get_serial_sequence" in names(sequence_df))
    return nothing
  end

  sequence_name = sequence_df[1, :pg_get_serial_sequence]
  return ismissing(sequence_name) || isnothing(sequence_name) ? nothing : sequence_name
end

function _update_sequence(model::PormGModel, connection::PormGPostgres, pk_field::Vector{String}, settings::SQLConn; ignore_tx::Bool = false)
  @pormg_debug true

  !(settings.change_db || settings.django_prefix !== nothing) && return nothing

  for field in pk_field
    # Resolve the PK field to its physical column (db_column when set) — #50.
    col = Models.model_column(model, field)
    sequence_name = _get_owned_sequence_name(connection, model, col; ignore_tx=ignore_tx)

    if isnothing(sequence_name)
      # Fallback for Django-managed tables where sequence ownership is not set:
      # scan pg_sequences for any sequence whose name starts with the table name.
      seqs_df = fetch(
        connection,
        "SELECT sequencename FROM pg_sequences WHERE sequencename LIKE '$(string(model.name) |> lowercase)%'";
        ignore_tx=ignore_tx,
      ) |> DataFrames.DataFrame
      
      size(seqs_df, 1) == 0 && continue
      sequence_name = seqs_df[1, :sequencename]
    end

    safe_field_name = quote_identifier(col, connection)
    safe_table_name = safe_table_identifier(string(model.name), connection)
    fetch(
      connection,
      "SELECT setval('$sequence_name', COALESCE((SELECT MAX($safe_field_name) FROM $safe_table_name), 0) + 1, false)";
      ignore_tx=ignore_tx,
    )
  end
end

function _fix_sequence_name(connection::PormGPostgres, model::PormGModel; ignore_tx::Bool = false) # TODO maby i need use Migration get_sequence_name aproach
  pk_field = [field for field in keys(model.fields) if model.fields[field].primary_key]
  sequences = fetch(connection, """SELECT *
      FROM pg_sequences
      WHERE sequencename LIKE '$(model.name |> lowercase)%';"""; ignore_tx=ignore_tx) |> DataFrames.DataFrame  
  for (index, row) in enumerate(eachrow(sequences))
    if index == 1 && row.sequencename != "$(model.name |> lowercase)_$(pk_field[1])_seq"
      if length(pk_field) == 0
        throw("Error in _fix_sequence_name, the model $(model.name) does not have a primary key")
      elseif length(pk_field) > 1
        throw("Error in _fix_sequence_name, the model $(model.name) has more than one primary key")
      end
      fetch(connection, "ALTER SEQUENCE $(row.sequencename) RENAME TO $(model.name |> lowercase)_$(pk_field[1])_seq;"; ignore_tx=ignore_tx)
    else
      fetch(connection, "DROP SEQUENCE $(row.sequencename);"; ignore_tx=ignore_tx)
    end
  end
end

# function _update_sequence(model::PormGModel, connection::PormGPostgres, pk_field::Vector{String})
#   sequences = fetch(connection, """SELECT *
#       FROM pg_sequences
#       WHERE sequencename LIKE '$(model.name |> lowercase)%';""") |> DataFrames.DataFrame
#   for row in eachrow(sequences)
#     if row.sequenceowner == model.name
#       fetch(connection, "SELECT setval('$(row.sequencename)', (SELECT MAX($(pk_field[1])) FROM $(model.name)), true);")
#     end
#   end
# end
function _update_sequence(model::PormGModel, connection::PormGSQLite, pk_field::Vector{String}, settings::SQLConn)
  for field in pk_field
    safe_field_name = quote_identifier(Models.model_column(model, field), connection)  # db_column (#50)
    safe_table_name = safe_table_identifier(string(model.name), connection)
    safe_table_literal = replace(string(model.name |> lowercase), "'" => "''")
    max_id_query = "SELECT MAX($(safe_field_name)) as m FROM $(safe_table_name);"
    # Execute query and convert to DataFrame to safely access the result
    df = fetch(connection, max_id_query) |> DataFrames.DataFrame
    
    if size(df, 1) > 0
      max_id = df[1, :m]
      if !ismissing(max_id) && !isnothing(max_id)
        # MAX(pk) is normally an Int64, but coerce defensively: a Float ("5.0") must still
        # resolve to its integer seq value instead of being silently skipped
        # (tryparse(Int64, "5.0") === nothing). A non-numeric value yields `nothing` → skipped.
        parsed_id = max_id isa Real ? floor(Int64, max_id) : tryparse(Int64, string(max_id))
        if parsed_id !== nothing
          # sqlite_sequence.name has no UNIQUE constraint, so `INSERT OR REPLACE` appends a
          # duplicate row instead of overwriting. Upsert by hand: UPDATE the existing row
          # (collapsing any duplicates a prior buggy run left, all to the same value), then
          # INSERT only if no row exists yet.
          fetch(settings, "UPDATE sqlite_sequence SET seq = $(parsed_id) WHERE name = '$(safe_table_literal)';")
          fetch(settings, "INSERT INTO sqlite_sequence (name, seq) SELECT '$(safe_table_literal)', $(parsed_id) " *
                          "WHERE NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = '$(safe_table_literal)');")
        end
      end
    end
  end
end

# TODO: Implement a function to handle the update with multiple dispatch
# Helper function to check if a field is a date field
function _is_date_field(field_name::String, instruc::SQLInstruction)
  model = instruc.object.model
  # @pormg_debug
  if haskey(model.fields, field_name)
    field_type = model.fields[field_name].type
    return field_type in ["DATE", "TIMESTAMPTZ", "TIMESTAMP"]
  elseif haskey(instruc.tab_field_cache, field_name)
    field_type = instruc.tab_field_cache[field_name].type
    return field_type in ["DATE", "TIMESTAMPTZ", "TIMESTAMP"]
  end 
  return false
end

function _set_update_query(v::SQLTypeFunction, instruc::SQLInstruction)
  return _get_select_query(v, instruc)
end

function _set_update_query_operand(operand::Any, field_name::Any, operation::String, instruc::SQLInstruction)
  if isa(operand, FExpression)
    return _set_update_query(operand, instruc)
  elseif isa(operand, SQLTypeFunction)
    return _get_select_query(operand, instruc)
  elseif isa(operand, String)
    # Check if it's a field reference
    if contains(operand, "__") || operand in instruc.object.model.field_names
      return _set_update_query(FExpression(field_name = operand, function_name = "F", column = operand), instruc)
    else
      # Keep scalar literals parameterized with an explicit SQL type on PostgreSQL so
      # expressions like integer_column / 2.0 don't get inferred back to integer.
      return add_parameter!(instruc, operand; sql_type=_infer_parameter_sql_type(operand, instruc))
    end
  elseif isa(operand, Integer)
    # SECURITY: Handle integer operands for date arithmetic and bitwise shifts
    sql_type = (operation in ["<<", ">>"]) ? "integer" : _infer_parameter_sql_type(operand, instruc)
    placeholder = add_parameter!(instruc, operand; sql_type=sql_type)
    if operation in ["+", "-"] && (field_name isa String && _is_date_field(field_name, instruc))
      if instruc.connection isa PormGSQLite
        # SQLite handles date arithmetic via functions, but for the infix expression
        # we just return the placeholder and handle the wrapper in the final return
        return placeholder
      else
        # Convert integer days to interval for date arithmetic (PostgreSQL)
        return "($placeholder || ' days')::interval"
      end
    else
      return placeholder
    end
  else
    # SECURITY: Use parameterized query for other numeric values
    return add_parameter!(instruc, operand; sql_type=_infer_parameter_sql_type(operand, instruc))
  end
end

function _set_update_query_left(value::Any, operation::String, instruc::SQLInstruction)
  if value isa String
    return _get_filter_query(value, instruc)
  elseif value isa Integer
    sql_type = (operation in ["<<", ">>"]) ? "integer" : _infer_parameter_sql_type(value, instruc)
    return add_parameter!(instruc, value; sql_type=sql_type)
  elseif value isa FExpression
    return _set_update_query(value, instruc)
  elseif value isa SQLTypeFunction
    return _get_select_query(value, instruc)
  else
    return _set_update_query(value, instruc)
  end
end

function _set_update_query(v::FExpression, instruc::SQLInstruction)
  if v.operation === nothing
    # Resolve the field using existing logic for joins and modifiers
    if v.field_name isa String
      return _get_filter_query(v.field_name, instruc)
    elseif v.field_name isa Integer
      return add_parameter!(instruc, v.field_name; sql_type=_infer_parameter_sql_type(v.field_name, instruc))
    else
      # Recursive call for nested expressions
      return _set_update_query(v.field_name, instruc)
    end
  elseif v.operation == "~"
    # Unary NOT operator
    left_side = _set_update_query_left(v.field_name, v.operation, instruc)
    return "~($(left_side))"
  elseif v.operation == "xor"
    if instruc.connection isa PormGPostgres
      left_side = _set_update_query_left(v.field_name, v.operation, instruc)
      right_side = _set_update_query_operand(v.operand, v.field_name, v.operation, instruc)
      return "($(left_side) # $(right_side))"
    elseif instruc.connection isa PormGSQLite
      # Positional Parameter Alignment: render each side twice to duplicate any embedded parameters
      left_side1 = _set_update_query_left(v.field_name, v.operation, instruc)
      right_side1 = _set_update_query_operand(v.operand, v.field_name, v.operation, instruc)

      left_side2 = _set_update_query_left(v.field_name, v.operation, instruc)
      right_side2 = _set_update_query_operand(v.operand, v.field_name, v.operation, instruc)

      return "((($(left_side1)) | ($(right_side1))) - (($(left_side2)) & ($(right_side2))))"
    else
      throw("Unsupported connection type")
    end
  else
    # Field with operation - handle nesting and date arithmetic properly
    left_side = _set_update_query_left(v.field_name, v.operation, instruc)

    # @pormg_debug
    right_side = _set_update_query_operand(v.operand, v.field_name, v.operation, instruc)
    
    if instruc.connection isa PormGSQLite && v.operation in ["+", "-"] && (v.field_name isa String && _is_date_field(v.field_name, instruc))
      op_sign = v.operation == "+" ? "+" : "-"
      return "date($(left_side), '$(op_sign)' || $(right_side) || ' days')"
    end

    return "($(left_side) $(v.operation) $(right_side))"
  end
end

function _build_from_tables(row_join::Vector{Dict{String, Union{String, Vector{FilterType}}}}, connection::Union{PormGPostgres, PormGSQLite})
  tables = String[]
  for join_dict in row_join
    try
      b = safe_table_identifier(join_dict["b"], connection)
      alias_b = quote_identifier(join_dict["alias_b"], connection)
      push!(tables, "$b AS $alias_b")
    catch e
      @error "Error building FROM tables for join: $join_dict" exception=(e, catch_backtrace())
    end
  end
  return join(unique(tables), ", ")
end

function _get_join_condition_list(row_join::Vector{Dict{String, Union{String, Vector{FilterType}}}}, connection)
  conditions = String[]
  for join_dict in row_join
    try
      alias_a = quote_identifier(join_dict["alias_a"], connection)
      key_a = quote_identifier(join_dict["key_a"], connection)
      alias_b = quote_identifier(join_dict["alias_b"], connection)
      key_b = quote_identifier(join_dict["key_b"], connection)
      push!(conditions, "$alias_a.$key_a = $alias_b.$key_b")
    catch e
      @error "Error building join condition for join: $join_dict" exception=(e, catch_backtrace())
    end
  end
  return conditions
end

function _build_join_conditions(row_join::Vector{Dict{String, Union{String, Vector{FilterType}}}}, connection::Union{PormGPostgres, PormGSQLite})
  return _get_join_condition_list(row_join, connection)
end

function _set_clause_uses_join_aliases(set_clause::String,
  row_join::Vector{Dict{String, Union{String, Vector{FilterType}}}},
  connection::Union{PormGPostgres, PormGSQLite})::Bool
  for join_dict in row_join
    alias_b = quote_identifier(join_dict["alias_b"], connection)
    occursin("$alias_b.", set_clause) && return true
  end
  return false
end

function _build_update_target_pk_subquery(instruction::SQLInstruction)::Union{String, Nothing}
  pk_field_sym = get_model_pk_field(instruction.object.model)
  pk_field_sym === nothing && return nothing

  safe_table_name = safe_table_identifier(instruction.object.model.name, instruction.connection)
  safe_alias = quote_identifier(instruction.alias, instruction.connection)
  quoted_pk = quote_identifier(Models.model_column(instruction.object.model, String(pk_field_sym)), instruction.connection)  # db_column (#50)

  io = IOBuffer()
  print(io, "SELECT DISTINCT ", safe_alias, ".", quoted_pk)
  print(io, "\nFROM ", safe_table_name, " as ", safe_alias, "\n")

  for j in instruction.join
    print(io, j, "\n")
  end

  if !isempty(instruction._where)
    print(io, "WHERE ")
    for (i, w) in enumerate(instruction._where)
      i > 1 && print(io, " AND \n   ")
      print(io, w)
    end
    print(io, "\n")
  end

  if instruction.agregate && !isempty(instruction.group)
    print(io, "GROUP BY ")
    for (i, g) in enumerate(instruction.group)
      i > 1 && print(io, ", ")
      print(io, g)
    end
    print(io, " \n")
  end

  if !isempty(instruction.having)
    print(io, "HAVING ")
    for (i, h) in enumerate(instruction.having)
      i > 1 && print(io, " AND \n   ")
      print(io, h)
    end
    print(io, "\n")
  end

  return String(take!(io))
end

function update(objct::SQLObject; table_alias::Union{Nothing, SQLTableAlias} = nothing, connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing, show_query::Symbol = :execute)
  real_obj = objct isa SQLObjectHandler ? objct.object : objct
  model = real_obj.model
  ensure_model_transaction_scope(model)

  # Resolve settings
  settings, connection, conn_key = get_settings(objct, connection=connection)

  # Check if is allowed to update
  !settings.change_data && throw(_argerr("Error in update, the connection \e[4m\e[31m$conn_key\e[0m not allowed to update"))

  # Guard: limit(), offset(), and order_by() cannot be combined with update().
  # Standard SQL UPDATE does not support these clauses. Silently dropping them
  # risks updating far more rows than the user intended (e.g., query.limit(5).update(...)
  # would mutate ALL matching rows, not just 5). To update a bounded set of rows,
  # filter by primary key explicitly or compose a subquery.
  if real_obj.limit > 0 || real_obj.offset > 0 || !isempty(real_obj.order)
    throw(ArgumentError(
      "Cannot call update() on a query that has limit(), offset(), or order_by() set. " *
      "Standard SQL UPDATE does not support these clauses, and silently dropping them " *
      "risks updating more rows than intended. " *
      "Filter by primary key explicitly or compose a subquery to update a bounded set."
    ))
  end

  if real_obj.distinct
    throw(ArgumentError(
      "Cannot call update() on a query with distinct(). " *
      "DISTINCT collapses the result set, which would cause UPDATE to target " *
      "different rows than intended. Remove distinct() or filter by primary key."
    ))
  end

  if any(v -> isa(v, SQLTypeField) && isa(v.field, Union{SQLTypeFunction, SQLTypeF}) && v.field.agregate, real_obj.values)
    throw(ArgumentError(
      "Cannot call update() on a query with group_by() / annotate aggregations. " *
      "GROUP BY collapses rows, making the UPDATE target ambiguous. " *
      "Remove the aggregation or filter by primary key."
    ))
  end

  instruction = build(real_obj, table_alias=table_alias, connection=connection) 

  # Don't allow to update a field without filter
  instruction._where |> isempty && throw("Error in update, the update must have a filter")
  
  parameters = instruction.parameters
  fields = model.field_names

  # Check if the fields need to be updated automatically
  for field in fields
    if !haskey(objct.insert, field)
      if model.fields[field].type == "TIMESTAMPTZ" && (model.fields[field].auto_now)
        objct.insert[field] = model.fields[field].formater(now(TimeZone(settings.time_zone)))
      elseif model.fields[field].type == "DATE" && (model.fields[field].auto_now)
        objct.insert[field] = model.fields[field].formater(today())
      end
    end
  end

  # Handle F expressions in SET clause
  # Switch context to :update for SET clause params (SET appears before WHERE/JOIN in SQL)
  set_context!(parameters, :update)
  set_clause_parts = String[]
  for field in keys(objct.insert)    
    # Validation checks
    validate_field_data(model, field, objct.insert[field], "update"; allow_primary_key = false)
    Models.is_many_to_many_field(model.fields[field]) && throw(ArgumentError("ManyToManyField $(model.name).$(field) cannot be written in update(); use the many-to-many manager add!, remove!, clear!, or set! methods"))
    
    quoted_field = quote_identifier(Models.field_db_column(model.fields[field], field), connection)  # db_column (#50)

    if isa(objct.insert[field], SQLTypeF) || isa(objct.insert[field], SQLTypeFunction)
      f_value = _set_update_query(objct.insert[field], instruction)
      push!(set_clause_parts, "$(quoted_field) = $(f_value)")
    else
      formatted_value = objct.insert[field] |> model.fields[field].formater
      placeholder = add_parameter!(parameters, formatted_value)
      push!(set_clause_parts, "$(quoted_field) = $(placeholder)")
    end
  end
   
  set_clause = join(set_clause_parts, ", ")   

  # Build secure UPDATE SQL with JOIN support
  safe_table_name = safe_table_identifier(string(model.name), connection)
  safe_alias = quote_identifier(instruction.alias, connection)
  pk_field_sym = get_model_pk_field(model)
  
  has_joins = !isempty(instruction.row_join)
  sql = ""
  
  if has_joins
    if connection isa PormGPostgres || connection isa PormGSQLite
      set_uses_join_aliases = _set_clause_uses_join_aliases(set_clause, instruction.row_join, connection)
      pk_subquery = (!set_uses_join_aliases && isempty(real_obj.ctes)) ? _build_update_target_pk_subquery(instruction) : nothing

      if pk_subquery !== nothing && pk_field_sym !== nothing
        quoted_pk = quote_identifier(Models.model_column(model, String(pk_field_sym)), connection)  # db_column (#50)
        sql = """
        UPDATE $(safe_table_name) AS $(safe_alias)
        SET $(set_clause)
        WHERE $(safe_alias).$(quoted_pk) IN (
        $(pk_subquery)
        )
        """
      else
        # PostgreSQL & SQLite 3.33+ support UPDATE FROM syntax
        from_clause = _build_from_tables(instruction.row_join, connection)
        join_conditions = _build_join_conditions(instruction.row_join, connection)
        
        # Merge structural joins and logical filters, then deduplicate
        final_where = unique([join_conditions; instruction._where])
        
        sql = """
        UPDATE $(safe_table_name) AS $(safe_alias)
        SET $(set_clause)
        FROM $(from_clause)
        WHERE $(join(final_where, " AND "))
        """
      end
    else
      @error "Error in update: Unsupported database type for JOIN operations" connection_type=typeof(connection)
      throw("Error in update: Unsupported database type for JOIN operations")
    end
  else
    # No joins - simple UPDATE
    sql = """
    UPDATE $(safe_table_name) AS $(safe_alias)
    SET $(set_clause)
    WHERE $(join(instruction._where, " AND \n   "))
    """
  end

  if show_query !== :execute
    return _show_query_result(show_query, sql, connection, model.name, :update; 
                            parameters=parameters)
  end

  # @pormg_debug

  # return nothing

  # Execute with parameters and return affected row count (Django matched-rows semantics).
  try
    if connection isa PormGPostgres
      # The driver result exposes a matched-row count; backend_num_affected_rows
      # delegates to LibPQ.num_affected_rows in the PostgreSQL extension.
      result = fetch(settings, sql, parameters)
      return backend_num_affected_rows(connection, result)
    elseif connection isa PormGSQLite
      # SQLite changes() must run on the same connection as the UPDATE.
      # If we are already inside a transaction context, fetch() reuses the
      # pinned connection so a subsequent SELECT changes() is safe.
      tx_conn = transaction_connection_for(settings)
      if tx_conn !== nothing
        fetch(settings, sql, parameters)
        changes_result = fetch(settings, "SELECT changes()")
        rows = changes_result |> DataFrames.DataFrame
        return Int(rows[1, 1])
      else
        # No active transaction — wrap in run_in_transaction to pin the
        # connection for both the UPDATE and SELECT changes().
        return run_in_transaction(settings) do
          fetch(settings, sql, parameters)
          changes_result = fetch(settings, "SELECT changes()")
          rows = changes_result |> DataFrames.DataFrame
          return Int(rows[1, 1])
        end
      end
    else
      throw("Unsupported connection type")
    end
  catch e
    @error "Error executing UPDATE query" exception=(e, catch_backtrace()) sql=sql
    rethrow(e)
  end
end


"""
Fetches a list of records from the database for the given `SQLObjectHandler`.

# Returns
- The result of the database query as returned by `fetch`.

# Example
```julia
query = M.Result |> object
query.filter("raceid__year" => 2020)
query.values("driverid__forename", "constructorid__name", "laps" => Count("laps"))
query.order_by("-laps")
df = query |> DataFrame
```
"""
function query_list(objct::SQLObjectHandler; show_query::Symbol = :execute)
  # Resolve settings
  settings, connection, conn_key = get_settings(objct)

  sql = query(objct, connection=connection, show_query=show_query)
  if show_query !== :execute
     return sql
  end
  return fetch(settings, sql, objct.object.parameters) 
end

"""
Creates a DataFrame directly from a SQLObjectHandler query.

This extends the DataFrame constructor to work directly with PormG query objects,

# Arguments
- `objct::SQLObjectHandler`: The SQL object handler containing the query

# Returns
- `DataFrames.DataFrame`: The query results as a DataFrame

# Example
```julia
query = M.Result |> object
query.filter("raceid__year" => 2020)
query.values("driverid__forename", "constructorid__name", "laps")
df = query |> DataFrame  # Direct conversion to DataFrame
```
"""
function DataFrames.DataFrame(objct::SQLObjectHandler)
  return query_list(objct) |> DataFrames.DataFrame
end


"""
    _sqlite_datetime_aliases(objct::SQLObjectHandler) → Set{Symbol}

Return the set of result-row column keys that map to a `DateTimeField` on the primary
model.  Only direct (non-joined) field projections are resolved; joined columns
(containing `__`) are skipped so no cross-model traversal is needed.

Used on the SQLite backend to normalise string datetime values in `list()` results into
proper Julia temporal types, giving the same contract as the PostgreSQL backend.
"""
function _sqlite_datetime_aliases(objct::SQLObjectHandler)::Set{Symbol}
    model = objct.object.model
    col_set = Set{Symbol}()

    if isempty(objct.object.values)
        # No .values() projection — all direct model fields appear in the result
        for (fname, fmeta) in model.fields
            fmeta isa Models.sDateTimeField && push!(col_set, Symbol(fname))
        end
    else
        for v in objct.object.values
            v isa SQLTypeField || continue
            # The effective alias is how the column appears in the result dict
            effective_alias = v.custom_as !== nothing ? v.custom_as : (v._as !== nothing ? v._as : (v.field isa String ? v.field : nothing))
            effective_alias === nothing && continue
            # The field reference must be a plain string to look up in model.fields.
            # Expressions or function objects are skipped.
            field_ref = v.field isa String ? v.field : nothing
            field_ref === nothing && continue
            # Skip joined columns — their source model is not tracked here
            occursin("__", field_ref) && continue
            if haskey(model.fields, field_ref) && model.fields[field_ref] isa Models.sDateTimeField
                push!(col_set, Symbol(effective_alias))
            end
        end
    end
    return col_set
end

"""
    _parse_sqlite_datetime(v) → Union{ZonedDateTime, DateTime, typeof(v)}

Parse a raw string value read from a SQLite DATETIME column into a Julia temporal type.

SQLite stores datetime values as TEXT.  PormG serialises `DateTimeField` values (including
`auto_now` / `auto_now_add`) as ZonedDateTime strings, e.g. `"2026-04-07T18:30:23.741-03:00"`.
This function converts those strings back into proper Julia types so that the SQLite backend
returns the same high-level types as the PostgreSQL backend (which returns `ZonedDateTime`
natively via LibPQ).

- Strings containing a timezone offset → `ZonedDateTime`
- Naive ISO 8601 strings → `DateTime`
- Non-string values or unparseable strings → returned unchanged
"""
function _parse_sqlite_datetime(v::Any)
    v isa AbstractString || return v
    normalized = Models.normalize_sqlite_datetime_string(v)
    # Try timezone-aware form first (e.g. "2026-04-07T18:30:23.741-03:00")
    try; return ZonedDateTime(normalized, dateformat"yyyy-mm-ddTHH:MM:SS.ssszzzz"); catch; end
    # Fall back to naive datetime (e.g. "2026-04-07T21:30:23")
    try; return DateTime(v[1:min(19, length(v))], dateformat"yyyy-mm-ddTHH:MM:SS"); catch; end
    return v
end
function _list_raw(objct::SQLObjectHandler)
  result = query_list(objct)
  rows = Tables.rowtable(result) |> collect |> x -> [Dict(Symbol(k) => v for (k, v) in pairs(row)) for row in x]
  # SQLite returns DATETIME columns as raw strings. Normalise columns that correspond to a
  # DateTimeField in the primary model into ZonedDateTime / DateTime so the return type
  # matches what the PostgreSQL backend produces natively.
  _, connection, _ = get_settings(objct)
  if connection isa PormGSQLite
    dt_cols = _sqlite_datetime_aliases(objct)
    if !isempty(dt_cols)
      rows = [Dict(k => (k in dt_cols && v isa AbstractString ? _parse_sqlite_datetime(v) : v)
                   for (k, v) in row) for row in rows]
    end
  end
  return rows
end

"""Return model-aware `PormGRow` objects. Default format."""
function list(objct::SQLObjectHandler, ::Val{:row}; show_query::Symbol = :execute)
  show_query !== :execute && return query_list(objct, show_query=show_query)
  model = objct.object.model
  return [PormGRow(row, model) for row in _list_raw(objct)]
end

"""Return plain `Dict{Symbol,Any}` rows for framework integrations that need real dictionaries."""
function list(objct::SQLObjectHandler, ::Val{:dict}; show_query::Symbol = :execute)
  show_query !== :execute && return query_list(objct, show_query=show_query)
  return _list_raw(objct)
end

"""Return a JSON string without allocating `PormGRow` wrappers."""
function list(objct::SQLObjectHandler, ::Val{:json}; show_query::Symbol = :execute)
  show_query !== :execute && return query_list(objct, show_query=show_query)
  return JSON.json([Dict(String(k) => v for (k, v) in row) for row in _list_raw(objct)])
end

function list(objct::SQLObjectHandler, ::Val{F}; kwargs...) where F
  throw(ArgumentError("Unknown list format :$F. Expected :row, :dict, or :json."))
end

list(objct::SQLObjectHandler, format::Symbol; kwargs...) = list(objct, Val(format); kwargs...)
list(objct::SQLObjectHandler; kwargs...) = list(objct, Val(:row); kwargs...)

"""
    first(objct::SQLObjectHandler; show_query::Symbol = :execute)

Return the first `PormGRow` matching the current query, or `nothing` if no records match.

**Mutates the handler**: calls `objct.limit(1)` on the handler before executing. This is
permanent — the `limit(1)` persists on the object after the call returns (last-call
semantics, consistent with all other fluent methods such as `filter`, `order_by`, etc.).

Because the limit is mutated into the handler, chaining `.first()` followed by `.update()`
on the **same handler** will raise an `ArgumentError` ("UPDATE with LIMIT/OFFSET is not
supported"). Obtain a fresh handler or call `.update()` before `.first()` if both
operations are needed.

```julia
q = M.Driver.objects
q.filter("nationality" => "British")
driver = q.first()           # q now has limit=1

# Wrong — throws because limit=1 was set by first()
# q.update("nationality" => "English")

# Correct — create a separate handler for the update
u = M.Driver.objects
u.filter("nationality" => "British")
u.update("nationality" => "English")
```
"""
function first(objct::SQLObjectHandler; show_query::Symbol = :execute)
  objct.limit(1)
  res = list(objct, show_query=show_query)
  if show_query !== :execute
    return res
  end
  return isempty(res) ? nothing : res[1]
end
first(; kwargs...) = (objct) -> first(objct; kwargs...)

function _get_filter_repr(filter::SQLTypeOper)::String
  column = filter.column isa SQLTypeField ? filter.column.field : filter.column
  return "$(column) $(filter.operator) $(filter.values)"
end

function _get_filter_repr(filter::SQLTypeQ)::String
  return "(" * join(_get_filter_repr.(filter.filters), " AND ") * ")"
end

function _get_filter_repr(filter::SQLTypeQor)::String
  return "(" * join(_get_filter_repr.(getfield(filter, :or)), " OR ") * ")"
end

_get_filter_repr(filter) = sprint(show, filter)

"""
    get(objct::SQLObjectHandler, filters...; show_query=:execute) -> PormGRow

Return exactly one row matching the query filters.

Filters can be passed inline or applied with `.filter()` before calling `.get()`:

```julia
driver = M.Driver.objects.get("driverref" => "hamilton")
driver = M.Driver.objects.filter("driverref" => "hamilton").get()
```

Raises `DoesNotExist` when no rows match and `MultipleObjectsReturned` when more
than one row matches.
"""
function get(objct::SQLObjectHandler, filters...; show_query::Symbol = :execute)
  !isempty(filters) && up_filter!(objct.object, filters)

  q = deepcopy(objct)
  q = q.limit(2)

  if show_query !== :execute
    return query_list(q, show_query=show_query)
  end

  rows = list(q)
  model_name = objct.object.model.name
  filter_repr = isempty(objct.object.filter) ? "(none)" : join(_get_filter_repr.(objct.object.filter), ", ")

  isempty(rows) && throw(DoesNotExist(model_name, filter_repr))
  length(rows) > 1 && throw(MultipleObjectsReturned(model_name, length(rows), filter_repr))

  return rows[1]
end

function _row_update_pairs(updates::Dict{String,Any})
  return [field => updates[field] for field in sort(collect(keys(updates)))]
end

function _row_related_model(model::PormGModel, fk_meta::Models.sForeignKey)::PormGModel
  fk_meta.to isa PormGModel && return fk_meta.to

  model._module !== nothing || throw(ArgumentError("Cannot resolve related model $(fk_meta.to) for $(model.name); model module is not initialized."))
  related = Base.invokelatest(getfield, model._module, Symbol(fk_meta.to))
  related isa PormGModel && return related
  throw(ArgumentError("Related model $(fk_meta.to) for $(model.name) is not a PormG model."))
end

function _row_require_data_key(data::Dict{Symbol,Any}, key::Symbol, context::String)
  haskey(data, key) && return data[key]
  throw(ArgumentError("Cannot save() $(context): row data does not include required key '$(key)'. Select it before mutating and saving the row."))
end

"""
    save(row::PormGRow; show_query=:execute) -> PormGRow | Vector

Persist dirty fields assigned on a `PormGRow`.

Direct fields update the row's own table. Projected fields like
`driverid__forename` update the related table identified by the `driverid`
foreign key value already present on the row.
"""
function save(row::PormGRow; show_query::Symbol = :execute)
  dirty = getfield(row, :_dirty)
  isempty(dirty) && return row

  data = getfield(row, :_data)
  model = getfield(row, :_model)

  pk_sym = try
    Models.get_model_pk_field(model)
  catch e
    e isa ArgumentError || rethrow(e)
    throw(ArgumentError("save() requires exactly one primary key field; $(model.name) is not supported."))
  end
  pk_sym === nothing && throw(ArgumentError("save() requires exactly one primary key field; $(model.name) is not supported."))

  own_updates = Dict{String,Any}()
  fk_updates = Dict{Symbol,Dict{String,Any}}()
  touched_fk_fields = Set{Symbol}()

  for dirty_sym in dirty
    normalized = _normalize_row_symbol(dirty_sym)
    normalized_string = String(normalized)
    separator = findfirst("__", normalized_string)

    if separator === nothing
      own_updates[normalized_string] = data[normalized]
      if haskey(model.fields, normalized_string) && model.fields[normalized_string] isa Models.sForeignKey
        push!(touched_fk_fields, normalized)
      end
    else
      fk_sym = Symbol(normalized_string[1:first(separator)-1])
      column = normalized_string[last(separator)+1:end]
      fk_bucket = get!(fk_updates, fk_sym, Dict{String,Any}())
      fk_bucket[column] = data[normalized]
    end
  end

  conflict = intersect(touched_fk_fields, Set(keys(fk_updates)))
  isempty(conflict) || throw(ArgumentError(
    "Cannot save() a row after mutating both FK field(s) $(collect(conflict)) and projected '__' fields under the same prefix. Save the FK change separately first."
  ))

  settings, _, _ = get_settings(object(model))

  function planned_updates(show_mode::Symbol)
    inspections = Any[]

    if !isempty(own_updates)
      pk_value = _row_require_data_key(data, pk_sym, "own-table updates for $(model.name)")
      own_pairs = _row_update_pairs(own_updates)
      push!(inspections, object(model).filter(String(pk_sym) => pk_value).update(own_pairs...; show_query=show_mode))
    end

    for fk_sym in sort(collect(keys(fk_updates)); by=String)
      fk_meta = model.fields[String(fk_sym)]::Models.sForeignKey
      if fk_meta.pk_field === nothing
        throw(ArgumentError(
          "save() cannot update projected fields under '$(fk_sym)' because the FK's " *
          "target primary key has not been resolved. Call set_models() to initialize " *
          "the model before using save() with projected FK fields."
        ))
      end
      fk_value = _row_require_data_key(data, fk_sym, "projected updates under '$(fk_sym)' for $(model.name)")
      related_model = _row_related_model(model, fk_meta)
      fk_pairs = _row_update_pairs(fk_updates[fk_sym])
      related_query = object(related_model)
      related_query.filter(String(fk_meta.pk_field) => fk_value)
      push!(inspections, related_query.update(fk_pairs...; show_query=show_mode))
    end

    return inspections
  end

  if show_query !== :execute
    return planned_updates(show_query)
  end

  run_in_transaction(settings) do
    planned_updates(:execute)
  end

  empty!(dirty)
  return row
end
