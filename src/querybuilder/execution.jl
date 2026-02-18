
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
  elseif mode === :dict
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
    throw(ArgumentError("Invalid show_query mode: $mode. Must be one of: :sql, :dict, :params, :none"))
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
      return query(q, show_query=:dict, connection=conn)
  elseif operation === :insert
      return insert(q.object, show_query=:dict, connection=conn)
  elseif operation === :update
      return update(q.object, show_query=:dict, connection=conn)
  elseif operation === :delete
      res = delete(q, show_query=:dict, connection=conn)
      # delete returns (count, results) when executing, but when show_query=:dict
      # it returns (results) or [(results)]. We want just the inspection dict.
      return res isa Tuple ? res[2] : (res isa Vector ? res[1] : res)
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
  show_query::Symbol = :execute
  )

  @infiltrate false

  # Create a shared table alias counter for both CTEs and main query
  table_alias === nothing && (table_alias = SQLTbAlias())
  
  settings, connection, conn_key = get_settings(q, connection=connection)

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
  set_context!(parameters, :cte)
  with_clause = build_cte_clause(q.object.ctes, connection, parameters, table_alias)  

  @infiltrate false

  # Main query uses the SAME parameters object (will continue numbering from where CTEs left off)
  # Context switching for select/where/join happens inside build()
  instruction = build(q.object, table_alias=table_alias, connection=connection, parameters=parameters)
  
  # Restore the context for parent query if this was a subquery
  if old_context !== nothing
    set_context!(parameters, old_context)
  end
  if cte !== nothing
    @infiltrate false
    _build_cte_custom_model(cte, instruction)
  end
  
  # Quote table name and alias to prevent SQL injection
  safe_table_name = safe_table_identifier(q.object.model.name, instruction.connection)
  safe_alias = quote_identifier(instruction.alias, instruction.connection)  
  
  respota = """$(with_clause)SELECT
      $(q.object.distinct ? "DISTINCT" : "") $(_query_select(instruction.select ))
    FROM $safe_table_name as $safe_alias
    $(join(instruction.join, "\n"))
    """
  if !isempty(instruction._where)
    respota *= "WHERE " * join(instruction._where, " AND \n   ") * "\n"
  end
  if instruction.agregate && size(instruction.group, 1) > 0
    respota *= "GROUP BY $(join(instruction.group, ", ")) \n"
  end
  if !isempty(instruction.having)
    respota *= "HAVING " * join(instruction.having, " AND \n   ") * "\n"
  end
  if !isempty(instruction.order)
    respota *= "ORDER BY " * join(instruction.order, ", \n  ") * "\n"
  end
  if q.object.limit !== 0
    respota *= "LIMIT $(q.object.limit) \n"
  end
  if q.object.offset !== 0
    respota *= "OFFSET $(q.object.offset) \n"
  end
  
  # Store the final parameters object with all CTEs + main query parameters
  q.object.parameters = instruction.parameters
  
  if show_query !== :execute
    return _show_query_result(respota, instruction.parameters, show_query; 
                            connection=instruction.connection, 
                            model_name=q.object.model.name, 
                            operation=:select)
  end
  return respota
end
show_query(q::SQLObjectHandler, mode::Symbol = :sql) = query(q; show_query=mode)

# ---
# Count or check if exists
#

function do_count(oq::SQLObjectHandler; table_alias::Union{Nothing, SQLTableAlias} = nothing)::Integer
  # Resolve settings
  settings, connection, conn_key = get_settings(oq)
  
  q = deepcopy(oq) # Create a copy of the SQLObjectHandler to avoid modifying the original object  
  q.object.order = []# clear order_by
  q.object.values = [] # clear values

  instruction = build(q.object, table_alias=table_alias, connection=connection) 
  
  # Quote table name and alias to prevent SQL injection
  safe_table_name = safe_table_identifier(q.object.model.name, instruction.connection)
  safe_alias = quote_identifier(instruction.alias, instruction.connection)
  
  # Build WITH clause if CTEs are defined
  with_clause = build_cte_clause(q.object.ctes, instruction.connection, instruction.parameters, table_alias)
  
  resposta = """$(with_clause)SELECT
      COUNT($(q.object.distinct ? "DISTINCT *" : "*"))
    FROM $safe_table_name as $safe_alias
    $(join(instruction.join, "\n"))
    $(instruction._where |> length > 0 ? "WHERE" : "") $(join(instruction._where, " AND \n   "))
    $(instruction.agregate ? "GROUP BY $(join(instruction.group, ", ")) \n" : "") 
    """
  query_result = fetch(settings, resposta, instruction.parameters)
  # SQLite returns a Query iterator that doesn't support [row, col] indexing;
  # convert to a rowtable first, then extract the scalar count value.
  if query_result isa AbstractMatrix || hasmethod(getindex, Tuple{typeof(query_result), Int, Int})
    return query_result[1, 1]
  else
    row = Tables.rowtable(query_result) |> first
    return first(values(row))
  end
