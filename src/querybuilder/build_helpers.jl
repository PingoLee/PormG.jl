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
  if conn_key === nothing
    # Fall back to the only loaded config when unambiguous; otherwise give a clear error.
    if length(config) == 1
      conn_key = first(keys(config))
    else
      throw(ArgumentError("Model '$(q.model.name)' is not bound to a database connection key. " *
        "Call `set_models()` or `PormG.@import_models` to bind the model before querying."))
    end
  end
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
function _check_function(f::WindowFunction)
  f.column !== nothing && (f.column = _check_function(f.column))
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
        throw(_argerr("\e[4m\e[31m$(x[end])\e[0m is not allowed.\n$yes\n$not"))
      else
        throw(_argerr("\"$(x[1])__\e[31m@$(x[end])\e[0m\" is invalid;\n please use a valid function:\n  - $(joined_keys_with_prefix_func)\e[0m\nor a valid operator:\n  - $(joined_keys_with_prefix_oper)\e[0m"))
      end
    end
  end
end
_check_function(x::String) = _check_function(String.(split(x, "__@")))
function _check_function(x::FExpression)
  return x
end

# ─────────────────────────────────────────────────────────────────────────────
# Invalid filter-operator diagnostics (#98)
#
# The scalar/function path (_check_function) already emits a rich "valid function
# / valid operator" message. The vector, subquery, and tuple value paths used to
# throw a terse message that neither listed the valid operators nor distinguished
# a typo (unknown operator, e.g. @notin) from a known operator that simply is not
# valid for that value shape (e.g. @gte with a vector). _raise_invalid_filter_operator
# gives all three shapes one consistent, actionable error, with a nearest-match
# "did you mean" suggestion for typos.
# ─────────────────────────────────────────────────────────────────────────────

# Iterative Levenshtein edit distance (two-row, O(min(m,n)) memory). Runs only when
# building a typo suggestion, never on the happy path.
function _levenshtein(a::AbstractString, b::AbstractString)::Int
  av, bv = collect(a), collect(b)
  m, n = length(av), length(bv)
  m == 0 && return n
  n == 0 && return m
  prev = collect(0:n)
  curr = Vector{Int}(undef, n + 1)
  for i in 1:m
    curr[1] = i
    @inbounds for j in 1:n
      cost = av[i] == bv[j] ? 0 : 1
      curr[j + 1] = min(curr[j] + 1, prev[j + 1] + 1, prev[j] + cost)
    end
    prev, curr = curr, prev
  end
  return prev[n + 1]
end

# Nearest valid operator suffix to `suffix`, or nothing when nothing is close enough
# to be a plausible typo (so garbage input does not get a nonsense suggestion).
function _suggest_operator(suffix::AbstractString)::Union{Nothing,String}
  best = nothing
  best_d = typemax(Int)
  for k in keys(PormGsuffix)
    d = _levenshtein(suffix, k)
    if d < best_d
      best_d = d
      best = k
    end
  end
  # Suggest only when the edit is small relative to the typed length: keeps real
  # near-misses (@notin→@nin, @containx→@contains) but rejects short garbage
  # (@xy is 2 edits from @in — the whole word — so no suggestion).
  return 2 * best_d <= length(suffix) ? best : nothing
end

# Consistent, actionable error for a filter operator that is not valid for the given
# value shape. `field_path` is the split lookup (…, suffix); `shape` is a human word
# ("vector", "subquery", "tuple"); `allowed` is the operator subset valid for that shape.
function _raise_invalid_filter_operator(field_path::Vector{String}, shape::AbstractString, allowed::Vector{String})
  all_opers = join(map(k -> "@" * k, sort!(collect(keys(PormGsuffix)))), ", ")
  allowed_opers = join(map(a -> "@" * a, allowed), ", ")
  if length(field_path) < 2
    # No __@ suffix at all: a bare field was paired with a $shape value.
    field = field_path[end]
    examples = join(map(a -> "$(field)__@" * a, allowed), ", ")
    throw(_argerr("Error in filter: field \e[31m$(field)\e[0m was given a $(shape) value but no operator.\n" *
                  "With a $(shape) value, use one of: $(examples)"))
  end
  suffix = field_path[end]
  if !haskey(PormGsuffix, suffix)
    # Unknown operator — typo or nonexistent. List every valid operator and, when the
    # input looks like a near-miss, suggest the intended one (e.g. @notin → @nin).
    suggestion = _suggest_operator(suffix)
    hint = suggestion === nothing ? "" : " Did you mean \e[32m@$(suggestion)\e[0m?"
    throw(_argerr("Error in filter: \e[31m@$(suffix)\e[0m is not a valid operator.$(hint)\n" *
                  "Valid operators: $(all_opers)\n" *
                  "With a $(shape) value, use one of: $(allowed_opers)"))
  else
    # Known operator, but not valid for this value shape (e.g. @gte with a vector).
    throw(_argerr("Error in filter: operator \e[31m@$(suffix)\e[0m is not valid with a $(shape) value.\n" *
                  "With a $(shape) value, use one of: $(allowed_opers)"))
  end
