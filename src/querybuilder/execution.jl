
function query(q::SQLObjectHandler; 
  table_alias::Union{Nothing, SQLTableAlias} = nothing,
  connection::Union{Nothing, PormGPostgres, SQLite.DB} = nothing,
  parameters::Union{Nothing, PormGPostgresParam} = nothing,
  cte::Union{Nothing, CTEDict} = nothing,
  show_query::Bool = false
  )

  @infiltrate false

  # Create a shared table alias counter for both CTEs and main query
  table_alias === nothing && (table_alias = SQLTbAlias())
  
  # IMPORTANT: Create the shared parameters object BEFORE building CTEs
  # This ensures all CTEs and the main query use sequential parameter numbering
  if parameters === nothing
    settings = config[q.object.model.connect_key]
    connection === nothing && (connection = settings.connections)
    parameters = get_parameter(connection)
  end

  # Build WITH clause - passes the SAME parameters object
  with_clause = build_cte_clause(q.object.ctes, connection, parameters, table_alias)  

  @infiltrate false

  # Main query uses the SAME parameters object (will continue numbering from where CTEs left off)
  instruction = build(q.object, table_alias=table_alias, connection=connection, parameters=parameters)
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
  
  # println(instruction.parameters)
    # $(instruction.agregate && size(instruction.group, 1) > 0 ? "GROUP BY $(join(instruction.group, ", ")) \n" : "") 
    # $(instruction.order |> length > 0 ? "ORDER BY" : "") $(join(instruction.order, ", \n  "))
    # $(q.object.limit !== 0 ? "LIMIT $(q.object.limit) \n" : "")
    # $(q.object.offset !== 0 ? "OFFSET $(q.object.offset) \n" : "")
    # """
  # @info respota  
  if show_query
    params_list = instruction.parameters.parameters
    @info "SQL Query" query=respota params=params_list |> string task_id=string(current_task())
    return nothing
  end
  return respota
end
show_query(q::SQLObjectHandler) = query(q; show_query=true)

# ---
# Count or check if exists
#

function do_count(oq::SQLObjectHandler; table_alias::Union{Nothing, SQLTableAlias} = nothing)::Integer
  settings = config[oq.object.model.connect_key]
  connection = settings.connections
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
  return query_result[1, 1]
end

function do_exists(oq::SQLObjectHandler; table_alias::Union{Nothing, SQLTableAlias} = nothing)
  try
    settings = config[oq.object.model.connect_key]
    connection = settings.connections
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

function insert(objct::SQLObject; table_alias::Union{Nothing, SQLTableAlias} = nothing, connection::Union{Nothing, PormGPostgres, SQLite.DB} = nothing)
  model = objct.model
  ensure_model_transaction_scope(model)
  settings = config[model.connect_key]
  connection === nothing && (connection = settings.connections) # TODO -- i need create a mode to handle with pools and create a function to this
  
  # colect name of the fields
  fields = model.field_names

  # Collect column names and parameter values
  quoted_field_columns = []
  param_values = []
  parameters = get_parameter(connection)
  
  # check if is allowed to insert
  !settings.change_data && throw(ArgumentError("Error in insert, the connection \e[4m\e[31m$(model.connect_key)\e[0m not allowed to insert"))
  
  # check if the fields are in objct.insert
  for field in fields
    if !haskey(objct.insert, field)
      # check if field allow null or if exist a default value
      if model.fields[field].default !== nothing
        objct.insert[field] = model.fields[field].default
      elseif model.fields[field].type == "TIMESTAMPTZ" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        objct.insert[field] = model.fields[field].formater(now(), settings.time_zone)
      elseif model.fields[field].type == "DATE" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        objct.insert[field] = model.fields[field].formater(today())
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
    # check if the insert has a field that not exist in the model
    in(field, fields) || throw("""Error in insert, the field "$(field)" not found in $(model.name)""")
    # check if the field is a primary key
    model.fields[field].primary_key && (pk_exist = true; push!(pk_field, field))
    # check if the field has max_length and validate
    hasfield(typeof(model.fields[field]), :max_length) && length(objct.insert[field]) > model.fields[field].max_length && error("""Error in insert, the field \e[4m\e[31m$(field)\e[0m has a max_length of \e[4m\e[32m$(model.fields[field].max_length)\e[0m, but the value has \e[4m\e[31m$(length(objct.create[field]))\e[0m""")
    # check if the field has max_digits and validate
    if hasfield(typeof(model.fields[field]), :max_digits)
      value_str = string(objct.insert[field])
      # @infiltrate
      parts = split(value_str, ".")
      integer_part = parts[1]
      fractional_part = length(parts) > 1 ? parts[2] : ""
      total_digits = length(replace(integer_part, "-" => "")) + (fractional_part == "" ? 0 : length(fractional_part))
      if total_digits > model.fields[field].max_digits
        error("""Error in insert, the field \e[4m\e[31m$(field)\e[0m has a max_digits of \e[4m\e[32m$(model.fields[field].max_digits)\e[0m, but the value has \e[4m\e[31m$(total_digits)\e[0m""")
      end
    end

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

  # @info sql

  # Execute safely
  if connection isa PormGPostgres
    result = fetch(settings, sql * " RETURNING *;", parameters)
    pk_exist && _update_sequence(model, connection, pk_field, settings)
    return Tables.rowtable(result) |> first |> x -> Dict(Symbol(k) => v for (k, v) in pairs(x))
  elseif connection isa SQLite.DB
    # SQLite implementation with parameters
    stmt = SQLite.Stmt(connection, sql)
    for (i, param) in enumerate(parameters.parameters)
      SQLite.bind!(stmt, i, param)
    end
    SQLite.execute(stmt)
    # Similar return logic as before
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
function _update_sequence(model::PormGModel, connection::SQLite.DB, pk_field::Vector{String})
  for field in pk_field
    max_id_query = "SELECT MAX($(field)) FROM $(string(model.name |> lowercase));"
    max_id_result = SQLite.Query(connection, max_id_query) |> DataFrame
    max_id = max_id_result[1, 1]
    if !isnothing(max_id)
      update_sequence_sql = "UPDATE sqlite_sequence SET seq = $(max_id + 1) WHERE name = '$(string(model.name |> lowercase))';"
      SQLite.execute(connection, update_sequence_sql)
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