end

function do_exists(oq::SQLObjectHandler; table_alias::Union{Nothing, SQLTableAlias} = nothing)
  try
    # Resolve settings
    settings, connection, conn_key = get_settings(oq)
    
    q = deepcopy(oq) # Create a copy of the SQLObjectHandler to avoid modifying the original object
    q.object.order = [] # clear order_by
    q.object.values = [] # clear values
    instruction = build(q.object, table_alias=table_alias, connection=connection)
    limit_clause = "LIMIT 1"
    offset_clause = q.object.offset > 0 ? "OFFSET $(q.object.offset)" : ""
    
    # Quote table name and alias to prevent SQL injection
    safe_table_name = safe_table_identifier(q.object.model.name, instruction.connection)
    safe_alias = quote_identifier(instruction.alias, instruction.connection)
    
    sql = """
    SELECT 1
    FROM $safe_table_name as $safe_alias
    $(join(instruction.join, "\n"))
    $(isempty(instruction._where) ? "" : "WHERE " * join(instruction._where, " AND \n   "))
    $(instruction.agregate && !isempty(instruction.group) ? "GROUP BY $(join(instruction.group, ", "))" : "")
    $limit_clause
    $offset_clause
    """    
    @infiltrate false
    result = fetch(settings, sql, instruction.parameters) |> Tables.rowtable
    @infiltrate false
    return length(result) > 0
  catch e
    @infiltrate false
    # Re-throw validation/argument errors so user sees helpful messages
    if e isa ArgumentError
      rethrow(e)
    end
    @error "Error in do_exists for model $(oq.object.model.name): $e"
    return false
  end
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
  !settings.change_data && throw(ArgumentError("Error in insert, the connection \e[4m\e[31m$conn_key\e[0m not allowed to insert"))
  
  # check if the fields are in objct.insert
  for field in fields
    if !haskey(real_obj.insert, field)
      # check if field allow null or if exist a default value
      if model.fields[field].default !== nothing
        real_obj.insert[field] = model.fields[field].default
      elseif model.fields[field].type == "TIMESTAMPTZ" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        real_obj.insert[field] = model.fields[field].formater(now(), settings.time_zone)
      elseif model.fields[field].type == "DATE" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        real_obj.insert[field] = model.fields[field].formater(today())
      elseif model.fields[field].null || model.fields[field].primary_key
        continue
      else
        throw(ArgumentError("Error in insert, the field \e[4m\e[31m$(field)\e[0m not allow null"))
      end
    end
  end

  pk_exist::Bool = false
  pk_field::Vector{String} = []
  for field in keys(objct.insert)
    # Validation checks
    validate_field_data(model, field, objct.insert[field], "insert"; allow_primary_key = true)

    # check if the field is a primary key
    model.fields[field].primary_key && (pk_exist = true; push!(pk_field, field))

     # Add safely quoted field name to columns list
    push!(quoted_field_columns, quote_identifier(field, connection))

    # Format and add value to parameters
    push!(param_values, add_parameter!(parameters, objct.insert[field] |> model.fields[field].formater))

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
    return _show_query_result(sql, parameters, show_query; 
                            connection=connection, 
                            model_name=model.name, 
                            operation=:insert)
  end

  # Execute safely
  if connection isa PormGPostgres
    result = fetch(settings, sql * " RETURNING *;", parameters)
    pk_exist && _update_sequence(model, connection, pk_field, settings)
    return Tables.rowtable(result) |> first |> x -> Dict(Symbol(k) => v for (k, v) in pairs(x))
  elseif connection isa PormGSQLite
    # SQLite: use fetch() to properly acquire/release from pool
    # Use RETURNING * if supported (SQLite 3.35+)
    try
        result = fetch(settings, sql * " RETURNING *;", parameters)
        return Tables.rowtable(result) |> first |> x -> Dict(Symbol(k) => v for (k, v) in pairs(x))
    catch e
        # Fallback for older SQLite versions
        fetch(settings, sql, parameters)
        # Return the input data as a fallback (will lack auto-generated fields)
        return Dict(Symbol(k) => v for (k, v) in pairs(real_obj.insert))
    end
  else
    throw("Unsupported connection type")
  end

end

