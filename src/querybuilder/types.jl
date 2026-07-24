# ExistsObject is a standalone EXISTS predicate, not a binary operator.
# It is defined here — before FilterType — because FilterType references it
# and Julia evaluates constant definitions sequentially at load time.
# ExistsObject inherits SQLType (not SQLTypeOper) to avoid accidental access to
# the .column / .values contract that SQLTypeOper implies.
@kwdef mutable struct ExistsObject <: SQLType
  query::SQLObjectHandler
end
Exists(query::SQLObjectHandler) = ExistsObject(query=query)
Base.deepcopy(x::ExistsObject) = ExistsObject(query=deepcopy(x.query))

# SubqueryObject is a scalar single-column subquery projected as a SELECT-list column (#92).
# Like ExistsObject it inherits SQLType directly. It is rendered via query() and correlated with the
# enclosing query through OuterRef. It is defined before FieldPart (below), which is widened to admit
# it so an SQLField.field can carry it until get_select_query resolves it to SQL text.
@kwdef mutable struct SubqueryObject <: SQLType
  query::SQLObjectHandler
end
Subquery(query::SQLObjectHandler) = SubqueryObject(query=query)
Base.deepcopy(x::SubqueryObject) = SubqueryObject(query=deepcopy(x.query))
# Defensive backstop: a SubqueryObject is always resolved to a string by get_select_query before any
# string()/show consumer sees it (audited). If one ever leaked, this keeps it legible rather than dumping
# the whole struct into a SQL string.
Base.show(io::IO, ::SubqueryObject) = print(io, "Subquery(…)")

#
# Type Aliases for Heavy Unions
#
"""Filter components: Operator objects, Q (AND), Qor (OR), F expressions, and EXISTS predicates."""
const FilterType = Union{SQLTypeQ,SQLTypeQor,SQLTypeOper,SQLTypeF,ExistsObject}

"""Field references in SQL: text, functions, string names, or projected subqueries (Subquery/Exists, #92)."""
const FieldPart = Union{SQLTypeText,SQLTypeFunction,String,SQLTypeF,SubqueryObject,ExistsObject}

"""Column references: fields, functions, strings, or vectors of operations."""
const ColumnPart = Union{SQLTypeField,SQLTypeFunction,String,SQLTypeF,Vector{Union{String,SQLTypeF}}}

"""Window PARTITION BY expressions."""
const WindowPartitionPart = Union{String,SQLTypeField,SQLTypeFunction,SQLTypeF}

"""Window ORDER BY expressions."""
const WindowOrderPart = Union{String,SQLTypeOrder}

"""Window function argument expressions."""
const WindowColumnPart = Union{Nothing,String,SQLTypeField,SQLTypeText,SQLTypeFunction,SQLTypeF}

"""Optional strings (often used for aliases or configs)."""
const OptionalString = Union{String,Nothing}

"""Database connections."""
const ConnType = Union{PormGSQLite,PormGPostgres,Nothing}

"""CTE configuration dictionary."""
const CTEDict = Dict{String,Union{SQLObjectHandler,PormGModel,Pair,String,Nothing}}

"""Join metadata dictionary."""
const JoinDict = Dict{String,Union{String,Vector{FilterType}}}

#
# SQLTypeArrays Objects
#
@kwdef mutable struct SQLArrays <: SQLTypeArrays # TODO -- check if I need to use this
  count::Integer = 1
  array_string::Array{String,2} = Array{String,2}(undef, 20, 3)
  array_int::Array{Integer,2} = Array{Integer,2}(undef, 20, 3)
end

#
# SQLInstruction Objects (instructions to build a query)
#
@kwdef mutable struct InstructionObject <: SQLInstruction
  text::String # text to be used in the query
  table_alias::SQLTableAlias
  alias::String
  object::SQLObject
  select::Vector{SQLTypeField} = Array{SQLTypeField,1}(undef, 60)
  join::Vector{String} = []  # values to be used in join query
  _where::Vector{String} = []  # values to be used in where query
  aggregate::Bool = false
  group::Vector{String} = []  # values to be used in group query
  having::Vector{String} = [] # values to be used in having query
  order::Vector{String} = [] # values to be used in order query  
  # df_join::Union{Missing, DataFrames.DataFrame} = missing # dataframe to be used in join query
  row_join::Vector{JoinDict} = [] # array of dictionary to be used in join query
  row_path::Vector{String} = [] # array of path to map the row_join (model__model__ etc)
  # array_join::Array{String, 2} = Array{String, 2}(undef, 30, 8) # array to be used in join query (meaby the best way to do this)
  tab_field_cache::Dict{String,PormGField} = sizehint!(Dict{String,PormGField}(), 12) # cache to be used in join query
  # #27: records each resolved JSON-lookup path (e.g. "payload__driver") → (JSON base field,
  # validated key segments). Set when the JSON-path gate renders an extraction; read by the
  # filter-render branch to bind the RHS as plain text (not through the JSON formatter) and to
  # reject containment operators on a nested key path.
  json_lookup_cache::Dict{String,Tuple{PormGField,Vector{String}}} = Dict{String,Tuple{PormGField,Vector{String}}}()
  connection::ConnType = nothing
  # array_defs::SQLTypeArrays = SQLArrays()
  cache::Dict{String,SQLTypeField} = sizehint!(Dict{String,SQLTypeField}(), 12)
  django::OptionalString = nothing
  parameters::Union{Nothing,AbstractPormGParam} = nothing # parameters to be used in the query
  outer::Union{Nothing,SQLInstruction} = nothing # parent query instruction for correlated subqueries
  # #74 fan-out guard: record each at-risk aggregate's source alias so build() can refuse
  # silently-inflated COUNT/SUM/AVG. To-many joins are flagged in-place on their row_join dict (a
  # "to_many" key) and the many-side alias set is derived from the *deduped* row_join at check time
  # (deriving avoids over-counting when _cache_join builds the same join twice). See _check_aggregate_fanout.
  agg_sources::Vector{NamedTuple{(:alias, :func, :label, :distinct),Tuple{String,String,String,Bool}}} =
    NamedTuple{(:alias, :func, :label, :distinct),Tuple{String,String,String,Bool}}[]
