
"""
    Q(x...)

Create a `QObject` with the given filters.

# Arguments
- `x...`: key-value pairs, `Qor(x...)`, or `Q(x...)` objects.

# Example
```julia
a = object("tb_user")
a.filter(Q("name" => "John", Qor("age" => 18, "age" => 19)))
```
"""
function Q(x...)
  colect = [isa(v, Pair) ? _check_filter(v) : isa(v, FilterType) ? v : throw(FilterError("Invalid argument: $(v); please use a pair (key => value).")) for v in x]
  return QObject(filters = colect)
end


"""
    Qor(x...)

Create a `QorObject` from the given arguments. The `QorObject` represents a disjunction of `SQLTypeQ` or `SQLTypeQor` objects.

# Arguments
- `x...`: A variable number of arguments. Each argument can be either a `SQLTypeQ` or `SQLTypeQor` object, or a `Pair` object.

# Example
```julia
a = object("tb_user")
a.filter(Qor("name" => "John", Q("age__gte" => 18, "age__lte" => 19)))
```
"""
function Qor(x...)
  colect = [isa(v, Pair) ? _check_filter(v) : isa(v, FilterType) ? v : throw(FilterError("Invalid argument: $(v); please use a pair (key => value).")) for v in x]
  return QorObject(or = colect)
end

#
# SQLTypeFunction Objects (functions from sql)
#


"""
    Sum(column; distinct=false)

Computes the sum of all values in the column.
"""
function Sum(x; distinct::Bool = false)
  return FObject(function_name = "SUM", column = x, aggregate = true, kwargs = Dict{String, Any}("distinct" => distinct))
end  
function Avg(x; distinct::Bool = false)
  return FObject(function_name = "AVG", column = x, aggregate = true, kwargs = Dict{String, Any}("distinct" => distinct))
end
"""
  Count(x; distinct::Bool = false)

Creates an aggregate COUNT function object for use in query building.

# Arguments
- `x`: The column or expression to count.
- `distinct::Bool = false`: If `true`, counts only distinct values of `x`.

# Examples
```julia
# Count just when other_model_id is distinct  
query = MyModels.model_test |> object;
query.filter("id__@gte" => 1)
query.values("id", "count" => Count("other_model_id", distinct=true))
df = query |> DataFrame
```
"""
function Count(x; distinct::Bool = false)
  return FObject(function_name = "COUNT", column = x, aggregate = true, kwargs = Dict{String, Any}("distinct" => distinct))
end
function Max(x)
  return FObject(function_name = "MAX", column = x, aggregate = true)
end
function Min(x)
  return FObject(function_name = "MIN", column = x, aggregate = true)
end

function _window_part_vector(value, part_name::String)::Vector{WindowPartitionPart}
  value === nothing && return WindowPartitionPart[]
  values = value isa Tuple ? collect(value) : value isa AbstractVector ? collect(value) : [value]
  parts = WindowPartitionPart[]
  for item in values
    item isa Symbol && (item = String(item))
    item isa WindowPartitionPart || throw(QueryBuildError("WindowOver $part_name entries must be strings, SQL fields, SQL functions, or F expressions. Got $(typeof(item))."))
    push!(parts, item)
  end
  return parts
end

function _window_order_vector(value)::Vector{WindowOrderPart}
  value === nothing && return WindowOrderPart[]
  values = value isa Tuple ? collect(value) : value isa AbstractVector ? collect(value) : [value]
  parts = WindowOrderPart[]
  for item in values
    item isa Symbol && (item = String(item))
    item isa WindowOrderPart || throw(QueryBuildError("WindowOver order_by entries must be strings or SQLOrder objects. Got $(typeof(item))."))
    push!(parts, item)
  end
  return parts
end

function WindowOver(partition_by, order_by=WindowOrderPart[]; frame::OptionalString=nothing)
  return WindowSpec(
    partition_by=_window_part_vector(partition_by, "partition_by"),
    order_by=_window_order_vector(order_by),
    frame=frame
  )
