# ---
# Process the query entries to build the SQLObjectQuery object
#

"""
    get_settings(obj::Union{SQLObject, SQLObjectHandler}; connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing)

Resolves the database settings for a query. 
Returns a tuple of `(settings::SQLConn, connection, conn_key::String)`.

If a `connection` is provided, it is returned as is. 
Otherwise, it returns the default connection from the resolved settings.
"""
function get_settings(obj::Union{SQLObject,SQLObjectHandler}; connection::Union{Nothing,PormGPostgres,PormGSQLite}=nothing)
  q = obj isa SQLObjectHandler ? obj.object : obj
  conn_key = q.connect_key !== nothing ? q.connect_key : q.model.connect_key
  settings = get_configuration_settings(conn_key)

  final_connection = connection === nothing ? settings.connections : connection
  return settings, final_connection, conn_key
end

# I may not need this function initially, but it can be useful when processing queries
# function _check_function(f::OperObject)
function _check_function(f::Vector{N} where N<:SQLObject)
  r_v::Vector{SQLObject} = []
  for v in f
    if isa(v, SQLTypeOper)
      push!(r_v, _check_filter(v))
    else
      push!(r_v, _check_function(v))
    end
  end
  return r_v
end
function _check_function(f::FObject)
  f.column = _check_function(f.column)
  return f
end
function _check_function(f::Vector{FObject})
  for i in 1:size(f, 1)
    f[i] = _check_function(f[i])
  end
  return f
end
function _check_function(f::SQLTypeOper)
  f.column = _check_function(f.column)
  return f
end
function _check_function(f::Union{SQLText,SQLField})
  return f
end
function _check_function(f::Vector{T}) where T<:Union{SQLType,Any}
  for i in 1:length(f)
    f[i] = _check_function(f[i])
  end
  return f
end
function _check_function(f::QorObject)
  for i in 1:length(f.or)
    f.or[i] = _check_function(f.or[i])
  end
  return f
end
function _check_function(f::QObject)
  for i in 1:length(f.filters)
    f.filters[i] = _check_function(f.filters[i])
  end
  return f
end
function _check_function(x::Vector{String})
  if length(x) == 1
    return x[1]
  else
    if haskey(PormGtransform, x[end])
      resp = getfield(@__MODULE__, Symbol(PormGtransform[x[end]]))(x[1:end-1])
      return _check_function(resp)
    else
      joined_keys_with_prefix_func = join(map(key -> " \e[32m@" * key, keys(PormGtransform) |> collect), ", ")
      joined_keys_with_prefix_oper = join(map(key -> " \e[33m@" * key, keys(PormGsuffix) |> collect), ", ")
      if haskey(PormGsuffix, x[end])
        yes = "you can use \"column__@\e[32m$(x[end])\e[0m\""
        not = "you can not use \"column__\e[31m@$(x[end])__@function\e[0m\". valid functions are:\n$(joined_keys_with_prefix_func)\e[0m\nvalid operators are:\n$(joined_keys_with_prefix_oper)\e[0m"
        throw(ArgumentError("\e[4m\e[31m$(x[end])\e[0m is not allowed.\n$yes\n$not"))
      else
        throw(ArgumentError("\"$(x[1])__\e[31m@$(x[end])\e[0m\" is invalid;\n please use a valid function:\n  - $(joined_keys_with_prefix_func)\e[0m\nor a valid operator:\n  - $(joined_keys_with_prefix_oper)\e[0m"))
      end
    end
  end
end
_check_function(x::String) = _check_function(String.(split(x, "__@")))
function _check_function(x::FExpression)
  return x
end