end

# Store information to decide the name from table alias in subquery
mutable struct SQLTbAlias <: SQLTableAlias
  count::Integer
end
SQLTbAlias() = SQLTbAlias(0)
function get_alias(s::SQLTableAlias)
  if s.count == 0
    s.count += 1
    return "Tb"
  end
  s.count += 1
  return "R$(s.count -1)"
end

# Return a value to sql query, like value from DjangoSQLText
mutable struct SQLText <: SQLTypeText
  field::Any
  _as::OptionalString
  custom_as::OptionalString
end
SQLText(field::Any; _as::OptionalString=nothing) = SQLText(field, _as, nothing)
SQLText(field::Any, _as::OptionalString) = SQLText(field, _as, nothing)
Base.deepcopy(x::SQLTypeText) = SQLText(x.field, x._as, x.custom_as)


# Return a field to sql query
mutable struct SQLField <: SQLTypeField
  field::FieldPart
  _as::OptionalString
  custom_as::OptionalString
end
SQLField(field::FieldPart; _as::OptionalString=nothing) = SQLField(field, _as, nothing)
SQLField(field::FieldPart, _as::OptionalString) = SQLField(field, _as, nothing)
Base.deepcopy(x::SQLTypeField) = SQLField(x.field, x._as, x.custom_as)

# `orientation` is interpolated into rendered SQL, so it is whitelisted here (#77) and stored
# uppercase. Single whitelist for every orientation path — the window path
# (_normalize_window_orientation, build_helpers.jl) delegates here with its own context label.
function _normalize_order_orientation(orientation::AbstractString; context::String="ORDER BY")::String
  normalized = uppercase(strip(String(orientation)))
  normalized in ("ASC", "DESC") || throw(_argerr("$(context) orientation must be ASC or DESC, got $(repr(orientation))"))
  return normalized
end

# Return a order of field to sql query
mutable struct SQLOrder <: SQLTypeOrder
  field::Union{SQLTypeField,String}
  order::Union{Integer,Nothing}
  orientation::String
  _as::OptionalString
  # NULL placement for this term (#75): `nothing` = apply the canonical backend-aligned default
  # (ASC → NULLS LAST, DESC → NULLS FIRST); `:first`/`:last` force the placement explicitly.
  nulls::Union{Symbol,Nothing}
  # Inner constructor: every construction path (keyword, positional, deepcopy) passes the
  # orientation whitelist (#77), so an injection-shaped direction never reaches the renderer.
  SQLOrder(field, order, orientation, _as, nulls) = new(field, order, _normalize_order_orientation(orientation), _as, nulls)
end
SQLOrder(field::Union{SQLTypeField,String}; order::Union{Integer,Nothing}=nothing, orientation::String="ASC", _as::OptionalString=nothing, nulls::Union{Symbol,Nothing}=nothing) = SQLOrder(field, order, orientation, _as, nulls)
Base.deepcopy(x::SQLTypeOrder) = SQLOrder(x.field, x.order, x.orientation, x._as, x.nulls)

#
# SQLObject Objects (main object to build a query)
#

# #26: row-level locking clause carried on a SELECT. `nothing` on the query means no lock;
# a `ForUpdateClause` renders `FOR [NO KEY] UPDATE [NOWAIT|SKIP LOCKED]` on PostgreSQL and is a
# silent no-op on SQLite (which has no row-level locking). Immutable/set-once — the
# `select_for_update!` mutator always builds a fresh clause, so it is shared by reference on copy.
# (An `OF <table>` target is a deferred follow-up: it must name the query's generated FROM alias,
# which is not yet exposed — see the row-locking follow-up issue.)
struct ForUpdateClause
  nowait::Bool
  skip_locked::Bool
  no_key::Bool                 # PostgreSQL: FOR NO KEY UPDATE (weaker lock, allows FK-referencing inserts)
end

mutable struct SQLObjectQuery <: SQLObject
  model::PormGModel
  connect_key::OptionalString # Override for multi-tenant scenarios
  values::Vector{Union{SQLTypeText,SQLTypeField}}
  filter::Vector{FilterType} # filters to be used in the query
  insert::OrderedCollections.OrderedDict{String,Any} # values to be used to create or insert (ordered so INSERT/UPDATE column lists follow call order — #97)
  limit::Integer
  offset::Integer
  order::Vector{SQLTypeOrder}
  group::Vector{String}
  having::Vector{String}
  list_joins::Vector{String} # is ther a better way to do this?
  row_join::Vector{Dict{String,Any}}
  distinct::Bool # Add distinct field
  for_update::Union{Nothing,ForUpdateClause} # #26: row-level lock clause (nothing = no lock)
  ctes::Dict{String,CTEDict}
  custom_join::Dict{String,Any}
  parameters::Union{Nothing,AbstractPormGParam}

  SQLObjectQuery(; model=nothing, connect_key=nothing, values=[], filter=[], insert=OrderedCollections.OrderedDict{String,Any}(), limit=0, offset=0,
    order=[], group=[], having=[], list_joins=[], row_join=[], distinct=false, for_update=nothing, ctes=Dict{String,CTEDict}(), custom_join=Dict{String,Any}(), parameters=nothing) = # Add ctes and custom_join to constructor
    new(model, connect_key, values, filter, insert, limit, offset, order, group, having, list_joins, row_join, distinct, for_update, ctes, custom_join, parameters) # Add ctes and custom_join to new
end

function Base.deepcopy(obj::SQLObjectHandler)
  return ObjectHandler(object=deepcopy(obj.object))
end