end
function WindowOver(; partition_by=WindowPartitionPart[], order_by=WindowOrderPart[], frame::OptionalString=nothing)
  return WindowOver(partition_by, order_by; frame=frame)
end

Rank(; over::WindowSpec=WindowOver()) = WindowFunction(function_name="RANK", column=nothing, over=over)
Rank(over::WindowSpec) = Rank(over=over)
DenseRank(; over::WindowSpec=WindowOver()) = WindowFunction(function_name="DENSE_RANK", column=nothing, over=over)
DenseRank(over::WindowSpec) = DenseRank(over=over)
RowNumber(; over::WindowSpec=WindowOver()) = WindowFunction(function_name="ROW_NUMBER", column=nothing, over=over)
RowNumber(over::WindowSpec) = RowNumber(over=over)

function Lag(x::WindowColumnPart; offset::Integer=1, default=nothing, over::WindowSpec=WindowOver())
  offset < 0 && throw(QueryBuildError("Lag offset must be a non-negative integer"))
  kwargs = Dict{String,Any}("offset" => offset)
  default !== nothing && (kwargs["default"] = default)
  return WindowFunction(function_name="LAG", column=x, over=over, kwargs=kwargs)
end

function Lead(x::WindowColumnPart; offset::Integer=1, default=nothing, over::WindowSpec=WindowOver())
  offset < 0 && throw(QueryBuildError("Lead offset must be a non-negative integer"))
  kwargs = Dict{String,Any}("offset" => offset)
  default !== nothing && (kwargs["default"] = default)
  return WindowFunction(function_name="LEAD", column=x, over=over, kwargs=kwargs)
end

FirstValue(x::WindowColumnPart; over::WindowSpec=WindowOver()) = WindowFunction(function_name="FIRST_VALUE", column=x, over=over)
LastValue(x::WindowColumnPart; over::WindowSpec=WindowOver()) = WindowFunction(function_name="LAST_VALUE", column=x, over=over)
function NthValue(x::WindowColumnPart, n::Integer; over::WindowSpec=WindowOver())
  n <= 0 && throw(QueryBuildError("NthValue n must be a positive integer"))
  return WindowFunction(function_name="NTH_VALUE", column=x, over=over, kwargs=Dict{String,Any}("n" => n))
end

"""
    Value(x)

Wraps a literal value (String, Number, or Nothing) for use in SQL queries.
"""
function Value(x::Any)
  return SQLText(x)
end

"""
    Cast(expression, type)

Casts a column or expression to a specific SQL type.
"""
function Cast(x::Union{String, SQLTypeField, SQLTypeText, SQLTypeFunction, SQLTypeF}, type::String)
  return FObject(function_name = "CAST", column = x, kwargs = Dict{String, Any}("type" => type))
end
function Cast(x::Union{String, SQLTypeField, SQLTypeText, SQLTypeFunction, SQLTypeF}, type::PormGField)
  return Cast(x, type.type)
end

"""
    Concat(expressions; output_field=nothing)

Concatenates multiple strings or columns.
"""
function Concat(x::Vector; output_field::Union{N, String, Nothing} where N <: PormGField = nothing, _as::String="")
  if isa(output_field, PormGField)
    output_field = output_field.type
  end
  return FObject(function_name = "CONCAT", column = x, kwargs = Dict{String, Any}("output_field" => output_field, "as" => _as))
end
# Variadic convenience: Concat("forename", Value(" "), "surname") → same as vector form
Concat(args...; kwargs...) = Concat(collect(args); kwargs...)