end

"""
  _get_pair_to_oper(x::Pair)

  Converts a Pair object to an OperObject. If the Pair's key is a string, it checks if it contains an operator suffix (e.g. "__@gte", "__@lte") and returns an OperObject with the corresponding operator. If the key does not contain an operator suffix, it returns an OperObject with the "=" operator. If the key is not a string, it throws an error.

  ## Arguments
  - `x::Pair`: A Pair object to be converted to an OperObject.

  ## Returns
  - `OperObject`: An OperObject with the corresponding operator and values.

"""
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:Union{AbstractString,Number,Bool,Dates.TimeType,Dates.Period,Dates.CompoundPeriod}
  if haskey(PormGsuffix, x.first[end])
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    return OperObject(operator="=", values=x.second, column=SQLField(_check_function(x.first), join(x.first, "__"))) # TODO, maybe I need to check if the column is valid and process the function before store
  end
end
function _get_pair_to_oper(x::Pair{String,T}) where T<:Union{AbstractString,Number,Bool,Dates.Date,Dates.DateTime,Dates.TimeType,Dates.Period,Dates.CompoundPeriod}
  return _get_pair_to_oper(String.(split(x.first, "__@")) => x.second)
end
function _get_pair_to_oper(x::Pair{String,Vector{T}}) where T<:Union{Missing,AbstractString,Number,Bool,Dates.TimeType,Dates.Period,Dates.CompoundPeriod}
  return _get_pair_to_oper(String.(split(x.first, "__@")) => x.second)
end
# Store SQLObject, to use __@in operator
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:SQLObjectHandler
  if x.first[end] in ["in", "nin"]
    # @pormg_debug
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    _raise_invalid_filter_operator(x.first, "subquery", ["in", "nin"])
  end
end
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:SQLTypeF
  if haskey(PormGsuffix, x.first[end])
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    return OperObject(operator="=", values=x.second, column=SQLField(_check_function(x.first), join(x.first, "__")))
  end
end
# Allow Case/When and other FObject expressions as filter RHS values
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:SQLTypeFunction
  if haskey(PormGsuffix, x.first[end])
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    return OperObject(operator="=", values=x.second, column=SQLField(_check_function(x.first), join(x.first, "__")))
  end
end
function _get_pair_to_oper(x::Pair{Vector{String},Vector{T}}) where T<:Union{Missing,AbstractString,Number,Bool,Dates.TimeType,Dates.Period,Dates.CompoundPeriod}
  if x.first[end] in ["in", "nin"]
    @pormg_debug false
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  elseif x.first[end] == "range"
    if length(x.second) != 2
      throw(_argerr("Error in filter, 'range' operator requires exactly 2 values, got $(length(x.second))"))
    end
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    _raise_invalid_filter_operator(x.first, "vector", ["in", "nin", "range"])
  end
