# ---
# Process the query entries to build the SQLObjectQuery object
#

"""
    get_settings(obj::Union{SQLObject, SQLObjectHandler}; connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing)

Resolves the database settings for a query. 
Returns a tuple of `(settings::PormGSettings, connection, conn_key::String)`.

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
      throw(InvalidConfigurationError("Model '$(q.model.name)' is not bound to a database connection key. " *
        "Call `set_models()` or `PormG.@import_models` to bind the model before querying."))
    end
  end
  settings = get_configuration_settings(conn_key)

  final_connection = connection === nothing ? settings.connections : connection
  # A config entry can exist with no pool built yet (`connections === nothing`); letting that
  # escape produced a raw `MethodError` at get_parameter downstream (audit probe). Same guard and
  # wording as `pool_stats(key)` in PormG.jl.
  final_connection === nothing && throw(InvalidConfigurationError(
    "Connection '$(conn_key)' has no pool yet (not built / not connected). " *
    "Call PormG.Configuration.load(...) so the pool exists before querying."))
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
        throw(FilterError("\e[4m\e[31m$(x[end])\e[0m is not allowed.\n$yes\n$not"))
      else
        throw(FilterError("\"$(x[1])__\e[31m@$(x[end])\e[0m\" is invalid;\n please use a valid function:\n  - $(joined_keys_with_prefix_func)\e[0m\nor a valid operator:\n  - $(joined_keys_with_prefix_oper)\e[0m"))
      end
    end
  end
end
_check_function(x::String) = _check_function(String.(split(x, "__@")))
function _check_function(x::FExpression)
  return x
end
# #444 — a CTE handle is already fully resolved; there is nothing left to peel.
_check_function(x::CTEReference) = x

# #444 — retag a resolved column expression so its terminal column becomes a CTE handle.
#
# The parse pipeline for a CTE reference deliberately runs on `ref.path` ALONE, which lets it reuse
# every existing String code path unchanged — operator-suffix peeling, transform-function
# construction, and all fifteen RHS-typed `_get_pair_to_oper` validations. What that leaves behind is
# a plain `"seen"` where a CTE-scoped reference belongs, so this walks the result and swaps it.
#
# Shape and boundary are copied from `_prefix_join_filter` (ctes.jl), which already does this kind of
# recursive rewrite: descend `.column` / `.field` only, NEVER `kwargs`. That boundary is load-bearing
# here — `Y_M(["seen"])` is `ToChar(x, "YYYY-MM", …)` (functions.jl), so the format literal sits in
# kwargs and retagging it would corrupt the rendered function.
#
# #481 widened the walk. A COMPOSITE transform does not build a bare function over the column: the
# `@quarter` / `@quadrimester` keys expand to `Concat([Cast(Year(x)), Value("-Q"), Case([When(...)])])`
# (`functions.jl`), so the walk also meets an `SQLText` literal, an `SQLField` wrapper and the
# `OperObject` inside each `When`. Without these three arms `CTE("ev","seen__@quarter")` — and the
# `Joined` twin below — died on the catch-all with an "Internal … please report" message for a
# documented transform. An `SQLText` is a LITERAL (the `"-Q"` separator) and must never be retagged,
# which is the same boundary the `kwargs` rule above draws.
_retag_cte_column(x::String, name::String) = CTEReference(name=name, path=x)
_retag_cte_column(x::CTEReference, ::String) = x
_retag_cte_column(x::SQLTypeText, ::String) = x
function _retag_cte_column(x::SQLTypeFunction, name::String)
  x.column = _retag_cte_column(x.column, name)
  return x
end
function _retag_cte_column(x::SQLTypeField, name::String)
  x.field = _retag_cte_column(x.field, name)
  return x
end
function _retag_cte_column(x::SQLTypeOper, name::String)
  x.column = _retag_cte_column(x.column, name)
  return x
end
_retag_cte_column(x::Vector, name::String) = Any[_retag_cte_column(v, name) for v in x]
function _retag_cte_column(x, ::String)
  throw(QueryBuildError(
    "Internal: a CTE reference resolved to an unexpected column expression (::$(typeof(x))). " *
    "Please report this (#444)."))
end

# Top-level entry: retag the SQLField a String-path parse produced, and restore the `name__path`
# spelling on `_as`. Keeping `_as` byte-identical to the pre-#444 string form is what lets every
# `_as`-keyed consumer downstream keep working untouched — the projection memo, the field memo,
# ORDER BY alias matching, the #352/#373 sargable date rewrite, the #441 duplicate-projection guard,
# and the result-column names users index DataFrames by.
function _retag_cte_field!(field::SQLField, name::String)
  field.field = _retag_cte_column(field.field, name)
  field._as === nothing || (field._as = _cte_as(name, field._as))
  # #474 — the single site that marks an expression CTE-rooted. `_as` keeps the `name__path`
  # spelling #444 pinned (it is the output column name); the MEMO moves to the other half of a
  # `MemoKey`, so a field path spelled identically can no longer read or claim this entry.
  field.root = :cte
  return field
end

# #481 — the joined-copy twin of the helpers above, arm for arm (see the composite-transform note
# there for why `SQLTypeText` / `SQLTypeField` / `SQLTypeOper` are walked).
#
# Never actually reached today: every entry point (`_check_filter`, `_values_field`, `_order_by!`)
# delegates on `ref.path`, which is a `String`, so `_check_function` sees the path and not the
# handle. Defined for symmetry with the CTE twin, and so a future caller that does pass a handle
# gets the identity rather than a MethodError.
_check_function(x::JoinedReference) = x

_retag_joined_column(x::String, alias::String) = JoinedReference(alias, x, false)
_retag_joined_column(x::JoinedReference, ::String) = x
_retag_joined_column(x::SQLTypeText, ::String) = x
function _retag_joined_column(x::SQLTypeFunction, alias::String)
  x.column = _retag_joined_column(x.column, alias)
  return x
end
function _retag_joined_column(x::SQLTypeField, alias::String)
  x.field = _retag_joined_column(x.field, alias)
  return x
end
function _retag_joined_column(x::SQLTypeOper, alias::String)
  x.column = _retag_joined_column(x.column, alias)
  return x
end
_retag_joined_column(x::Vector, alias::String) = Any[_retag_joined_column(v, alias) for v in x]
function _retag_joined_column(x, ::String)
  throw(QueryBuildError(
    "Internal: a Joined reference resolved to an unexpected column expression (::$(typeof(x))). " *
    "Please report this (#481)."))
end

function _retag_joined_field!(field::SQLField, alias::String)
  field.field = _retag_joined_column(field.field, alias)
  field._as === nothing || (field._as = _joined_as(alias, field._as))
  field.root = :joined
  return field
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

# Nearest valid operator suffix to `suffix`, or nothing when nothing is close enough
# to be a plausible typo (so garbage input does not get a nonsense suggestion).
# Uses the shared Kernel `_suggest_name` helper with the same threshold (#365).
_suggest_operator(suffix::AbstractString)::Union{Nothing,String} =
  _suggest_name(suffix, keys(PormGsuffix))

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
    throw(FilterError("Error in filter: field \e[31m$(field)\e[0m was given a $(shape) value but no operator.\n" *
                  "With a $(shape) value, use one of: $(examples)"))
  end
  suffix = field_path[end]
  if !haskey(PormGsuffix, suffix)
    # Unknown operator — typo or nonexistent. List every valid operator and, when the
    # input looks like a near-miss, suggest the intended one (e.g. @notin → @nin).
    suggestion = _suggest_operator(suffix)
    hint = suggestion === nothing ? "" : " Did you mean \e[32m@$(suggestion)\e[0m?"
    throw(FilterError("Error in filter: \e[31m@$(suffix)\e[0m is not a valid operator.$(hint)\n" *
                  "Valid operators: $(all_opers)\n" *
                  "With a $(shape) value, use one of: $(allowed_opers)"))
  else
    # Known operator, but not valid for this value shape (e.g. @gte with a vector).
    throw(FilterError("Error in filter: operator \e[31m@$(suffix)\e[0m is not valid with a $(shape) value.\n" *
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
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:Union{AbstractString,Number,Bool,Dates.TimeType,Dates.Period,Dates.CompoundPeriod,Base.UUID}
  if haskey(PormGsuffix, x.first[end])
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    return OperObject(operator="=", values=x.second, column=SQLField(_check_function(x.first), join(x.first, "__"))) # TODO, maybe I need to check if the column is valid and process the function before store
  end
end
function _get_pair_to_oper(x::Pair{String,T}) where T<:Union{AbstractString,Number,Bool,Dates.Date,Dates.DateTime,Dates.TimeType,Dates.Period,Dates.CompoundPeriod}
  return _get_pair_to_oper(String.(split(x.first, "__@")) => x.second)
end
# Widened alongside its `Pair{Vector{String},…}` twin below (#411). Not reachable from
# `_check_filter`, which splits the key at `__@` first — but leaving one of a matched pair behind
# is the drift that bites whoever calls it directly next.
function _get_pair_to_oper(x::Pair{String,Vector{T}}) where T<:Union{Missing,AbstractString,Number,Bool,Dates.TimeType,Dates.Period,Dates.CompoundPeriod,Base.UUID}
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
# #444 — `filter("raceid" => CTE("r91", "raceid"))`: the RHS is a COLUMN reference, not a value.
# Same shape as the SQLTypeF method below it (that is the idiom `F("r91__raceid")` used pre-#444).
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:SQLTypeCTE
  _reject_cte_desc(x.second, "a filter comparison")
  if haskey(PormGsuffix, x.first[end])
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    return OperObject(operator="=", values=x.second, column=SQLField(_check_function(x.first), join(x.first, "__")))
  end
end
# #481 — the same shape for a joined-copy handle on the RHS:
# `filter("driverid" => Joined("d", "driverid"))` compares two columns.
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:SQLTypeJoined
  _reject_joined_desc(x.second, "a filter comparison")
  if haskey(PormGsuffix, x.first[end])
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    return OperObject(operator="=", values=x.second, column=SQLField(_check_function(x.first), join(x.first, "__")))
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
# `Base.UUID` and `Vector{UInt8}` (#411): without them a `Vector{UUID}` or `Vector{Vector{UInt8}}`
# right-hand side never reached this method at all, so `__@in` on a UUIDField or a BinaryField
# failed at PARSE time with a MethodError — before any formatter ran, which is why mapping the
# formatter at the call site does not fix those two on its own.
# `Vector{Any}` (#411). `[]` — the way anyone writes an empty list, and what `ids = []` gives you
# before the first `push!` — is `Vector{Any}`, and `Any` satisfies none of the element bounds the
# methods below dispatch on. So the most natural spelling of an empty membership list raised a
# `MethodError` naming `_get_pair_to_oper` and a tuple type nobody typed: the exact untyped-error
# class this pair of issues exists to remove, on the one shape the documentation shows.
#
# `_normalize_filter_pair`'s comprehension already narrows a NON-empty `Any[…]` whose elements share
# a type, which is why `Any[UInt8[1], UInt8[2]]` reaches the binary guard correctly. It cannot narrow
# an empty one — there is nothing to infer from — so that case is handled here.
function _get_pair_to_oper(x::Pair{Vector{String},Vector{Any}})
  # Empty: no element type to preserve, because nothing is ever bound. `String[]` is as good as any.
  isempty(x.second) && return _get_pair_to_oper(x.first => String[])
  narrowed = identity.(x.second)
  # Genuinely heterogeneous — narrowing changed nothing, so re-dispatching would recurse forever.
  # Report it as what it is rather than looping or leaking a MethodError.
  narrowed isa Vector{Any} && throw(FilterError(
    "The filter \e[4m\e[31m$(join(x.first, "__"))\e[0m was given a list whose values do not share " *
    "a type: \e[4m\e[31m$(join(unique(typeof.(x.second)), ", "))\e[0m. A membership list must be " *
    "homogeneous — build it as a typed vector, e.g. \e[1mInt[…]\e[0m or \e[1mString[…]\e[0m."))
  return _get_pair_to_oper(x.first => narrowed)
end

# A membership filter over BINARY values is refused, deliberately and by name (#411).
#
# `format_binary_sql` returns a `PormGBytes` wrapper, and the two ARRAY methods of `add_parameter!`
# are the only ones that do not unwrap it — the scalar methods exist precisely to. So a mapped list
# binds wrappers: SQLite stores a Julia-serialized blob that matches nothing (silently zero rows,
# no error) and PostgreSQL emits a nonsense `bytea[]` literal. Supporting this properly means
# teaching the array collectors to unwrap, which is a driver round-trip change and cannot be
# validated without the integration suite.
#
# So it stays unsupported — but loudly, and naming the path the user wrote. It used to raise a
# `MethodError` naming `_get_pair_to_oper` and a tuple type nobody typed; silently wrong rows would
# have been worse still.
function _get_pair_to_oper(x::Pair{Vector{String},Vector{T}}) where T<:AbstractVector{UInt8}
  # Only `@in`/`@nin` are refused HERE, for the binary-specific reason. Any other suffix — or none at
  # all, `filter("blob" => [bytes...])` — is the ordinary "vector value, wrong operator" mistake, and
  # the shared funnel already reports it with the list of operators that DO take a vector. Claiming
  # "membership filter" for `blob__@gte`, or rendering `__@blob` for a path with no suffix at all,
  # would undercut the one thing this guard is for: naming what the user actually wrote.
  x.first[end] in ("in", "nin") ||
    _raise_invalid_filter_operator(x.first, "binary vector", ["in", "nin"])
  path = join(x.first[1:end-1], "__")
  throw(FilterError(
    "A membership filter over binary values is not supported: " *
    "\e[4m\e[31m$(path)__@$(x.first[end])\e[0m. Binary values bind through a wrapper the list " *
    "parameter path cannot unwrap, so this would match nothing rather than fail. Compare one value " *
    "at a time (\e[1m\"$(path)\" => bytes\e[0m), combining them with \e[1mQor\e[0m if you need several."))
end

function _get_pair_to_oper(x::Pair{Vector{String},Vector{T}}) where T<:Union{Missing,AbstractString,Number,Bool,Dates.TimeType,Dates.Period,Dates.CompoundPeriod,Base.UUID}
  suffix = x.first[end]
  if suffix in ["in", "nin"]
    @pormg_debug false
    return OperObject(operator=PormGsuffix[suffix], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  elseif suffix in ("range", "nrange")   # #207: nrange = NOT BETWEEN, same 2-value shape
    if length(x.second) != 2
      throw(FilterError("Error in filter, '$(suffix)' operator requires exactly 2 values, got $(length(x.second))"))
    end
    return OperObject(operator=PormGsuffix[suffix], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  elseif suffix in ("has_any_keys", "has_keys")
    # #27: JSONB overlap operators (?| / ?&) take an array of keys; the render branch binds the
    # vector as a single text[] parameter.
    return OperObject(operator=PormGsuffix[suffix], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  elseif suffix == "jcontains"
    # #27: JSONB array containment (@>) with a vector RHS — serialize to a JSON document string at
    # parse time so OperObject.values stays a String (no downstream type-union change).
    return OperObject(operator="jcontains", values=Models.format_json_sql(x.second), column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    _raise_invalid_filter_operator(x.first, "vector", ["in", "nin", "range", "nrange", "has_any_keys", "has_keys", "jcontains"])
  end
end
# #27: JSONB document containment (@>) with a Dict / NamedTuple RHS — serialize at parse time so
# OperObject.values stays a String.
function _get_pair_to_oper(x::Pair{Vector{String},<:AbstractDict})
  x.first[end] == "jcontains" || _raise_invalid_filter_operator(x.first, "dict", ["jcontains"])
  return OperObject(operator="jcontains", values=Models.format_json_sql(x.second), column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
end
function _get_pair_to_oper(x::Pair{Vector{String},<:NamedTuple})
  x.first[end] == "jcontains" || _raise_invalid_filter_operator(x.first, "namedtuple", ["jcontains"])
  return OperObject(operator="jcontains", values=Models.format_json_sql(x.second), column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
end
function _get_pair_to_oper(x::Pair{Vector{String},Tuple{T,T}}) where T
  if x.first[end] in ("range", "nrange")   # #207: nrange = NOT BETWEEN, same 2-value shape
    return OperObject(operator=PormGsuffix[x.first[end]], values=[x.second[1], x.second[2]], column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    _raise_invalid_filter_operator(x.first, "tuple", ["range", "nrange"])
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

  throw(FilterError(
    "PormG: '$lookup' requires a subquery that returns exactly one column. " *
    detail * " Fix: call .values(\"field_name\") on the subquery so it projects only the key used by the filter."
  ))
end

function _check_filter(x::Pair)
  # #444: a CTE-scoped LHS. Delegate on `ref.path` so the whole String pipeline runs — the `__@`
  # peel, `_check_function`'s transform construction, and whichever of the fifteen RHS-typed
  # `_get_pair_to_oper` methods matches (with its `in`/`range`/`jcontains`/arity validation intact) —
  # then retag the column it produced. Reusing the ladder is the point: a hand-written CTE branch
  # would have to re-derive every one of those checks and would drift from them.
  if isa(x.first, CTEReference)
    ref = _reject_cte_desc(x.first, "filter(...)")
    oper = _check_filter(ref.path => x.second)
    isa(oper, SQLTypeOper) && isa(oper.column, SQLField) && _retag_cte_field!(oper.column, ref.name)
    return oper
  end
  # #481: the joined-copy twin, for exactly the reason above. Delegating on `ref.path` is also what
  # makes an ALIAS-QUALIFIED OPERATOR PAIR work — `filter(Joined("d","points__@gte") => 3)` — which
  # the removed `F("d.points")` spelling could never express: the `__@` peel and the RHS-typed
  # `_get_pair_to_oper` ladder run on the path, and only the column it produced is retagged.
  if isa(x.first, JoinedReference)
    ref = _reject_joined_desc(x.first, "filter(...)")
    oper = _check_filter(ref.path => x.second)
    isa(oper, SQLTypeOper) && isa(oper.column, SQLField) && _retag_joined_field!(oper.column, ref.alias)
    return oper
  end
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
    throw(FilterError("Error in filter: '$(x.first) => ...' must use a String key, got $(typeof(x.first))"))
  end
end

# The next free generated alias (`<base>_<n>`) for a join row.
#
# #480 — it steps around every alias the caller DECLARED, not only the ones already materialized.
# `cjoin_on` rows are built in `build()`'s ALIAS materialization loop, after `values()` /
# `filter()` / `order_by()` have already resolved their joins, and `_build_cjoin_on_row_join`
# writes the user's alias straight into `alias_b`. So when this function chose `R1_1` for a CTE or
# ForeignKey join, no `cjoin_on(alias = "R1_1")` was in `row_join` yet to be avoided, and the
# statement ended up with two range variables of one name — invalid on both engines, and where an
# engine did resolve it, the projection and the ON clause named different relations. The declared
# aliases all sit in `object.alias_join` before `build()` starts, which is early enough.
function _get_alias_name(instruct::SQLInstruction)::String
  return _get_alias_name(instruct.row_join, instruct.alias, _declared_join_aliases(instruct.object))
end
function _get_alias_name(row_join::Vector{Dict{String,Union{String,Vector{FilterType}}}}, alias::String,
                         reserved::Vector{String}=String[])::String
  taken = vcat([r["alias_a"] for r in row_join], [r["alias_b"] for r in row_join], reserved)
  count = 1
  while true
    alias_name = alias * string("_", count)
    in(alias_name, taken) || return alias_name
    count += 1
  end
end

# #480 — every `cjoin_on` alias declared on the query, materialized or not. Since #484 that is
# exactly `alias_join`'s key set: `cjoin` and `on()` entries live in `custom_join`, keyed by PATH
# rather than by an alias they introduce, and their joins get generated aliases like any ForeignKey
# hop.
_declared_join_aliases(object::SQLObject)::Vector{String} = collect(keys(object.alias_join))

# `track_path = false` (#474) records the join WITHOUT claiming its name in `row_path`. A CTE hop
# uses it: `row_path` exists so `build()`'s PATH materialization loop can skip a `custom_join` entry
# that traversal already built, and a CTE has no `custom_join` entry — so a CTE hop registering its
# own name there could only ever suppress an unrelated user join that happened to share it. A
# `cjoin_on` row uses it for the same reason since #484 — an alias is not a path, so it has no
# business claiming a name in the PATH membership set. Nothing indexes `row_path` positionally (its
# one remaining reader is an `∉` membership test), so the two vectors do not have to stay the same
# length.
function _insert_join(
  row_join::Vector{Dict{String,Union{String,Vector{FilterType}}}},
  row::Dict{String,Union{String,Vector{FilterType}}},
  row_path::Vector{String}, join_path::String; track_path::Bool=true)
  @pormg_debug false
  if size(row_join, 1) == 0
    push!(row_join, row)
    track_path && push!(row_path, join_path)
    return row["alias_b"]
  else
    # The tuple has no CTE-vs-physical discriminator on purpose (#479): a CTE row and a model row
    # agree on `b` only when a CTE is named after a physical table, and `_with` refuses that at
    # declaration for every table reachable from the registered models. SQL would resolve both
    # joins to the CTE anyway, so keeping such rows apart here could only ever render a second
    # join that reads the wrong relation — a discriminator would not fix the shape, only hide it.
    check = filter(r -> r["a"] == row["a"] && r["b"] == row["b"] && r["key_a"] == row["key_a"] && r["key_b"] == row["key_b"] && r["alias_a"] == row["alias_a"], row_join)
    if size(check, 1) == 0
      @pormg_debug false
      push!(row_join, row)
      track_path && push!(row_path, join_path)
      return row["alias_b"]
    else
      if size(check, 1) > 1
        # #197: was `throw("Error in join")` — a raw String with zero context. This branch means
        # the dedup filter matched the same (a, b, key_a, key_b, alias_a) join row more than once,
        # which the dedup invariant forbids.
        error(_emsg("PormG internal error in _insert_join: duplicate deduplicated join rows for $(row["a"]) → $(row["b"]) (alias $(row["alias_a"])) — please report this."))
      end
      return check[1]["alias_b"]
    end
  end
end

function _check_if_field_is_a_operator(field::String)
  common_operators = ["exact", "iexact", "contains", "icontains", "iunaccent_contains", "iunaccent_exact", "in", "gt", "gte", "lt", "lte",
    "startswith", "istartswith", "endswith", "iendswith", "range", "date",
    "ncontains", "nicontains", "niunaccent_contains", "niunaccent_exact", "nstartswith", "nendswith", "nrange",  # #207
    "year", "iso_year", "quarter", "month", "day", "week", "week_day", "iso_week_day",
    "hour", "minute", "second", "isnull", "regex", "iregex"]
  if field in common_operators
    throw(FilterError("The filter operator '\e[31m$field\e[0m' requires '@' prefix. Use '\e[32m$field\e[0m' => ... as part of '__\e[33m@$field\e[0m' syntax. Example: \e[36mq.filter(\"name__@$field\" => value)\e[0m"))
  end
end

# #474: `"CROSS"` is NOT in this list, and its absence is the fix rather than an oversight. Every
# consumer of this function feeds `row_join["how"]`, and Phase 2 of `build_row_join_sql_text` emits
# `"$(value["how"]) JOIN $b AS $alias ON $on_clause"` unconditionally — so an accepted `"CROSS"`
# could only ever render `CROSS JOIN … ON …`, which BOTH PostgreSQL and SQLite reject. Measured on
# all three writers before removal: `cjoin_on(join_type="CROSS")`, `on(join_type="CROSS")` and a
# `field.how` of `"CROSS"` each produced that statement. It was never documented either
# (`docs/src/api.md` has always listed only the four below).
#
# The one real CROSS JOIN PormG emits is an UNKEYED `.with(...)` that is REFERENCED — that path sets
# `row_join["cross"]` in `build_joins.jl` and short-circuits ahead of the `ON` render; it never comes
# through here. That is also the only supported spelling for a deliberate cross product, so the
# message points at it (and at the reference, not just the declaration: since #444 a `.with(...)`
# alone emits no join at all).
function _normalize_join_type(join_type::String)
  valid_joins = ["INNER", "LEFT", "RIGHT", "FULL"]
  normalized = uppercase(strip(join_type))
  if !(normalized in valid_joins)
    cross_hint = normalized == "CROSS" ?
      ("\n  A \e[4m\e[32mCROSS JOIN\e[0m cannot carry the \e[4m\e[32mON\e[0m clause this join " *
       "renders. For a deliberate cross product, declare the table as an UNKEYED " *
       "\e[4m\e[32m.with(\"n\" => sub)\e[0m and REFERENCE it — e.g. " *
       "\e[4m\e[32mvalues(\"x\" => CTE(\"n\", \"col\"))\e[0m — which emits a real CROSS JOIN and " *
       "warns that it is Cartesian (#44, #474).") : ""
    throw(QueryBuildError(
      "Invalid join type \e[4m\e[31m$(join_type)\e[0m. Valid types: " *
      "\e[4m\e[32m$(join(valid_joins, ", "))\e[0m.$(cross_hint)"))
  end
  return normalized
end

# The three readers below resolve a MODEL JOIN PATH, so they read the path namespace and only that
# (#484). A `cjoin_on` alias is unreachable from here by construction — it is not in this map — which
# is what makes the alias-equals-ForeignKey-name collision unrepresentable rather than guarded: this
# is the site that used to hand a ForeignKey hop the alias's ON clause and join type.
_get_join_config(q::SQLObject, join_path::String)::Union{PathJoin,Nothing} = get(q.custom_join, join_path, nothing)

function _get_join_field(q::SQLObject, join_path::String)
  config = _get_join_config(q, join_path)
  config === nothing && return nothing
  return config.field
end

function _get_join_filters(q::SQLObject, join_path::String)
  config = _get_join_config(q, join_path)
  config === nothing && return nothing
  return config.filters
end

function _get_join_type_override(q::SQLObject, join_path::String)
  config = _get_join_config(q, join_path)
  config === nothing && return nothing
  return config.join_type
end
"""
This function checks if the given `field` is a valid field in the provided `model`. If the field is valid, it returns the field name, potentially modified based on certain conditions.
"""
# The one place an unknown field name becomes a typed error (#446).
#
# Returns the exception; the call site throws it — the convention `test_docs_error_type_drift.jl`
# pins for `_unsupported_conn` / `_write_not_allowed` / `_fielderr`. A helper that threw internally
# would invite the mirror-image mistake at a returning one, where a forgotten `throw(` silently
# constructs an exception and lets execution continue past the guard.
#
# The choices are SORTED, and that is not cosmetic: `field_names` is declaration order, so on a wide
# model the name a user typo'd sits at an unpredictable offset in a 40-item line. Django sorts the
# same list in `names_to_path` for the same reason. Reverse accessors are listed too — they are
# addressable at exactly the same position in a path, so omitting them makes a legal name look
# unavailable.
function _unknown_field(model::PormGModel, name::AbstractString;
                       aliases::Vector{String} = String[])::UnknownFieldError
  choices = sort(collect(model.field_names))
  accessors = sort(collect(keys(model.related_objects)))
  tail = isempty(accessors) ? "" :
    "; and the reverse accessors: \e[4m\e[32m$(join(accessors, ", "))\e[0m"
  # A projection alias is addressable in exactly the same position as a field — `filter("tot__@gt")`
  # over a `Sum(...)` alias is the documented way to write HAVING — so a message that omitted them
  # would call a legal name unavailable. Django lists `annotation_select` alongside the fields for
  # the same reason.
  tail *= isempty(aliases) ? "" :
    "; and the declared aliases: \e[4m\e[32m$(join(sort(aliases), ", "))\e[0m"
  # #481 — a dotted name is almost always the removed `F("alias.col")` spelling rather than a column
  # anyone believes exists. Without this the reader is sent looking for a field named `d.surname`,
  # which is exactly the misdirection the fail-open resolver used to produce. It is a HINT on the
  # message, not a resolver: the name still does not exist and the error is still the same type.
  # Shaped like an alias reference — exactly one dot, with an identifier on each side. A looser
  # `occursin('.', name)` also fired on `"1.5"`, `"a.b.c"`, `".note"` and `"note."`, none of which
  # anyone wrote meaning a joined copy. A schema-qualified `"public.result"` still matches, and
  # that is accepted: it is indistinguishable from an alias reference by shape alone, and the hint
  # is additive text on an error the name earns either way.
  looks_like_alias_ref = occursin(r"^[\p{L}_][\p{L}\p{M}\p{N}_]*\.[\p{L}_][\p{L}\p{M}\p{N}_]*$", name)
  tail *= looks_like_alias_ref ?
    "\n  If you meant a \e[4m\e[32mcjoin_on\e[0m joined copy: \e[4m\e[31mF(\"alias.column\")\e[0m " *
    "was removed in #481 — write \e[4m\e[32mJoined(\"alias\", \"column\")\e[0m instead." : ""
  return UnknownFieldError(
    "the column \e[4m\e[31m$(name)\e[0m not found in \e[4m\e[32m$(Models.model_table_name(model))\e[0m, " *
    "that contains the fields: \e[4m\e[32m$(join(choices, ", "))\e[0m$(tail)")
end

function _solve_field(field::String, model::PormGModel, instruct::SQLInstruction)
  # check if last_column a field from the model    
  if !(field in model.field_names)
    _check_if_field_is_a_operator(field)
    @pormg_debug false
    throw(_unknown_field(model, field))
  end
  # (instruct.django !== nothing && hasfield(model.fields[field] |> typeof, :to)) && (field = string(field, "_id"))

  # Resolve to the physical column (db_column when set, else the field name) and quote
  # it to prevent SQL injection (#50). SELECT auto-aliases back to the field name, so
  # rows stay keyed by the declared field name even when the column differs.
  return safe_column_identifier(Models.field_db_column(model.fields[field], field), instruct.connection)
end
_solve_field(field::String, _module::Module, model_name::Symbol, instruct::SQLInstruction) = _solve_field(field, getfield(_module, model_name), instruct)
_solve_field(field::String, _module::Module, model_name::String, instruct::SQLInstruction) = _solve_field(field, _module, Symbol(model_name), instruct)
_solve_field(field::String, _module::Module, model_name::PormGModel, instruct::SQLInstruction) = _solve_field(field, model_name, instruct)


# `_df_to_dic` used to live here — deleted in #197: it had zero callers and referenced an
# undefined variable (`filtro`), so it was both dead and broken.

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
    
    # #474: `v` is a column of the BASE model here, so the base-model half of the namespace.
    if _as !== nothing && memo_field(instruc, memo_key(:base, _as)) !== nothing && haskey(instruc.object.model.fields, v)
      # The fields haskey guard matters: an invalid `v` must fall through to _solve_field's
      # UnknownFieldError below, not die here with a raw KeyError (audit finding).
      memo_field!(instruc, memo_key(:base, _as), instruc.object.model.fields[v])
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
    isempty(v) && throw(QueryBuildError("Window expression fields cannot be empty"))
    return _get_select_query(_check_function(v), instruc)
  elseif v isa SQLType
    return _get_select_query(v, instruc)
  else
    throw(QueryBuildError("Unsupported window expression $(repr(v)) of type $(typeof(v))"))
  end
end

# Delegates to the shared whitelist (types.jl, #77) so the ORDER BY and window paths can't drift.
_normalize_window_orientation(orientation::AbstractString)::String =
  _normalize_order_orientation(orientation; context="Window ORDER BY")

function _resolve_window_order(v::String, instruc::SQLInstruction)::String
  isempty(v) && throw(QueryBuildError("Window ORDER BY fields cannot be empty"))
  orientation = startswith(v, "-") ? "DESC" : "ASC"
  field = startswith(v, "-") ? v[2:end] : v
  isempty(field) && throw(QueryBuildError("Window ORDER BY fields cannot be empty"))
  return string(_resolve_window_expression(field, instruc), " ", orientation)
end

function _resolve_window_order(v::SQLTypeOrder, instruc::SQLInstruction)::String
  return string(_resolve_window_expression(v.field, instruc), " ", _normalize_window_orientation(v.orientation))
end
# #444 — a window's ORDER BY is the SECOND place where `desc = true` is meaningful (the fluent
# `order_by(...)` is the first), so it consumes the flag here instead of letting `_cte_join_path`
# refuse it. Rendering goes through the same `_get_select_query` every other CTE reference uses,
# which is what keeps the emitted OVER (...) clause identical to the pre-#444 `"-<cte>__col"` string.
function _resolve_window_order(v::CTEReference, instruc::SQLInstruction)::String
  orientation = v.desc ? "DESC" : "ASC"
  return string(_get_select_query(CTEReference(name=v.name, path=v.path), instruc), " ", orientation)
end
# #481 — the joined-copy twin: consume `desc` here, then render through the same resolver.
function _resolve_window_order(v::JoinedReference, instruc::SQLInstruction)::String
  orientation = v.desc ? "DESC" : "ASC"
  return string(_get_select_query(JoinedReference(v.alias, v.path, false), instruc), " ", orientation)
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
    instruc.connection isa PormGSQLite && throw(BackendCapabilityError("SQLite window functions in PormG do not support explicit frame specifications yet. Remove frame=$(repr(over.frame)) or use PostgreSQL."))
    frame = strip(over.frame)
    isempty(frame) && throw(QueryBuildError("Window frame cannot be empty"))
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
      throw(QueryBuildError("$(v.function_name) requires a column argument; got nothing"))
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
    n isa Integer || throw(QueryBuildError("NthValue requires a positive integer n"))
    n <= 0 && throw(QueryBuildError("NthValue n must be a positive integer"))
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
# #92: fail loud rather than silently mis-correlate a projected subquery nested inside another one —
# OuterRef resolves only one level, so nesting could bind to the wrong outer query and return a wrong
# value. `instruc.outer !== nothing` means the current build is itself a subquery.
function _guard_no_nested_projection(instruc::SQLInstruction, what::AbstractString)
  instruc.outer === nothing || throw(QueryBuildError(
    "$what(...) projected inside another subquery is not supported yet: OuterRef resolves one level " *
    "only, so a nested projected subquery could correlate to the wrong level. Keep projected subqueries " *
    "to a single level of correlation."))
  return nothing
end

# #433: a `.with(...)` declared INSIDE a Subquery / Exists / `__@in` subquery is refused, because
# no backend renders it correctly today. The three call sites fail in two different ways, and the
# guard is deliberately wider than either break:
#
#   - `Exists(...)` never rendered it AT ALL. `_build_exists_query` hand-rolls its own SELECT rather
#     than going through `query()`, so it emits no `WITH` prefix and never materializes the CTE's
#     model — the first path resolving `<cte>__col` reached the "internal error … please report it"
#     in `build_joins.jl`, for a shape the user was always entitled to write. That message is for a
#     broken invariant; this was a missing render step.
#   - `Subquery(...)` and `"col__@in" => sub` DO render an inline `WITH`, and on PostgreSQL they are
#     correct. On SQLite they can misbind: `build_cte_clause` binds unconditionally into the `:cte`
#     bucket, `:cte` is flattened FIRST (`get_final_parameters`), and the subquery's text sits in
#     SELECT or WHERE. Any value whose TEXT precedes the nested CTE but whose bucket flattens later
#     ends up bound behind it. Measured on this fixture:
#         filter("note" => "A", "parent__@in" => <sub declaring .with("gv" => …)>)
#         PostgreSQL ["A", "CTEVAL", "INNERVAL"]   SQLite ["CTEVAL", "INNERVAL", "A"]
#     — wrong rows, no error. It is conditional, not universal: with no earlier parameter to jump,
#     the same shapes bind correctly, which is why this survived so long.
#
# Refusing on BOTH backends rather than only on SQLite is the "keep PostgreSQL and SQLite aligned"
# rule: a query that builds on one engine and is refused on the other is a worse trap than one
# refused on both. The removal of the working PostgreSQL shapes is recorded in `UPGRADING.md`.
#
# NOT guarded, on purpose: a CTE declared inside a CTE **body**. That renders through
# `build_cte_clause` → `query(…, cte=…)`, so its values bind in `:cte` during the same pass that
# emits their text, all of it inside the leading `WITH` — measured correct on both backends. The
# guard therefore belongs at these three filter/projection sites and nowhere else.
function _guard_no_nested_cte(handler::SQLObjectHandler, what::AbstractString)
  ctes = handler.object.ctes
  isempty(ctes) && return nothing
  names = join(collect(keys(ctes)), ", ")
  throw(QueryBuildError(
    "$what does not support a subquery that declares its own \e[4m\e[32m.with(...)\e[0m; " *
    "this one declares \e[4m\e[31m$(names)\e[0m.\n  " *
    "A nested CTE renders inside the subquery's parentheses, but its values bind into the " *
    "\e[4m\e[31m:cte\e[0m parameter bucket, which is flattened ahead of \e[4m\e[31m:select\e[0m " *
    "and \e[4m\e[31m:where\e[0m — on SQLite that binds them ahead of any value whose text comes " *
    "first, silently matching the wrong rows.\n  " *
    "Fold the CTE's predicate into the subquery's own \e[4m\e[32m.filter(...)\e[0m, or declare " *
    "the CTE on a query that is not nested inside a filter or a projection (#433)."))
end

_projection_is_aggregate(v)::Bool =
  v isa SQLTypeField && v.field isa SQLTypeFunction &&
  hasproperty(v.field, :aggregate) && getproperty(v.field, :aggregate) === true

# Soft heads-up: a non-aggregate scalar subquery with no LIMIT may match >1 row and error at the DB.
function _warn_if_possible_multirow(handler::SQLObjectHandler)
  vals = handler.object.values
  length(vals) == 1 || return nothing
  is_agg = _projection_is_aggregate(vals[1])
  has_limit = handler.object.limit != 0
  (!is_agg && !has_limit) && @warn(_emsg(
    "Subquery(...) projects a non-aggregate column with no LIMIT; if the correlation matches more than " *
    "one row the database raises \"more than one row returned by a subquery used as an expression\". " *
    "Use an aggregate, or add order_by + a limit of 1."))
  return nothing
end

function _get_select_query(v::ExistsObject, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  _guard_no_nested_projection(instruc, "Exists")   # #92
  return _get_filter_query(v, instruc)
end
function _get_select_query(v::OuterRefObject, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  return _get_filter_query(v, instruc)
end
function _get_select_query(v::CTEReference, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  return _build_row_join(_cte_join_path(v), instruc, cte=true)
end
# #481 — unlike a CTE reference, a joined-copy reference does NOT materialize a join: `cjoin_on`
# already declared it, and `build()`'s ALIAS loop emits it. This only has to render the column.
function _get_select_query(v::JoinedReference, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  return _resolve_joined(v, instruc)
end
function _get_select_query(v::SubqueryObject, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  # #92: scalar single-column correlated subquery projected as a SELECT-list column.
  _guard_no_nested_projection(instruc, "Subquery")
  # #433: renders an inline WITH that binds into `:cte` while its text sits in the SELECT list.
  _guard_no_nested_cte(v.query, "Subquery(...)")

  # query() mutates the handler's parameters, and SQLField deepcopy is shallow on `.field`, so the same
  # SubqueryObject can be shared across list()/count() deepcopies — copy before rendering.
  handler = deepcopy(v.query)

  # Exactly one projected column (reuse the @in one-column rule).
  labels = _subquery_projection_labels(handler)
  length(labels) == 1 || throw(QueryBuildError(
    "Subquery(...) must project exactly one column; it currently projects $(length(labels)): " *
    "$(_summarize_projection_labels(labels)). Call .values(\"alias\" => <expr>) on the inner query."))

  _warn_if_possible_multirow(handler)

  # Passing the shared `parameters` makes query() treat this as a subquery: it inherits the ambient
  # :select bucket (set by build()) and restores the context afterward, so the inner params flatten in
  # :select — textually correct (the SELECT list precedes FROM/JOIN/WHERE). Correlate via outer=instruc.
  # #432: same nested-run reordering as `_build_exists_query` — this subquery's text sits in the
  # SELECT list, so everything it binds must be one clause-ordered run in the ambient bucket.
  nested_mark = nested_parameter_mark(instruc)
  inner_sql = query(handler,
                    table_alias=instruc.table_alias,
                    connection=instruc.connection,
                    parameters=instruc.parameters,
                    outer=instruc,
                    own_contexts=true)
  reattach_parameters!(instruc, detach_nested_run!(instruc, nested_mark))
  return string("(", inner_sql, ")")
end
function _get_select_query(q::SQLTypeF, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  return _set_update_query(q, instruc)
end

function _resolve_outer_ref_field_name(ref::OuterRefObject, outer::SQLInstruction)::String
  if ref.field_name == "pk"
    pk_field = Models.get_model_pk_field(outer.object.model)
    pk_field === nothing && throw(QueryBuildError("OuterRef(\"pk\") requires the outer model '$(outer.object.model.name)' to define exactly one primary key field"))
    return String(pk_field)
  end
  return ref.field_name
end

function _build_exists_query(subquery::SQLObjectHandler, instruc::SQLInstruction)::String
  # #433 — before the deepcopy: this renderer emits no `WITH` prefix at all, so a CTE declared on
  # the subquery would be dropped from the SQL while still being resolvable by path. Guarding here
  # covers `Exists` in BOTH positions, because the projected form (`_get_select_query`) delegates
  # to the filter form.
  _guard_no_nested_cte(subquery, "Exists(...)")
  q = deepcopy(subquery)
  q.object.values = []
  q.object.order = []
  q.object.limit = 0
  q.object.offset = 0

  old_context = instruc.parameters isa PormGSQLiteParam ? instruc.parameters.current_context : nothing
  # #432: the inner build scatters its values across its own clause buckets while this EXISTS text is
  # spliced into ONE of the parent's clauses. Mark every bucket, then re-emit what it bound as one
  # contiguous run, clause-ordered, at this fragment's position. See `detach_nested_run!`.
  nested_mark = nested_parameter_mark(instruc)
  instruction = try
    build(
      q.object,
      table_alias=instruc.table_alias,
      connection=instruc.connection,
      parameters=instruc.parameters,
      # #432: record this subquery's OWN clause roles so `detach_nested_run!` can sort its values
      # into text order. The `finally` below restores the parent's ambient bucket.
      set_contexts=true,
      outer=instruc,
    )
  finally
    old_context !== nothing && set_context!(instruc.parameters, old_context)
  end
  reattach_parameters!(instruc, detach_nested_run!(instruc, nested_mark))

  safe_table_name = safe_table_identifier(Models.model_table_name(q.object.model), instruction.connection)
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

  if instruction.aggregate && !isempty(instruction.group)
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
      throw(QueryBuildError("Unknown date function or modifier: \e[31m@$func_key\e[0m"))
    end
  end
  return text
end
function _get_filter_query(v::String, instruc::SQLInstruction)
  # V does not have be suffix
  contains(v, "@") && return _get_filter_query(split(v, "__@"), instruc)
  # #481 removed the `"alias.column"` branch that used to sit here. It resolved FAIL-OPEN — an
  # unknown prefix fell through to ordinary field resolution and reported an unknown field named
  # `"typo.col"` — and it existed on this resolver only, which is why the same spelling never
  # worked in `values(...)` or in an operator pair. `Joined(alias, path)` replaces it.
  parts = split(v, "__")
  if size(parts, 1) > 1
    return _build_row_join(parts, instruc, as=false)
  else
    quoted_alias = quote_identifier(instruc.alias, instruc.connection)
    return string(quoted_alias, ".", _solve_field(v, instruc.object.model, instruc))
  end
end

# #481 — resolve a `Joined(alias, path)` reference to `"alias"."db_column"`. It replaces #45's
# `_resolve_cjoin_on_alias_column`, which took a `"alias.column"` String and returned `nothing` for
# an unknown prefix so the caller could fall through. Every exit here is loud: a reference that
# names no declared alias is the caller's typo, and reporting it as an unknown *field* (what the
# fail-open path did) sent people looking for a column that was never the problem.
#
# The lookup is `object.alias_join`, NOT `instruct.row_join`: `cjoin_on` rows materialize in
# `build()`'s alias loop, after `values()` / `filter()` / `order_by()` have already rendered, so at
# the moment a projection resolves the row may not exist yet — but the declaration always does.
# Rendering needs only the alias and the target model, both of which the config carries.
#
# The rendered text is byte-identical to what the dotted-string path produced, which is what keeps
# the #435 relocation guard, the #448 self-reference guard and Phase 1b working: all three
# substring-match `"alias".` in the emitted ON clause.
function _resolve_joined(ref::JoinedReference, instruc::SQLInstruction)::String
  _reject_joined_desc(ref, "a projection or predicate")
  # A `__@` segment is one of two different things, and they end differently.
  #
  # A TRANSFORM (`@year`, `@yyyy_mm`, …) is part of the column expression: the removed
  # `F("b2.dt__@year")` spelling supported it inside an ON clause — `_get_filter_query(::String)`
  # peeled it before reaching the alias branch — and dropping that would be a capability
  # regression, the exact failure #444 recorded when it swapped in a typed handle without widening
  # the paths around it. So it is built here, over the bare reference, through the same
  # `_check_function` ladder every other clause uses.
  #
  # An operator SUFFIX (`@gte`, `@in`, …) is a comparison, not a column, and belongs on the LEFT of
  # a filter pair where `_check_filter` peels it. Reaching here with one means the caller wrote it
  # somewhere that cannot carry it.
  if occursin("__@", ref.path)
    segments = String.(split(ref.path, "__@"))
    haskey(PormGsuffix, segments[end]) && throw(QueryBuildError(
      "Joined(\"$(ref.alias)\", \"$(ref.path)\") carries an operator suffix, which is only meaningful " *
      "on the left of a filter pair — write filter(Joined(\"$(ref.alias)\", \"$(ref.path)\") => value)."))
    transformed = _retag_joined_column(_check_function(segments), ref.alias)
    return _get_select_query(transformed, instruc)
  end
  occursin("__", ref.path) && throw(QueryBuildError(
    "Joined(\"$(ref.alias)\", \"$(ref.path)\") cannot traverse a relation: a cjoin_on joined copy is " *
    "one table, so its reference is a single column on that model. Declare another cjoin_on for the " *
    "next hop and reference its alias."))
  config = get(instruc.object.alias_join, ref.alias, nothing)
  if config === nothing
    declared = collect(keys(instruc.object.alias_join))
    throw(QueryBuildError(
      "Joined(\"$(ref.alias)\", …) names no cjoin_on alias on this query. " *
      (isempty(declared) ? "This query declares no cjoin_on at all." :
       "Declared aliases: $(join(declared, ", ")).")))
  end
  target_model = config.target
  (ref.path in target_model.field_names) ||
    throw(_unknown_field(target_model, ref.path))
  # Memoize the joined field so a filter's RHS formats through it (the same service
  # `tab_field_cache` performs for a base-model column), under the `:joined` namespace so an
  # identically spelled field path or CTE reference cannot read or claim the entry.
  memo_field!(instruc, memo_key(ref), target_model.fields[ref.path])
  return string(quote_identifier(ref.alias, instruc.connection), ".",
                safe_column_identifier(Models.field_db_column(target_model.fields[ref.path], ref.path), instruc.connection))
end
function _get_filter_query(v::SQLTypeFunction, instruc::SQLInstruction)
  return _get_select_query(v, instruc) # Does this have any coletaral efect?
end
function _get_filter_query(v::ExistsObject, instruc::SQLInstruction)
  return _build_exists_query(v.query, instruc)
end
function _get_filter_query(v::OuterRefObject, instruc::SQLInstruction)
  instruc.outer === nothing && throw(QueryBuildError("OuterRef(\"$(v.field_name)\") can only be resolved while building a correlated subquery such as Exists(subquery)."))
  return _get_filter_query(_resolve_outer_ref_field_name(v, instruc.outer), instruc.outer)
end
function _get_filter_query(v::CTEReference, instruc::SQLInstruction)
  return _build_row_join(_cte_join_path(v), instruc, as=false, cte=true)
end
# #481 — see `_get_select_query(::JoinedReference, …)`: the join already exists, so only the column
# is rendered, and both clauses share one resolver.
function _get_filter_query(v::JoinedReference, instruc::SQLInstruction)
  return _resolve_joined(v, instruc)
end

# #444 — lower a CTE handle to the segment vector `_build_row_join` walks. It is byte-for-byte the
# vector the pre-#444 string `"<name>__<path>"` produced, which is why the deep-hop loop, the
# FK-reached JSON gate and the terminality error all keep working with no edit of their own.
function _cte_join_path(v::CTEReference)
  _reject_cte_desc(v, "a projection or predicate")
  # Every legitimate suffix has been peeled by the parse boundary (`_check_filter` splits `ref.path`
  # on `__@` before retagging; `values`/`order_by` refuse suffixes outright). One surviving here can
  # only come from a spelling those boundaries never see — e.g. a CTE handle on a filter's RIGHT side.
  occursin("__@", v.path) && throw(QueryBuildError(
    "\e[4m\e[31mCTE(\"$(v.name)\", \"$(v.path)\")\e[0m carries an operator or transform suffix " *
    "(\e[4m\e[31m__@\e[0m) where a plain column path is required. Suffixes belong on the LEFT side " *
    "of a \e[4m\e[32mfilter(...)\e[0m pair."))
  return String[v.name; String.(split(v.path, "__"))]
end
# function _get_filter_query(v::SQLTypeText, instruc::SQLInstruction)
#   return _get_select_query(v, instruc)
# end
function _get_filter_query(v::SQLTypeField, instruc::SQLInstruction)
  # check if SQLTypeField exists in cache
  # #474: keyed by `memo_key`, not `_as`. This is the site the measured defect went
  # through — a CTE reference projected as `CTE("parent", "sku")` claimed the memo under
  # `"parent__sku"`, and a later `filter("parent__sku" => …)` on the model's OWN ForeignKey read it
  # back, filtering the CTE's column while the ForeignKey's join sat unused in the statement.
  key = memo_key(v)
  cached = memo_projection(instruc, key)
  if cached !== nothing
    return cached.field
  else
    v_copy = deepcopy(v)
    v_copy.field = _get_select_query(v_copy.field, instruc)
    if key !== nothing
      memo_projection!(instruc, key, v_copy)
    end
    return v_copy.field
  end
end
# Coerce a JSON numeric-comparison RHS to an actual Julia number, so BOTH dialects compare
# numerically (PostgreSQL casts the extracted text `::numeric`; SQLite's json_extract returns a
# native number). Binding a string here would make SQLite compare number-vs-text and silently
# invert every comparison.
function _json_numeric_rhs(value)
  value isa Bool && return Int(value)
  value isa Integer && return value
  value isa AbstractFloat && return value
  s = strip(string(value))
  n = tryparse(Int, s); n !== nothing && return n
  f = tryparse(Float64, s); (f !== nothing && isfinite(f)) && return f
  throw(FilterError("A numeric JSON comparison requires a number; got \e[31m$(value)\e[0m."))
end

# #27: render a comparison against a JSON path lookup (e.g. `payload__driver`). The RHS binds
# dialect-aware — NOT through the JSON field's formatter (which would reject a plain string like
# "hamilton"):
#   - PostgreSQL `#>>` always yields TEXT, so equality binds text and `<`/`>` cast the LHS
#     `::numeric`.
#   - SQLite `json_extract` returns the value's NATIVE type, so equality binds the raw Julia value
#     (a JSON number stays a number → `5 = 5`, not `5 = '5'`) and comparisons need no cast.
function _render_json_lookup_comparison(v::SQLTypeOper, column::String, instruc::SQLInstruction)::String
  op = v.operator
  is_pg = instruc.connection isa PormGPostgres
  if op == "ISNULL"
    # Render IS NULL directly — the shared ISNULL() rejects any column containing "(", which a
    # legitimate SQLite json_extract(...) expression trips.
    return string(column, v.values == true ? " IS NULL" : " IS NOT NULL")
  elseif op in ("=", "!=", "<>")
    # PG: bind text (LHS is text). SQLite: bind the native value (LHS keeps its JSON type).
    ph = add_parameter!(instruc, is_pg ? string(v.values) : v.values)
    return string(column, " ", op, " ", ph)
  elseif op in (">", ">=", "<", "<=")
    lhs = is_pg ? "($(column))::numeric" : column
    ph = add_parameter!(instruc, _json_numeric_rhs(v.values))
    return string(lhs, " ", op, " ", ph)
  else
    throw(FilterError("The operator \e[31m$(op)\e[0m is not supported on a JSON path lookup. Use =, !=, <, <=, >, >=, or __@isnull."))
  end
end

# #27: render a JSONB containment/overlap operator (@>, ?, ?|, ?&). The LHS must be a JSON COLUMN
# (terminal), not a nested key path. Binds the RHS per operator (jsonb document / text key /
# text[] key array) and dispatches to the per-dialect Dialect renderer (PG emits the operator;
# SQLite throws PG-only).
function _render_json_operator(v::SQLTypeOper, column::String, instruc::SQLInstruction)::String
  col_as = isa(v.column, SQLTypeField) ? v.column._as : nothing
  # #474: the memo is keyed by namespace, the MESSAGE by what the caller wrote.
  col_key = isa(v.column, SQLTypeField) ? memo_key(v.column) : nothing
  if memo_json_lookup(instruc, col_key)
    throw(FilterError("The \e[31m@$(v.operator)\e[0m operator applies to a JSON column, not a nested key path (\e[31m$(col_as)\e[0m); this is not supported in v1."))
  end
  base = _resolve_json_operator_field(v, instruc)
  (base !== nothing && Models.is_json_field(base)) ||
    throw(FilterError("The \e[31m@$(v.operator)\e[0m operator requires a JSONField column; \e[31m$(something(col_as, "the target"))\e[0m is not JSON."))
  op = v.operator
  ph = if op == "jcontains"
    add_parameter!(instruc, Models.format_json_sql(v.values); sql_type="jsonb")
  elseif op == "has_key"
    add_parameter!(instruc, string(v.values))
  else  # has_any_keys / has_keys
    v.values isa AbstractVector ||
      throw(FilterError("The \e[31m@$(op)\e[0m operator requires an array of keys, e.g. filter(\"col__@$(op)\" => [\"a\", \"b\"]); got a single value."))
    add_parameter!(instruc, String.(v.values); sql_type="text[]")
  end
  return getfield(Dialect, Symbol(op))(instruc.connection, column, ph)
end

# Resolve the base PormGField a JSON operator targets: a bare column name lives on the model;
# an FK-reached terminal JSON column was cached in tab_field_cache when `column` resolved.
function _resolve_json_operator_field(v::SQLTypeOper, instruc::SQLInstruction)
  isa(v.column, SQLTypeField) || return nothing
  fld = v.column.field
  if fld isa String && !contains(fld, "__")
    return get(instruc.object.model.fields, fld, nothing)
  end
  # #474: the memo key, like every other `tab_field_cache` reader. Missing this one made a JSONB
  # containment operator over a CTE column — `filter(CTE("evc", "payload__@has_key") => "driver")` —
  # miss the entry `_build_row_join` had just written under the namespaced key and fail closed with
  # "evc__payload is not JSON", a shape that rendered before #474. The mirror hazard is worse: with
  # a base-model path spelled the same, the un-namespaced lookup could return the OTHER namespace's
  # field and license a jsonb operator against a CTE's text column.
  return memo_field(instruc, memo_key(v.column))
end

# #352: sargable rewrite for `col__@yyyy_mm` / `col__@year` / `col__@date` comparisons.
#
# `to_char(col, 'YYYY-MM') <= $1` (and the EXTRACT(YEAR ...) equivalent) puts a function call on
# the indexed column: no index on `col` applies, and PostgreSQL cannot estimate selectivity
# through it (issue #352 measured a 193x row-count misestimate cascading into an 18+ minute plan).
# Rewritten as a plain comparison/range on the raw column:
#
#   @exact (bare `=`)  col >= F AND col < N
#   @gte               col >= F
#   @gt                col >= N
#   @lte               col < N
#   @lt                col < F
#
# where F = first day of the bucket period and N = first day of the following period. `@date`
# needs no range at all (F == the literal) since to_char at day granularity on a DATE column
# preserves chronological order exactly — the rewrite there is just "drop the to_char".
#
# #373 extended the rewrite to a JOINED path (`fk__col__@yyyy_mm`), which #352 had left out
# because the terminal field's TYPE — what the DATE-only gate below needs — is not readable off
# `instruc.object.model`. See `_resolve_bucket_column` for how that is answered.
#
# Scope:
#   - Only a plain DATE column (`_is_date_field`) — TIMESTAMPTZ/TIMESTAMP are excluded because
#     to_char renders in the session TimeZone, so naively computing F/N would shift the boundary
#     around midnight. Left on the existing rendering.
#   - Only a plain scalar RHS (String/Number) — an F()/subquery/Case RHS falls through unchanged.
#
# Returns the rendered SQL string, or `nothing` to fall through to the existing rendering.
function _render_sargable_date_range(v::SQLTypeOper, instruc::SQLInstruction)::Union{String,Nothing}
  isa(v.column, SQLTypeField) || return nothing
  fobj = v.column.field
  isa(fobj, FObject) || return nothing
  raw_field = fobj.column
  # #444: a CTE-scoped bucket column arrives as a handle rather than a `"<cte>__col"` string. It
  # must be admitted here or the rewrite silently stops firing for every CTE date filter — the exact
  # failure mode #376 describes two paragraphs down in `_resolve_bucket_column`, reached by a
  # different route. Measured against main by rendering both spellings: without this line
  # `filter(CTE("ev","seen__@yyyy_mm__@lte") => "1991-10")` degraded from `"seen" < '1991-11-01'`
  # back to `to_char("seen",'YYYY-MM') <= '1991-10'`.
  # #481: `JoinedReference` for the same reason, one namespace over.
  isa(raw_field, Union{String,CTEReference,JoinedReference}) || return nothing
  v.operator in ("=", ">=", ">", "<=", "<") || return nothing
  (v.values isa AbstractString || v.values isa Number) || return nothing

  # The bucket gate runs BEFORE the column is resolved: resolving a joined path renders its join,
  # and a non-bucket transform (`@month`, `@quarter`, …) must never reach that.
  bucket = if fobj.function_name == "EXTRACT_DATE" && get(fobj.kwargs, "format", nothing) == "YYYY-MM"
    :yyyy_mm
  elseif fobj.function_name == "EXTRACT_DATE" && get(fobj.kwargs, "format", nothing) == "YYYY-MM-DD"
    :date
  elseif fobj.function_name == "EXTRACT" && get(fobj.kwargs, "part", nothing) == "YEAR" && !haskey(fobj.kwargs, "format")
    :year
  else
    return nothing
  end

  f_meta, column_sql = _resolve_bucket_column(raw_field, instruc)
  f_meta === nothing && return nothing
  _is_date_field(f_meta) || return nothing                          # DATE only, not TIMESTAMP(TZ)

  bind(x) = add_parameter!(instruc, f_meta.formatter(x))

  if bucket == :date
    # Same granularity as the column: no range, operator unchanged — just drop the to_char.
    return string(column_sql, " ", v.operator, " ", bind(v.values))
  end

  first_of_period, next_period = bucket == :yyyy_mm ? _yyyy_mm_bucket_bounds(v.values) : _year_bucket_bounds(v.values)

  if v.operator == ">="
    return string(column_sql, " >= ", bind(first_of_period))
  elseif v.operator == ">"
    return string(column_sql, " >= ", bind(next_period))
  elseif v.operator == "<="
    return string(column_sql, " < ", bind(next_period))
  elseif v.operator == "<"
    return string(column_sql, " < ", bind(first_of_period))
  else # "="
    p1, p2 = bind(first_of_period), bind(next_period)
    return string("(", column_sql, " >= ", p1, " AND ", column_sql, " < ", p2, ")")
  end
end

# Terminal field metadata + rendered SQL for the column a date-bucket comparison targets, or
# `(nothing, "")` to fall through to the existing rendering.
#
# A bare column reads its metadata straight off the queried model. A JOINED path (#373) cannot:
# `FObject.column` still holds the unsplit dotted string at this point, and the terminal field only
# becomes knowable once the path has actually been walked. So the path is RENDERED first and the
# type read back out of `tab_field_cache`, which `_build_row_join` populates as it goes.
#
# Rendering first is the design, not a compromise. `_build_row_join` is the only authority on which
# model and field a dotted path resolves to — forward FK, reverse relation, many-to-many, and the
# `driver` → `driver_id` short-form rewrite whose ambiguity against a declared `related_name` is
# documented on `_resolve_fk_short_form`. Re-deriving that walk here would be a SECOND resolver able
# to disagree with the renderer, and a disagreement puts the date range on a different table's
# column with no error and wrong rows. Nothing is saved by not rendering, either: the rewritten
# predicate references the joined column, so the join is built either way.
#
# The early render is side-effect-free in every way that matters here: `build_joins.jl` binds no
# parameters, and `_insert_join` dedups on (a, b, key_a, key_b, alias_a) — so when the DATE gate
# rejects the field, the fall-through renders the same path again and gets the same alias back.
# Identical SQL, one extra traversal.
function _resolve_bucket_column(raw_field::String, instruc::SQLInstruction)
  if !contains(raw_field, "__")
    f_meta = get(instruc.object.model.fields, raw_field, nothing)
    f_meta === nothing && return (nothing, "")
    return _checked_bucket_column(f_meta, raw_field, _get_select_query(raw_field, instruc), instruc)
  end

  # A CTE-rooted reference now takes the `::CTEReference` method below (#444) rather than this
  # branch, but the reasoning that makes the DATE gate trustworthy over a CTE is the same and is
  # recorded here because it is not obvious.
  # A CTE model's column types are INFERRED (`_set_field_from_sql_function`, ctes.jl), so the
  # question is whether one can ever be typed DATE while the column holds something else. It cannot:
  # a plain-column projection reads the real field; COUNT/SUM yield IntegerField; CASE/WHEN route
  # through `_infer_case_output_type`, which only ever returns Integer/Float/CharField; MIN/MAX
  # carry the base DateField and genuinely produce a date; and every OTHER function — `ToChar`
  # included, which is what would actually produce a "1991-10" text column — is rejected outright
  # when the CTE model is built. So the DATE gate is as trustworthy here as anywhere else.
  #
  # #376: the drift guard below still MATCHES on a CTE path. It matched before the fix too — both
  # sides read the SAME field object, so they agreed on the physical name and the rewrite was
  # applied to a column the CTE does not expose. What changed is WHICH name they agree on: the CTE
  # model's fields now carry no db_column (`Models.field_without_db_column`, applied in
  # `_build_cte_custom_model`), so `field_db_column(f_meta, <alias>)` and the rendered column both
  # answer the projection ALIAS. Resolving the alias at the REFERENCE site instead would have left
  # `f_meta` claiming the physical name while the render answered the alias — failing this guard
  # closed and silently dropping the #352/#373 rewrite for every CTE date-bucket filter, with no
  # other symptom. That is why the fix belongs at construction.
  column_sql = _get_select_query(raw_field, instruc)
  # #474: a String path is base-model by construction — since #444 a string cannot name a CTE. Its
  # CTE twin below asks for the same entry under the other half of the namespace.
  f_meta = memo_field(instruc, memo_key(:base, raw_field))
  f_meta === nothing && return (nothing, "")
  return _checked_bucket_column(f_meta, String(last(split(raw_field, "__"))), column_sql, instruc)
end

# #444 — the CTE-handle twin of the joined-path branch above, and deliberately identical to it in
# every step: render first (only `_build_row_join` is authority on what a path resolves to), read
# the terminal field back out of `tab_field_cache`, then run the same drift guard. The cache key is
# `_cte_as(ref)` — `"<name>__<path>"` — which is precisely the key `_build_row_join` writes, because
# the segment vector it walks is the one the pre-#444 string produced. All the reasoning above about
# why the DATE gate can be trusted over a CTE (inferred column types, #376's db_column stripping)
# applies here unchanged.
function _resolve_bucket_column(ref::CTEReference, instruc::SQLInstruction)
  column_sql = _get_select_query(ref, instruc)
  f_meta = memo_field(instruc, memo_key(ref))   # #474: namespaced memo
  f_meta === nothing && return (nothing, "")
  return _checked_bucket_column(f_meta, String(last(split(ref.path, "__"))), column_sql, instruc)
end

# #481 — the joined-copy twin. `_resolve_joined` writes the memo entry as it renders, so the read
# below always hits; the same drift guard then applies.
function _resolve_bucket_column(ref::JoinedReference, instruc::SQLInstruction)
  column_sql = _get_select_query(ref, instruc)
  f_meta = memo_field(instruc, memo_key(ref))
  f_meta === nothing && return (nothing, "")
  return _checked_bucket_column(f_meta, ref.path, column_sql, instruc)
end

# Drift guard: the rewrite may only range on a column that IS the one `f_meta` describes. That holds
# by construction on every branch today — `_build_row_join` renders the terminal column through
# `_solve_field` and caches `last_field` from the same model and segment — which is precisely why it
# is worth pinning. If the correspondence ever breaks, the rewrite falls back to the existing
# (correct, merely non-sargable) rendering instead of quietly ranging on some other column.
# Fail-safe, never fail-loud: a mismatch is a PormG-internal invariant, not a user error.
function _checked_bucket_column(f_meta, last_segment::String, column_sql::String, instruc::SQLInstruction)
  expected = safe_column_identifier(Models.field_db_column(f_meta, last_segment), instruc.connection)
  endswith(column_sql, string(".", expected)) || return (nothing, "")
  return (f_meta, column_sql)
end

# Reuses Models.format_yyyy_mm for shape/type validation (String "YYYY-MM" regex, or 6-digit
# Integer YYYYMM), then parses the normalized string for range math. format_yyyy_mm does NOT
# validate the month is 01-12 (only the regex shape) — Dates.Date(y, m, 1) does, and its
# ArgumentError is caught and rethrown as a FilterError so a filter-level defect isn't a bare
# Dates.jl exception (consistent with the catch/rethrow pattern below for BETWEEN-style errors).
# A year outside 1..9999 cannot be expressed as a date bound: `Dates.Date` happily accepts year 0
# and negatives and stringifies them as "0000-01-01" / "-0005-01-01", which both backends reject at
# execution with an opaque server-side error — and `format_date_sql(::Date)` is a bare `string(...)`
# that validates nothing. Takes any `Real` so it can run before `Int(...)` narrowing.
function _check_year_bound(y::Real)
  (1 <= y <= 9999) || throw(FilterError("The year \e[31m$(y)\e[0m is out of the range a date bound can express (1-9999)."))
  return nothing
end

function _yyyy_mm_bucket_bounds(value)::Tuple{Dates.Date,Dates.Date}
  normalized = Models.format_yyyy_mm(value)   # throws InvalidValueError on bad shape/type
  y = parse(Int, normalized[1:4])
  m = parse(Int, normalized[6:7])
  # The regex admits "0000-01", which would render the unusable "0000-01-01". Same bound as @year.
  _check_year_bound(y)
  try
    first_of_period = Dates.Date(y, m, 1)
    return first_of_period, first_of_period + Dates.Month(1)
  catch e
    throw(FilterError("The value \e[31m$(value)\e[0m is not a valid YYYY-MM bucket: $(sprint(showerror, e))"))
  end
end

# Resolve `@year`'s RHS to a calendar year, accepting every value shape the pre-#352 rendering
# accepted via `Models.format_number_sql` — Integer, Decimal, and a whole-valued Float (an ETL
# app pulling a year out of a Float64 DataFrame column is the common case), plus a numeric
# String. Narrowing this would be a breaking change for consuming apps, not a tightening.
#
# What IS rejected, because the range rewrite cannot express it while `EXTRACT(YEAR ...)` could:
#   - Bool (`Bool <: Integer` in Julia; format_number_sql carries a ::Bool overload for exactly
#     this trap) — `false` would silently become year 0.
#   - a fractional year (1991.7) — no single date bound represents it.
#   - a year outside 1..9999 — `Dates.Date` accepts year 0 and negatives and renders them
#     "0000-01-01" / "-0005-01-01", which both backends reject at execution with an opaque
#     server-side error; `format_date_sql(::Date)` is a bare `string(...)` and validates nothing.
# The string branch parses base-10 explicitly: `tryparse(Int, "0x10")` returns 16 in Julia, so
# the default would silently accept a hex literal as a year.
function _year_bucket_bounds(value)::Tuple{Dates.Date,Dates.Date}
  # The range check runs BEFORE `Int(...)` narrowing on every numeric branch: `Int(big(10)^20)`
  # and `Int(1e30)` throw a raw `InexactError`, which is not a PormGError at all and whose message
  # never mentions a year filter. `isinteger(1e30)` is `true`, so the whole-year guard alone does
  # not stop it. Comparing first works on any Real — BigInt, BigFloat, Rational, Decimal.
  y = if value isa Bool
    throw(FilterError("A __@year filter requires a year, not a Bool; got \e[31m$(value)\e[0m."))
  elseif value isa Integer
    _check_year_bound(value)
    Int(value)
  elseif value isa Real
    isinteger(value) || throw(FilterError("The value \e[31m$(value)\e[0m is not a whole year for a __@year filter."))
    _check_year_bound(value)
    Int(value)
  elseif value isa AbstractString
    n = tryparse(Int, strip(value), base=10)
    n === nothing && throw(FilterError("The value \e[31m$(value)\e[0m is not a valid year for a __@year filter."))
    _check_year_bound(n)
    n
  else
    throw(FilterError("A __@year filter requires a year as an Integer, a whole Real, or a numeric String; got $(typeof(value))."))
  end
  first_of_period = Dates.Date(y, 1, 1)
  return first_of_period, first_of_period + Dates.Year(1)
end

# Apply a field's formatter to a filter's right-hand side (#411).
#
# Django's answer, in one function. `Field.get_prep_value` is scalar-only for EVERY Django field type;
# `In` and `Range` inherit `FieldGetDbPrepValueIterableMixin`, whose `get_prep_lookup()` maps it over
# the rhs itself. The iterable-aware layer belongs to the LOOKUP, not to the field. PormG had that
# contract inverted — the three call sites below handed the whole vector to `field.formatter`, so
# every formatter had to cope with an array individually, and only two of them did. `__@in` was
# therefore broken on DateField, DateTimeField, BooleanField, DurationField, UUIDField and
# BinaryField, and silently WRONG on JSONField.
#
# The operator is the discriminator, not the value's type, and that distinction is the whole point.
# `format_binary_sql` and `format_json_sql` are the field types whose SCALAR value is itself a
# collection: a `Vector{UInt8}` IS one binary value, and `[1, 2]` IS one JSON array. Dispatching on
# `values isa AbstractArray` would map over the bytes of a BinaryField and destroy it. Only "this is a
# MEMBERSHIP lookup, so the rhs is a list of values" licenses the map — which is exactly why Django
# puts the mixin on the lookup class.
#
# Everything that is not `IN`/`NOT IN` passes through untouched, so `BETWEEN` (which indexes its two
# operands separately, below) and every scalar comparison are unaffected.
_format_filter_value(formatter, values, operator::AbstractString) =
  operator in ("IN", "NOT IN") && values isa AbstractArray ? [formatter(v) for v in values] :
                                                             formatter(values)

# The single renderer for `IN` / `NOT IN` (#411). Extracted so the WHERE path and the HAVING path
# cannot drift: `get_filter_query`'s aggregate-alias branch used to build its own
# `"$(field) $(operator) $(placeholder)"`, which produced `HAVING MAX(x) IN $1` on PostgreSQL and
# `HAVING MAX(x) IN ?, ?` on SQLite — no parentheses, no `= ANY`, a syntax error on both engines.
# That was invisible because nothing asserted on the rendered HAVING text.
#
# `column` is the already-rendered left-hand side; `placeholders` is whatever `add_parameter!`
# returned, which is dialect-dependent by design.
function _render_membership(column::AbstractString, operator::AbstractString, placeholders,
                            instruc::SQLInstruction)::String
  # An EMPTY membership list, handled before the dialect split because only one dialect breaks.
  # SQLite has no array type, so `add_parameter!` expands a vector into one `?` per element and binds
  # them individually — for an empty vector that is ZERO parameters and an empty placeholder string,
  # which rendered `IN ()`: a syntax error. PostgreSQL binds the whole vector as a single array
  # parameter and rendered a valid `= ANY($1)` over `'{}'` that simply never matches. One query, a
  # loud failure on one backend and correct behavior on the other.
  #
  # Render the constant the empty set means, so the two agree on BEHAVIOR — which is what the
  # PG/SQLite alignment rule actually requires; their SQL text already differs here, `IN (?, ?)`
  # against `= ANY($1)`. Nothing is a member of the empty set, and everything is not a member of it.
  # Django reaches the same truth value from the other end, raising `EmptyResultSet` so the query is
  # never sent; PormG has no such short-circuit and emits a predicate with the same meaning instead.
  #
  # Dropping `column` is safe because no filter-LHS renderer binds a parameter of its own — that is
  # the real invariant, not "an empty placeholder means nothing was bound", and it is what keeps the
  # parameter list in step. Registered joins live in `instruct.row_join`, not in the discarded string.
  if isempty(placeholders)
    return operator == "IN" ? "(1 = 0)" : "(1 = 1)"
  end
  if isa(placeholders, String)
    # One placeholder for the whole list: PostgreSQL bound it as a single array parameter.
    if instruc.connection isa PormGPostgres
      return string(column, " ", operator == "IN" ? "= ANY" : "<> ALL", "(", placeholders, ")")
    else
      return string(column, " ", operator, " (", placeholders, ")")
    end
  elseif isa(placeholders, AbstractArray)
    # SQLite and friends: one placeholder per element, so the list is spelled out.
    return string(column, " ", operator, " (", join(placeholders, ", "), ")")
  else
    # Internal invariant: add_parameter! only ever returns a String or a Vector of placeholders.
    error(_emsg("PormG internal error rendering $(operator): parameter placeholders must be a String or a Vector, got $(typeof(placeholders))."))
  end
end

function _get_filter_query(v::SQLTypeOper, instruc::SQLInstruction)
  @pormg_debug false
  # #352/#373: rewrite a non-sargable date-bucket comparison (to_char/EXTRACT on the column) into a
  # plain range/comparison directly on the column, so an index on the column — and the planner's
  # selectivity estimate — both apply. Covers joined paths as well as bare ones; see
  # _render_sargable_date_range and _resolve_bucket_column for scope.
  sargable = _render_sargable_date_range(v, instruc)
  sargable !== nothing && return sargable

  column = _get_filter_query(v.column, instruc)
  # #27: JSONB containment/overlap operators (@>, ?, ?|, ?&) — dedicated binding + PG-only render.
  if v.operator in JSON_CONTAINMENT_OPERATORS
    return _render_json_operator(v, column, instruc)
  end
  # #27: comparison against a JSON path lookup (payload__key). Resolving `column` above populated
  # json_lookup_paths; the dedicated branch binds the RHS as plain text (the generic path would run
  # the JSON formatter on the RHS and throw on plain strings) and applies the PG numeric cast for </>.
  # The `_as !== nothing` test this used to carry was redundant — `memo_key` answers `nothing` for an
  # unnamed expression and `memo_json_lookup` answers `false` for a `nothing` key.
  if isa(v.column, SQLTypeField) && memo_json_lookup(instruc, memo_key(v.column))
    return _render_json_lookup_comparison(v, column, instruc)
  end
  if isa(v.values, Union{SQLTypeF,SQLTypeCTE,SQLTypeJoined})
    @pormg_debug false
    # F expressions are safe since they reference model fields; a CTE handle (#444) is the same
    # thing scoped to a CTE — `filter("raceid" => CTE("r91", "raceid"))` is a column comparison,
    # never a bound value.
    placeholders = _get_filter_query(v.values, instruc)
    return string(column, " ", v.operator, " ", placeholders)
  elseif isa(v.values, SQLTypeFunction)
    # Case/When and other SQL function expressions as filter RHS
    placeholders = _get_filter_query(v.values, instruc)
    return string(column, " ", v.operator, " ", placeholders)
  elseif isa(v.column, SQLTypeField) && isa(v.column.field, SQLTypeFunction) && v.column.field.formatter !== nothing
    @pormg_debug false
    placeholders = add_parameter!(instruc,
      _format_filter_value(v.column.field.formatter, v.values, v.operator))
  elseif isa(v.column, SQLTypeField) && isa(v.column.field, SQLTypeFunction) && haskey(PormGTypeField, v.column.field.function_name)
    # Through the same helper as the other sites (#411). These work today only because
    # `PormGTypeField` maps to `format_number_sql` / `format_text_sql` — the two formatters that
    # happen to carry an `AbstractArray` method, which is precisely the coincidence this issue is
    # about. Leaving them raw would keep that coincidence load-bearing.
    placeholders = add_parameter!(instruc,
      _format_filter_value(getfield(Models, PormGTypeField[v.column.field.function_name]), v.values, v.operator))
    # value = getfield(Models, PormGTypeField[v.column.field.function_name])(v.values)
  elseif isa(v.column, SQLTypeFunction) && haskey(PormGTypeField, v.column.function_name)
    # Function with formatter
    @pormg_debug false
    # Through the same helper as the other sites (#411). These work today only because
    # `PormGTypeField` maps to `format_number_sql` / `format_text_sql` — the two formatters that
    # happen to carry an `AbstractArray` method, which is precisely the coincidence this issue is
    # about. Leaving them raw would keep that coincidence load-bearing.
    placeholders = add_parameter!(instruc,
      _format_filter_value(getfield(Models, PormGTypeField[v.column.function_name]), v.values, v.operator))
  elseif isa(v.values, SQLObjectHandler)
    # Subqueries - these are safe since they're built through PormG.jl
    if !(v.operator in ["IN", "NOT IN"])
      @pormg_debug
      throw(FilterError("Invalid subquery filter on \"$(v.column.field)\": a queryset value requires a membership operator — use \"$(v.column.field)__@in\" => subquery or __@nin."))
    end
    _validate_membership_subquery(v)
    # #433: renders an inline WITH that binds into `:cte` while its text sits in the WHERE clause.
    _guard_no_nested_cte(v.values, "A membership filter (__@in / __@nin)")
    # #432: same nested-run reordering — the subquery renders inside this predicate's clause.
    nested_mark = nested_parameter_mark(instruc)
    placeholders = query(v.values, table_alias=instruc.table_alias, connection=instruc.connection, parameters=instruc.parameters, outer=instruc, own_contexts=true)
    reattach_parameters!(instruc, detach_nested_run!(instruc, nested_mark))
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
    elseif v.operator in ("BETWEEN", "NOT BETWEEN")
      # Handle (NOT) BETWEEN with two parameters. #207: `nrange` renders NOT BETWEEN — the operator
      # string carries "BETWEEN"/"NOT BETWEEN" so both branches emit it verbatim.
      column_sql = _get_filter_query(v.column, instruc)
      field_name = ""
      if isa(v.column, SQLTypeField)
        if isa(v.column.field, String)
          field_name = v.column.field
        end
      end

      if field_name != "" && haskey(instruc.object.model.fields, field_name)
        formatter = instruc.object.model.fields[field_name].formatter
        p1 = add_parameter!(instruc, formatter(v.values[1]))
        p2 = add_parameter!(instruc, formatter(v.values[2]))
        return string(column_sql, " ", v.operator, " ", p1, " AND ", p2)
      else
        p1 = add_parameter!(instruc, v.values[1])
        p2 = add_parameter!(instruc, v.values[2])
        return string(column_sql, " ", v.operator, " ", p1, " AND ", p2)
      end
    elseif haskey(instruc.object.model.fields, v.column.field)
      placeholders = nothing
      try
        # Determine if this is a LIKE-based operator and which wildcard pattern to use
        is_like_op = v.operator in ["contains", "icontains", "iunaccent_contains", "startswith", "endswith",
                                    "ncontains", "nicontains", "niunaccent_contains", "nstartswith", "nendswith"]
        placeholders = add_parameter!(instruc,
          _format_filter_value(instruc.object.model.fields[v.column.field].formatter, v.values, v.operator),
          contains=is_like_op, operator=v.operator)
      catch e
        @pormg_debug false
        # #411: this used to string-match `"The date"` && `"is invalid"`. That fired for exactly one
        # case — `format_date_sql(::AbstractString)`, whose message is literally "The date $value is
        # invalid" — and for nothing else. The `format_date_sql` CATCH-ALL says "The date must be a
        # Date, DateTime, …", and no other field type's formatter mentions dates at all, so a
        # wrong-typed value on any non-Date field escaped as a raw `InvalidValueError`, whose own
        # docstring scopes it to the insert/update coercion helpers rather than to a filter.
        #
        # Widening it to a type check makes the filter path report its own house type consistently.
        # It is a deliberate behavior change, not a no-op: `filter("n" => "abc")` on an IntegerField
        # now raises `FilterError` where it raised `InvalidValueError`. Both are `PormGError`.
        #
        # `@range`/`@nrange` still escape as `InvalidValueError` because the BETWEEN branch formats
        # its two operands OUTSIDE this `try`. Left alone deliberately: moving it is a separate change
        # to a separate branch, and doing it here would widen an already-wide diff.
        if e isa InvalidValueError
          throw(FilterError("The \e[4m\e[31m$(v.column.field)\e[0m field is the type \e[4m\e[32m$(instruc.object.model.fields[v.column.field].type)\e[0m. Please check the value: \e[4m\e[31m$(v.values)\e[0m"))
        end
        @pormg_debug false
        rethrow(e)
      end
    elseif (_vc_field = memo_field(instruc, memo_key(v.column))) !== nothing # #474
      @pormg_debug false
      is_like_op = v.operator in ["contains", "icontains", "iunaccent_contains", "startswith", "endswith",
                                  "ncontains", "nicontains", "niunaccent_contains", "nstartswith", "nendswith"]
      placeholders = add_parameter!(instruc,
        _format_filter_value(_vc_field.formatter, v.values, v.operator),
        contains=is_like_op, operator=v.operator)
    elseif isa(v.column, SQLTypeField)
      @pormg_debug false
      is_like_op = v.operator in ["contains", "icontains", "iunaccent_contains", "startswith", "endswith",
                                  "ncontains", "nicontains", "niunaccent_contains", "nstartswith", "nendswith"]
      placeholders = add_parameter!(instruc, v.values, contains=is_like_op, operator=v.operator)
    else
      @pormg_debug false
      throw(UnknownFieldError("Field \"$(v.column.field)\" not found in model $(instruc.object.model.name)"))
    end
  end

  if v.operator in ["=", ">", "<", ">=", "<=", "<>", "!="]
    return string(column, " ", v.operator, " ", placeholders)
  elseif v.operator in ["IN", "NOT IN"]
    return _render_membership(column, v.operator, placeholders, instruc)
  elseif v.operator in ["contains", "icontains", "iunaccent_contains", "iunaccent_exact", "startswith", "endswith",
                        "ncontains", "nicontains", "niunaccent_contains", "niunaccent_exact", "nstartswith", "nendswith"]
    @pormg_debug false
    return getfield(Dialect, Symbol(v.operator))(instruc.connection, column, placeholders)
  else
    throw(FilterError("Invalid filter operator: $(v.operator) is not a supported operator."))
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