function _update_sequence(model::PormGModel, connection::PormGPostgres, pk_field::Vector{String}, settings::SQLConn; ignore_tx::Bool = false)
  @infiltrate false
  for field in pk_field
    if settings.change_db
      try
        safe_field_name = quote_identifier(field, connection)
        safe_table_name = safe_table_identifier(string(model.name), connection)
        fetch(connection, "SELECT setval('$(string(model.name))_$(field)_seq', (SELECT MAX($(safe_field_name)) + 1 FROM $(safe_table_name)), true)"; ignore_tx=ignore_tx)
      catch e
        if occursin("does not exist", e |> string)        
          _fix_sequence_name(connection, model, ignore_tx=ignore_tx)
          safe_table_name = safe_table_identifier(string(model.name), connection)
          safe_field_name = quote_identifier(field, connection)
          fetch(connection, "SELECT setval('$(string(model.name))_$(field)_seq', (SELECT MAX($safe_field_name) + 1 FROM $safe_table_name), true)"; ignore_tx=ignore_tx)
        end
      end
    elseif settings.django_prefix !== nothing
      @infiltrate false
      try
        # For Django prefixed tables, try with django prefix pattern
        sequence_name = "$(model.name)_$(field)_seq"
        safe_table_name = safe_table_identifier(model.name, connection)
        safe_field_name = quote_identifier(field, connection)
        fetch(connection, "SELECT setval('$sequence_name', (SELECT MAX($safe_field_name) + 1 FROM $safe_table_name), true)"; ignore_tx=ignore_tx)
      catch e
        if occursin("does not exist", e |> string)
          # # Try to find the actual sequence name
          # sequences = fetch(connection, """
          #   SELECT sequence_name 
          #   FROM information_schema.sequences 
          #   WHERE sequence_name LIKE '%$(settings.django_prefix)_$(model.name |> lowercase)%'
          #   AND sequence_schema = 'public';
          # """) |> DataFrames.DataFrame
          
          # if size(sequences, 1) > 0
          #   sequence_name = sequences[1, :sequence_name]
          #   fetch(connection, "SELECT setval('$(sequence_name)', (SELECT MAX($(field)) + 1 FROM $(settings.django_prefix)_$(model.name |> lowercase)), true);")
          # else
          #   @warn "Could not find sequence for $(settings.django_prefix)_$(model.name |> lowercase).$(field)"
          # end
        else
          rethrow(e)
        end
      end
    end
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
    max_id_query = "SELECT MAX($(field)) as m FROM $(string(model.name |> lowercase));"
    # Execute query and convert to DataFrame to safely access the result
    df = fetch(connection, max_id_query) |> DataFrames.DataFrame
    
    if size(df, 1) > 0
      max_id = df[1, :m]
      if !ismissing(max_id) && !isnothing(max_id)
        update_sequence_sql = "UPDATE sqlite_sequence SET seq = $(max_id + 1) WHERE name = '$(string(model.name |> lowercase))';"
        fetch(settings, update_sequence_sql)
      end
    end
  end
end

# TODO: Implement a function to handle the update with multiple dispatch
# Helper function to check if a field is a date field
function _is_date_field(field_name::String, instruc::SQLInstruction)
  model = instruc.object.model
  # @infiltrate
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

function _set_update_query(v::FExpression, instruc::SQLInstruction)
  if v.operation === nothing
    # Resolve the field using existing logic for joins and modifiers
    if v.field_name isa String
      return _get_filter_query(v.field_name, instruc)
    else
      # Recursive call for nested expressions
      return _set_update_query(v.field_name, instruc)
    end
  else
    # Field with operation - handle nesting and date arithmetic properly
    left_side = if v.field_name isa String
      _get_filter_query(v.field_name, instruc)
    else
      _set_update_query(v.field_name, instruc)
    end

    # @infiltrate
    right_side = if isa(v.operand, FExpression)
      _set_update_query(v.operand, instruc)
    elseif isa(v.operand, String)
      # Check if it's a field reference
      if contains(v.operand, "__") || v.operand in instruc.object.model.field_names
        _set_update_query(FExpression(field_name = v.operand, function_name = "F", column = v.operand), instruc)
      else
        # SECURITY: Use parameterized query for literal values
        placeholder = add_parameter!(instruc.parameters, v.operand)
        # For string literals that might be used in date operations, add explicit casting
        if v.operation in ["+", "-"] && (v.field_name isa String && _is_date_field(v.field_name, instruc))
          instruc.connection isa PormGSQLite ? placeholder : "$placeholder::text"
        else
          placeholder
        end
      end
    elseif isa(v.operand, Integer)
      # SECURITY: Handle integer operands for date arithmetic
      placeholder = add_parameter!(instruc.parameters, v.operand)
      if v.operation in ["+", "-"] && (v.field_name isa String && _is_date_field(v.field_name, instruc))
        if instruc.connection isa PormGSQLite
          # SQLite handles date arithmetic via functions, but for the infix expression
          # we just return the placeholder and handle the wrapper in the final return
          placeholder
        else
          # Convert integer days to interval for date arithmetic (PostgreSQL)
          "($placeholder || ' days')::interval"
        end
      else
        placeholder
      end
    else
      # SECURITY: Use parameterized query for other numeric values
      add_parameter!(instruc.parameters, v.operand)
    end
    
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