# #43: CTE state must be copied deeply enough that a copy's execution can't mutate
# the original. A shallow `copy(ctes)` aliases the inner CTEDict values, so
# materializing the per-build "model" (see _build_cte_custom_model) on one copy
# clobbers the other. Rebuild each CTEDict with a fresh dict: deep-copy the sub-query
# handler (recursion covers nested CTEs), carry the scalar join config by reference
# (Pair/String are immutable), and DROP the transient "model" — it is re-derived on
# every build and holds a Model_Type → Module reference that deepcopy cannot traverse
# (the very reason the original copy was shallow).
function _copy_ctes(ctes::Dict{String,CTEDict})::Dict{String,CTEDict}
  out = Dict{String,CTEDict}()
  for (name, cte_dict) in ctes
    fresh = CTEDict()
    for (k, v) in cte_dict
      k == "model" && continue  # transient per-build artifact; re-materialized each build
      fresh[k] = v isa SQLObjectHandler ? deepcopy(v) : v
    end
    out[name] = fresh
  end
  return out
end

# #112: custom_join is the build-time sibling of the #43 CTE aliasing. A shallow
# `copy(custom_join)` shares the inner per-join Dicts, and on() mutates those in place
# ("filters" / "join_type") — so extending a join path on a copy rewrote the original's
# join definition. Rebuild a fresh inner dict per path: copy the "filters" vector into a
# new Vector (its FilterType elements are shared — on() replaces the whole vector, it
# never mutates elements in place), share the "field" PormGField by reference (it holds
# a Model_Type → Module that deepcopy cannot traverse — the very reason this copy was
# shallow), and carry scalar entries ("join_type") as-is.
function _copy_custom_join(custom_join::Dict{String,Any})::Dict{String,Any}
  out = Dict{String,Any}()
  for (path, config) in custom_join
    if config isa AbstractDict
      # AbstractDict (not just Dict{String,Any}) so a future writer storing a differently
      # typed inner dict still gets an independent copy instead of silently re-aliasing.
      fresh = Dict{String,Any}()
      for (k, v) in config
        fresh[k] = v isa Vector ? copy(v) : v
      end
      out[path] = fresh
    else
      out[path] = config  # non-dict config: nothing produces one today (cjoin/on store Dicts)
    end
  end
  return out
end

function Base.deepcopy(obj::SQLObjectQuery)
  try
    return SQLObjectQuery(
      model=obj.model,  # PormGModel doesn't need deep copy (immutable reference)
      connect_key=obj.connect_key,
      values=deepcopy(obj.values),
      filter=deepcopy(obj.filter),
      insert=deepcopy(obj.insert),
      limit=obj.limit,
      offset=obj.offset,
      order=deepcopy(obj.order),
      group=deepcopy(obj.group),
      having=deepcopy(obj.having),
      list_joins=deepcopy(obj.list_joins),
      row_join=deepcopy(obj.row_join),
      distinct=obj.distinct,
      for_update=obj.for_update,  # #26: immutable/set-once lock clause — share by reference (like distinct)
      ctes=_copy_ctes(obj.ctes),  # #43: independent CTE state (deep sub-query, drop transient "model")
      custom_join=_copy_custom_join(obj.custom_join)  # #112: fresh per-join dicts; "field" shared by ref (Module — deepcopy can't traverse)
    )
  catch e
    @pormg_debug false
    @error "Error in deepcopy for SQLObjectQuery: $e" exception = (e, catch_backtrace())
    rethrow(e)
  end
end
function Base.deepcopy(filter::Vector{FilterType})
  return [deepcopy(f) for f in filter]
end
function Base.deepcopy(oper::SQLTypeOper)
  @pormg_debug false
  return OperObject(
    operator=oper.operator,
    values=oper.values |> typeof <: SQLObjectHandler ? oper.values : deepcopy(oper.values),
    column=deepcopy(oper.column)
  )
end


#
# SQLTypeQ and SQLTypeQor Objects
#

"""
Mutable struct representing an SQL operator object for using in the filter and annotate.
That is a internal function, please do not use it.

# Fields
- `operator::String`: the operator used in the SQL query.
- `values::Union{String, Integer, Bool}`: the value(s) to be used with the operator.
- `column::Union{String, SQLTypeFunction}`: the column to be used with the operator.

"""
@kwdef mutable struct OperObject <: SQLTypeOper
  operator::String
  values::Union{String,Number,Bool,Dates.TimeType,Dates.Period,Dates.CompoundPeriod,SQLObjectHandler,SQLTypeF,SQLTypeFunction,Vector{T}} where T<:Union{Missing,String,Dates.TimeType,Dates.Period,Dates.CompoundPeriod,Number,Bool,SQLTypeF}
  column::ColumnPart # Vector{String} is needed
end
OP(column::String, value) = OperObject(operator="=", values=value, column=SQLField(column))
OP(column::SQLTypeFunction, value) = OperObject(operator="=", values=value, column=column)
OP(column::String, operator::String, value) = OperObject(operator=operator, values=value, column=SQLField(column))
OP(column::SQLTypeFunction, operator::String, value) = OperObject(operator=operator, values=value, column=column)

@kwdef mutable struct QObject <: SQLTypeQ
  filters::Vector{FilterType} # filters to be used in the query
end
function Base.deepcopy(q::QObject)
  return QObject(filters=deepcopy(q.filters))
end

@kwdef mutable struct QorObject <: SQLTypeQor
  or::Vector{FilterType} # filters to be used in the query
end
function Base.deepcopy(q::QorObject)
  return QorObject(or=deepcopy(q.or))
end

function Base.push!(q::SQLTypeQ, x...)
  for v in x
    if isa(v, Pair)
      push!(q.filters, _check_filter(v))
    elseif isa(v, FilterType)
      push!(q.filters, v)
    else
      throw(FilterError("Invalid argument: $(v); please use a pair (key => value) or a Q/Qor/OP object."))
    end
  end
  return q
end

function Base.push!(q::SQLTypeQor, x...)
  for v in x
    if isa(v, Pair)
      push!(q.or, _check_filter(v))
    elseif isa(v, FilterType)
      push!(q.or, v)
    else
      throw(FilterError("Invalid argument: $(v); please use a pair (key => value) or a Q/Qor/OP object."))
    end
  end
  return q