"""
    Extract(column, part)

Extracts a component (YEAR, MONTH, DAY, etc.) from a date/time column.
"""
function Extract(x::Union{String, SQLTypeField, SQLTypeFunction, SQLTypeF, Vector{String}}, part::String; formatter::Union{Nothing, Function, PormGField} = nothing)
  isa(formatter, PormGField) && (formatter = formatter.formatter)
  return FObject(function_name = "EXTRACT", column = x, formatter = formatter, kwargs = Dict{String, Any}("part" => part))
end

function Extract(x::Union{String, SQLTypeField, SQLTypeFunction, SQLTypeF, Vector{String}}, part::String, format::String; formatter::Union{Nothing, Function, PormGField} = nothing)
  isa(formatter, PormGField) && (formatter = formatter.formatter)
  return FObject(function_name = "EXTRACT", column = x, formatter = formatter, kwargs = Dict{String, Any}("part" => part, "format" => format))
end
# Build a WHEN fragment. When `otherwise` is provided, wrap it in a CASE automatically so
# When(..., otherwise=x) is a complete standalone expression. When used inside Case([...]),
# `otherwise` is always missing (the default) so no wrapping occurs — Case owns the ELSE branch.
function _make_when(column, then, otherwise)
  fobj = FObject(function_name = "WHEN", column = column, kwargs = Dict{String, Any}("then" => then, "else" => missing))
  ismissing(otherwise) && return fobj
  return FObject(function_name = "CASE", column = fobj, kwargs = Dict{String, Any}("else" => otherwise, "output_field" => nothing))
end

function When(x::NTuple{N, <:Pair}; then::Any = 0, otherwise::Any = missing) where N
  return When(Q(x), then = then, otherwise = otherwise)
end
function When(x::Pair{String, T}; then::Any = 0, otherwise::Any = missing) where T
  return _make_when(_get_pair_to_oper(x), then, otherwise)
end
function When(x::Union{SQLTypeQ, SQLTypeQor}; then::Any = 0, otherwise::Any = missing)
  return _make_when(x, then, otherwise)
end
function When(x::Union{SQLTypeOper, SQLTypeFunction}; then::Any = 0, otherwise::Any = missing)
  return _make_when(x, then, otherwise)
end
function Case(conditions::Vector{N} where N <: SQLTypeFunction; default::Any = "NULL", output_field::Union{N, String, Nothing} where N <: PormGField = nothing)
  if isa(output_field, PormGField)
    output_field = output_field.type
  end  
  return FObject(function_name = "CASE", column = conditions, kwargs = Dict{String, Any}("else" => default, "output_field" => output_field)) 
end
function Case(conditions::SQLTypeFunction; default::Any = "NULL", output_field::Union{N, String, Nothing} where N <: PormGField = nothing)
  if isa(output_field, PormGField)
    output_field = output_field.type
  end  
  return FObject(function_name = "CASE", column = conditions, kwargs = Dict{String, Any}("else" => default, "output_field" => output_field)) 
end
function ToChar(x::Union{String, SQLTypeField, SQLTypeFunction, SQLTypeF, Vector{String}}, format::String; formatter::Union{Nothing, Function, PormGField} = nothing)
  isa(formatter, PormGField) && (formatter = formatter.formatter)
  return FObject(function_name = "EXTRACT_DATE", column = x, formatter = formatter, kwargs = Dict{String, Any}("format" => format))
end


"""
    Coalesce(args...; output_field=nothing)

Returns the first non-null value in the list of arguments.
"""
function Coalesce(x...; output_field::Union{N, String, Nothing} where N <: PormGField = nothing)
  if isa(output_field, PormGField)
    output_field = output_field.type
  end
  processed_cols = [isa(v, String) ? SQLField(v) : v for v in x]
  return FObject(function_name = "COALESCE", column = processed_cols, kwargs = Dict{String, Any}("output_field" => output_field))
end

"""
    Greatest(args...; output_field=nothing)

Returns the greatest value in the list of arguments.
"""
function Greatest(x...; output_field::Union{N, String, Nothing} where N <: PormGField = nothing)
  if isa(output_field, PormGField)
    output_field = output_field.type
  end
  processed_cols = [isa(v, String) ? SQLField(v) : v for v in x]
  return FObject(function_name = "GREATEST", column = processed_cols, kwargs = Dict{String, Any}("output_field" => output_field))