end
function _get_pair_to_oper(x::Pair{Vector{String},Tuple{T,T}}) where T
  if x.first[end] == "range"
    return OperObject(operator=PormGsuffix[x.first[end]], values=[x.second[1], x.second[2]], column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    _raise_invalid_filter_operator(x.first, "tuple", ["range"])
  end
end
function _get_pair_to_oper(x::Pair{Vector{String},Date})
  _get_pair_to_oper(x.first => x.second |> string)
end



# Normalize filter values at the public boundary so _get_pair_to_oper and
# OperObject always receive concrete String (not SubString or other AbstractString
# subtypes that fail the Union constraint and hold parent-string references).
function _normalize_filter_pair(value::AbstractString)
  return String(value)
end
function _normalize_filter_pair(values::AbstractVector)
  return [v isa AbstractString ? String(v) : v for v in values]
end
_normalize_filter_pair(value) = value

function _is_wildcard_projection(value)
  return false
end

function _is_wildcard_projection(value::Union{SQLTypeText,SQLTypeField})
  value isa SQLTypeText && return false
  if value.custom_as == "*" || value._as == "*"
    return true
  end
  return value.field isa String && (value.field == "*" || endswith(value.field, ".*"))
end

function _subquery_projection_labels(subquery::SQLObjectHandler)
  if isempty(subquery.object.values)
    return subquery.object.model.field_names
  end

  labels = String[]
  for value in subquery.object.values
    if _is_wildcard_projection(value)
      append!(labels, subquery.object.model.field_names)
      continue
    end

    alias = value.custom_as !== nothing ? value.custom_as : value._as

    if alias !== nothing && !isempty(alias)
      push!(labels, alias)
    elseif value isa SQLTypeField && value.field isa String
      push!(labels, value.field)
    else
      push!(labels, "<expression>")
    end
  end
  return labels
end

function _summarize_projection_labels(labels::Vector{String}; max_items::Integer=4)
  shown = labels[1:min(length(labels), max_items)]
  summary = join(shown, ", ")
  if length(labels) > max_items
    summary *= ", ..."
  end
  return summary
end

function _validate_membership_subquery(v::SQLTypeOper)
  v.values isa SQLObjectHandler || return nothing
  v.operator in ["IN", "NOT IN"] || return nothing

  subquery = v.values
  projection_labels = _subquery_projection_labels(subquery)
  projection_count = length(projection_labels)
  projection_count == 1 && return nothing

  filter_field = v.column isa SQLTypeField && v.column.field isa String ? v.column.field : "field"
  operator_suffix = v.operator == "IN" ? "in" : "nin"
  lookup = string(filter_field, "__@", operator_suffix)
  detail = if isempty(subquery.object.values)
    "The subquery currently selects all columns from '$(subquery.object.model.name)' because .values(...) was not called."
  else
    "The subquery currently selects $(projection_count) columns: $(_summarize_projection_labels(projection_labels))."
  end

  throw(ArgumentError(
    "PormG: '$lookup' requires a subquery that returns exactly one column. " *
    detail * " Fix: call .values(\"field_name\") on the subquery so it projects only the key used by the filter."
  ))
end

function _check_filter(x::Pair)
  if isa(x.first, AbstractString)
    key = String(x.first)
    check = String.(split(key, "__@"))
    normalized_value = _normalize_filter_pair(x.second)
    try
      # @pormg_debug
      return _get_pair_to_oper(check => normalized_value)
    catch e
      @pormg_debug false
      @error "Error in filter processing '$(key)'" exception = (e, catch_backtrace())
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
  common_operators = ["exact", "iexact", "contains", "icontains", "iunaccent_contains", "iunaccent_exact", "in", "gt", "gte", "lt", "lte",
    "startswith", "istartswith", "endswith", "iendswith", "range", "date",
    "year", "iso_year", "quarter", "month", "day", "week", "week_day", "iso_week_day",
    "hour", "minute", "second", "isnull", "regex", "iregex"]
  if field in common_operators
    throw(_argerr("The filter operator '\e[31m$field\e[0m' requires '@' prefix. Use '\e[32m$field\e[0m' => ... as part of '__\e[33m@$field\e[0m' syntax. Example: \e[36mq.filter(\"name__@$field\" => value)\e[0m"))
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
    throw(_argerr("The field \e[31m$(field)\e[0m not found in \e[34m$(model.name)\e[0m: \e[32m$(join(model.field_names, ", "))\e[0m"))
  end
  # (instruct.django !== nothing && hasfield(model.fields[field] |> typeof, :to)) && (field = string(field, "_id"))

  # Resolve to the physical column (db_column when set, else the field name) and quote
  # it to prevent SQL injection (#50). SELECT auto-aliases back to the field name, so
  # rows stay keyed by the declared field name even when the column differs.
  return quote_identifier(Models.field_db_column(model.fields[field], field), instruct.connection)
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
function _resolve_window_expression(v, instruc::SQLInstruction)
  if v isa Symbol
    return _resolve_window_expression(String(v), instruc)
  elseif v isa String
    isempty(v) && throw(ArgumentError("Window expression fields cannot be empty"))
    return _get_select_query(_check_function(v), instruc)
  elseif v isa SQLType
    return _get_select_query(v, instruc)
  else
    throw(ArgumentError("Unsupported window expression $(repr(v)) of type $(typeof(v))"))
  end
end

# Delegates to the shared whitelist (types.jl, #77) so the ORDER BY and window paths can't drift.
_normalize_window_orientation(orientation::AbstractString)::String =
  _normalize_order_orientation(orientation; context="Window ORDER BY")

function _resolve_window_order(v::String, instruc::SQLInstruction)::String
  isempty(v) && throw(ArgumentError("Window ORDER BY fields cannot be empty"))
  orientation = startswith(v, "-") ? "DESC" : "ASC"
  field = startswith(v, "-") ? v[2:end] : v
  isempty(field) && throw(ArgumentError("Window ORDER BY fields cannot be empty"))
  return string(_resolve_window_expression(field, instruc), " ", orientation)
end

function _resolve_window_order(v::SQLTypeOrder, instruc::SQLInstruction)::String
  return string(_resolve_window_expression(v.field, instruc), " ", _normalize_window_orientation(v.orientation))
end

function _build_over_clause(over::WindowSpec, instruc::SQLInstruction)::String
  parts = String[]

  if !isempty(over.partition_by)
    partition_sql = [_resolve_window_expression(field, instruc) for field in over.partition_by]
    push!(parts, "PARTITION BY " * join(partition_sql, ", "))
  end

  if !isempty(over.order_by)
    order_sql = [_resolve_window_order(order_field, instruc) for order_field in over.order_by]
    push!(parts, "ORDER BY " * join(order_sql, ", "))
  end

  if over.frame !== nothing
    instruc.connection isa PormGSQLite && throw(ArgumentError("SQLite window functions in PormG do not support explicit frame specifications yet. Remove frame=$(repr(over.frame)) or use PostgreSQL."))
    frame = strip(over.frame)
    isempty(frame) && throw(ArgumentError("Window frame cannot be empty"))
    push!(parts, frame)
  end

  return join(parts, " ")
end

function _resolve_window_kwarg(value, instruc::SQLInstruction; sql_type::Union{Nothing,String}=nothing)
  if value isa Missing || value === nothing || value == "NULL"
    return "NULL"
  elseif value isa SQLType
    return _get_select_query(value, instruc)
  else
    return add_parameter!(instruc, value; sql_type=sql_type === nothing ? _infer_parameter_sql_type(value, instruc) : sql_type)
  end
end

function _get_select_query(v::WindowFunction, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  over_sql = _build_over_clause(v.over, instruc)
  func_name = Symbol(v.function_name)

  if v.column === nothing
    v.function_name in ["LAG", "LEAD", "FIRST_VALUE", "LAST_VALUE", "NTH_VALUE"] &&
      throw(ArgumentError("$(v.function_name) requires a column argument; got nothing"))
    return getfield(Dialect, func_name)(over_sql, instruc.connection)
  end

  resolved_column = _resolve_window_expression(v.column, instruc)

  if v.function_name in ["LAG", "LEAD"]
    resolved_kwargs = Dict{String,Any}()
    if haskey(v.kwargs, "offset")
      resolved_kwargs["offset"] = _resolve_window_kwarg(v.kwargs["offset"], instruc; sql_type="integer")
    end
    if haskey(v.kwargs, "default")
      resolved_kwargs["default"] = _resolve_window_kwarg(v.kwargs["default"], instruc)
    end
    return getfield(Dialect, func_name)(resolved_column, over_sql, resolved_kwargs, instruc.connection)
  elseif v.function_name == "NTH_VALUE"
    n = get(v.kwargs, "n", nothing)
    n isa Integer || throw(ArgumentError("NthValue requires a positive integer n"))
    n <= 0 && throw(ArgumentError("NthValue n must be a positive integer"))
    return getfield(Dialect, func_name)(resolved_column, n, over_sql, instruc.connection)
  else
    return getfield(Dialect, func_name)(resolved_column, over_sql, instruc.connection)
  end
end
# #74: extract the single source table alias from a fully-resolved bare column reference like
# `"Tb_1"."points"` or `"Tb".*`. Returns the unquoted alias, or `nothing` for anything that is not a
# single column (nested aggregate, F-expression, multi-column) — the fan-out guard treats `nothing`
# as ambiguous and conservatively refuses. Both backends quote identifiers with double quotes.
function _extract_leading_alias(s)
  s isa AbstractString || return nothing
  m = match(r"^\"((?:[^\"]|\"\")+)\"\.(?:\"(?:[^\"]|\"\")+\"|\*)$", s)
  m === nothing ? nothing : replace(m.captures[1], "\"\"" => "\"")
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

  # #74 fan-out guard: record COUNT/SUM/AVG and the source alias of their column so build() can
  # refuse aggregates a to-many join would silently inflate. MAX/MIN are immune and omitted; a
  # `distinct=true` aggregate is an explicit opt-in and is exempted by the check.
  if v.function_name in ("COUNT", "SUM", "AVG")
    src = _extract_leading_alias(resolved_column)
    push!(instruc.agg_sources, (
      alias = src === nothing ? "\0AMBIGUOUS" : src,
      func = v.function_name,
      label = _as === nothing ? string(v.function_name, "(", resolved_column, ")") : _as,
      distinct = get(v.kwargs, "distinct", false) === true))
  end

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
function _get_select_query(v::ExistsObject, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  return _get_filter_query(v, instruc)
end
function _get_select_query(v::OuterRefObject, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  return _get_filter_query(v, instruc)
end
function _get_select_query(q::SQLTypeF, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  return _set_update_query(q, instruc)
end

function _resolve_outer_ref_field_name(ref::OuterRefObject, outer::SQLInstruction)::String
  if ref.field_name == "pk"
    pk_field = Models.get_model_pk_field(outer.object.model)
    pk_field === nothing && throw(ArgumentError("OuterRef(\"pk\") requires the outer model '$(outer.object.model.name)' to define exactly one primary key field"))
    return String(pk_field)
  end
  return ref.field_name
end

function _build_exists_query(subquery::SQLObjectHandler, instruc::SQLInstruction)::String
  q = deepcopy(subquery)
  q.object.values = []
  q.object.order = []
  q.object.limit = 0
  q.object.offset = 0

  old_context = instruc.parameters isa PormGSQLiteParam ? instruc.parameters.current_context : nothing
  instruction = try
    build(
      q.object,
      table_alias=instruc.table_alias,
      connection=instruc.connection,
      parameters=instruc.parameters,
      set_contexts=false,
      outer=instruc,
    )
  finally
    old_context !== nothing && set_context!(instruc.parameters, old_context)
  end

  safe_table_name = safe_table_identifier(q.object.model.name, instruction.connection)
  safe_alias = quote_identifier(instruction.alias, instruction.connection)

  io = IOBuffer()
  print(io, "EXISTS (SELECT 1\nFROM ", safe_table_name, " as ", safe_alias, "\n")

  for join_sql in instruction.join
    print(io, join_sql, "\n")
  end

  if !isempty(instruction._where)
    print(io, "WHERE ")
    for (index, where_sql) in enumerate(instruction._where)
      index > 1 && print(io, " AND \n   ")
      print(io, where_sql)
    end
    print(io, "\n")
  end

  if instruction.agregate && !isempty(instruction.group)
    print(io, "GROUP BY ", join(instruction.group, ", "), " \n")
  end

  if !isempty(instruction.having)
    print(io, "HAVING ")
    for (index, having_sql) in enumerate(instruction.having)
      index > 1 && print(io, " AND \n   ")
      print(io, having_sql)
    end
    print(io, "\n")
  end

  print(io, "LIMIT 1)")
  return String(take!(io))
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
      throw(_argerr("Unknown date function or modifier: \e[31m@$func_key\e[0m"))
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
function _get_filter_query(v::ExistsObject, instruc::SQLInstruction)
  return _build_exists_query(v.query, instruc)
end
function _get_filter_query(v::OuterRefObject, instruc::SQLInstruction)
  instruc.outer === nothing && throw(ArgumentError("OuterRef(\"$(v.field_name)\") can only be resolved while building a correlated subquery such as Exists(subquery)."))
  return _get_filter_query(_resolve_outer_ref_field_name(v, instruc.outer), instruc.outer)
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
  elseif isa(v.values, SQLTypeFunction)
    # Case/When and other SQL function expressions as filter RHS
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
    _validate_membership_subquery(v)
    placeholders = query(v.values, table_alias=instruc.table_alias, connection=instruc.connection, parameters=instruc.parameters, outer=instruc)
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
        is_like_op = v.operator in ["contains", "icontains", "iunaccent_contains", "startswith", "endswith"]
        placeholders = add_parameter!(instruc, instruc.object.model.fields[v.column.field].formater(v.values), contains=is_like_op, operator=v.operator)
      catch e
        @pormg_debug false
        if contains(string(e), "The date") && contains(string(e), "is invalid")
          throw(_argerr("The \e[4m\e[31m$(v.column.field)\e[0m field is the type \e[4m\e[32m$(instruc.object.model.fields[v.column.field].type)\e[0m. Please check the value: \e[4m\e[31m$(v.values)\e[0m"))
        end
        @pormg_debug false
        rethrow(e)
      end
    elseif haskey(instruc.tab_field_cache, v.column._as) # Check cache first
      @pormg_debug false
      is_like_op = v.operator in ["contains", "icontains", "iunaccent_contains", "startswith", "endswith"]
      placeholders = add_parameter!(instruc, instruc.tab_field_cache[v.column._as].formater(v.values), contains=is_like_op, operator=v.operator)
    elseif isa(v.column, SQLTypeField)
      @pormg_debug false
      is_like_op = v.operator in ["contains", "icontains", "iunaccent_contains", "startswith", "endswith"]
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
  elseif v.operator in ["contains", "icontains", "iunaccent_contains", "iunaccent_exact", "startswith", "endswith"]
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