end


"""
    Interval(period)
    Interval(duration_string)

Explicit duration wrapper for F-expression date arithmetic (#25). Holds a Julia
`Dates.Period` / `Dates.CompoundPeriod`, or parses a portable time-duration string
(`"HH:MM:SS(.fff)"`, `"M:SS"`, or bare seconds) into a time-only `CompoundPeriod`.

`Interval(...)` is interchangeable with a bare period wherever date arithmetic is used —
`F("date") + Interval(Month(1))` is identical to `F("date") + Month(1)`. The string form is
the escape hatch for time-based intervals: `F("logged_at") + Interval("01:30:00")`.

Note: the name is shared with the `Intervals.jl` ecosystem — if you also `using Intervals`,
disambiguate as `PormG.QueryBuilder.Interval`.
"""
struct Interval
  period::Union{Dates.Period, Dates.CompoundPeriod}
end

# Parse a portable time-duration string into a time-only CompoundPeriod (Hour+Minute+Second
# [+sub-second]). Reuses the DurationField normalizer so accepted input formats stay identical,
# then rebuilds the period directly WITHOUT `canonicalize` (which would roll >=24h into days and
# >=7d into weeks — surprising for a time duration and would break the portable time-only guarantee).
function _parse_time_string_to_compoundperiod(s::AbstractString)::Dates.CompoundPeriod
  normalized = Models._normalize_duration_string(s)  # -> "±H:MM:SS(.fff)" (fields may exceed 2 digits,
                                                     # e.g. bare "120" seconds normalizes to "00:00:120")
  m = match(r"^(-?)(\d+):(\d+):(\d+)(?:\.(\d+))?$", normalized)
  m === nothing && throw(InvalidValueError("Interval: could not parse normalized duration '$(normalized)'"))
  sign = m.captures[1] == "-" ? -1 : 1
  parts = Dates.Period[Hour(sign * parse(Int, m.captures[2])),
                       Minute(sign * parse(Int, m.captures[3])),
                       Second(sign * parse(Int, m.captures[4]))]
  frac = m.captures[5]
  if frac !== nothing
    nanos = parse(Int, rpad(frac, 9, '0')[1:9])  # fractional seconds -> nanoseconds
    push!(parts, Nanosecond(sign * nanos))
  end
  return Dates.CompoundPeriod(parts)
end

Interval(s::AbstractString) = Interval(_parse_time_string_to_compoundperiod(s))

# Duration operands accepted by F-expression +/- date arithmetic (#25).
const _DurationOperand = Union{Dates.Period, Dates.CompoundPeriod, Interval}

"""
F object for direct database field references and operations (similar to Django F expressions).

Allows you to reference database fields directly in operations without pulling data into Julia.

# Examples
```julia
# Update a field with another field's value
query = MyModel |> object
query.filter("id" => 1)
query.update("field1" => F("field2"))

# Increment a field by a constant
query.update("counter" => F("counter") + 1)

# Update with arithmetic operations between fields
query.update("total" => F("price") * F("quantity"))

# Use in filters to compare fields
query.filter(F("start_date") <= F("end_date"))

# Use in annotations/values
query.values("price", "discounted_price" => F("price") * 0.9)
```
"""
@kwdef mutable struct FExpression <: SQLTypeF
  field_name::Union{String,Integer,SQLTypeF,SQLTypeFunction}
  operation::OptionalString = nothing  # +, -, *, /, etc.
  operand::Union{String,Integer,Float64,SQLTypeF,SQLTypeFunction,Dates.Period,Dates.CompoundPeriod,Interval,Nothing} = nothing
  function_name::String = "F"
  column::Union{String,SQLTypeField,Vector{String}} = ""
  aggregate::Bool = false
  _as::OptionalString = nothing
  kwargs::Dict{String,Any} = Dict{String,Any}()
end

# Constructor for F expressions
function F(field_name::String)
  return FExpression(
    field_name=field_name,
    function_name="F",
    column=field_name
  )
end
function Base.deepcopy(f::FExpression)
  try
    return FExpression(
      field_name=f.field_name,
      operation=f.operation,
      operand=deepcopy(f.operand),
      function_name=f.function_name,
      column=deepcopy(f.column),
      aggregate=f.aggregate,
      _as=f._as,
      kwargs=deepcopy(f.kwargs)
    )
  catch e
    @error "Error in deepcopy for FExpression: $e" exception = (e, catch_backtrace())
    rethrow(e)
  end
end

# Arithmetic operations for F expressions
# Aggregate propagation helper: result is aggregate if any operand is aggregate
_is_agg(f::FExpression) = f.aggregate
_is_agg(f::SQLTypeFunction) = f.aggregate
_is_agg(::Any) = false

function Base.:+(f::FExpression, operand::Union{Integer,Float64,String,FExpression,SQLTypeFunction})
  return FExpression(
    field_name=f.operation === nothing ? f.field_name : f,
    operation="+",
    operand=operand,
    function_name="F",
    column=f.operation === nothing ? (f.field_name isa String ? f.field_name : "") : "",
    aggregate=f.aggregate || _is_agg(operand)
  )
end

function Base.:-(f::FExpression, operand::Union{Integer,Float64,String,FExpression,SQLTypeFunction})
  return FExpression(
    field_name=f.operation === nothing ? f.field_name : f,
    operation="-",
    operand=operand,
    function_name="F",
    column=f.operation === nothing ? (f.field_name isa String ? f.field_name : "") : "",
    aggregate=f.aggregate || _is_agg(operand)
  )
end

function Base.:*(f::FExpression, operand::Union{Integer,Float64,String,FExpression,SQLTypeFunction})
  return FExpression(
    field_name=f.operation === nothing ? f.field_name : f,
    operation="*",
    operand=operand,
    function_name="F",
    column=f.operation === nothing ? (f.field_name isa String ? f.field_name : "") : "",
    aggregate=f.aggregate || _is_agg(operand)
  )
end