end

"""
    Least(args...; output_field=nothing)

Returns the least value in the list of arguments.
"""
function Least(x...; output_field::Union{N, String, Nothing} where N <: PormGField = nothing)
  if isa(output_field, PormGField)
    output_field = output_field.type
  end
  processed_cols = [isa(v, String) ? SQLField(v) : v for v in x]
  return FObject(function_name = "LEAST", column = processed_cols, kwargs = Dict{String, Any}("output_field" => output_field))
end



"""
    Lower(column)

Converts a string to lowercase.
"""
function Lower(x::Union{String, SQLTypeField, SQLTypeText, SQLTypeFunction, SQLTypeF})
  return FObject(function_name = "LOWER", column = x)
end

"""
    Upper(column)

Converts a string to uppercase.
"""
function Upper(x::Union{String, SQLTypeField, SQLTypeText, SQLTypeFunction, SQLTypeF})
  return FObject(function_name = "UPPER", column = x)
end

"""
    Length(column)

Returns the length of a string.
"""
function Length(x::Union{String, SQLTypeField, SQLTypeText, SQLTypeFunction, SQLTypeF})
  return FObject(function_name = "LENGTH", column = x, formatter = Models.format_number_sql)
end

"""
    Abs(column)

Returns the absolute value of a number.
"""
function Abs(x::Union{String, SQLTypeField, SQLTypeText, SQLTypeFunction, SQLTypeF})
  return FObject(function_name = "ABS", column = x, aggregate = _is_agg(x), formatter = Models.format_number_sql)
end

"""
    Round(column, precision=0)

Rounds a number to the specified precision.
"""
function Round(x::Union{String, SQLTypeField, SQLTypeText, SQLTypeFunction, SQLTypeF}, precision::Integer = 0)
  return FObject(function_name = "ROUND", column = x, aggregate = _is_agg(x), kwargs = Dict{String, Any}("precision" => precision), formatter = Models.format_number_sql)
end

"""
    NullIf(field1, field2)

Returns NULL if field1 equals field2, otherwise returns field1.
"""
function NullIf(x, y)
  return FObject(function_name = "NULLIF", column = [isa(x, String) ? SQLField(x) : x, isa(y, String) ? SQLField(y) : y])
end


"""
    Replace(column, find, replace)

Replaces all occurrences of `find` with `replace` in the string.
"""
function Replace(x, find, replace)
  return FObject(function_name = "REPLACE", column = [
    isa(x, String) ? SQLField(x) : x, 
    isa(find, String) ? Value(find) : find, 
    isa(replace, String) ? Value(replace) : replace
  ])
end

"""
    Trim(column)

Removes leading and trailing whitespace from a string.
"""
function Trim(x::Union{String, SQLTypeField, SQLTypeText, SQLTypeFunction, SQLTypeF})
  return FObject(function_name = "TRIM", column = x)
end

"""
    LTrim(column)

Removes leading whitespace from a string.
"""
function LTrim(x::Union{String, SQLTypeField, SQLTypeText, SQLTypeFunction, SQLTypeF})
  return FObject(function_name = "LTRIM", column = x)
end

"""
    RTrim(column)

Removes trailing whitespace from a string.
"""
function RTrim(x::Union{String, SQLTypeField, SQLTypeText, SQLTypeFunction, SQLTypeF})
  return FObject(function_name = "RTRIM", column = x)
end

"""
    Floor(column)

Returns the largest integer less than or equal to a number.
"""
function Floor(x::Union{String, SQLTypeField, SQLTypeText, SQLTypeFunction, SQLTypeF})
  return FObject(function_name = "FLOOR", column = x, aggregate = _is_agg(x), formatter = Models.format_number_sql)
