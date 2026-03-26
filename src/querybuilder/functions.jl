
"""
  Q(x...)

  Create a `QObject` with the given filters.
  Ex.:
  ```julia
  a = object("tb_user")
  a.filter(Q("name" => "John", Qor("age" => 18, "age" => 19)))
  ```

  Arguments:
  - `x`: A list of key-value pairs or Qor(x...) or Q(x...) objects.

"""
function Q(x...)
  colect = [isa(v, Pair) ? _check_filter(v) : isa(v, Union{SQLTypeQor, SQLTypeQ, SQLTypeOper, SQLTypeF}) ? v : throw("Invalid argument: $(v); please use a pair (key => value)") for v in x]
  return QObject(filters = colect)
end


"""
  Qor(x...)

  Create a `QorObject` from the given arguments. The `QorObject` represents a disjunction of `SQLTypeQ` or `SQLTypeQor` objects.

  Ex.:
  ```julia
  a = object("tb_user")
  a.filter(Qor("name" => "John", Q("age__gte" => 18, "age__lte" => 19)))
  ```

  # Arguments
  - `x...`: A variable number of arguments. Each argument can be either a `SQLTypeQ` or `SQLTypeQor` object, or a `Pair` object.

"""
function Qor(x...)
  colect = [isa(v, Pair) ? _check_filter(v) : isa(v, Union{SQLTypeQor, SQLTypeQ, SQLTypeOper, SQLTypeF}) ? v : throw("Invalid argument: $(v); please use a pair (key => value)") for v in x]
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
  return FObject(function_name = "SUM", column = x, agregate = true, kwargs = Dict{String, Any}("distinct" => distinct))