function Base.:/(f::FExpression, operand::Union{Integer,Float64,String,FExpression,SQLTypeFunction})
  return FExpression(
    field_name=f.operation === nothing ? f.field_name : f,
    operation="/",
    operand=operand,
    function_name="F",
    column=f.operation === nothing ? (f.field_name isa String ? f.field_name : "") : "",
    aggregate=f.aggregate || _is_agg(operand)
  )
end

# Date arithmetic with explicit Julia duration types (#25): F("date") + Day(30), - Hour(6),
# + (Month(1) + Day(15)), + Interval("01:30:00"), etc. Only + and - are meaningful — multiplying
# or dividing a date field by a duration is nonsense (`Day(30) * 2` is resolved by Julia's own
# Period arithmetic before it ever reaches an FExpression). A duration is never an aggregate, so
# `aggregate` propagates from `f` unchanged.
function Base.:+(f::FExpression, operand::_DurationOperand)
  return FExpression(
    field_name=f.operation === nothing ? f.field_name : f,
    operation="+",
    operand=operand,
    function_name="F",
    column=f.operation === nothing ? (f.field_name isa String ? f.field_name : "") : "",
    aggregate=f.aggregate
  )
end

function Base.:-(f::FExpression, operand::_DurationOperand)
  return FExpression(
    field_name=f.operation === nothing ? f.field_name : f,
    operation="-",
    operand=operand,
    function_name="F",
    column=f.operation === nothing ? (f.field_name isa String ? f.field_name : "") : "",
    aggregate=f.aggregate
  )
end

# Reversed + only: `Day(30) + F("date")` commutes to `F("date") + Day(30)`. Reversed - is omitted
# on purpose (`interval - date` is not valid date arithmetic).
Base.:+(operand::_DurationOperand, f::FExpression) = f + operand

# Comparison operations for F expressions
function Base.:(==)(f::FExpression, operand::Union{Integer,Float64,String,Dates.Date,Dates.DateTime,FExpression})
  if f.operation === nothing
    f.operation = "="
    f.operand = operand
    return f
  else
    return FExpression(field_name=f, operation="=", operand=operand, function_name="F", column="", aggregate=f.aggregate)
  end
end
function Base.:(!=)(f::FExpression, operand::Union{Integer,Float64,String,Dates.Date,Dates.DateTime,FExpression})
  if f.operation === nothing
    f.operation = "!="
    f.operand = operand
    return f
  else
    return FExpression(field_name=f, operation="!=", operand=operand, function_name="F", column="", aggregate=f.aggregate)
  end
end
function Base.:>(f::FExpression, operand::Union{Integer,Float64,String,Dates.Date,Dates.DateTime,FExpression})
  if f.operation === nothing
    f.operation = ">"
    f.operand = operand
    return f
  else
    return FExpression(field_name=f, operation=">", operand=operand, function_name="F", column="", aggregate=f.aggregate)
  end
end

function Base.:<(f::FExpression, operand::Union{Integer,Float64,String,Dates.Date,Dates.DateTime,FExpression})
  if f.operation === nothing
    f.operation = "<"
    f.operand = operand
    return f
  else
    return FExpression(field_name=f, operation="<", operand=operand, function_name="F", column="", aggregate=f.aggregate)
  end
end

function Base.:>=(f::FExpression, operand::Union{Integer,Float64,String,Dates.Date,Dates.DateTime,FExpression})
  if f.operation === nothing
    f.operation = ">="
    f.operand = operand
    return f
  else
    return FExpression(field_name=f, operation=">=", operand=operand, function_name="F", column="", aggregate=f.aggregate)
  end
end

function Base.:<=(f::FExpression, operand::Union{Integer,Float64,String,Dates.Date,Dates.DateTime,FExpression})
  if f.operation === nothing
    f.operation = "<="
    f.operand = operand
    return f
  else
    return FExpression(field_name=f, operation="<=", operand=operand, function_name="F", column="", aggregate=f.aggregate)
  end
end
# function Base.:>(f::FExpression, operand::Union{Integer, Float64, String, Dates.Date, Dates.DateTime, FExpression})
#   return OperObject(operator = ">", values = operand, column = f)
# end

# function Base.:<(f::FExpression, operand::Union{Integer, Float64, String, Dates.Date, Dates.DateTime, FExpression})
#   return OperObject(operator = "<", values = operand, column = f)
# end

# function Base.:>=(f::FExpression, operand::Union{Integer, Float64, String, Dates.Date, Dates.DateTime, FExpression})
#   return OperObject(operator = ">=", values = operand, column = f)
# end

# function Base.:<=(f::FExpression, operand::Union{Integer, Float64, String, Dates.Date, Dates.DateTime, FExpression})
#   return OperObject(operator = "<=", values = operand, column = f)
# end

# Allow arithmetic operations with F expressions on the right side
function Base.:+(operand::Union{Integer,Float64}, f::FExpression)
  return FExpression(
    field_name=f.field_name,
    operation="+",
    operand=operand,
    function_name="F",
    column=f.field_name,
    aggregate=f.aggregate
  )
end

function Base.:*(operand::Union{Integer,Float64}, f::FExpression)
  return FExpression(
    field_name=f.field_name,
    operation="*",
    operand=operand,
    function_name="F",
    column=f.field_name,
    aggregate=f.aggregate
  )
end

@kwdef mutable struct OuterRefObject <: SQLTypeF
  field_name::String
end
function OuterRef(field_name::AbstractString)
  normalized = String(field_name)
  isempty(normalized) && throw(QueryBuildError("OuterRef requires a non-empty field name"))
  return OuterRefObject(field_name=normalized)
end
Base.deepcopy(x::OuterRefObject) = OuterRefObject(field_name=x.field_name)

#
# SQLTypeFunction Objects (functions from sql)
#