end

"""
    Ceil(column)

Returns the smallest integer greater than or equal to a number.
"""
function Ceil(x::Union{String, SQLTypeField, SQLTypeText, SQLTypeFunction, SQLTypeF})
  return FObject(function_name = "CEIL", column = x, aggregate = _is_agg(x), formatter = Models.format_number_sql)
end



"""
    Sqrt(column)

Returns the square root of a number.
"""
function Sqrt(x::Union{String, SQLTypeField, SQLTypeText, SQLTypeFunction, SQLTypeF})
  return FObject(function_name = "SQRT", column = x, aggregate = _is_agg(x), formatter = Models.format_number_sql)
end

"""
    Exp(column)

Returns the exponential value (e^x) of a number.
"""
function Exp(x::Union{String, SQLTypeField, SQLTypeText, SQLTypeFunction, SQLTypeF})
  return FObject(function_name = "EXP", column = x, aggregate = _is_agg(x), formatter = Models.format_number_sql)
end

"""
    Ln(column)

Returns the natural logarithm of a number.
"""
function Ln(x::Union{String, SQLTypeField, SQLTypeText, SQLTypeFunction, SQLTypeF})
  return FObject(function_name = "LN", column = x, aggregate = _is_agg(x), formatter = Models.format_number_sql)
end

"""
    Power(base, exponent)

Returns `base` raised to the power of `exponent`.
"""
function Power(x, y)
  return FObject(function_name = "POWER", column = [isa(x, String) ? SQLField(x) : x, isa(y, String) ? SQLField(y) : y], formatter = Models.format_number_sql)
end

"""
    Mod(dividend, divisor)

Returns the remainder (modulo) of a division.
"""
function Mod(x, y)
  return FObject(function_name = "MOD", column = [isa(x, String) ? SQLField(x) : x, isa(y, String) ? SQLField(y) : y], formatter = Models.format_number_sql)
end


MONTH(x) = Extract(x, "MONTH", formatter = Models.format_number_sql)
YEAR(x) = Extract(x, "YEAR", formatter = Models.format_number_sql)
DAY(x) = Extract(x, "DAY", formatter = Models.format_number_sql)
Y_M(x) = ToChar(x, "YYYY-MM", formatter = Models.format_yyyy_mm)
DATE(x) = ToChar(x, "YYYY-MM-DD", formatter = Models.format_date_sql)
# Same that function CAST in django ORM
# # relatorio = relatorio.annotate(quarter=functions.Concat(functions.Cast(f'{data}__year', CharField()), Value('-Q'), Case(
# # 					When(**{ f'{data}__month__lte': 4 }, then=Value('1')),
# # 					When(**{ f'{data}__month__lte': 8 }, then=Value('2')),
# # 					When(**{ f'{data}__month__lte': 12 }, then=Value('3')),
# # 					output_field=CharField()
# # 				)))

function QUADRIMESTER(x)
  return Concat([
                Cast(YEAR(x), CharField()), 
                Value("-Q"), 
                Case([When(OP(MONTH(x), "<=", 4), then = 1), 
                      When(OP(MONTH(x), "<=", 8), then = 2), 
                      When(OP(MONTH(x), "<=", 12), then = 3)
                      ], 
                      output_field = CharField())
                ], 
                output_field = CharField(), 
                _as = "$(x[1])__quarter")
end
function QUARTER(x)
  return Concat([
                Cast(YEAR(x), CharField()), 
                Value("-Q"), 
                Case([When(OP(MONTH(x), "<=", 3), then = 1), 
                      When(OP(MONTH(x), "<=", 6), then = 2), 
                      When(OP(MONTH(x), "<=", 9), then = 3), 
                      When(OP(MONTH(x), "<=", 12), then = 4)
                      ], 
                      output_field = CharField())
                ],
                output_field = CharField(),
                _as = "$(x[1])__trimester")