"""
  _get_pair_to_oper(x::Pair)

  Converts a Pair object to an OperObject. If the Pair's key is a string, it checks if it contains an operator suffix (e.g. "__@gte", "__@lte") and returns an OperObject with the corresponding operator. If the key does not contain an operator suffix, it returns an OperObject with the "=" operator. If the key is not a string, it throws an error.

  ## Arguments
  - `x::Pair`: A Pair object to be converted to an OperObject.

  ## Returns
  - `OperObject`: An OperObject with the corresponding operator and values.

"""
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:Union{String,Number,Bool,Dates.TimeType,Dates.Period,Dates.CompoundPeriod}
  if haskey(PormGsuffix, x.first[end])
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    return OperObject(operator="=", values=x.second, column=SQLField(_check_function(x.first), join(x.first, "__"))) # TODO, maybe I need to check if the column is valid and process the function before store
  end
end
function _get_pair_to_oper(x::Pair{String,T}) where T<:Union{String,Number,Bool,Dates.Date,Dates.DateTime,Dates.TimeType,Dates.Period,Dates.CompoundPeriod}
  return _get_pair_to_oper(String.(split(x.first, "__@")) => x.second)
end
function _get_pair_to_oper(x::Pair{String,Vector{T}}) where T<:Union{Missing,String,Number,Bool,Dates.TimeType,Dates.Period,Dates.CompoundPeriod}
  return _get_pair_to_oper(String.(split(x.first, "__@")) => x.second)
end
# Store SQLObject, to use __@in operator
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:SQLObjectHandler
  if x.first[end] in ["in", "nin"]
    # @pormg_debug
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    throw(ArgumentError("Error in filter, Invalid operator for \e[31m$(x.first[end])\e[0m, only \e[32m'in and nin'\e[0m is allowed with a object"))
  end
end
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:SQLTypeF
  if haskey(PormGsuffix, x.first[end])
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    return OperObject(operator="=", values=x.second, column=SQLField(_check_function(x.first), join(x.first, "__")))
  end
end
function _get_pair_to_oper(x::Pair{Vector{String},Vector{T}}) where T<:Union{Missing,String,Number,Bool,Dates.TimeType,Dates.Period,Dates.CompoundPeriod}
  if x.first[end] in ["in", "nin"]
    @pormg_debug false
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  elseif x.first[end] == "range"
    if length(x.second) != 2
      throw(ArgumentError("Error in filter, 'range' operator requires exactly 2 values, got $(length(x.second))"))
    end
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    throw(ArgumentError("Error in filter, Invalid operator for \e[31m$(x.first[end])\e[0m, only \e[32m'in, nin and range'\e[0m is allowed with a vector of values"))
  end