@kwdef mutable struct FObject <: SQLTypeFunction
  function_name::String
  column::Union{String,SQLTypeField,SQLTypeText,N,Vector{N},Vector{T},SQLTypeOper,SQLTypeQ,SQLTypeQor,SQLTypeF} where {N<:SQLTypeFunction,T}
  aggregate::Bool = false
  formatter::Union{Nothing,Function} = nothing # function to format the value
  _as::OptionalString = nothing
  kwargs::Dict{String,Any} = Dict{String,Any}()
end
function Base.deepcopy(f::FObject)
  return FObject(
    function_name=f.function_name,
    column=deepcopy(f.column),
    aggregate=f.aggregate,
    formatter=f.formatter,
    _as=f._as,
    kwargs=deepcopy(f.kwargs)
  )
end

@kwdef mutable struct WindowSpec <: SQLType
  partition_by::Vector{WindowPartitionPart} = WindowPartitionPart[]
  order_by::Vector{WindowOrderPart} = WindowOrderPart[]
  frame::OptionalString = nothing
end
function Base.deepcopy(w::WindowSpec)
  return WindowSpec(
    partition_by=deepcopy(w.partition_by),
    order_by=deepcopy(w.order_by),
    frame=w.frame
  )
end

@kwdef mutable struct WindowFunction <: SQLTypeFunction
  function_name::String
  column::WindowColumnPart = nothing
  over::WindowSpec
  aggregate::Bool = false
  formatter::Union{Nothing,Function} = nothing
  _as::OptionalString = nothing
  kwargs::Dict{String,Any} = Dict{String,Any}()
end
function Base.deepcopy(f::WindowFunction)
  return WindowFunction(
    function_name=f.function_name,
    column=deepcopy(f.column),
    over=deepcopy(f.over),
    aggregate=f.aggregate,
    formatter=f.formatter,
    _as=f._as,
    kwargs=deepcopy(f.kwargs)
  )
end

_is_agg(::WindowFunction) = false
_is_window_expr(::WindowFunction) = true
_is_window_expr(f::FExpression) = _is_window_expr(f.field_name) || _is_window_expr(f.operand)
_is_window_expr(f::FObject) = _is_window_expr(f.column)
_is_window_expr(values::Vector) = any(_is_window_expr, values)
_is_window_expr(::Any) = false

function Base.:+(f::WindowFunction, operand::Union{Integer,Float64,String,FExpression,SQLTypeFunction})
  return FExpression(field_name=f, operation="+", operand=operand, function_name="F", column="", aggregate=_is_agg(operand))
end
function Base.:-(f::WindowFunction, operand::Union{Integer,Float64,String,FExpression,SQLTypeFunction})
  return FExpression(field_name=f, operation="-", operand=operand, function_name="F", column="", aggregate=_is_agg(operand))
end
function Base.:*(f::WindowFunction, operand::Union{Integer,Float64,String,FExpression,SQLTypeFunction})
  return FExpression(field_name=f, operation="*", operand=operand, function_name="F", column="", aggregate=_is_agg(operand))
end
function Base.:/(f::WindowFunction, operand::Union{Integer,Float64,String,FExpression,SQLTypeFunction})
  return FExpression(field_name=f, operation="/", operand=operand, function_name="F", column="", aggregate=_is_agg(operand))
end

function Base.:+(operand::Union{Integer,Float64}, f::WindowFunction)
  return FExpression(field_name=f, operation="+", operand=operand, function_name="F", column="", aggregate=false)
end

function Base.:*(operand::Union{Integer,Float64}, f::WindowFunction)
  return FExpression(field_name=f, operation="*", operand=operand, function_name="F", column="", aggregate=false)
end

# Arithmetic operations for FObject (aggregate functions like Sum, Count, Avg)
# Enable expressions like Sum("points") / Count("resultid")
function Base.:+(f::FObject, operand::Union{Integer,Float64,String,FExpression,FObject})
  return FExpression(field_name=f, operation="+", operand=operand, function_name="F", column="", aggregate=f.aggregate || _is_agg(operand))
end
function Base.:-(f::FObject, operand::Union{Integer,Float64,String,FExpression,FObject})
  return FExpression(field_name=f, operation="-", operand=operand, function_name="F", column="", aggregate=f.aggregate || _is_agg(operand))
end
function Base.:*(f::FObject, operand::Union{Integer,Float64,String,FExpression,FObject})
  return FExpression(field_name=f, operation="*", operand=operand, function_name="F", column="", aggregate=f.aggregate || _is_agg(operand))
end
function Base.:/(f::FObject, operand::Union{Integer,Float64,String,FExpression,FObject})
  return FExpression(field_name=f, operation="/", operand=operand, function_name="F", column="", aggregate=f.aggregate || _is_agg(operand))
end


# Commutative: scalar op FObject
function Base.:+(operand::Union{Integer,Float64}, f::FObject)
  return FExpression(field_name=f, operation="+", operand=operand, function_name="F", column="", aggregate=f.aggregate)
end

function Base.:*(operand::Union{Integer,Float64}, f::FObject)
  return FExpression(field_name=f, operation="*", operand=operand, function_name="F", column="", aggregate=f.aggregate)
end


# ---
# Bitwise expression types and operands (narrow overloads to prevent spooky dispatch)
# ---
const BitwiseExpression = Union{FExpression,WindowFunction,FObject}
const BitwiseOperand = Union{Integer,FExpression,WindowFunction,FObject}

_bitwise_is_agg(f::BitwiseExpression) = f.aggregate
_bitwise_is_agg(::Integer) = false

function _build_bitwise_expr(left, op::String, right)
  return FExpression(
    field_name=left isa FExpression && left.operation === nothing ? left.field_name : left,
    operation=op,
    operand=right,
    function_name="F",
    column=left isa FExpression && left.operation === nothing ? (left.field_name isa String ? left.field_name : "") : "",
    aggregate=_bitwise_is_agg(left) || _bitwise_is_agg(right)
  )
end

function _build_bitwise_unary(expr, op::String)
  return FExpression(
    field_name=expr,
    operation=op,
    operand=nothing,
    function_name="F",
    column="",
    aggregate=_bitwise_is_agg(expr)
  )
end