function _set_update_query(v::FExpression, instruc::SQLInstruction)
  if v.operation === nothing
    # Simple field reference
    parts = split(v.field_name, "__")
    if size(parts, 1) > 1      
      return _build_row_join(parts, instruc)
    else
      if !(v.field_name in instruc.object.model.field_names)
        @error "Invalid field name for F expression" field_name=v.field_name model_name=instruc.object.model.name
        throw(ArgumentError("Invalid field name: $(v.field_name) for model $(instruc.object.model.name)"))
      end
      quoted_alias = quote_identifier(instruc.alias, instruc.connection)
      quoted_field = quote_identifier(v.field_name, instruc.connection)
      return string(quoted_alias, ".", quoted_field)
    end
  else
    # Field with operation - handle date arithmetic properly
    left_side = _set_update_query(FExpression(field_name = v.field_name, function_name = "F", column = v.field_name), instruc)    

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
        if v.operation in ["+", "-"] && _is_date_field(v.field_name, instruc)
          "$placeholder::text"
        else
          placeholder
        end
      end
    elseif isa(v.operand, Integer)
      # SECURITY: Handle integer operands for date arithmetic
      placeholder = add_parameter!(instruc.parameters, v.operand)
      if v.operation in ["+", "-"] && _is_date_field(v.field_name, instruc)
        # Convert integer days to interval for date arithmetic
        "($placeholder || ' days')::interval"
      else
        placeholder
      end
    else
      # SECURITY: Use parameterized query for other numeric values
      add_parameter!(instruc.parameters, v.operand)
    end
    
    return "($(left_side) $(v.operation) $(right_side))"
  end
end

function _build_from_tables(row_join::Vector{Dict{String, Union{String, Vector{FilterType}}}}, connection)
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
  return join(tables, ", ")
end
function _build_join_conditions(row_join::Vector{Dict{String, Union{String, Vector{FilterType}}}}, connection)
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
  return join(conditions, " AND ")
end