end
function _get_pair_to_oper(x::Pair{Vector{String},Tuple{T,T}}) where T
  if x.first[end] == "range"
    return OperObject(operator=PormGsuffix[x.first[end]], values=[x.second[1], x.second[2]], column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    throw(ArgumentError("Error in filter, Invalid operator for \e[31m$(x.first[end])\e[0m, only \e[32m'range'\e[0m is allowed with a tuple of values"))
  end
end
function _get_pair_to_oper(x::Pair{Vector{String},Date})
  _get_pair_to_oper(x.first => x.second |> string)
end



function _check_filter(x::Pair)
  if isa(x.first, String)
    check = String.(split(x.first, "__@"))
    try
      # @pormg_debug
      return _get_pair_to_oper(check => x.second)
    catch e
      @pormg_debug false
      @error "Error in filter processing '$(x.first)'" exception = (e, catch_backtrace())
      rethrow(e)
    end
  else
    throw("Error in filter: '$(x.first) => ...' must be a String, got $(typeof(x.first))")
  end
end

# does this obsolet?
function _get_join_query(array::Vector{String}; array_store::Vector{String}=String[])
  array = copy(array)
  for i in 1:size(array, 1)
    for (k, value) in PormGsuffix
      if endswith(array[i], k)
        array[i] = array[i][1:end-length(k)]
      end
    end
    for (k, value) in PormGtransform
      if endswith(array[i], k)
        array[i] = array[i][1:end-length(k)]
      end
    end
  end

  # how join to Vector
  append!(array_store, array)
  unique!(array_store)
  return array_store
end

function _get_join_query(x::Tuple{Pair{String,Integer},Vararg{Pair{String,Integer}}}; array_store::Vector{String}=String[])
  array = String[]
  for (k, v) in x
    push!(array, k)
  end
  _get_join_query(array, array_store=array_store)
end
function _get_join_query(x::Tuple{String,Vararg{String}}; array_store::Vector{String}=String[])
  array = String[]
  for v in x
    push!(array, v)
  end
  _get_join_query(array, array_store=array_store)
end
function _get_join_query(x::Dict{String,Union{Integer,String}}; array_store::Vector{String}=String[])
  array = String[]
  for (k, v) in x
    push!(array, k)
  end
  _get_join_query(array, array_store=array_store)
end

function _get_alias_name(df::DataFrames.DataFrame, alias::String)
  array = vcat(df.alias_a, df.alias_b)
  count = 1
  while true
    alias_name = alias * string("_", count) # TODO maybe when exist more then one sql, the alias must be different
    if !in(alias_name, array)
      return alias_name
    end
    count += 1
  end
end
function _get_alias_name(row_join::Vector{Dict{String,Union{String,Vector{FilterType}}}}, alias::String)
  array = vcat([r["alias_a"] for r in row_join], [r["alias_b"] for r in row_join])
  count = 1
  while true
    alias_name = alias * string("_", count) # TODO maybe when exist more then one sql, the alias must be different
    if !in(alias_name, array)
      return alias_name
    end
    count += 1
  end
end

function _insert_join(
  row_join::Vector{Dict{String,Union{String,Vector{FilterType}}}},
  row::Dict{String,Union{String,Vector{FilterType}}},
  row_path::Vector{String}, join_path::String)
  @pormg_debug false
  if size(row_join, 1) == 0
    push!(row_join, row)
    push!(row_path, join_path)
    return row["alias_b"]
  else
    check = filter(r -> r["a"] == row["a"] && r["b"] == row["b"] && r["key_a"] == row["key_a"] && r["key_b"] == row["key_b"] && r["alias_a"] == row["alias_a"], row_join)
    if size(check, 1) == 0
      @pormg_debug false
      push!(row_join, row)
      push!(row_path, join_path)
      return row["alias_b"]
    else
      if size(check, 1) > 1
        throw("Error in join")
      end
      return check[1]["alias_b"]
    end
  end
end

function _check_if_field_is_a_operator(field::String)
  common_operators = ["exact", "iexact", "contains", "icontains", "in", "gt", "gte", "lt", "lte",
    "startswith", "istartswith", "endswith", "iendswith", "range", "date",
    "year", "iso_year", "quarter", "month", "day", "week", "week_day", "iso_week_day",
    "hour", "minute", "second", "isnull", "regex", "iregex"]
  if field in common_operators
    throw(ArgumentError("The filter operator '\e[31m$field\e[0m' requires '@' prefix. Use '\e[32m$field\e[0m' => ... as part of '__\e[33m@$field\e[0m' syntax. Example: \e[36mq.filter(\"name__@$field\" => value)\e[0m"))
  end
end

function _normalize_join_type(join_type::String)
  valid_joins = ["INNER", "LEFT", "RIGHT", "FULL", "CROSS"]
  normalized = uppercase(strip(join_type))
  normalized in valid_joins || throw(ArgumentError("Invalid join type '$(join_type)'. Valid types: $(join(valid_joins, ", "))"))
  return normalized
end

function _get_join_config(q::SQLObject, join_path::String)
  haskey(q.custom_join, join_path) || return nothing
  config = q.custom_join[join_path]
  return config isa Dict{String,Any} ? config : nothing
end

function _get_join_field(q::SQLObject, join_path::String)
  config = _get_join_config(q, join_path)
  config === nothing && return nothing
  return get(config, "field", nothing)
end

function _get_join_filters(q::SQLObject, join_path::String)
  config = _get_join_config(q, join_path)
  config === nothing && return nothing
  filters = get(config, "filters", nothing)
  return filters isa Vector{FilterType} ? filters : nothing
end

function _get_join_type_override(q::SQLObject, join_path::String)
  config = _get_join_config(q, join_path)
  config === nothing && return nothing
  join_type = get(config, "join_type", nothing)
  return join_type isa String ? join_type : nothing
end
"""
This function checks if the given `field` is a valid field in the provided `model`. If the field is valid, it returns the field name, potentially modified based on certain conditions.
"""
function _solve_field(field::String, model::PormGModel, instruct::SQLInstruction)
  # check if last_column a field from the model    
  if !(field in model.field_names)
    _check_if_field_is_a_operator(field)
    @pormg_debug false
    throw(ArgumentError("The field \e[31m$(field)\e[0m not found in \e[34m$(model.name)\e[0m: \e[32m$(join(model.field_names, ", "))\e[0m"))
  end
  # (instruct.django !== nothing && hasfield(model.fields[field] |> typeof, :to)) && (field = string(field, "_id"))

  # Quote the field name to prevent SQL injection
  return quote_identifier(field, instruct.connection)
end
_solve_field(field::String, _module::Module, model_name::Symbol, instruct::SQLInstruction) = _solve_field(field, getfield(_module, model_name), instruct)
_solve_field(field::String, _module::Module, model_name::String, instruct::SQLInstruction) = _solve_field(field, _module, Symbol(model_name), instruct)
_solve_field(field::String, _module::Module, model_name::PormGModel, instruct::SQLInstruction) = _solve_field(field, model_name, instruct)



# outher functions
function _df_to_dic(df::DataFrames.DataFrame, column::String, filter::String)
  column = Symbol(column)
  loc = DataFrames.subset(df, DataFrames.AsTable([column]) => (@. x -> x[column] == filtro))
  if size(loc, 1) == 0
    throw("Error in _df_to_dic, $(filter) not found in $(column)")
  elseif size(loc, 1) > 1
    throw("Error in _df_to_dic, $(filter) found more than one time in $(column)")
  else
    return loc[1, :]
  end
end

# ---
# Build the SQLInstruction object
#

# select
function _infer_parameter_sql_type(value, instruc::SQLInstruction; fallback::Union{Nothing,String}=nothing)
  instruc.connection isa PormGPostgres || return nothing
  fallback !== nothing && return fallback
  value isa AbstractString && return "text"
  value isa Bool && return "boolean"
  value isa Integer && return "bigint"
  value isa AbstractFloat && return "double precision"
  value isa Dates.Date && return "date"
  value isa Dates.DateTime && return "timestamp"
  value isa Dates.Time && return "time"
  return nothing
end

function _deferred_kwarg_sql_type(v::SQLTypeFunction, key::String, resolved_kwargs::Dict{String,Any}, instruc::SQLInstruction)
  value = v.kwargs[key]

  if key == "precision"
    return _infer_parameter_sql_type(value, instruc; fallback="integer")
  end

  output_field = get(resolved_kwargs, "output_field", nothing)
  if output_field isa AbstractString && !isempty(output_field)
    return _infer_parameter_sql_type(value, instruc; fallback=output_field)
  end

  return _infer_parameter_sql_type(value, instruc)
end

function _get_select_query(v::SQLText, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  # Parameterize Value(x) instead of rendering as raw SQL literal.
  # NULL must stay literal (can't parameterize NULL in SQL).
  if v.field === nothing
    return "NULL"
  end
  return add_parameter!(instruc, v.field; sql_type=_infer_parameter_sql_type(v.field, instruc))
end
function _get_select_query(v::Vector{T}, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing) where T
  resp = []
  for item in v
    push!(resp, _get_select_query(item, instruc, _as=_as))
  end
  return resp
end
function _get_select_query(v::String, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  parts = split(v, "__")
  if size(parts, 1) > 1
    return _build_row_join(parts, instruc)
  else
    quoted_alias = quote_identifier(instruc.alias, instruc.connection)
    
    # Fast path: allow "*" to select all main-table columns seamlessly.
    # We intercept this before _solve_field to prevent the missing-field validation error.
    if v == "*"
      return string(quoted_alias, ".*")
    end
    
    if _as !== nothing && haskey(instruc.tab_field_cache, _as)
      instruc.tab_field_cache[_as] = instruc.object.model.fields[v]
    end
    return string(quoted_alias, ".", _solve_field(v, instruc.object.model, instruc))
  end
end
function _get_select_query(v::SQLField, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  return _get_select_query(v.field, instruc, _as=_as)
  # return v.field
end
function _get_select_query(v::SQLTypeOper, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  # use logic to when funtion
  return _get_filter_query(v, instruc)
end
function _get_select_query(v::SQLTypeFunction, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  # Parameterize scalar kwargs instead of rendering them as SQL literals.
  # IMPORTANT: these must be parameterized AFTER the column is resolved, because the SQL text order
  # places condition params first positionally (e.g., WHEN cond THEN ? ... ELSE ? END).
  #
  # Parameterizable kwargs by function:
  #   CASE/WHEN  → "then", "else"      (output values)
  #   ROUND      → "precision"         (decimal places)
  parameterize_keys = if v.function_name in ["CASE", "WHEN"]
    Set(["then", "else"])
  elseif v.function_name == "ROUND"
    Set(["precision"])
  else
    Set{String}()
  end

  # Phase 1: Resolve non-parameterizable kwargs (output_field, distinct, etc.)
  resolved_kwargs = Dict{String,Any}()
  deferred_kwargs = Dict{String,Any}()  # kwargs to parameterize after column
  for (k, val) in v.kwargs
    # For CASE/WHEN, THEN/ELSE must always be resolved after condition SQL so positional
    # placeholders follow SQL text order (important for SQLite/MySQL style backends).
    if k in parameterize_keys
      if val isa Missing || val == "NULL"
        resolved_kwargs[k] = val
      else
        deferred_kwargs[k] = val
      end
    elseif isa(val, Union{SQLObject,SQLType})
      resolved_kwargs[k] = _get_select_query(val, instruc)
    else
      resolved_kwargs[k] = val
    end
  end

  # Phase 2: Resolve column (conditions) — this adds condition params in SQL text order
  resolved_column = _get_select_query(v.column, instruc, _as=_as)

  # Phase 3: Now parameterize deferred kwargs (they appear AFTER conditions in SQL)
  # Order matters for positional backends: then → else → precision
  for key in ["then", "else", "precision"]
    if haskey(deferred_kwargs, key)
      deferred_val = deferred_kwargs[key]
      if isa(deferred_val, Union{SQLObject,SQLType})
        resolved_kwargs[key] = _get_select_query(deferred_val, instruc)
      else
        resolved_kwargs[key] = add_parameter!(instruc, deferred_val; sql_type=_deferred_kwarg_sql_type(v, key, resolved_kwargs, instruc))
      end
    end
  end

  return getfield(Dialect, Symbol(v.function_name))(resolved_column, resolved_kwargs, instruc.connection)
end
function _get_select_query(q::SQLTypeQor, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  resp = []
  for v in q.or
    push!(resp, _get_select_query(v, instruc, _as=_as))
  end
  return "(" * join(resp, " OR ") * ")"
end

function _get_select_query(q::SQLTypeQ, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  resp = []
  for v in q.filters
    push!(resp, _get_select_query(v, instruc, _as=_as))
  end
  return "(" * join(resp, " AND ") * ")"
end
function _get_select_query(q::SQLTypeF, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  return _set_update_query(q, instruc)
end


function _get_filter_query(v::Vector{SubString{String}}, instruc::SQLInstruction)
  v_str = String.(v)
  # column is the first part
  text = _get_filter_query(v_str[1], instruc)

  # Apply functions in sequence
  for i in 2:length(v_str)
    func_key = v_str[i]
    if haskey(PormGtransform, func_key)
      func_name = Symbol(PormGtransform[func_key])
      # Note: Dialect functions usually take (column, format_dict, connection)
      # We need to construct the format_dict if needed, but for date parts it's simple
      text = getfield(Dialect, func_name)(text, Dict{String,Any}(), instruc.connection)
    else
      throw(ArgumentError("Unknown date function or modifier: \e[31m@$func_key\e[0m"))
    end
  end
  return text
end
function _get_filter_query(v::String, instruc::SQLInstruction)
  # V does not have be suffix
  contains(v, "@") && return _get_filter_query(split(v, "__@"), instruc)
  parts = split(v, "__")
  if size(parts, 1) > 1
    return _build_row_join(parts, instruc, as=false)
  else
    quoted_alias = quote_identifier(instruc.alias, instruc.connection)
    return string(quoted_alias, ".", _solve_field(v, instruc.object.model, instruc))
  end
end
function _get_filter_query(v::SQLTypeFunction, instruc::SQLInstruction)
  return _get_select_query(v, instruc) # Does this have any coletaral efect?
end
# function _get_filter_query(v::SQLTypeText, instruc::SQLInstruction)
#   return _get_select_query(v, instruc)
# end
function _get_filter_query(v::SQLTypeField, instruc::SQLInstruction)
  # check if SQLTypeField exists in cache
  if v._as !== nothing && haskey(instruc.cache, v._as)
    return instruc.cache[v._as].field
  else
    v_copy = deepcopy(v)
    v_copy.field = _get_select_query(v_copy.field, instruc)
    if v_copy._as !== nothing
      instruc.cache[v_copy._as] = v_copy
    end
    return v_copy.field
  end
end
function _get_filter_query(v::SQLTypeOper, instruc::SQLInstruction)
  @pormg_debug false
  column = _get_filter_query(v.column, instruc)
  if isa(v.values, SQLTypeF)
    @pormg_debug false
    # F expressions are safe since they reference model fields    
    placeholders = _get_filter_query(v.values, instruc)
    return string(column, " ", v.operator, " ", placeholders)
  elseif isa(v.column, SQLTypeField) && isa(v.column.field, SQLTypeFunction) && v.column.field.formater !== nothing
    @pormg_debug false
    placeholders = add_parameter!(instruc, v.column.field.formater(v.values))
  elseif isa(v.column, SQLTypeField) && isa(v.column.field, SQLTypeFunction) && haskey(PormGTypeField, v.column.field.function_name)
    placeholders = add_parameter!(instruc, getfield(Models, PormGTypeField[v.column.field.function_name])(v.values))
    # value = getfield(Models, PormGTypeField[v.column.field.function_name])(v.values)
  elseif isa(v.column, SQLTypeFunction) && haskey(PormGTypeField, v.column.function_name)
    # Function with formater
    @pormg_debug false
    placeholders = add_parameter!(instruc, getfield(Models, PormGTypeField[v.column.function_name])(v.values))
  elseif isa(v.values, SQLObjectHandler)
    # Subqueries - these are safe since they're built through PormG.jl
    if !(v.operator in ["IN", "NOT IN"])
      @pormg_debug
      throw("Error in values, $(v.column.field) in filter is not a object")
    end
    placeholders = query(v.values, table_alias=instruc.table_alias, connection=instruc.connection, parameters=instruc.parameters)
    return string(_get_filter_query(v.column, instruc), " ", v.operator, " ($placeholders)")
  else
    @pormg_debug false
    if isa(v.column, SQLTypeField)
      @pormg_debug false
      _get_select_query(v.column, instruc, _as=v.column._as) # TODO, how do this i where before do operates
    else
      @pormg_debug false
    end
    if v.operator in ["ISNULL"]
      return getfield(QueryBuilder, Symbol(v.operator))(_get_filter_query(v.column, instruc), v.values)
    elseif v.operator == "BETWEEN"
      # Handle BETWEEN with two parameters
      column_sql = _get_filter_query(v.column, instruc)
      field_name = ""
      if isa(v.column, SQLTypeField)
        if isa(v.column.field, String)
          field_name = v.column.field
        end
      end

      if field_name != "" && haskey(instruc.object.model.fields, field_name)
        formater = instruc.object.model.fields[field_name].formater
        p1 = add_parameter!(instruc, formater(v.values[1]))
        p2 = add_parameter!(instruc, formater(v.values[2]))
        return string(column_sql, " BETWEEN ", p1, " AND ", p2)
      else
        p1 = add_parameter!(instruc, v.values[1])
        p2 = add_parameter!(instruc, v.values[2])
        return string(column_sql, " BETWEEN ", p1, " AND ", p2)
      end
    elseif haskey(instruc.object.model.fields, v.column.field)
      placeholders = nothing
      try
        # Determine if this is a LIKE-based operator and which wildcard pattern to use
        is_like_op = v.operator in ["contains", "icontains", "startswith", "endswith"]
        placeholders = add_parameter!(instruc, instruc.object.model.fields[v.column.field].formater(v.values), contains=is_like_op, operator=v.operator)
      catch e
        @pormg_debug false
        if contains(string(e), "The date") && contains(string(e), "is invalid")
          throw(ArgumentError("The \e[4m\e[31m$(v.column.field)\e[0m field is the type \e[4m\e[32m$(instruc.object.model.fields[v.column.field].type)\e[0m. Please check the value: \e[4m\e[31m$(v.values)\e[0m"))
        end
        @pormg_debug false
        rethrow(e)
      end
    elseif haskey(instruc.tab_field_cache, v.column._as) # Check cache first
      @pormg_debug false
      is_like_op = v.operator in ["contains", "icontains", "startswith", "endswith"]
      placeholders = add_parameter!(instruc, instruc.tab_field_cache[v.column._as].formater(v.values), contains=is_like_op, operator=v.operator)
    elseif isa(v.column, SQLTypeField)
      @pormg_debug false
      is_like_op = v.operator in ["contains", "icontains", "startswith", "endswith"]
      placeholders = add_parameter!(instruc, v.values, contains=is_like_op, operator=v.operator)
    else
      @pormg_debug false
      throw("Error in values, $(v.column.field) not found in $(instruc.object.model.name)")
    end
  end

  if v.operator in ["=", ">", "<", ">=", "<=", "<>", "!="]
    return string(column, " ", v.operator, " ", placeholders)
  elseif v.operator in ["IN", "NOT IN"]
    if isa(placeholders, String)
      # Se placeholders for uma única string (ex: "$1" ou "?")
      if instruc.connection isa PormGPostgres
        return string(column, " ", v.operator == "IN" ? "= ANY" : "<> ALL", "(", placeholders, ")")
      else
        # Para SQLite e outros que não suportam ANY(array), precisamos que os placeholders
        # tenham sido expandidos ou usar uma abordagem diferente.
        # No PormG atual, se chegou aqui como String, é porque add_parameter! retornou um único "?"
        # para o vetor inteiro.
        return string(column, " ", v.operator, " (", placeholders, ")")
      end
    elseif isa(placeholders, AbstractArray)
      return string(column, " ", v.operator, " (", join(placeholders, ", "), ")")
    else
      throw("Error in operator: $(v.operator), the value must be a String or a Vector of Strings")
    end
  elseif v.operator in ["contains", "icontains", "startswith", "endswith"]
    @pormg_debug false
    return getfield(Dialect, Symbol(v.operator))(instruc.connection, column, placeholders)
  else
    throw("Error in operator, $(v.operator) is not a valid operator")
  end
end
function _get_filter_query(q::SQLTypeQ, instruc::SQLInstruction)
  resp = []
  for v in q.filters
    push!(resp, _get_filter_query(v, instruc))
  end
  return "(" * join(resp, " AND ") * ")"
end
function _get_filter_query(q::SQLTypeQor, instruc::SQLInstruction)
  resp = []
  for v in q.or
    push!(resp, _get_filter_query(v, instruc))
  end
  return "(" * join(resp, " OR ") * ")"
end
function _get_filter_query(v::SQLTypeF, instruc::SQLInstruction)
  return _get_select_query(v, instruc)
end