# Overload Base operators
function Base.:&(a::BitwiseExpression, b::BitwiseOperand)
  return _build_bitwise_expr(a, "&", b)
end
function Base.:&(a::Integer, b::BitwiseExpression)
  return _build_bitwise_expr(b, "&", a)
end

function Base.:|(a::BitwiseExpression, b::BitwiseOperand)
  return _build_bitwise_expr(a, "|", b)
end
function Base.:|(a::Integer, b::BitwiseExpression)
  return _build_bitwise_expr(b, "|", a)
end

function Base.:~(f::BitwiseExpression)
  return _build_bitwise_unary(f, "~")
end

function Base.:<<(a::BitwiseExpression, b::BitwiseOperand)
  return _build_bitwise_expr(a, "<<", b)
end
function Base.:<<(a::Integer, b::BitwiseExpression)
  return FExpression(
    field_name=a,
    operation="<<",
    operand=b,
    function_name="F",
    column="",
    aggregate=_bitwise_is_agg(b)
  )
end

function Base.:>>(a::BitwiseExpression, b::BitwiseOperand)
  return _build_bitwise_expr(a, ">>", b)
end
function Base.:>>(a::Integer, b::BitwiseExpression)
  return FExpression(
    field_name=a,
    operation=">>",
    operand=b,
    function_name="F",
    column="",
    aggregate=_bitwise_is_agg(b)
  )
end

function Base.xor(a::BitwiseExpression, b::BitwiseOperand)
  return _build_bitwise_expr(a, "xor", b)
end
function Base.xor(a::Integer, b::BitwiseExpression)
  return _build_bitwise_expr(b, "xor", a)
end


# ---
# Define a struct ObjectHandler that wraps a SQLObjectQuery
# ---
mutable struct ObjectHandler <: SQLObjectHandler
  object::SQLObject
end
ObjectHandler(; object::SQLObject) = ObjectHandler(object)

"""
A model-aware row returned by `list()`, `first()`, and `get()`.

Wraps a `Dict{Symbol, Any}` and remembers which model produced it, enabling
dot-access to fields and many-to-many relationship accessors.
"""
mutable struct PormGRow
  _data::Dict{Symbol,Any}
  _model::PormGModel
  _dirty::Set{Symbol}
end
PormGRow(data::Dict{Symbol,<:Any}, model::PormGModel) = PormGRow(Dict{Symbol,Any}(data), model, Set{Symbol}())

"""Normalize row-facing symbols to the declared-case storage keys used internally
(strips a leading underscore per `format_fild_name`; case is preserved, #57)."""
function _normalize_row_symbol(sym::Symbol)::Symbol
  parts = split(String(sym), "__")
  any(isempty, parts) && throw(UnknownFieldError("Invalid projected row field '$sym'. Empty '__' path segment."))
  return Symbol(join(Models.format_fild_name.(String.(parts)), "__"))
end

Base.getindex(row::PormGRow, key::Symbol) = getfield(row, :_data)[_normalize_row_symbol(key)]
Base.getindex(row::PormGRow, key::String) = getfield(row, :_data)[_normalize_row_symbol(Symbol(key))]
Base.haskey(row::PormGRow, key::Symbol) = haskey(getfield(row, :_data), _normalize_row_symbol(key))
Base.haskey(row::PormGRow, key::String) = haskey(getfield(row, :_data), _normalize_row_symbol(Symbol(key)))
Base.get(row::PormGRow, key::Symbol, default) = get(getfield(row, :_data), _normalize_row_symbol(key), default)
Base.get(row::PormGRow, key::String, default) = get(getfield(row, :_data), _normalize_row_symbol(Symbol(key)), default)
Base.keys(row::PormGRow) = keys(getfield(row, :_data))
Base.values(row::PormGRow) = values(getfield(row, :_data))
Base.pairs(row::PormGRow) = pairs(getfield(row, :_data))
Base.iterate(row::PormGRow, args...) = iterate(getfield(row, :_data), args...)

function Base.getproperty(row::PormGRow, sym::Symbol)
  sym === :_data && return getfield(row, :_data)
  sym === :_model && return getfield(row, :_model)
  sym === :_dirty && return getfield(row, :_dirty)
  sym === :save && return (; show_query::Symbol=:execute) -> save(row; show_query=show_query)

  data = getfield(row, :_data)
  model = getfield(row, :_model)
  normalized = _normalize_row_symbol(sym)

  haskey(data, normalized) && return data[normalized]

  # Virtual `.pk` alias → the model's primary-key value (a real column named `pk`, if one
  # existed, would already have been returned by the `haskey` lookup above).
  normalized === :pk && return pk(row)

  if Models.has_many_to_many_accessor(model, String(normalized))
    descriptor = ManyToManyDescriptor(model, String(normalized), Models.get_many_to_many_relation(model, String(normalized)))
    return descriptor(data)
  end

  if haskey(model.fields, String(normalized)) && model.fields[String(normalized)] isa Models.sForeignKey
    throw(LazyTraversalError(
      "$(model.name).$(normalized) is a ForeignKey that this row didn't project; " *
      "PormG does not support lazy FK access (`row.$(normalized)`). " *
      "Project it up front in `values(...)`: add `\"$(normalized)\"` for the raw key value, " *
      "or `\"$(normalized)__<field>\"` for a column from the related table — " *
      "then read it as `row[:$(normalized)]` or `row[:$(normalized)__<field>]`."
    ))
  end

  throw(UnknownFieldError("$(model.name) row has no field or accessor '$(sym)'"))
end