end


function ISNULL(v::String , value::Bool)
  if contains(v, "(")
    throw(FilterError("Error in ISNULL: the column $(v) cannot be a function expression."))
  end
  if value
    return string(v, " IS NULL")
  else
    return string(v, " IS NOT NULL")
  end
end


# ---
# Pagination
#
# INTERNAL, and NOT the fluent implementation. `query.page(...)` routes through
# `ChainCaller(page!, q)` (object_manager.jl), which dispatches on `SQLObject`; these methods take
# an `SQLObjectHandler` and are never reached from the chain. `page` is un-exported (#202), has no
# caller in this repo, and survives only because test_public_exports.jl pins it as
# defined-but-unexported. The external API is the fluent `query.page(limit)` /
# `query.page(limit, offset)` — nothing in `docs/` or `README.md` mentions the function form.
#
# It is a second, parallel implementation of the same semantics, and the two surfaces silently
# drifting apart is exactly what #272 was. `test_fluent_parity_208.jl` now pins them equal; keep
# that test passing rather than editing one side alone.
#
# No docstring on purpose — `docs/src/api.md` builds an `@autodocs` page over the whole QueryBuilder
# module with `Private = true`, so a docstring here publishes `page` in the public API reference as
# if the function form were supported surface. The `.page(...)` reference lives on the `object`
# docstring and in `docs/src/api.md` (the split that test_docstring_coverage.jl enforces).

# Sets BOTH clauses (offset falls back to its 0 default). Unreachable from the chain: `ChainCaller`
# forwards positional arguments only, so no keyword can arrive on the fluent path.
function page(object::SQLObjectHandler; limit::Integer = 10, offset::Integer = 0)
  object.object.limit = limit
  object.object.offset = offset
  return object
end
# Limit-only: the offset already on the handler is left alone. `page!`'s 1-tuple method mirrors this.
function page(object::SQLObjectHandler, limit::Integer)
  object.object.limit = limit
  return object
end
function page(object::SQLObjectHandler, limit::Integer, offset::Integer)
  object.object.limit = limit
  object.object.offset = offset
  return object
end

# ---
# Fluent mutators behind `query.limit(...)`, `query.offset(...)` and `query.page(...)`.
#
# `ChainCaller` packs the call's varargs into ONE tuple and calls `f(q.object, args)`, so the
# argument these receive is always a `Tuple` and the arity check IS the dispatch. Every shape that is
# not an accepted arity therefore needs an `::Any` fallback throwing a `PormGError`: without one the
# user gets a bare `MethodError` naming `page!` and a `Tuple{String, String}` — neither of which
# appears anywhere in their code — and `catch PormGError` (#231/#239) does not cover it (#272).
function limit!(object::SQLObject, limit::Tuple{Integer})
  object.limit = limit[1]
end
function limit!(object::SQLObject, limit)
  throw(QueryBuildError("Invalid limit() arguments: $(limit) (::$(typeof(limit))) — limit() takes exactly one Integer, e.g. limit(20)."))
end
function offset!(object::SQLObject, offset::Tuple{Integer})
  object.offset = offset[1]
end
function offset!(object::SQLObject, offset)
  throw(QueryBuildError("Invalid offset() arguments: $(offset) (::$(typeof(offset))) — offset() takes exactly one Integer, e.g. offset(40)."))
end
# page(n) is limit-only — the offset already on the handler survives, matching page(object, limit).
function page!(object::SQLObject, v::Tuple{Integer})
  object.limit = v[1]
end
function page!(object::SQLObject, v::Tuple{Integer, Integer})
  object.limit = v[1]
  object.offset = v[2]
end
function page!(object::SQLObject, v)
  throw(QueryBuildError("Invalid page() arguments: $(v) (::$(typeof(v))) — page() takes one Integer (limit) or two Integers (limit, offset), e.g. page(20) or page(20, 40)."))
end