function update(objct::SQLObject; table_alias::Union{Nothing, SQLTableAlias} = nothing, connection::Union{Nothing, PormGPostgres, SQLite.DB} = nothing, show_query::Bool = false)
  model = objct.model
  ensure_model_transaction_scope(model)
  settings = config[model.connect_key]
  connection === nothing && (connection = settings.connections)
 
  instruction = build(objct, table_alias=table_alias, connection=connection) 

  # Check if is allowed to update
  !settings.change_data && throw(ArgumentError("Error in update, the connection \e[4m\e[31m$(model.connect_key)\e[0m not allowed to update"))
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
  set_clause_parts = String[]
  for field in keys(objct.insert)    
    # check if the create has a field that not exist in the model
    in(field, fields) || throw("""Error in update, the field "$(field)" not found in $(model.name)""")
    # check if field is a primary key and not allow to update
    model.fields[field].primary_key && throw("Error in update, the field \e[4m\e[31m$(field)\e[0m is a primary key and not allow to update")
    
    # Max length validation
    if hasfield(typeof(model.fields[field]), :max_length) && isa(objct.insert[field], AbstractString)
      length(objct.insert[field]) > model.fields[field].max_length && 
        throw("""Error in update, the field \e[4m\e[31m$(field)\e[0m has a max_length of \e[4m\e[32m$(model.fields[field].max_length)\e[0m, but the value has \e[4m\e[31m$(length(objct.insert[field]))\e[0m""")
    end
    
    # Max digits validation
    if hasfield(typeof(model.fields[field]), :max_digits)
      value_str = string(objct.insert[field])
      if contains(value_str, ".")
        integer_part, fractional_part = split(value_str, ".")
        total_digits = length(replace(integer_part, "-" => "")) + length(fractional_part)
        if total_digits > model.fields[field].max_digits
          throw("""Error in update, the field \e[4m\e[31m$(field)\e[0m has a max_digits of \e[4m\e[32m$(model.fields[field].max_digits)\e[0m, but the value has \e[4m\e[31m$(total_digits)\e[0m""")
        end
      end
    end
    
    quoted_field = quote_identifier(field, connection)

    if isa(objct.insert[field], SQLTypeF)     
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
    if connection isa PormGPostgres
      # PostgreSQL: UPDATE...FROM syntax
      from_tables = _build_from_tables(instruction.row_join, connection)
      join_conditions = _build_join_conditions(instruction.row_join, connection)
      all_conditions = isempty(instruction._where) ? join_conditions :
          join([join_conditions, join(instruction._where, " AND ")], " AND ")
      
      sql = """
      UPDATE $(safe_table_name) AS $(safe_alias)
      SET $(set_clause)
      FROM $(from_tables)
      WHERE $(all_conditions)
      """
    elseif connection isa SQLite.DB
      # SQLite: Use subquery or multiple table syntax
      # For SQLite, we need to use a different approach since it doesn't support UPDATE...FROM
      # We'll use UPDATE with WHERE EXISTS or IN subqueries
      
      # Build subquery for the joined tables
      subquery_conditions = String[]
      for join_dict in instruction.row_join
        b_table = safe_table_identifier(join_dict["b"], connection)
        alias_a = quote_identifier(instruction.alias, connection)
        alias_b = quote_identifier(join_dict["alias_b"], connection)
        key_a = quote_identifier(join_dict["key_a"], connection)
        key_b = quote_identifier(join_dict["key_b"], connection)
        
        push!(subquery_conditions, """
        EXISTS (
          SELECT 1 FROM $(b_table) AS $(alias_b) 
          WHERE $(alias_a).$(key_a) = $(alias_b).$(key_b)
        )
        """)
      end
      
      all_conditions = vcat(subquery_conditions, instruction._where)
      
      sql = """
      UPDATE $(safe_table_name) AS $(safe_alias)
      SET $(set_clause)
      WHERE $(join(all_conditions, " AND "))
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

  if show_query
    params_list = (parameters === nothing) ? [] : (hasproperty(parameters, :parameters) ? parameters.parameters : parameters)
    @info "SQL Query" query=sql params=params_list |> string task_id=string(current_task())
    return sql
  end

  # @infiltrate

  # return nothing

  try
    # Execute with parameters
    if connection isa PormGPostgres
      fetch(settings, sql, parameters)
    elseif connection isa SQLite.DB
      stmt = SQLite.Stmt(connection, sql)
      for (i, param) in enumerate(parameters.parameters)
        SQLite.bind!(stmt, i, param)
      end
      SQLite.execute(stmt)
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
function query_list(objct::SQLObjectHandler)
  if objct.object.model.connect_key === nothing
    throw(ArgumentError("Error in quering data, the model \e[4m\e[31m$(objct.object.model.name)\e[0m not have a build correctly, please reload the app"))
  end
  settings = config[objct.object.model.connect_key]
  connection = settings.connections

  sql = query(objct, connection=connection)
  @infiltrate false
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
function list(objct::SQLObjectHandler)
  result = query_list(objct)
  return Tables.rowtable(result) |> collect |> x -> [Dict(Symbol(k) => v for (k, v) in pairs(row)) for row in x]
end

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
function list_json(objct::SQLObjectHandler)
  records = list(objct)
  # Convert Symbol keys to String keys for JSON serialization
  string_key_records = [Dict(String(k) => v for (k, v) in pairs(record)) for record in records]
  return JSON.json(string_key_records)
end