function Base.setproperty!(row::PormGRow, sym::Symbol, value)
  sym in (:_data, :_model, :_dirty) && return setfield!(row, sym, value)

  normalized = _normalize_row_symbol(sym)
  model = getfield(row, :_model)
  normalized_string = String(normalized)

  if occursin("__", normalized_string)
    fk_name = first(split(normalized_string, "__", limit=2)) |> String
    if !(haskey(model.fields, fk_name) && model.fields[fk_name] isa Models.sForeignKey)
      throw(QueryBuildError("Cannot assign to '$(sym)': '$(fk_name)' is not a ForeignKey field on $(model.name)."))
    end
  else
    if !haskey(model.fields, normalized_string)
      throw(UnknownFieldError("$(model.name) row has no writable field '$(sym)'."))
    end
    if model.fields[normalized_string].primary_key
      throw(QueryBuildError("Cannot mutate primary key field '$(normalized)' on a PormGRow."))
    end
  end

  getfield(row, :_data)[normalized] = value
  push!(getfield(row, :_dirty), normalized)
  return value
end

"""
    pk(row::PormGRow)
    pk(row::PormGRow, default)

Primary-key value of `row`, read through its model's declared pk column — so it works for any
pk name, not only `id`. The 1-arg form throws if the model has no single-column primary key, or
the pk column is absent from the row. The 2-arg form returns `default` in those cases instead of
throwing (for best-effort callers). A composite (multi-column) primary key has no scalar `pk`;
read the individual key columns instead.
"""
function pk(row::PormGRow)
  model = getfield(row, :_model)
  field = Models.get_model_pk_field(model)
  field === nothing && throw(QueryBuildError("$(model.name) row has no single-column primary key"))
  data = getfield(row, :_data)
  haskey(data, field) || throw(QueryBuildError("$(model.name) row is missing its primary-key column '$(field)'"))
  return data[field]
end

function pk(row::PormGRow, default)
  model = getfield(row, :_model)
  field = try
    Models.get_model_pk_field(model)     # throws on a composite (multi-column) pk
  catch
    return default
  end
  field === nothing && return default
  data = getfield(row, :_data)
  return haskey(data, field) ? data[field] : default
end

# PormGRow overrides getproperty to expose its stored columns (plus the `save` closure) via
# dot-access. Without these overrides Julia's defaults only saw the struct's real fields
# (_data/_model/_dirty), so hasproperty(row, :id) was false even though row.id works. Report the
# stored columns so introspection, REPL tab-completion, and hasproperty stay honest and
# consistent with getproperty. (`:pk` is a synthesized alias, not listed; the real pk column is.)
function Base.propertynames(row::PormGRow, private::Bool = false)
  cols = collect(keys(getfield(row, :_data)))
  push!(cols, :save)
  private && append!(cols, (:_data, :_model, :_dirty))
  return Tuple(cols)
end

# haskey(row, ::Symbol) applies the same leading-underscore normalization getproperty does, so
# this matches getproperty's success set for stored columns exactly.
Base.hasproperty(row::PormGRow, sym::Symbol) =
  sym in (:save, :_data, :_model, :_dirty) || haskey(row, sym)

Tables.isrowtable(::Type{Vector{PormGRow}}) = true
Tables.columnnames(row::PormGRow) = collect(keys(getfield(row, :_data)))
Tables.getcolumn(row::PormGRow, nm::Symbol) = getfield(row, :_data)[_normalize_row_symbol(nm)]


"""
Wraps a PormGModel into an ObjectHandler on which you can call:
```
- .filter(...) to add WHERE clauses
- .values(...) to choose/annotate columns
- .order_by(...) to sort
- .distinct() to add DISTINCT clause
- .create(...) for single-row DML
- .update(...) for single-row DML
- .limit(...), .offset(...), .page(...) for pagination
- .count(), .exists() for quick checks without fetching data
- .on(...) to specify joins with other models
- .cjoin(...) for complex joins with custom conditions
- .with(...) to define CTEs
- plus bulk_insert, bulk_update, do_count, do_exists, list, etc.
```

# Arguments
- `model::PormGModel`: The model to be wrapped and handled.

# Example
```julia
using PormG, DataFrames

# assume models loaded as `M`
query = M.User.objects

# 1) Filtering & selecting
query.filter("is_active" => true)
query.values("id", "username", "email")
df = query |> DataFrame

# 2) Counting
active_users = query.count()

# 3) Inserting a single row
new = M.Status.objects.create("statusid" => 42, "status" => "Foo")
# returns a PormGRow of the inserted row (dot-access + .save())

# 4) Updating a single row
M.Status.objects.filter("statusid" => 42).update("status" => "Bar")

# 5) Ordering & aggregation
query = M.Result.objects.filter("raceid__year" => 2020)
query.values(
  "driverid__forename", 
  "constructorid__name", 
  "laps" => Count("laps")
).order_by("-laps")
df2 = query |> DataFrame

# 6) Existence check
exists = M.User.objects.filter("id" => 1).exists()

```
"""
function object(model::PormGModel)
  return ObjectHandler(object=SQLObjectQuery(model=model))
end


# delection

mutable struct DeletionCollector{T}
  model::PormGModel  # The main model being deleted from
  settings::PormGSettings  # Connection settings
  connection::Union{PormGPostgres,PormGSQLite}  # Database connection
  objects::Dict{PormGModel,Vector{Dict{Symbol,T}}}  # Models and their objects to delete
  dependencies::Dict{PormGModel,Set{PormGModel}}  # Model dependencies
  field_updates::Dict{Tuple{String,Any},Dict{PormGModel,Dict{Symbol,T}}}  # Field updates for SET_NULL etc.
  fast_deletes::Dict{PormGModel,Vector{Dict{Symbol,T}}}  # Objects that can be deleted directly
  sorted_models::Vector{PormGModel}  # Models in deletion order
  show_query::Symbol  # Controls whether to execute or inspect; skips do_exists during inspection

  DeletionCollector(model, settings, show_query=:execute) = new{Union{String,SQLObjectHandler}}(
    model,
    settings,
    settings.connections,
    Dict{PormGModel,Vector{Dict{Symbol,Union{String,SQLObjectHandler}}}}(),
    Dict{PormGModel,Set{PormGModel}}(),
    Dict{Tuple{String,Any},Dict{PormGModel,Dict{Symbol,String}}}(),
    Dict{PormGModel,Dict{Symbol,String}}(),
    Vector{PormGModel}(),
    show_query
  )
end
