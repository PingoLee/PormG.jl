
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
function Value(x::String)
  return SQLText(x)
end

function Cast(x::Union{String, SQLTypeText, SQLTypeFunction}, type::String)
  return FObject(function_name = "CAST", column = x, kwargs = Dict{String, Any}("type" => type))
end
function Cast(x::Union{String, SQLTypeText, SQLTypeFunction}, type::PormGField)
  return Cast(x, type.type)
end
function Concat(x::Union{Vector{String}, Vector{N}} where N <: SQLType; output_field::Union{N, String, Nothing} where N <: PormGField = nothing, _as::String="")
  if isa(output_field, PormGField)
    output_field = output_field.type
  end
  return FObject(function_name = "CONCAT", column = x, kwargs = Dict{String, Any}("output_field" => output_field, "as" => _as))
end
function Extract(x::Union{String, SQLTypeFunction, Vector{String}}, part::String; formater::Union{Nothing, Function, PormGField} = nothing)
  isa(formater, PormGField) && (formater = formater.formater)
  return FObject(function_name = "EXTRACT", column = x, formater = formater, kwargs = Dict{String, Any}("part" => part))
end
function Extract(x::Union{String, SQLTypeFunction, Vector{String}}, part::String, format::String; formater::Union{Nothing, Function, PormGField} = nothing)
  isa(formater, PormGField) && (formater = formater.formater)
  return FObject(function_name = "EXTRACT", column = x, formater = formater, kwargs = Dict{String, Any}("part" => part, "format" => format))
end
function When(x::NTuple{N, Pair{String, Union{T, Vector{T}}}}; then::Union{String, Integer, Bool, SQLTypeFunction} = 0, _else::Union{String, Integer, Bool, SQLTypeFunction, Missing} = missing) where {T, N}
  return When(Q(x), then = then, _else = _else)
end
function  When(x::Union{Pair{String, Vector{T}}}; then::Union{String, Integer, Bool, SQLTypeFunction} = 0, _else::Union{String, Integer, Bool, SQLTypeFunction, Missing} = missing) where T <: Union{Missing, String, Integer, Bool, SQLTypeFunction}
  return FObject(function_name = "WHEN", column = x |> _get_pair_to_oper, kwargs = Dict{String, Any}("then" => then, "else" => _else))
end
function When(x::Union{SQLTypeQ, SQLTypeQor}; then::Union{String, Integer, Bool, SQLTypeFunction} = 0, _else::Union{String, Integer, Bool, SQLTypeFunction, Missing} = missing)
  return FObject(function_name = "WHEN", column = x, kwargs = Dict{String, Any}("then" => then, "else" => _else))
end
function When(x::Union{SQLTypeOper, SQLTypeFunction}; then::Union{String, Integer, Bool, SQLTypeFunction} = 0, _else::Union{String, Integer, Bool, SQLTypeFunction, Missing} = missing)
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
page(query, limit=20, offset=10) |> list |> DataFrame or page(query, 20, 10)
page(query, limit=20) |> list |> DataFrame or page(query, 20)
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