end  
function Avg(x; distinct::Bool = false)
  return FObject(function_name = "AVG", column = x, agregate = true, kwargs = Dict{String, Any}("distinct" => distinct))
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
df = query |> list |> DataFrame
```
"""
function Count(x; distinct::Bool = false)
  return FObject(function_name = "COUNT", column = x, agregate = true, kwargs = Dict{String, Any}("distinct" => distinct))
end
function Max(x)
  return FObject(function_name = "MAX", column = x, agregate = true)
end
function Min(x)
  return FObject(function_name = "MIN", column = x, agregate = true)
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
function Cast(x::Union{String, SQLTypeText, SQLTypeFunction}, type::String)
  return FObject(function_name = "CAST", column = x, kwargs = Dict{String, Any}("type" => type))
end
function Cast(x::Union{String, SQLTypeText, SQLTypeFunction}, type::PormGField)
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

"""
    Extract(column, part)

Extracts a component (YEAR, MONTH, DAY, etc.) from a date/time column.
"""
function Extract(x::Union{String, SQLTypeFunction, Vector{String}}, part::String; formater::Union{Nothing, Function, PormGField} = nothing)
  isa(formater, PormGField) && (formater = formater.formater)
  return FObject(function_name = "EXTRACT", column = x, formater = formater, kwargs = Dict{String, Any}("part" => part))
end

function Extract(x::Union{String, SQLTypeFunction, Vector{String}}, part::String, format::String; formater::Union{Nothing, Function, PormGField} = nothing)
  isa(formater, PormGField) && (formater = formater.formater)
  return FObject(function_name = "EXTRACT", column = x, formater = formater, kwargs = Dict{String, Any}("part" => part, "format" => format))
end
function When(x::NTuple{N, <:Pair}; then::Any = 0, _else::Any = missing) where N
  return When(Q(x), then = then, _else = _else)
end
function  When(x::Pair{String, T}; then::Any = 0, _else::Any = missing) where T
  return FObject(function_name = "WHEN", column = _get_pair_to_oper(x), kwargs = Dict{String, Any}("then" => then, "else" => _else))
end
function When(x::Union{SQLTypeQ, SQLTypeQor}; then::Any = 0, _else::Any = missing)
  return FObject(function_name = "WHEN", column = x, kwargs = Dict{String, Any}("then" => then, "else" => _else))
end
function When(x::Union{SQLTypeOper, SQLTypeFunction}; then::Any = 0, _else::Any = missing)
  return FObject(function_name = "WHEN", column = x, kwargs = Dict{String, Any}("then" => then, "else" => _else))
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
function To_char(x::Union{String, SQLTypeFunction, Vector{String}}, format::String; formater::Union{Nothing, Function, PormGField} = nothing)
  isa(formater, PormGField) && (formater = formater.formater)
  return FObject(function_name = "EXTRACT_DATE", column = x, formater = formater, kwargs = Dict{String, Any}("format" => format))
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
function Lower(x)
  return FObject(function_name = "LOWER", column = x)
end

"""
    Upper(column)

Converts a string to uppercase.
"""
function Upper(x)
  return FObject(function_name = "UPPER", column = x)
end

"""
    Length(column)

Returns the length of a string.
"""
function Length(x)
  return FObject(function_name = "LENGTH", column = x, formater = Models.format_number_sql)
end

"""
    Abs(column)

Returns the absolute value of a number.
"""
function Abs(x)
  return FObject(function_name = "ABS", column = x, formater = Models.format_number_sql)
end

"""
    Round(column, precision=0)

Rounds a number to the specified precision.
"""
function Round(x, precision::Integer = 0)
  return FObject(function_name = "ROUND", column = x, kwargs = Dict{String, Any}("precision" => precision), formater = Models.format_number_sql)
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
function Trim(x)
  return FObject(function_name = "TRIM", column = x)
end

"""
    LTrim(column)

Removes leading whitespace from a string.
"""
function LTrim(x)
  return FObject(function_name = "LTRIM", column = x)
end

"""
    RTrim(column)

Removes trailing whitespace from a string.
"""
function RTrim(x)
  return FObject(function_name = "RTRIM", column = x)
end

"""
    Floor(column)

Returns the largest integer less than or equal to a number.
"""
function Floor(x)
  return FObject(function_name = "FLOOR", column = x, formater = Models.format_number_sql)
end

"""
    Ceil(column)

Returns the smallest integer greater than or equal to a number.
"""
function Ceil(x)
  return FObject(function_name = "CEIL", column = x, formater = Models.format_number_sql)
end



"""
    Sqrt(column)

Returns the square root of a number.
"""
function Sqrt(x)
  return FObject(function_name = "SQRT", column = x, formater = Models.format_number_sql)
end

"""
    Exp(column)

Returns the exponential value (e^x) of a number.
"""
function Exp(x)
  return FObject(function_name = "EXP", column = x, formater = Models.format_number_sql)
end

"""
    Ln(column)

Returns the natural logarithm of a number.
"""
function Ln(x)
  return FObject(function_name = "LN", column = x, formater = Models.format_number_sql)
end

"""
    Power(base, exponent)

Returns `base` raised to the power of `exponent`.
"""
function Power(x, y)
  return FObject(function_name = "POWER", column = [isa(x, String) ? SQLField(x) : x, isa(y, String) ? SQLField(y) : y], formater = Models.format_number_sql)
end

"""
    Mod(dividend, divisor)

Returns the remainder (modulo) of a division.
"""
function Mod(x, y)
  return FObject(function_name = "MOD", column = [isa(x, String) ? SQLField(x) : x, isa(y, String) ? SQLField(y) : y], formater = Models.format_number_sql)
end


MONTH(x) = Extract(x, "MONTH", formater = Models.format_number_sql)
YEAR(x) = Extract(x, "YEAR", formater = Models.format_number_sql)
DAY(x) = Extract(x, "DAY", formater = Models.format_number_sql)
Y_M(x) = To_char(x, "YYYY-MM", formater = Models.format_yyyy_mm)
DATE(x) = To_char(x, "YYYY-MM-DD", formater = Models.format_date_sql)
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
    throw("Error in ISNULL, the column $(v) can't be a function")
  end
  if value
    return string(v, " IS NULL")
  else
    return string(v, " IS NOT NULL")
  end
end


# ---
# Pagination functions
#


"""
Set pagination parameters for a SQL query object.

# Arguments
- `object::SQLObjectHandler`: The SQL object handler to modify
- `limit::Integer`: Maximum number of records to return (default: 10)  
- `offset::Integer`: Number of records to skip from the beginning (default: 0)

# Examples
query.page(20, 10) |> DataFrame
query.page(20) |> DataFrame

The function form `page(query, 20, 10)` is still supported, but the fluent
`query.page(...)` style is the preferred public API.
"""
function page(object::SQLObjectHandler; limit::Integer = 10, offset::Integer = 0)
  object.object.limit = limit
  object.object.offset = offset
  return object
end
function page(object::SQLObjectHandler, limit::Integer)
  object.object.limit = limit
  return object
end
function page(object::SQLObjectHandler, limit::Integer, offset::Integer)
  object.object.limit = limit
  object.object.offset = offset
  return object
end

function limit!(object::SQLObject, limit::Tuple{Integer})
  object.limit = limit[1]
end
function limit!(object::SQLObject, limit)
  throw(ArgumentError("Error in page, limit must be an Integer"))
end
function offset!(object::SQLObject, offset::Tuple{Integer})
  object.offset = offset[1]
end
function offset!(object::SQLObject, offset)
  throw(ArgumentError("Error in page, offset must be an Integer"))
end
function page!(object::SQLObject, v::Tuple{Integer, Integer})
  object.limit = v[1]
  object.offset = v[2]
end