function update(objct::SQLObject; table_alias::Union{Nothing, SQLTableAlias} = nothing, connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing, show_query::Symbol = :execute)
  real_obj = objct isa SQLObjectHandler ? objct.object : objct
  model = real_obj.model
  ensure_model_transaction_scope(model)

  # Resolve settings
  settings, connection, conn_key = get_settings(objct, connection=connection)
 
  instruction = build(real_obj, table_alias=table_alias, connection=connection) 

  # Check if is allowed to update
  !settings.change_data && throw(ArgumentError("Error in update, the connection \e[4m\e[31m$conn_key\e[0m not allowed to update"))
  # Don't allow to update a field without filter
  instruction._where |> isempty && throw("Error in update, the update must have a filter")
  
  parameters = instruction.parameters
  fields = model.field_names

  # Check if the fields need to be updated automatically
  for field in fields
    if !haskey(objct.insert, field)
      if model.fields[field].type == "TIMESTAMPTZ" && (model.fields[field].auto_now)
        objct.insert[field] = model.fields[field].formater(now(), settings.time_zone)
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
    
    quoted_field = quote_identifier(field, connection)

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
  
  has_joins = !isempty(instruction.row_join)
  sql = ""
  
  if has_joins
    if connection isa PormGPostgres || connection isa PormGSQLite
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
    return _show_query_result(sql, parameters, show_query; 
                            connection=connection, 
                            model_name=model.name, 
                            operation=:update)
  end

  # @infiltrate

  # return nothing

  # Execute with parameters
  try
    if connection isa PormGPostgres
      fetch(settings, sql, parameters)
    elseif connection isa PormGSQLite
      # SQLite: use fetch() to properly acquire/release from pool
      fetch(settings, sql, parameters)
    else
      throw("Unsupported connection type")
    end
    
    # @info "Update completed successfully"
    
  catch e
    @error "Error executing UPDATE query" exception=(e, catch_backtrace()) sql=sql
    rethrow(e)
  end

  return nothing
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
df = query |> list |> DataFrame
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
Fetches a list of records from the database and returns them as an array of dictionaries.

This function executes the query and converts each row to a dictionary with column names as keys.

# Arguments
- `objct::SQLObjectHandler`: The SQL object handler containing the query

# Returns
- `Vector{Dict{Symbol, Any}}`: Array of dictionaries, where each dictionary represents a row

# Example
```julia
query = M.Result |> object
query.filter("raceid__year" => 2020)
query.values("driverid__forename", "constructorid__name", "laps")
records = query |> list  # Returns array of dictionaries
# Example output: [Dict(:driverid__forename => "Lewis", :constructorid__name => "Mercedes", :laps => 58), ...]
```
"""
function list(objct::SQLObjectHandler; show_query::Symbol = :execute)
  result = query_list(objct, show_query=show_query)
  if show_query !== :execute
    return result
  end
  return Tables.rowtable(result) |> collect |> x -> [Dict(Symbol(k) => v for (k, v) in pairs(row)) for row in x]
end
list(; kwargs...) = (objct) -> list(objct; kwargs...)

"""
Fetches a list of records from the database and returns them as a JSON string.

This function executes the query, converts each row to a dictionary, and serializes the result as JSON.

# Arguments
- `objct::SQLObjectHandler`: The SQL object handler containing the query

# Returns
- `String`: JSON string representation of the query results

# Example
```julia
query = M.Result |> object
query.filter("raceid__year" => 2020)
query.values("driverid__forename", "constructorid__name", "laps")
json_data = query |> list_json  # Returns JSON string
# Example output: "[{\"driverid__forename\":\"Lewis\",\"constructorid__name\":\"Mercedes\",\"laps\":58}]"
```
"""
function list_json(objct::SQLObjectHandler; show_query::Symbol = :execute)
  records = list(objct, show_query=show_query)
  if show_query !== :execute
    return records
  end
  # Convert Symbol keys to String keys for JSON serialization
  string_key_records = [Dict(String(k) => v for (k, v) in pairs(record)) for record in records]
  return JSON.json(string_key_records)
end
list_json(; kwargs...) = (objct) -> list_json(objct; kwargs...)

function first(objct::SQLObjectHandler; show_query::Symbol = :execute)
  objct.limit(1)
  res = list(objct, show_query=show_query)
  if show_query !== :execute
    return res
  end
  return isempty(res) ? nothing : res[1]
end
first(; kwargs...) = (objct) -> first(objct; kwargs...)
