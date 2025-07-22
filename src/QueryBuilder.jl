module QueryBuilder

import DataFrames, Tables
using Dates, TimeZones, Intervals
using SQLite, LibPQ

import PormG.Models: CharField, IntegerField, get_model_pk_field, capitalize_symbol, sForeignKey
import PormG: Dialect, Models
import PormG: config
import PormG: SQLType, SQLConn, PormGPostgres, PormGPostgresParam, SQLInstruction, SQLTypeF, SQLTypeFunction, SQLTypeOper, SQLTypeQ, SQLTypeQor, SQLObjectHandler, SQLObject, SQLTableAlias, SQLTypeText, SQLTypeOrder, SQLTypeField, SQLTypeArrays, PormGModel, PormGField, PormGTypeField
import PormG: PormGsuffix, PormGtrasnform
import PormG.Configuration: fetch, with_transaction
import PormG.Infiltrator: @infiltrate

#
# SQL Sanitization
#

"""
Sanitize SQL identifiers (table names, column names) to prevent injection.
Only allows alphanumeric characters, underscores, and validates against model schema.
"""
function sanitize_identifier(identifier::String, valid_identifiers::Vector{String})::String
    # Remove any non-alphanumeric/underscore characters
    clean_id = replace(identifier, r"[^a-zA-Z0-9_]" => "")
    
    # Validate against whitelist
    if !(clean_id in valid_identifiers)
        throw(ArgumentError("Invalid identifier: $identifier"))
    end
    
    return "\"$clean_id\""  # Quote the identifier
end

"""
Escape LIKE patterns to prevent wildcard injection
"""
function escape_like_pattern(pattern::String)::String
    # Escape special LIKE characters
    escaped = replace(pattern, "\\" => "\\\\")
    escaped = replace(escaped, "%" => "\\%")
    escaped = replace(escaped, "_" => "\\_")
    return escaped
end

"""
Quote SQL identifiers based on database type
"""
function quote_identifier(identifier::String, conn)::String
    clean_id = replace(identifier, r"[^a-zA-Z0-9_]" => "")
    return "\"$clean_id\""
end

"""
Validate and quote table name
"""
function safe_table_identifier(table_name::String, conn)::String
    clean_name = replace(table_name, r"[^a-zA-Z0-9_]" => "")
    
    if clean_name != table_name
        @warn "Table name contains invalid characters, sanitized: $table_name -> $clean_name"
    end
    
    return quote_identifier(clean_name, conn)
end

"""
Validate field name against model and return quoted identifier
"""
function safe_field_identifier(field_name::String, model::PormGModel, conn)::String
    # Validate field exists in model
    if !(field_name in model.field_names)
        throw(ArgumentError("Invalid field name: $field_name for model $(model.name)"))
    end
    return quote_identifier(field_name, conn)
end

#
# Parameters
#

mutable struct PgParameterizedQuery <: PormGPostgresParam
  sql::String
  parameters::Union{AbstractVector, Tuple}
  parameter_count::Int

  PgParameterizedQuery(sql::String, parameters::Union{AbstractVector, Tuple}, parameter_count::Int) = new(sql, parameters, parameter_count)
end
get_parameter(connection::PormGPostgres) = PgParameterizedQuery("", Any[], 0)

function add_parameter!(pq::PormGPostgresParam, value::AbstractArray; contains::Bool = false)
  # parameters::Vector{String} = String[]
  # for v in value
  #   pq.parameter_count += 1
  #   push!(pq.parameters, v)
  #   push!(parameters, "\$$(pq.parameter_count)")
  # end
  contains && (throw(ArgumentError("Contains option is not supported for array parameters")))
  pq.parameter_count += 1
  push!(pq.parameters, value)
  # push!(pq.parameters, "ANY(\$$(pq.parameter_count))")
  return "\$$(pq.parameter_count)"
end
function add_parameter!(pq::PormGPostgresParam, value; contains::Bool = false)::String
  contains && (value = string("%", value |> escape_like_pattern, "%"))  # Escape LIKE patterns if needed
  pq.parameter_count += 1
  push!(pq.parameters, value)
  return "\$$(pq.parameter_count)"  # PostgreSQL style
end
add_parameter!(instruc::SQLInstruction, value::Any; contains::Bool = false) = add_parameter!(instruc.parameters, value; contains = contains)

#
# SQLTypeArrays Objects
#
@kwdef mutable struct SQLArrays <: SQLTypeArrays # TODO -- check if I need to use this
  count::Integer = 1
  array_string::Array{String, 2} = Array{String, 2}(undef, 20, 3)
  array_int::Array{Integer, 2} = Array{Integer, 2}(undef, 20, 3)
end

#
# SQLInstruction Objects (instructions to build a query)
#
@kwdef mutable struct InstrucObject <: SQLInstruction
  text::String # text to be used in the query
  table_alias::SQLTableAlias
  alias::String
  object::SQLObject
  select::Vector{SQLTypeField} = Array{SQLTypeField, 1}(undef, 60)
  join::Vector{String} = []  # values to be used in join query
  _where::Vector{String} = []  # values to be used in where query
  agregate::Bool = false
  group::Vector{String} = []  # values to be used in group query
  having::Vector{String} = [] # values to be used in having query
  order::Vector{String} = [] # values to be used in order query  
  # df_join::Union{Missing, DataFrames.DataFrame} = missing # dataframe to be used in join query
  row_join::Vector{Dict{String, Any}} = [] # array of dictionary to be used in join query
  # array_join::Array{String, 2} = Array{String, 2}(undef, 30, 8) # array to be used in join query (meaby the best way to do this)
  tab_field_cache::Dict{String, PormGField} = sizehint!(Dict{String, PormGField}(), 12) # cache to be used in join query
  connection::Union{SQLite.DB, PormGPostgres, Nothing} = nothing
  array_defs::SQLTypeArrays = SQLArrays()
  cache::Dict{String, SQLTypeField} = sizehint!(Dict{String, SQLTypeField}(), 12)
  django::Union{Nothing, String} = nothing
  parameters::Union{Nothing, PormGPostgresParam} = nothing # parameters to be used in the query
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
  field::String
  _as::Union{String, Nothing}
end
SQLText(field::String; _as::Union{String, Nothing} = nothing) = SQLText(field, _as)
Base.deepcopy(x::SQLTypeText) = SQLText(x.field, x._as)


# Return a field to sql query
mutable struct SQLField <: SQLTypeField
  field::Union{SQLTypeText, SQLTypeFunction, String}
  _as::Union{String, Nothing}
end
SQLField(field::String; _as::Union{String, Nothing} = nothing) = SQLField(field, _as)
Base.deepcopy(x::SQLTypeField) = SQLField(x.field, x._as)

# Return a order of field to sql query
mutable struct SQLOrder <: SQLTypeOrder
  field::Union{SQLTypeField, String}
  order::Union{Integer, Nothing}
  orientation::String
  _as::Union{String, Nothing}
end
SQLOrder(field::Union{SQLTypeField, String}; order::Union{Integer, Nothing} = nothing, orientation::String = "ASC", _as::Union{String, Nothing} = nothing) = SQLOrder(field, order, orientation, _as)
Base.deepcopy(x::SQLTypeOrder) = SQLOrder(x.field, x.order, x.orientation, x._as)

#
# SQLObject Objects (main object to build a query)
#

mutable struct SQLObjectQuery <: SQLObject
  model::PormGModel
  values::Vector{Union{SQLTypeText, SQLTypeField}}
  filter::Vector{Union{SQLTypeQ, SQLTypeQor, SQLTypeOper, SQLTypeF}} # filters to be used in the query
  insert::Dict{String, Any} # values to be used to create or insert
  limit::Integer
  offset::Integer
  order::Vector{SQLTypeOrder}
  group::Vector{String}
  having::Vector{String}
  list_joins::Vector{String} # is ther a better way to do this?
  row_join::Vector{Dict{String, Any}}  
  distinct::Bool # Add distinct field
  parameters::Union{Nothing, PormGPostgresParam}

  SQLObjectQuery(; model=nothing, values = [],  filter = [], insert = Dict(), limit = 0, offset = 0,
        order = [], group = [], having = [], list_joins = [], row_join = [], distinct = false, parameters = nothing) = # Add distinct to constructor
    new(model, values, filter, insert, limit, offset, order, group, having, list_joins, row_join, distinct, parameters) # Add distinct to new
end

#
# SQLTypeOper Objects (operators from sql)
#
export OP

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
  values::Union{String, Integer, Bool, SQLObjectHandler, SQLTypeF, Vector{T}} where T <: Union{Missing, String, DateTime, Integer, Bool, Date, SQLTypeF}
  column::Union{SQLTypeField, SQLTypeFunction, String, SQLTypeF, Vector{Union{String, SQLTypeF}}} # Vector{String} is need 
end
OP(column::String, value) = OperObject(operator = "=", values = value, column = SQLField(column))
OP(column::SQLTypeFunction, value) = OperObject(operator = "=", values = value, column = column)
OP(column::String, operator::String, value) = OperObject(operator = operator, values = value, column = SQLField(column))
OP(column::SQLTypeFunction, operator::String, value) = OperObject(operator = operator, values = value, column = column)

#
# SQLTypeQ and SQLTypeQor Objects
#

export Q, Qor

@kwdef mutable struct QObject <: SQLTypeQ
  filters::Vector{Union{SQLTypeOper, SQLTypeQ, SQLTypeQor, SQLTypeF}} # filters to be used in the query
end
function Base.deepcopy(q::QObject)
  return QObject(filters = deepcopy(q.filters))
end

@kwdef mutable struct QorObject <: SQLTypeQor
  or::Vector{Union{SQLTypeOper, SQLTypeQ, SQLTypeQor, SQLTypeF}} # filters to be used in the query
end
function Base.deepcopy(q::QorObject)
  return QorObject(or = deepcopy(q.or))
end

function Base.push!(q::SQLTypeQ, x...)
  for v in x
    if isa(v, Pair)
      push!(q.filters, _check_filter(v))
    elseif isa(v, Union{SQLTypeQor, SQLTypeQ, SQLTypeOper})
      push!(q.filters, v)
    else
      throw("Invalid argument: $(v); please use a pair (key => value) or Q/Qor/OP object")
    end
  end
  return q
end

function Base.push!(q::SQLTypeQor, x...)
  for v in x
    if isa(v, Pair)
      push!(q.or, _check_filter(v))
    elseif isa(v, Union{SQLTypeQor, SQLTypeQ, SQLTypeOper})
      push!(q.or, v)
    else
      throw("Invalid argument: $(v); please use a pair (key => value) or Q/Qor/OP object")
    end
  end
  return q
end


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

export Sum, Avg, Count, Max, Min, When, F

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
  field_name::String
  operation::Union{String, Nothing} = nothing  # +, -, *, /, etc.
  operand::Union{String, Integer, Float64, SQLTypeF, Nothing} = nothing
  function_name::String = "F"
  column::Union{String, SQLTypeField, Vector{String}} = ""
  agregate::Bool = false
  _as::Union{String, Nothing} = nothing
  kwargs::Dict{String, Any} = Dict{String, Any}()
end

# Constructor for F expressions
function F(field_name::String)
  return FExpression(
    field_name = field_name,
    function_name = "F",
    column = field_name
  )
end
function Base.deepcopy(f::FExpression)
  try
    return FExpression(
      field_name = f.field_name,
      operation = f.operation,
      operand = deepcopy(f.operand),
      function_name = f.function_name,
      column = deepcopy(f.column),
      agregate = f.agregate,
      _as = f._as,
      kwargs = deepcopy(f.kwargs)
    )
  catch e
    @error "Error in deepcopy for FExpression: $e" exception=(e, catch_backtrace())
    rethrow(e)
  end
end

# Arithmetic operations for F expressions
function Base.:+(f::FExpression, operand::Union{Integer, Float64, String, FExpression})
  return FExpression(
    field_name = f.field_name,
    operation = "+",
    operand = operand,
    function_name = "F",
    column = f.field_name
  )
end

function Base.:-(f::FExpression, operand::Union{Integer, Float64, String, FExpression})
  return FExpression(
    field_name = f.field_name,
    operation = "-",
    operand = operand,
    function_name = "F",
    column = f.field_name
  )
end

function Base.:*(f::FExpression, operand::Union{Integer, Float64, String, FExpression})
  return FExpression(
    field_name = f.field_name,
    operation = "*",
    operand = operand,
    function_name = "F",
    column = f.field_name
  )
end

function Base.:/(f::FExpression, operand::Union{Integer, Float64, String, FExpression})
  return FExpression(
    field_name = f.field_name,
    operation = "/",
    operand = operand,
    function_name = "F",
    column = f.field_name
  )
end

# Comparison operations for F expressions
function Base.:(==)(f::FExpression, operand::Union{Integer, Float64, String, Dates.Date, Dates.DateTime, FExpression})  
  f.operation = "="
  f.operand = operand
  return f
end
function Base.:>(f::FExpression, operand::Union{Integer, Float64, String, Dates.Date, Dates.DateTime, FExpression})
  f.operation = ">"
  f.operand = operand
  return f
end

function Base.:<(f::FExpression, operand::Union{Integer, Float64, String, Dates.Date, Dates.DateTime, FExpression})
  f.operation = "<"
  f.operand = operand
  return f
end

function Base.:>=(f::FExpression, operand::Union{Integer, Float64, String, Dates.Date, Dates.DateTime, FExpression})
  f.operation = ">="
  f.operand = operand
  return f
end

function Base.:<=(f::FExpression, operand::Union{Integer, Float64, String, Dates.Date, Dates.DateTime, FExpression})
  f.operation = "<="
  f.operand = operand
  return f
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
function Base.:+(operand::Union{Integer, Float64}, f::FExpression)
  return FExpression(
    field_name = f.field_name,
    operation = "+",
    operand = operand,
    function_name = "F",
    column = f.field_name
  )
end

function Base.:*(operand::Union{Integer, Float64}, f::FExpression)
  return FExpression(
    field_name = f.field_name,
    operation = "*",
    operand = operand,
    function_name = "F",
    column = f.field_name
  )
end


@kwdef mutable struct FObject <: SQLTypeFunction
  function_name::String
  column::Union{String, SQLTypeField, N, Vector{N}, Vector{String}, SQLTypeOper, SQLTypeQ, SQLTypeQor, Vector{M}} where {N <: SQLTypeFunction, M <: SQLType} # TODO Vector{M} is needed?
  agregate::Bool = false
  formater::Union{Nothing, Function} = nothing # function to format the value
  _as::Union{String, Nothing} = nothing
  kwargs::Dict{String, Any} = Dict{String, Any}()
end
function Base.deepcopy(f::FObject)
  return FObject(
    function_name = f.function_name,
    column = deepcopy(f.column),
    agregate = f.agregate,
    formater = f.formater,
    _as = f._as,
    kwargs = deepcopy(f.kwargs)
  )
end

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



function _get_pair_list_joins(q::SQLObject, v::Pair)
  push!(q.list_joins, v[1])
  unique!(q.list_joins)
end
function _get_pair_list_joins(q::SQLObject, v::SQLTypeQ)
  for v in v.filters
    _get_pair_list_joins(q, v)
  end
end
function _get_pair_list_joins(q::SQLObject, v::SQLTypeQor)
  for v in v.or
    _get_pair_list_joins(q, v)
  end
end

# ---
# Build the object
#

# Why Vector{String}
"Agora eu tenho que ver como que eu padronizo todas as variáveis para sair como SQLTypeField"
function up_values!(q::SQLObject, values::NTuple{N, Union{String, Symbol, SQLTypeFunction, SQLTypeText, SQLTypeField, Pair{String, T}}} where N where T <: SQLTypeFunction)
  # every call of values, reset the values
  q.values = []
  for v in values 
    isa(v, Symbol) && (v = String(v))
    if isa(v, SQLTypeText) || isa(v, SQLTypeField)
      push!(q.values, _check_function(v))
    elseif isa(v, SQLTypeFunction)
      push!(q.values, SQLField(_check_function(v), v._as))
    elseif isa(v, Pair) && isa(v.second, SQLTypeFunction)
      try
        push!(q.values, SQLField(_check_function(v.second), v.first))
      catch e
        @infiltrate
      end
    elseif isa(v, String)
      check = String.(split(v, "__@"))
      if size(check, 1) == 1
        push!(q.values, SQLField(v, v))
      elseif haskey(PormGsuffix, check[end])
        throw("Invalid argument: $(v) does not must contain operators (lte, gte, contains ...)")
      else    
        push!(q.values, SQLField(_check_function(check), join(check, "__")))
      end     
    else
      throw("Invalid argument: $(v) (::$(typeof(v)))); please use a string or a function (Mounth, Year, Day, Y_M ...)")
    end    
  end 
  
  return q
end
function up_values!(q::SQLObject, values)
  @error "Invalid argument: $(values) (::$(typeof(values))); please use a string or a function (Mounth, Year, Day, Y_M ...)"
end
  
function up_create!(q::SQLObject, values)
  q.insert = Dict()
  for (k,v) in values   
    q.insert[k] = v 
  end  

  return insert(q)
end

# function up_values!(q::SQLObject, values::NTuple{N, Union{String, Symbol, SQLTypeFunction, SQLTypeText, SQLTypeField, Pair{String, T}}} where N where T <: SQLTypeFunction)
# function up_update!(q::SQLObject, values::NTuple{N, Pair{String, T}} where N where T <: Union{String, Integer, FExpression, SQLTypeF, Missing, Nothing, Bool})
# function up_update!(q::SQLObject, values::NTuple{N, T} where N where T <: Union{Pair{String, String}, Pair{String, Integer}, Pair{String, FExpression}, Pair{String, SQLTypeF}, Pair{String, Missing}, Pair{String, Nothing}, Pair{String, Bool}})
function up_update!(q::SQLObject, values)
  q.insert = Dict()
  for (k,v) in values   
    q.insert[k] = v 
  end  

  return update(q)
end

function up_filter!(q::SQLObject, filter)  
  for v in filter   
    if isa(v, Union{SQLTypeQ, SQLTypeQor, SQLTypeOper, SQLTypeF})
      push!(q.filter, v) # TODO I need process the Qor and Q with _check_filter
    elseif isa(v, Pair)
      push!(q.filter, _check_filter(v))
    else
      error("Invalid argument: $(v) (::$(typeof(v)))); please use a pair (key => value) or a Q(key => value...) or a Qor(key => value...)")
    end
  end
  return q
end

function distinct!(q::SQLObject, value::Bool) #::Union{Bool, Nothing}) 
  q.distinct = value
  return q
end
distinct!(q::SQLObject, value::Tuple{}) = distinct!(q, true) # if no value is passed, distinct is true
distinct!(q::SQLObject, value::Tuple{Bool}) = distinct!(q, value[1]) # if a value is passed, distinct is the value
function distinct!(q::SQLObject, value)
  throw("Invalid argument: $(value) (::$(typeof(value))); please use a boolean value (true or false)")
end

# function distinct!(q::SQLObject, value)
#   throw("Invalid argument: $(value) (::$(typeof(value))); please use a boolean value (true or false)")
# end

function _query_select(array::Vector{SQLTypeField})
  if !isassigned(array, 1, 1)
    return "*"
  else
    colect = []
    for i in 1:size(array, 1)     
      if !isassigned(array, i, 1)
        return join(colect,  ", \n  ")
      else
        push!(colect, "$(array[i, 1].field) as $(array[i, 1]._as)")
      end
    end
  end   
end

function order_by!(q::SQLObject, values::NTuple{N, Union{String, SQLTypeOrder}} where N)
  q.order = [] # every call of order_by, reset the order
  for v in values 
    if isa(v, String)
      # check if v constains - in the first position
      v[1:1] == "-" ? (orientation = "DESC"; v = v[2:end]) : orientation = "ASC"
      check = String.(split(v, "__@"))
      if size(check, 1) == 1
        push!(q.order, SQLOrder(SQLField(v, v), orientation=orientation))
      elseif haskey(PormGsuffix, check[end])
        throw("Invalid argument: $(v) does not must contain operators (lte, gte, contains ...)")
      else    
        push!(q.order, SQLOrder(SQLField(_check_function(check), join(check, "__")), orientation=orientation))
      end     
    else
      push!(q.order, v)
    end    
  end   
  return q  
end
function order_by!(q::SQLObject, values)
  throw("Invalid argument: $(values) (::$(typeof(values))); please use a string or a SQLTypeOrder)")
end

  
mutable struct ObjectHandler <: SQLObjectHandler
  object::SQLObject
  values::Function
  filter::Function
  create::Function
  update::Function
  order_by::Function
  distinct::Function # Add distinct function

  # Constructor with keyword arguments
  function ObjectHandler(; object::SQLObject, 
                          values::Function = (x...) -> up_values!(object, x), 
                          filter::Function = (x...) -> up_filter!(object, x), 
                          create::Function = (x...) -> up_create!(object, x), 
                          update::Function = (x...) -> up_update!(object, x), 
                          order_by::Function = (x...) -> order_by!(object, x),
                          distinct::Function = (x...) -> distinct!(object, x))
      return new(object, values, filter, create, update, order_by, distinct) # Add distinct to new
  end
end

export object

"""
Wraps a PormGModel into an ObjectHandler on which you can call:
```
- .filter(...) to add WHERE clauses
- .values(...) to choose/annotate columns
- .order_by(...) to sort
- .distinct() to add DISTINCT clause
- .create(...) for single-row DML
- .update(...) for single-row DML
- plus bulk_insert, bulk_update, do_count, do_exists, list
```

# Arguments
- `model::PormGModel`: The model to be wrapped and handled.

# Example
```julia
using PormG, DataFrames

# assume models loaded as `M`
query = M.User |> object

# 1) Filtering & selecting
query.filter("is_active" => true)
query.values("id", "username", "email")
df = query |> list |> DataFrame

# 2) Counting
active_users = query |> do_count

# 3) Inserting a single row
query = M.Status |> object
new = query.create("statusid" => 42, "status" => "Foo")  
# returns a Dict of the inserted row

# 4) Updating a single row
query = M.Status |> object
query.filter("statusid" => 42)
query.update("status" => "Bar")

# 5) Ordering & aggregation
query = M.Result |> object
query.filter("raceid__year" => 2020)
query.values(
  "driverid__forename", 
  "constructorid__name", 
  "laps" => Count("laps")
)
query.order_by("-laps")
df2 = query |> list |> DataFrame

# 6) Existence check
query = M.User |> object
query.filter("id" => 1)
exists = query |> do_exists

# 7) Bulk insert
df_new = DataFrame(name=["A","B"], age=[30,25])
bulk_insert(M.User |> object, df_new)

# 8) Bulk update (by primary key)
df_up = DataFrame(id=[1,2], name=["Alice","Bob"])
bulk_update(M.User |> object, df_up, columns=["name"], filters=["id"])
``
"""
function object(model::PormGModel)
  return ObjectHandler(object = SQLObjectQuery(model = model))
end
function Base.deepcopy(obj::SQLObjectHandler)
  return ObjectHandler(object = deepcopy(obj.object))
end
function Base.deepcopy(obj::SQLObjectQuery)
  try
    return SQLObjectQuery(
      model = obj.model,  # PormGModel doesn't need deep copy (immutable reference)
      values = deepcopy(obj.values),
      filter = deepcopy(obj.filter),
      insert = deepcopy(obj.insert),
      limit = obj.limit,
      offset = obj.offset,
      order = deepcopy(obj.order),
      group = deepcopy(obj.group),
      having = deepcopy(obj.having),
      list_joins = deepcopy(obj.list_joins),
      row_join = deepcopy(obj.row_join),
      distinct = obj.distinct
    )
  catch e
    @infiltrate false
    @error "Error in deepcopy for SQLObjectQuery: $e" exception=(e, catch_backtrace())
    rethrow(e)
  end
end
function Base.deepcopy(filter::Vector{Union{SQLTypeF, SQLTypeOper, SQLTypeQ, SQLTypeQor}})
  return [deepcopy(f) for f in filter]
end
function Base.deepcopy(filter::Vector{Union{SQLTypeQ, SQLTypeQor, SQLTypeOper}})
  return [deepcopy(f) for f in filter]
end
function Base.deepcopy(oper::SQLTypeOper)
  @infiltrate false
  return OperObject(
    operator = oper.operator,
    values = oper.values |> typeof <: SQLObjectHandler ? oper.values : deepcopy(oper.values),
    column = deepcopy(oper.column)
  )
end
# function object(model::String)
#   return object(getfield(Models, Symbol(model)))
# end
# function object(model::Symbol)
#   return object(getfield(Models, model))
# end
 
### string(q::SQLObjectQuery, m::Type{T}) where {T<:AbstractModel} = to_fetch_sql(m, q)

#
# Process the query entries to build the SQLObjectQuery object
#

# talvez eu não precise dessa função no inicio, mas pode ser útil na hora de processar o query
# function _check_function(f::OperObject)
function _check_function(f::Vector{N} where N <: SQLObject)
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
function _check_function(f::Union{SQLText, SQLField})
  return f
end
function _check_function(f::Vector{SQLType})
  for i in 1:size(f, 1)    
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
    if haskey(PormGtrasnform, x[end])
      resp = getfield(@__MODULE__, Symbol(PormGtrasnform[x[end]]))(x[1:end-1])  
      return _check_function(resp)
    else
      joined_keys_with_prefix = join(map(key -> " \e[32m@" * key, keys(PormGtrasnform) |> collect), "\n")
      if haskey(PormGsuffix, x[end])
        yes = "you can use \"column__@\e[32m$(x[end])\e[0m\""
        not = "you can not use \"column__\e[31m@$(x[end])__@function\e[0m\". valid functions are:\n$(joined_keys_with_prefix)\e[0m"
        throw(ArgumentError("\e[4m\e[31m$(x[end])\e[0m is not allowed.\n$yes\n$not"))
      else
        throw(ArgumentError("\"$(x[1])__\e[31m@$(x[end])\e[0m\" is invalid; please use a valid function:\n$(joined_keys_with_prefix)\e[0m"))
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
function _get_pair_to_oper(x::Pair{Vector{String}, T}) where T <: Union{String, Integer, Bool}
  if haskey(PormGsuffix, x.first[end])
    return OperObject(operator = PormGsuffix[x.first[end]], values = x.second, column = SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else    
    return OperObject(operator = "=", values = x.second, column = SQLField(_check_function(x.first), join(x.first, "__"))) # TODO, maybe I need to check if the column is valid and process the function before store
  end  
end
function _get_pair_to_oper(x::Pair{String, T}) where T <: Union{String, Integer, Bool, Date}
  return _get_pair_to_oper(String.(split(x.first, "__@")) => x.second)
end
function _get_pair_to_oper(x::Pair{String, Vector{T}}) where T <: Union{Missing, String, Integer, Bool}
  return _get_pair_to_oper(String.(split(x.first, "__@")) => x.second)
end  
# Store SQLObject, to use __@in operator
function _get_pair_to_oper(x::Pair{Vector{String}, T}) where T <: SQLObjectHandler
  if x.first[end] in ["in", "nin"]
    return OperObject(operator = x.first[end], values = x.second, column = SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    throw(ArgumentError("Error in filter, Invalid operator for \e[31m$(x.first[end])\e[0m, only \e[32m'in and nin'\e[0m is allowed with a object"))
  end
end
function _get_pair_to_oper(x::Pair{Vector{String}, Vector{T}}) where T <: Union{Missing, String, Integer, Bool}
  if x.first[end] in ["in", "nin"]
    @infiltrate false
    return OperObject(operator = PormGsuffix[x.first[end]], values = x.second, column = SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    throw(ArgumentError("Error in filter, Invalid operator for \e[31m$(x.first[end])\e[0m, only \e[32m'in and nin'\e[0m is allowed with a object"))
  end
end
function _get_pair_to_oper(x::Pair{Vector{String}, Date})
  _get_pair_to_oper(x.first => x.second |> string)
end

  

function _check_filter(x::Pair)  
  if isa(x.first, String)
    check = String.(split(x.first, "__@"))  
    try
      # @infiltrate
      return _get_pair_to_oper(check => x.second)
    catch e
      @infiltrate
      @error "Error in filter: '$(x.first) => ...' must be a String, got $(typeof(x.first))" exception=(e, catch_backtrace())
      rethrow(e)
    end
  else    
    throw("Error in filter: '$(x.first) => ...' must be a String, got $(typeof(x.first))")
  end
end

# does this obsolet?
function _get_join_query(array::Vector{String}; array_store::Vector{String}=String[]) 
  array = copy(array)
  for i in 1: size(array, 1) 
    for (k, value) in PormGsuffix
      if endswith(array[i], k)
        array[i] = array[i][1:end-length(k)]          
      end
    end
    for (k, value) in PormGtrasnform
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

function _get_join_query(x::Tuple{Pair{String, Integer}, Vararg{Pair{String, Integer}}}; array_store::Vector{String} = String[])
  array = String[]
  for (k,v) in x
    push!(array, k)
  end
  _get_join_query(array, array_store=array_store)  
end
function _get_join_query(x::Tuple{String, Vararg{String}}; array_store::Vector{String} = String[])
  array = String[]
  for v in x
    push!(array, v)
  end
  _get_join_query(array, array_store=array_store)  
end
function _get_join_query(x::Dict{String,Union{Integer, String}}; array_store::Vector{String} = String[])
  array = String[]
  for (k,v) in x
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
function _get_alias_name(row_join::Vector{Dict{String, Any}}, alias::String)
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

function _insert_join(row_join::Vector{Dict{String, Any}}, row::Dict{String,String})
  @infiltrate false
  if size(row_join, 1) == 0
    push!(row_join, row)
    return row["alias_b"]
  else
    check = filter(r -> r["a"] == row["a"] && r["b"] == row["b"] && r["key_a"] == row["key_a"] && r["key_b"] == row["key_b"] && r["alias_a"] == row["alias_a"], row_join)
    if size(check, 1) == 0
      @infiltrate false
      push!(row_join, row)
      return row["alias_b"]
    else
      if size(check, 1) > 1
        throw("Error in join")
      end
      return check[1]["alias_b"]  
    end
  end
end

"""
This function checks if the given `field` is a valid field in the provided `model`. If the field is valid, it returns the field name, potentially modified based on certain conditions.
"""
function _solve_field(field::String, model::PormGModel, instruct::SQLInstruction)
  # check if last_column a field from the model    
  if !(field in model.field_names)
    @infiltrate false
    throw(ArgumentError("The field \e[31m$(field)\e[0m not found in \e[34m$(model.name)\e[0m: \e[32m$(join(model.field_names, ", "))\e[0m"))
  end
  # (instruct.django !== nothing && hasfield(model.fields[field] |> typeof, :to)) && (field = string(field, "_id"))
  
  # Quote the field name to prevent SQL injection
  return quote_identifier(field, instruct.connection)
end
_solve_field(field::String, _module::Module, model_name::Symbol, instruct::SQLInstruction) = _solve_field(field, getfield(_module, model_name), instruct) 
_solve_field(field::String, _module::Module, model_name::String, instruct::SQLInstruction) = _solve_field(field, _module, Symbol(model_name), instruct)
_solve_field(field::String, _module::Module, model_name::PormGModel, instruct::SQLInstruction) = _solve_field(field, model_name, instruct)

"build a row to join"
function _determine_join_type(field::PormGField; previus_how::Union{String, Nothing} = nothing)
  valid_joins = ["INNER", "LEFT", "RIGHT", "FULL", "CROSS"]

  if previus_how !== nothing && previus_how == "LEFT"
    # if the previous join was a LEFT JOIN, the current join must be a LEFT JOIN
    return "LEFT"
  end
  
  if field.how !== nothing && !isempty(field.how)
    join_type = uppercase(strip(field.how))
    if join_type ∉ valid_joins
      throw(ArgumentError("Invalid join type '$(field.how)'. Valid types: $(join(valid_joins, ", "))"))
    end
    return join_type
  end
  
  return field.null ? "LEFT" : "INNER"
end
function _build_row_join(field::Vector{SubString{String}}, instruct::SQLInstruction; as::Bool=true)
  # convert the field to a vector of string
  vector = String.(field)
  _build_row_join(vector, instruct, as=as)  
end
function _build_row_join(field::Vector{String}, instruct::SQLInstruction; as::Bool=true)
  vector = copy(field) 
  foreign_table_name::Union{String, PormGModel, Nothing} = nothing
  foreing_table_module::Module = instruct.object.model._module::Module
  row_join = sizehint!(Dict{String,String}(), 8)
 
  @infiltrate false

  first_column = instruct.django !== nothing ? string(vector[1], "_id") : vector[1]
  last_field::Union{Nothing, PormGField} = nothing

  if first_column in instruct.object.model.field_names # vector moust be a field from the model    
    row_join["a"] = instruct.object.model.name
    row_join["alias_a"] = instruct.alias
    first_field = instruct.object.model.fields[first_column]
    @infiltrate false
    row_join["how"] = _determine_join_type(first_field)
    foreign_table_name = first_field.to
    if foreign_table_name === nothing
      throw("Error in _build_row_join, the column $(first_column) does not have a foreign key")
    elseif isa(foreign_table_name, PormGModel)
      row_join["b"] = foreign_table_name.name
      size(vector, 1) == 2 && (last_field = foreign_table_name.fields[vector[2]])
    else
      row_join["b"] = instruct.django !== nothing ? string(instruct.django,  foreign_table_name |> lowercase) : foreign_table_name |> lowercase
      size(vector, 1) == 2 && (last_field = getfield(foreing_table_module, foreign_table_name |> Symbol).fields[vector[2]])
    end
    # row_join["alias_b"] = _get_alias_name(instruct.df_join) # TODO chage by row_join and test the speed
    row_join["alias_b"] = _get_alias_name(instruct.row_join, instruct.alias)
    row_join["key_b"] = first_field.pk_field::String
    row_join["key_a"] = first_column
  elseif haskey(instruct.object.model.related_objects, vector[1])
    # @infiltrate false
    s_model = Symbol(uppercasefirst(string(instruct.object.model.related_objects[vector[1]][3])))
    reverse_model = getfield(foreing_table_module, s_model)
    length(vector) == 1 && throw("Error in _build_row_join, the column $(vector[1]) is a reverse field, you must inform the column to be selected. Example: ...filter(\"$(vector[1])__column\")")
    # !(vector[2] in reverse_model.field_names) && throw("Error in _build_row_join, the column $(vector[2]) not found in $(reverse_model.name)")
    row_join["a"] = instruct.object.model.name
    row_join["alias_a"] = instruct.alias
    last_field = reverse_model.fields[instruct.object.model.related_objects[vector[1]][1] |> String]   
    row_join["how"] = _determine_join_type(last_field)
    foreign_table_name = instruct.object.model.related_objects[vector[1]][3] |> String
    if foreign_table_name === nothing
      throw("Error in _build_row_join, the column $(foreign_table_name) does not have a foreign key")
    elseif isa(foreign_table_name, PormGModel)
      row_join["b"] = foreign_table_name.name
    else
      row_join["b"] = instruct.django !== nothing ? string(instruct.django,  foreign_table_name |> lowercase) : foreign_table_name |> lowercase
    end

    row_join["alias_b"] = _get_alias_name(instruct.row_join, instruct.alias)
    row_join["key_a"] = instruct.object.model.related_objects[vector[1]][2] |> String
    row_join["key_b"] = instruct.object.model.related_objects[vector[1]][1] |> String
    foreign_table_name = s_model |> string
    @infiltrate false
  else
    @infiltrate
    throw(ArgumentError("the column \e[4m\e[31m$(vector[1])\e[0m not found in \e[4m\e[32m$(instruct.object.model.name)\e[0m, that contains the fields: \e[4m\e[32m$(join(instruct.object.model.field_names, ", "))\e[0m and the related objects: \e[4m\e[32m$(join(keys(instruct.object.model.related_objects), ", "))\e[0m"))
  end
  
  vector = vector[2:end]  

  @infiltrate false
  tb_alias = _insert_join(instruct.row_join, row_join)
  while size(vector, 1) > 1
    # get new object
    @infiltrate false
    new_object = foreign_table_name isa PormGModel ? foreign_table_name : getfield(foreing_table_module, foreign_table_name |> Symbol)
    first_column = instruct.django !== nothing ? string(vector[1], "_id") : vector[1]

    if first_column in new_object.field_names
      first_field = new_object.fields[first_column]
      !hasfield(typeof(first_field), :to) && throw("Error in _build_row_join, the column $(first_column) is a field from $(new_object.name), but this field has not a foreign key")
      row_join["a"] = row_join["b"]
      row_join["alias_a"] = tb_alias      
      row_join["how"] = _determine_join_type(new_object.fields[first_column], previus_how=row_join["how"])
      foreign_table_name = new_object.fields[first_column].to
      if foreign_table_name === nothing
        throw("Error in _build_row_join, the column $(vector[2]) does not have a foreign key")
      elseif isa(foreign_table_name, PormGModel)
        row_join["b"] = foreign_table_name.name
        size(vector, 1) == 2 && (last_field = foreign_table_name.fields[vector[2]])
      else
        row_join["b"] = instruct.django !== nothing ? string(instruct.django,  foreign_table_name |> lowercase) : foreign_table_name |> lowercase
        size(vector, 1) == 2 && (last_field = getfield(foreing_table_module, foreign_table_name |> Symbol).fields[vector[2]])
      end
      row_join["alias_b"] = _get_alias_name(instruct.row_join, instruct.alias) # TODO chage by row_join and test the speed
      row_join["key_b"] = new_object.fields[first_column].pk_field::String
      row_join["key_a"] = first_column    
    elseif haskey(new_object.related_objects, vector[1])
      s_model = Symbol(uppercasefirst(string(new_object.related_objects[vector[1]][3])))
      reverse_model = getfield(foreing_table_module, s_model)
      length(vector) == 1 && throw("Error in _build_row_join, the column $(vector[1]) is a reverse field, you must inform the column to be selected. Example: ...filter(\"$(vector[1])__column\")")
      !(vector[2] in reverse_model.field_names) && throw("Error in _build_row_join, the column $(vector[2]) not found in $(reverse_model.name)")
      row_join["a"] = row_join["b"]
      row_join["alias_a"] = tb_alias
      last_field = reverse_model.fields[new_object.related_objects[vector[1]][1] |> String]
      row_join["how"] = _determine_join_type(last_field, previus_how=row_join["how"])
      foreign_table_name = new_object.related_objects[vector[1]][3] |> String
      if foreign_table_name === nothing
        throw("Error in _build_row_join, the column $(foreign_table_name) does not have a foreign key")
      elseif isa(foreign_table_name, PormGModel)
        row_join["b"] =  foreign_table_name.name
      else
        row_join["b"] = instruct.django !== nothing ? string(instruct.django,  foreign_table_name |> lowercase) : foreign_table_name |> lowercase
      end

      row_join["alias_b"] = _get_alias_name(instruct.row_join, instruct.alias)
      row_join["key_a"] = new_object.related_objects[vector[1]][2] |> String
      row_join["key_b"] = new_object.related_objects[vector[1]][1] |> String
      vector = vector[2:end]

    else
      throw("Error in _build_row_join, the column $(vector[1]) not found in $(new_object.name)")
    end

    @infiltrate false
    tb_alias = _insert_join(instruct.row_join, row_join)

    vector = vector[2:end]
  end

  # tb_alias is the last table alias in the join ex. tb_1
  # last_column is the last column in the join ex. last_login
  # vector is the full path to the column ex. user__last_login__date (including functions (except the suffix))

  @infiltrate false

  # println("$(join(field, "__"))")
  # functions must be processed here
  instruct.tab_field_cache["$(join(field, "__"))"] = last_field
  return string(quote_identifier(tb_alias, instruct.connection), ".", _solve_field(vector[end], foreing_table_module, foreign_table_name, instruct))
  
end

# outher functions
function _df_to_dic(df::DataFrames.DataFrame, column::String, filter::String)
  column = Symbol(column)
  loc = DataFrames.subset(df, DataFrames.AsTable([column]) => ( @. x -> x[column] == filtro) )
  if size(loc, 1) == 0
    throw("Error in _df_to_dic, $(filter) not found in $(column)")
  elseif size(loc, 1) > 1
    throw("Error in _df_to_dic, $(filter) found more than one time in $(column)")
  else 
    return loc[1, :]
  end
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
# Build the SQLInstruction object
#

# select
function _get_select_query(v::SQLText, instruc::SQLInstruction; _as::Union{Nothing, String} = nothing)
  return Dialect.VALUE(v.field, instruc.connection)
end
function _get_select_query(v::Vector{SQLObject}, instruc::SQLInstruction; _as::Union{Nothing, String} = nothing)
  @infiltrate
  resp = []
  for v in v
    push!(resp, _get_select_query(v, instruc, _as=_as))
  end
  return resp
end
function _get_select_query(v::Vector{SQLType}, instruc::SQLInstruction; _as::Union{Nothing, String} = nothing)
  resp = []
  for v in v
    push!(resp, _get_select_query(v, instruc, _as=_as))
  end
  return resp
end
function _get_select_query(v::Vector{FObject}, instruc::SQLInstruction; _as::Union{Nothing, String} = nothing)
  resp = []
  for v in v
    push!(resp, _get_select_query(v, instruc, _as=_as))
  end
  return resp
end
function _get_select_query(v::String, instruc::SQLInstruction; _as::Union{Nothing, String} = nothing)
  parts = split(v, "__")  
  if size(parts, 1) > 1
    return _build_row_join(parts, instruc)
  else
    if _as !== nothing && haskey(instruc.tab_field_cache, _as)
      instruc.tab_field_cache[_as] = instruc.object.model.fields[v]
    end
    quoted_alias = quote_identifier(instruc.alias, instruc.connection)
    return string(quoted_alias, ".", _solve_field(v, instruc.object.model, instruc))
  end
end
function _get_select_query(v::SQLField, instruc::SQLInstruction; _as::Union{Nothing, String} = nothing)
  return _get_select_query(v.field, instruc, _as=_as)
  # return v.field
end
function _get_select_query(v::SQLTypeOper, instruc::SQLInstruction; _as::Union{Nothing, String} = nothing)
  # use logic to when funtion
  return _get_filter_query(v, instruc)
end
function _get_select_query(v::SQLTypeFunction, instruc::SQLInstruction; _as::Union{Nothing, String} = nothing)
  @infiltrate false
  return getfield(Dialect, Symbol(v.function_name))(_get_select_query(v.column, instruc, _as=_as), v.kwargs, instruc.connection)
  try
    return getfield(Dialect, Symbol(v.function_name))(_get_select_query(v.column, instruc, _as=_as), v.kwargs, instruc.connection)
  catch e
    @infiltrate 
    throw(ArgumentError("Error in function \e[4m\e[31m$(v.function_name)\e[0m, the function does not exist or is not implemented for the dialect \e[4m\e[32m$(instruc.dialect)\e[0m. Please check the function name and the dialect."))
  end

end
function _get_select_query(q::SQLTypeQor, instruc::SQLInstruction; _as::Union{Nothing, String} = nothing)
  resp = []
  for v in q.or
    push!(resp, _get_select_query(v, instruc, _as=_as))
  end
  return "(" * join(resp, " OR ") * ")"
end

function _get_select_query(q::SQLTypeQ, instruc::SQLInstruction; _as::Union{Nothing, String} = nothing)
  resp = []
  for v in q.filters
    push!(resp, _get_select_query(v, instruc, _as=_as))
  end
  return "(" * join(resp, " AND ") * ")"
end
function _get_select_query(q::SQLTypeF, instruc::SQLInstruction; _as::Union{Nothing, String} = nothing)
  # TODO check if the field is in the model
  @infiltrate false
  if q.operation !== nothing
    return _set_update_query(q, instruc)
  elseif q.field in instruc.object.model.field_names
    return string(instruc.alias, ".", _solve_field(q.field, instruc.object.model, instruc))
  else
    throw(ArgumentError("The field \e[31m$(q.field)\e[0m not found in \e[34m$(instruc.object.model.name)\e[0m: \e[32m$(join(instruc.object.model.field_names, ", "))\e[0m"))
  end
end


"""
  get_select_query(object::SQLObject, instruc::SQLInstruction)

  Iterates over the values of the object and generates the SELECT query for the given SQLInstruction object.

  #### ALERT
  - This internal function is called by the `build` function.

  #### Arguments
  - `object::SQLObject`: The object containing the values to be selected.
  - `instruc::SQLInstruction`: The SQLInstruction object to which the SELECT query will be added.
"""
function get_select_query(values::Vector{Union{SQLTypeText, SQLTypeField}}, instruc::SQLInstruction)
  for i in eachindex(values) # linear indexing
    v_copy = deepcopy(values[i])
    if isa(v_copy.field, SQLTypeFunction) 
      if v_copy.field.agregate == false
        push!(instruc.group, i |> string)
      else 
        instruc.agregate = true
      end
    else
      push!(instruc.group, i |> string)
    end

    if haskey(instruc.cache, v_copy._as)
      instruc.select[i] = instruc.cache[v_copy._as]  # TODO That is necessary in get_select_query    
    else
      @infiltrate false
      v_copy.field = _get_select_query(v_copy.field, instruc, _as=v_copy._as)
      instruc.select[i] = v_copy
      if v_copy._as === nothing
        throw(ArgumentError("Field requires an alias: \e[4m\e[31m$(v_copy.field)\e[0m must have a name using the format \e[4m\e[32m\"field_name\" => $(v_copy.field)\e[0m or use \e[4m\e[32mSQLField($(v_copy.field), \"alias_name\")\e[0m"))
      end
      instruc.cache[v_copy._as] = instruc.select[i]
    end    
  end
end

function get_order_query(object::SQLObject, instruc::SQLInstruction)
  for v in object.order 
    found_in_select = false
    v_field_copy = deepcopy(v.field)
    if haskey(instruc.cache, v_field_copy._as)
      v_field_copy.field = instruc.cache[v_field_copy._as].field # TODO how can i recover the order of the field in select, maybe is better thar use the function in order by
    else
      v_field_copy.field = _get_select_query(v_field_copy.field, instruc)
    end     
    push!(instruc.order, string(v_field_copy.field, " ", v.orientation))
    instruc.cache[v_field_copy._as] = v_field_copy   

    # check if the field is in the select
    for value in object.values
      if isa(value, SQLTypeFunction) && value.field.agregate == true
        continue
      elseif value._as == v_field_copy._as
        found_in_select = true
        break
      end
    end

    if !found_in_select
      push!(instruc.group, v_field_copy.field)
    end

  end  
  return nothing  
end

function _get_filter_query(v::Vector{SubString{String}}, instruc::SQLInstruction, )
  # what to do with the functions?
  @infiltrate
  v = String.(v)
  text = _build_row_join(v[1], instruc, as=false)
  i = 2
  to = size(v, 1)
  
  while i <= to
    function_name = functions[end]      
    text = getfield(Dialect, Symbol(PormGtrasnform[string(function_name)]))(text)
    functions = functions[1:end-1]
  end
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
  if haskey(instruc.cache, v._as)
    return instruc.cache[v._as].field
  else
    v_copy = deepcopy(v)
    v_copy.field = _get_select_query(v_copy.field, instruc)
    instruc.cache[v_copy._as] = v_copy
    return v_copy.field
  end
end
function _get_filter_query(v::SQLTypeOper, instruc::SQLInstruction)
  @infiltrate false
  column = _get_filter_query(v.column, instruc)
  if isa(v.values, SQLTypeF)
    @infiltrate false
    # F expressions are safe since they reference model fields    
    placeholders = _get_filter_query(v.values, instruc)
    return string(column, " ", v.operator, " ", placeholders)
  elseif isa(v.column, SQLTypeField) && isa(v.column.field, SQLTypeFunction) && v.column.field.formater !== nothing
    @infiltrate false
    placeholders = add_parameter!(instruc, v.column.field.formater(v.values)) 
  elseif isa(v.column, SQLTypeField) && isa(v.column.field, SQLTypeFunction) && haskey(PormGTypeField, v.column.field.function_name)
    placeholders = add_parameter!(instruc, getfield(Models, PormGTypeField[v.column.field.function_name])(v.values))
    # value = getfield(Models, PormGTypeField[v.column.field.function_name])(v.values)
  elseif isa(v.column, SQLTypeFunction) && haskey(PormGTypeField, v.column.function_name)
    # Function with formater
    @infiltrate false
    placeholders = add_parameter!(instruc, getfield(Models, PormGTypeField[v.column.function_name])(v.values))
  elseif isa(v.values, SQLObjectHandler)
    # Subqueries - these are safe since they're built through PormG.jl
    if !(v.operator in ["in", "not in"])
      throw("Error in values, $(v.values) is not a SQLObjectHandler")
    end
    placeholders = query(v.values, table_alias=instruc.table_alias, connection=instruc.connection, parameters=instruc.parameters)
    return string(_get_filter_query(v.column, instruc), " ", v.operator, " ($placeholders)")
  else   
    @infiltrate false
    if isa(v.column, SQLTypeField)
      @infiltrate false
      _get_select_query(v.column, instruc, _as=v.column._as) # TODO, how do this i where before do operates
    else 
      @infiltrate false
    end
    if v.operator in ["ISNULL"]
      return getfield(QueryBuilder, Symbol(v.operator))(_get_filter_query(v.column, instruc), v.values)
    elseif haskey(instruc.object.model.fields, v.column.field)
      placeholders = nothing
      try
        placeholders = add_parameter!(instruc, instruc.object.model.fields[v.column.field].formater(v.values))
      catch e
        @infiltrate false
        if contains(string(e), "The date") && contains(string(e), "is invalid")          
          throw(ArgumentError("The \e[4m\e[31m$(v.column.field)\e[0m field is the type \e[4m\e[32m$(instruc.object.model.fields[v.column.field].type)\e[0m. Please check the value: \e[4m\e[31m$(v.values)\e[0m"))
        end
        @infiltrate
      end      
    elseif haskey(instruc.tab_field_cache, v.column._as) # Check cache first
      @infiltrate false
      placeholders = add_parameter!(instruc, instruc.tab_field_cache[v.column._as].formater(v.values), contains = v.operator in ["contains", "icontains"])
    elseif isa(v.column, SQLTypeField)
      @infiltrate false
      placeholders = add_parameter!(instruc, v.values, contains = v.operator in ["contains", "icontains"])
    else
      @infiltrate false
      throw("Error in values, $(v.column.field) not found in $(instruc.object.model.name)")
    end
  end
  
  if v.operator in ["=", ">", "<", ">=", "<=", "<>", "!="]   
    return string(column, " ", v.operator, " ", placeholders)     
  elseif v.operator in ["in", "not in"]
    if isa(placeholders, String)
      return string(column, " ", v.operator == "in" ? "= ANY" : "<> ALL", "(", placeholders, ")")
    elseif isa(placeholders, AbstractArray)
      return string(column, " ", v.operator, " (", join(placeholders, ", "), ")")
    else
      throw("Error in operator: $(v.operator), the value must be a String or a Vector of Strings")
    end
  elseif v.operator in ["contains", "icontains"]
    # @infiltrate
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
  if v.operation === nothing
    @infiltrate
    @error "Operation is nothing, this is not a valid SQLTypeF"
  else
    # Field with operation
    @infiltrate false
    left_side = _get_select_query(_check_function(v.field_name), instruc)
    
    right_side = if isa(v.operand, SQLTypeF)
      _get_select_query(_check_function(v.operand.field_name), instruc)
    else
      @infiltrate
      @error "Operand is not a SQLTypeF: $(typeof(v.operand))"
    end
    
    return "($(left_side) $(v.operation) $(right_side))"
  end
end


"""
  get_filter_query(object::SQLObject, instruc::SQLInstruction)

  Iterates over the filter of the object and generates the WHERE query for the given SQLInstruction object.

  #### ALERT
  - This internal function is called by the `build` function.

  #### Arguments
  - `object::SQLObject`: The object containing the filter to be selected.
  - `instruc::SQLInstruction`: The SQLInstruction object to which the WHERE query will be added.
"""
function get_filter_query(object::SQLObject, instruc::SQLInstruction)::Nothing 
  # [isa(v, Union{SQLTypeQor, SQLTypeQ, SQLTypeOper}) ? push!(instruc._where, _get_filter_query(v, instruc)) : throw("Error in values, $(v) is not a SQLTypeQor, SQLTypeQ or SQLTypeOper") for v in object.filter]
  @infiltrate false
  for v in object.filter
    if isa(v, SQLTypeOper)
      @infiltrate false
      if isa(v.column, SQLTypeField) && isa(v.column.field, String) && !contains(v.column.field, "__") && !(v.column.field in instruc.object.model.field_names)
        # @infiltrate false
        field = instruc.cache[v.column._as].field
        if haskey(instruc.tab_field_cache, v.column._as)
          _validation = instruc.tab_field_cache[instruc.cache[v.column._as]._as]
        else
          _validation = IntegerField()
        end
        push!(instruc.having, "$(field) $(v.operator) $(_validation.formater(v.values))")
        return nothing
      end
      push!(instruc._where, _get_filter_query(v, instruc))
    elseif isa(v, Union{SQLTypeQor, SQLTypeQ, SQLTypeF})
      push!(instruc._where, _get_filter_query(v, instruc))
    else      
      throw("Error in values, $(v) is not a SQLTypeQor, SQLTypeQ or SQLTypeOper")
    end
  end  
  return nothing
end

function build_row_join_sql_text(instruc::SQLInstruction)
  @infiltrate false
  for value in instruc.row_join
    b_quoted = safe_table_identifier(value["b"], instruc.connection)
    alias_b_quoted = quote_identifier(value["alias_b"], instruc.connection)
    alias_a_quoted = quote_identifier(value["alias_a"], instruc.connection)
    key_a_quoted = quote_identifier(value["key_a"], instruc.connection)
    key_b_quoted = quote_identifier(value["key_b"], instruc.connection)
    push!(instruc.join, """ $(value["how"]) JOIN $b_quoted AS $alias_b_quoted ON $alias_a_quoted.$key_a_quoted = $alias_b_quoted.$key_b_quoted """)
  end
end

function build(object::SQLObject; 
  table_alias::Union{Nothing, SQLTableAlias} = nothing, 
  connection::Union{Nothing, PormGPostgres, SQLite.DB} = nothing,
  parameters::Union{Nothing, PormGPostgresParam} = nothing)
  settings = config[object.model.connect_key]
  connection === nothing && (connection = settings.connections) # TODO -- i need create a mode to handle with pools
  table_alias === nothing && (table_alias = SQLTbAlias())
  parameters === nothing && (parameters = get_parameter(connection))
  instruct = InstrucObject(text = "", 
    object = object,
    table_alias = table_alias === nothing ? SQLTbAlias() : table_alias,
    alias = get_alias(table_alias),
    connection = connection,
    django = settings.django_prefix === nothing ? nothing : settings.django_prefix * "_", # TODO, remover
    parameters = parameters,
  )   
  
  get_select_query(object.values, instruct)
  get_filter_query(object, instruct)
  build_row_join_sql_text(instruct)
  get_order_query(object, instruct)

  @infiltrate false
  
  return instruct
end

# ---
# Pagination functions
#

export page

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

# ---
# Execute the query
#

export query

function query(q::SQLObjectHandler; 
  table_alias::Union{Nothing, SQLTableAlias} = nothing, 
  connection::Union{Nothing, PormGPostgres, SQLite.DB} = nothing,
  parameters::Union{Nothing, PormGPostgresParam} = nothing)
  instruction = build(q.object, table_alias=table_alias, connection=connection, parameters=parameters)
  
  # Quote table name and alias to prevent SQL injection
  safe_table_name = safe_table_identifier(q.object.model.name, instruction.connection)
  safe_alias = quote_identifier(instruction.alias, instruction.connection)
  
  respota = """
    SELECT
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
  q.object.parameters = instruction.parameters
    # $(instruction.agregate && size(instruction.group, 1) > 0 ? "GROUP BY $(join(instruction.group, ", ")) \n" : "") 
    # $(instruction.order |> length > 0 ? "ORDER BY" : "") $(join(instruction.order, ", \n  "))
    # $(q.object.limit !== 0 ? "LIMIT $(q.object.limit) \n" : "")
    # $(q.object.offset !== 0 ? "OFFSET $(q.object.offset) \n" : "")
    # """
  # @info respota
  return respota
end

# ---
# Count or check if exists
#

export do_count, do_exists

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
  
  resposta = """
    SELECT
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
    @infiltrate
    @error "Error in do_exists for model $(q.object.model.name): $e"
    return false
  end
end

function insert(objct::SQLObject; table_alias::Union{Nothing, SQLTableAlias} = nothing, connection::Union{Nothing, PormGPostgres, SQLite.DB} = nothing)
  model = objct.model
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
      integer_part, fractional_part = split(value_str, ".")
      total_digits = length(replace(integer_part, "-" => "")) + length(fractional_part)
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

function _update_sequence(model::PormGModel, connection::PormGPostgres, pk_field::Vector{String}, settings::SQLConn)
  @infiltrate false
  for field in pk_field
    if settings.change_db
      try
        safe_field_name = quote_identifier(field, connection)
        safe_table_name = safe_table_identifier(string(model.name), connection)
        fetch(connection, "SELECT setval('$(string(model.name))_$(field)_seq', (SELECT MAX($(safe_field_name)) + 1 FROM $(safe_table_name)), true);")
      catch e
        if occursin("does not exist", e |> string)        
          _fix_sequence_name(connection, model)
          safe_table_name = safe_table_identifier(string(model.name), connection)
          safe_field_name = quote_identifier(field, connection)
          fetch(connection, "SELECT setval('$(string(model.name))_$(field)_seq)', (SELECT MAX($safe_field_name) + 1 FROM $safe_table_name), true);")
        end
      end
    elseif settings.django_prefix !== nothing
      @infiltrate
      try
        # For Django prefixed tables, try with django prefix pattern
        sequence_name = "$(model.name)_$(field)_seq"
        safe_table_name = safe_table_identifier(model.name, connection)
        safe_field_name = quote_identifier(field, connection)
        fetch(connection, "SELECT setval('$sequence_name', (SELECT MAX($safe_field_name) + 1 FROM $safe_table_name), true);")
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

function _fix_sequence_name(connection::PormGPostgres, model::PormGModel) # TODO maby i need use Migration get_sequence_name aproach
  pk_field = [field for field in keys(model.fields) if model.fields[field].primary_key]
  sequences = fetch(connection, """SELECT *
      FROM pg_sequences
      WHERE sequencename LIKE '$(model.name |> lowercase)%';""") |> DataFrames.DataFrame  
  for (index, row) in enumerate(eachrow(sequences))
    if index == 1 && row.sequencename != "$(model.name |> lowercase)_$(pk_field[1])_seq"
      if length(pk_field) == 0
        throw("Error in _fix_sequence_name, the model $(model.name) does not have a primary key")
      elseif length(pk_field) > 1
        throw("Error in _fix_sequence_name, the model $(model.name) has more than one primary key")
      end
      fetch(connection, "ALTER SEQUENCE $(row.sequencename) RENAME TO $(model.name |> lowercase)_$(pk_field[1])_seq;")
    else
      fetch(connection, "DROP SEQUENCE $(row.sequencename);")
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

function _build_from_tables(row_join::Vector{Dict{String, Any}}, connection)
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
function _build_join_conditions(row_join::Vector{Dict{String, Any}}, connection)
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

function update(objct::SQLObject; table_alias::Union{Nothing, SQLTableAlias} = nothing, connection::Union{Nothing, PormGPostgres, SQLite.DB} = nothing)
  model = objct.model
  settings = config[model.connect_key]
  connection === nothing && (connection = settings.connections) # TODO -- i need create a mode to handle with pools and create a function to this
 
  instruction = build(objct, table_alias=table_alias, connection=connection) 

  # raize error if is used join in update
  instruction.row_join |> isempty || throw("Error in update, the join is not allowed in update")
  # check if is allowed to insert
  !settings.change_data && throw(ArgumentError("Error in update, the connection \e[4m\e[31m$(model.connect_key)\e[0m not allowed to update"))
  # don't allow to update a field without filter
  instruction._where |> isempty && throw("Error in update, the update must have a filter")
  
  # Create parameter collection
  parameters = instruction.parameters  # Reuse parameters from filters

  # colect name of the fields
  fields = model.field_names

  # check if the fields need to be updated automatically
  for field in fields
    if !haskey(objct.insert, field)
      # check if field allow null or if exist a default value
      if model.fields[field].type == "TIMESTAMPTZ" && (model.fields[field].auto_now)
        objct.insert[field] = model.fields[field].formater(now(), settings.time_zone)
      elseif model.fields[field].type == "DATE" && (model.fields[field].auto_now)
        objct.insert[field] = model.fields[field].formater(today())
      end
    end
  end

  # check if the fields are in objct.insert
  # Handle F expressions in SET clause
  set_clause_parts = String[]
  for field in keys(objct.insert)    
    # check if the create has a field that not exist in the model
    in(field, fields) || throw("""Error in update, the field "$(field)" not found in $(model.name)""")
    # check if field is a primary key and not allow to update
    model.fields[field].primary_key && throw("Error in update, the field \e[4m\e[31m$(field)\e[0m is a primary key and not allow to update")
    # check if the field has max_length and validate
    hasfield(typeof(model.fields[field]), :max_length) && length(objct.insert[field]) > model.fields[field].max_length && error("""Error in update, the field \e[4m\e[31m$(field)\e[0m has a max_length of \e[4m\e[32m$(model.fields[field].max_length)\e[0m, but the value has \e[4m\e[31m$(length(objct.create[field]))\e[0m""")
    # check if the field has max_digits and validate
    if hasfield(typeof(model.fields[field]), :max_digits)
      value_str = string(objct.insert[field])
      integer_part, fractional_part = split(value_str, ".")
      total_digits = length(replace(integer_part, "-" => "")) + length(fractional_part)
      if total_digits > model.fields[field].max_digits
        error("""Error in update, the field \e[4m\e[31m$(field)\e[0m has a max_digits of \e[4m\e[32m$(model.fields[field].max_digits)\e[0m, but the value has \e[4m\e[31m$(total_digits)\e[0m""")
      end
    end
    
    quoted_field = quote_identifier(field, connection)

    if isa(objct.insert[field], SQLTypeF)     
      @infiltrate false
      f_value = _set_update_query(objct.insert[field], instruction)
      push!(set_clause_parts, "$(quoted_field) = $(f_value)")
    else
      formatted_value = objct.insert[field] |> model.fields[field].formater
      placeholder = add_parameter!(parameters, formatted_value)
      push!(set_clause_parts, "$(quoted_field) = $(placeholder)")
    end
  end
   
  set_clause = join(set_clause_parts, ", ")   

  # --- NEW: Support FROM clause for PostgreSQL ---
  @infiltrate false
  has_joins = !isempty(instruction.row_join)
  sql = ""
  # Build secure UPDATE SQL
  safe_table_name = safe_table_identifier(string(model.name), connection)
  safe_alias = quote_identifier(instruction.alias, connection)
  if has_joins
    if connection isa PormGPostgres
      from_tables = _build_from_tables(instruction.row_join, connection)
      join_conditions = _build_join_conditions(instruction.row_join, connection)
      all_conditions = isempty(instruction._where) ? join_conditions :
          join([join_conditions, join(instruction._where, " AND ")], " AND ")
      @infiltrate false
      sql = """
      UPDATE $(safe_table_name) AS $(safe_alias)
      SET $(set_clause)
      FROM $(from_tables)
      WHERE $(all_conditions)
      """
    else
      @error "Error in update: JOINs in UPDATE are only supported in PostgreSQL"
      throw("Error in update: JOINs in UPDATE are only supported in PostgreSQL")
    end
  else
    sql = """
    UPDATE $(safe_table_name) as $(safe_alias)
    SET $(set_clause)
    WHERE $(join(instruction._where, " AND \n   "))
    """
  end

  # @info sql

  @infiltrate false

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

  return nothing
end



export list
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
function list(objct::SQLObjectHandler)
  if objct.object.model.connect_key === nothing
    throw(ArgumentError("Error in list, the model \e[4m\e[31m$(objct.object.model.name)\e[0m not have a build correctly, please reload the app"))
  end
  settings = config[objct.object.model.connect_key]
  connection = settings.connections

  sql = query(objct, connection=connection)
  @infiltrate false
  return fetch(settings, sql, objct.object.parameters) 
end

# ---
# Execute bulk insert and update
#

export bulk_insert

"""
Inserts multiple rows into the database in bulk from a DataFrame.

  #### Arguments
  - `objct::SQLObjectHandler`: The SQL object handler to use for the operation.
  - `df::DataFrames.DataFrame`: The DataFrame containing the data to be inserted.
  - `columns::Vector{Union{String, Pair{String, String}}}`: Optional. Specifies the columns to insert and their mappings.
  - `chunk_size::Integer`: Optional. The number of rows to insert in each batch (default: 1000).
  - `show_query::Bool`: Optional. If true, prints the generated SQL query (default: false).
  - `copy::Bool`: Optional. If true, creates a copy of the DataFrame before processing (default: false).

  #### Examples
  ```julia
  include("models.jl")
  import models as mdl

  # Basic usage
  query = mdl.User |> object
  df = DataFrame(name=["Alice", "Bob"], age=[30, 25])
  bulk_insert(query, df)

  # With column mapping and excluding unwanted variables
  query = mdl.Boook |> object
  df = DataFrame(title=["Book A", "Book B"], author_name=["Alice", "Bob"], year=[2020, 2021], ignore_me=["x", "y"])
  # Map DataFrame column "author_name" to model field "author"
  # Exclude "ignore_me" by not including it in the columns argument
  bulk_insert(query, df, columns=["title", "year", "author_name" => "author"])
  # the df will be modified to only include the columns "title", "year", and "author_name" (renamed to "author").

  # If you want to copy the DataFrame before processing, set `copy=true`:
  bulk_insert(query, df, columns=["title", "year", "author_name" => "author"], copy=true)
    
  ```
"""
function bulk_insert(objct::SQLObjectHandler, df_o::DataFrames.DataFrame; 
    columns::Vector{Union{String, Pair{String, String}}} = Union{String, Pair{String, String}}[], 
    chunk_size::Integer = 1000,
    show_query::Bool = false,
    copy::Bool = false
  ) 
  model = objct.object.model
  settings = config[model.connect_key]
  connection = settings.connections
  django_prefix = settings.django_prefix === nothing ? false : true

  

  # check if is allowed to insert
  !settings.change_data && throw(ArgumentError("Error in bulk_insert, the connection \e[4m\e[31m$(model.connect_key)\e[0m not allowed to insert"))

  # If no rows then nothing to do
  if size(df_o, 1) == 0
    @warn("Warning in bulk_insert, the DataFrame is empty")
    return nothing
  end

  df = copy ? deepcopy(df_o) : df_o 

  # colect name of the fields
  fields = model.field_names
  fields_df::Vector{String} = []
  if !isempty(columns)   
    if length(columns) > 0
      for column in columns
        if column isa Pair
          if !(column.first in df |> names)
            @error("""Error in bulk_insert, the column \e[4m\e[31m$(column.first)\e[0m not found in the DataFrame, the dataframe has the columns: \e[4m\e[32m$(names(df))\e[0m""")
          end
          if column.second in df |> names
            DataFrames.select!(df, DataFrames.Not(column.second |> Symbol))
          end
          DataFrames.rename!(df, column.first => column.second)
          push!(fields_df, column.second)
        else
          push!(fields_df, column)
        end
      end
    end
  else
    for field in names(df)
      fld_ = field |> lowercase
      if fld_ in fields
        push!(fields_df, fld_)
      end
      if fld_ != field
        DataFrames.rename!(df, field => fld_)
      end
    end    
  end  

  # check if missing fields in fields_df are not null or dont have a default value
  pk_exist::Bool = false
  pk_field::Vector{String} = []
  @infiltrate false
  for field in fields
    if in(field, fields_df)
      if model.fields[field].default !== nothing
        df[!, field] = map(x -> x |> ismissing ? model.fields[field].default : x, df[!, field])
      elseif model.fields[field].type == "TIMESTAMPTZ" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        df[!, field] = map(x -> x |> ismissing ? model.fields[field].default : x, df[!, field])
      elseif model.fields[field].type == "DATE" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        df[!, field] = map(x -> x |> ismissing ? model.fields[field].default : x, df[!, field])
      elseif !model.fields[field].null
        if any(ismissing, df[!, field]) || any(isnothing, df[!, field])
          throw(ArgumentError("Error in bulk_insert, the field \e[4m\e[31m$(field)\e[0m not allow null but contains missing/nothing values"))
        end
      elseif model.fields[field].primary_key
        pk_exist = true
      end
    else
      if model.fields[field].default !== nothing
        df[!, field] = map(x -> model.fields[field].default, df[!, fields_df[1]])
        push!(fields_df, field)
      elseif model.fields[field].type == "TIMESTAMPTZ" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        df[!, field] = map(x -> x |> ismissing ? model.fields[field].default : x, df[!, fields_df[1]])
        push!(fields_df, field)
      elseif model.fields[field].type == "DATE" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        df[!, field] = map(x -> x |> ismissing ? model.fields[field].default : x, df[!, fields_df[1]])
        push!(fields_df, field)
      elseif model.fields[field].primary_key
        continue
      elseif !model.fields[field].null
        throw(ArgumentError("Error in bulk_insert, the field \e[4m\e[31m$(field)\e[0m not allow null but contains missing/nothing values"))      
      end
    end   
  end 

  @infiltrate false
  
  # check if the fields_df are not in fields
  for field in fields_df
    in(field, fields) || throw("""Error in bulk_insert, the field \e[4m\e[31m$(field)\e[0m not found in \e[4m\e[32m$(model.name)\e[0m""")
  end
   
  # Build a list of row value strings by applying each model field formatter.
  rows = String[]
  count::Integer = 0
  total::Integer = size(df, 1)
  # Security: Create parameterized query
  parameters = get_parameter(connection)
  param_placeholders::Vector{String} = String[]
  for (index, row) in enumerate(eachrow(df))
    values = String[]
    try
      param_placeholders = [add_parameter!(parameters, model.fields[field].formater(row[field])) for field in fields_df]
      # param_placeholders = add_parameter!(parameters, values)
    catch e
      @infiltrate false
      _depuration_values_bulk_insert(fields_df, model, row, index, django_prefix)
      throw("Error in bulk_update, the row $(index) has a problem: $(e)")
    end
    push!(rows, "($(join(param_placeholders, ", ")))")
    count += 1
    if count == chunk_size || index == total
      # @infiltrate
      _bulk_insert(model, connection, fields_df, rows, pk_exist, pk_field, settings, django_prefix, show_query, parameters)
      count = 0
      rows = String[]
      parameters = get_parameter(connection)
      param_placeholders = String[]
    end
  end  

  return nothing
  
end

function _depuration_values_bulk_insert(fields::Vector{String}, model::PormGModel, row::DataFrames.DataFrameRow, index::Integer, django_prefix::Bool)
  for field in fields
    # Check if field exists in the row before trying to format it
    if !(field in names(row))
      return nothing
    end
    try
      model.fields[field].formater(row[field])
    catch e
      throw(ArgumentError("Error in bulk_insert, the field \e[4m\e[31m$(field)\e[0m in row \e[4m\e[31m$(index)\e[0m has a value that can't be formatted: \e[4m\e[31m$(row[field])\e[0m"))
    end
  end  
end

function _bulk_insert(model::PormGModel, connection::PormGPostgres, 
  fields::Vector{String}, rows::Vector{String}, 
  pk_exist::Bool, pk_field::Vector{String}, settings::SQLConn, 
  django_prefix::Bool, show_query::Bool, parameters:: PormGPostgresParam)

  # Security: Quote table name and field names
  safe_table_name = safe_table_identifier(string(model.name), connection)
  quoted_fields = [quote_identifier(field, connection) for field in fields]
  
  # Construct the bulk insert SQL.
  sql = """
  INSERT INTO $(safe_table_name) ($(join(quoted_fields, ", ")))
  VALUES $(join(rows, ", "))
  """

  # Execute the query or just show it
  if show_query
    @info sql
  else
    # Execute the query for the given connection type.
    if connection isa PormGPostgres
      try
        fetch(settings, sql, parameters)
      catch e
        if occursin("duplicate key value violates unique constraint", e |> string)
          _update_sequence(model, connection, pk_field, settings)
          throw("Error in bulk_insert, the row has a duplicate key value")
        elseif occursin("violates foreign key constraint", e |> string)
          throw("Error in bulk_insert, the row has a foreign key constraint")
        else
          throw(e)
        end
      end
    elseif connection isa SQLite.DB
      SQLite.execute(connection, sql)
    else
      throw("Unsupported connection type")
    end

    pk_exist && _update_sequence(model, connection, pk_field, settings)
  end
end

export bulk_update

"""
Performs a bulk update operation on a database table using the provided `DataFrame` and a query object.

# Arguments
- `objct::SQLObjectHandler`: The database handler object.
- `df::DataFrames.DataFrame`: The DataFrame containing the data to be used for the update.
- `columns`: (Optional) Specifies which columns to update. Can be a `String`, a `Pair{String, String}`, or a `Vector` of these. If `nothing`, no columns are specified.
- `filters`: (Optional) Specifies the filters to apply for the update. Can be a `String`, a `Pair{String, T}` where `T` is `String`, `Integer`, `Bool`, `Date`, or `DateTime`, or a `Vector` of these. If `nothing`, no filters are applied.
- `show_query::Bool`: (Optional) If `true`, prints the generated SQL query. Defaults to `false`.
- `chunk_size::Integer`: (Optional) Number of rows to process per chunk. Defaults to `1000`.

# Example
```julia
# Update the columns of the DataFrame df if df contains the primary key of the table
bulk_update(objct, df)
# Update the name and dof columns for the security_id in the DataFrame df
bulk_update(objct, df, columns=["security_id", "name", "dof"], filters=["security_id"])
```
"""
function bulk_update(objct::SQLObjectHandler, df::DataFrames.DataFrame; 
    columns=nothing, # what columns to update
    filters=nothing, # what columns to do the filter
    show_query::Bool=false, 
    chunk_size::Integer=1000)

  _columns::Vector{Union{String, Pair{String, String}}} = []
  _filters::Vector{Union{String, Pair{String, <:Union{String, Integer, Bool, Date, DateTime}}}} = []
  if columns === nothing
  elseif columns isa AbstractString
    push!(_columns, columns)
  elseif columns isa Pair{String, String}
    push!(_columns, columns)
  elseif columns isa Vector
    for column in columns
      if column isa AbstractString
        push!(_columns, column)
      elseif column isa Pair{String, String}
        push!(_columns, column)
      else
        throw("Error in bulk_update, the columns must be a String or a Pair{String, String}")
      end
    end
  else
    throw("Error in bulk_update, the columns must be a String or a Pair{String, String}")
  end

  if filters === nothing
  elseif filters isa AbstractString
    push!(_filters, filters)
  elseif filter isa Pair{String, <:Union{String, Integer, Bool, Date, DateTime}}
    push!(_filters, filters)
  elseif filters isa Vector
    for filter in filters
      if filter isa AbstractString
        push!(_filters, filter)
      elseif filter isa Pair{String, <:Union{String, Integer, Bool, Date, DateTime}}
        push!(_filters, filter)
      else
        throw("Error in bulk_update, the filters must be a String or a Pair{String, T} where T<:Union{String, NumIntegerber, Bool, Date, DateTime}")
      end
    end
  else
    throw("Error in bulk_update, the filters must be a String or a Pair{String, T} where T<:Union{String, Integer, Bool, Date, DateTime}")
  end

  _bulk_update(objct, df, _columns, _filters, show_query, chunk_size)
  
end

function _bulk_update(objct::SQLObjectHandler, df::DataFrames.DataFrame,
  columns::Vector{Union{String, Pair{String, String}}},
  filters::Vector{Union{String, Pair{String, <:Union{String, Integer, Bool, Date, DateTime}}}},
  show_query::Bool,
  chunk_size::Integer=1000)

  model = objct.object.model
  settings = config[model.connect_key]
  connection = settings.connections

  # check if is allowed to insert
  !settings.change_data && throw(ArgumentError("Error in bulk_update, the connection \e[4m\e[31m$(model.connect_key)\e[0m not allowed to update"))

  # If no rows then nothing to do
  if size(df, 1) == 0
    @warn("Warning in bulk_update, the DataFrame is empty")
    return nothing
  end

  # colect name of the fields
  fields = model.field_names
  fields_df::Vector{String} = []
  if !isempty(columns)   
    if length(columns) > 0
      for column in columns
        if column isa Pair
          if !(column.first in df |> names)
            @error("""Error in bulk_update, the column \e[4m\e[31m$(column.first)\e[0m not found in the DataFrame, the dataframe has the columns: \e[4m\e[32m$(names(df))\e[0m""")
          end
          if column.second in df |> names
            DataFrames.select!(df, DataFrames.Not(column.second |> Symbol))
          end
          DataFrames.rename!(df, column.first => column.second)
          push!(fields_df, column.second)
        else
          push!(fields_df, column)
        end
      end
    end
  else
    for field in names(df)
      fld_ = field |> lowercase
      if fld_ in fields
        push!(fields_df, fld_)
      end
      if fld_ != field
        DataFrames.rename!(df, field => fld_)
      end
    end    
  end  

  # check if missing fields in fields_df are updated automatically
  pk_exist::Bool = false
  pk_field::Vector{String} = []
  for field in fields
    if in(field, fields_df)
      if model.fields[field].default !== nothing
        df[!, field] = map(x -> x |> ismissing || x |> isnothing ? model.fields[field].default : x, df[!, field])
      elseif model.fields[field].type == "TIMESTAMPTZ" && model.fields[field].auto_now
        df[!, field] = map(x -> x |> ismissing || x |> isnothing ? model.fields[field].default : x, df[!, field])
      elseif model.fields[field].type == "DATE" && model.fields[field].auto_now
        df[!, field] = map(x -> x |> ismissing || x |> isnothing ? model.fields[field].default : x, df[!, field])
      elseif !model.fields[field].null
        if any(ismissing, df[!, field]) || any(isnothing, df[!, field])
          throw(ArgumentError("Error in bulk_update, the field \e[4m\e[31m$(field)\e[0m not allow null but contains missing/nothing values"))
        end
      elseif model.fields[field].primary_key
        pk_exist = true
        push!(pk_field, field)
      end
    else
      if model.fields[field].type == "TIMESTAMPTZ" && model.fields[field].auto_now
        df[!, field] = map(x -> x |> ismissing || x |> isnothing ? model.fields[field].default : x, df[!, fields_df[1]])
        push!(fields_df, field)
      elseif model.fields[field].type == "DATE" && model.fields[field].auto_now
        df[!, field] = map(x -> x |> ismissing || x |> isnothing ? model.fields[field].default : x, df[!, fields_df[1]])
        push!(fields_df, field)     
      end
    end   
  end  

  # colect the filters
  pks = [field for field in keys(model.fields) if model.fields[field].primary_key]
  dinanic_filters::Vector{String} = []
  static_filters::Vector{Pair{String, Any}} = []
  if !isempty(filters)
    for filter in filters
      if filter isa Pair
        push!(static_filters, filter)
      else
        push!(dinanic_filters, filter)
        filter in fields_df || push!(fields_df, filter)
      end
    end
  else
    dinanic_filters = pks    
  end  

  objct.object.filter = [] # clear the filters
  if size(static_filters, 1) > 0
    for filter in static_filters
      objct.filter(filter)
    end    
  end
  instruction = build(objct.object, connection=connection) 

  @infiltrate false

  # check if the fields_df are not in fields
  for field in fields_df
    in(field, fields) || @error("""Error in bulk_update, the field \e[4m\e[31m$(field)\e[0m not found in \e[4m\e[32m$(model.name)\e[0m""")
  end

  # Build a list of row value strings by applying each model field formatter.
  rows = String[]
  # deny_fields = vcat(pks, dinanic_filters, [filter.first for filter in static_filters]) |> unique # colect all keys that are not allowed/need to update
  deny_fields = vcat(dinanic_filters, [filter.first for filter in static_filters]) |> unique # colect all keys that are not allowed/need to update
  # set_columns = join([ "$(field) = source.$(field)::$(model.fields[field].type |> lowercase)" for field in fields_df if !(field in deny_fields) ], ", ")

  # Security: Build safe SET clause with quoted identifiers
  safe_set_parts = []
  for field in fields_df
    if !(field in deny_fields)
      # @infiltrate
      quoted_field = quote_identifier(field, connection)
      quoted_source_field = quote_identifier(field, connection)
      field_type = model.fields[field].type |> lowercase
      push!(safe_set_parts, "$quoted_field = source.$quoted_source_field::$field_type")
    end
  end
  safe_set_clause = join(safe_set_parts, ", ")

  count::Integer = 0
  total::Integer = size(df, 1)
  @infiltrate false
  # Security: Create parameterized query
  parameters_initial =  deepcopy(instruction.parameters)
  param_placeholders::Vector{String} = String[]
  joined_columns = unique(vcat(fields_df, dinanic_filters))

  for (index, row) in enumerate(eachrow(df))
    values = String[]    
    try
      param_placeholders = [add_parameter!(instruction.parameters, model.fields[field].formater(row[field])) for field in joined_columns]
      # param_placeholders = add_parameter!(instruction.parameters, values)
    catch e
      _depuration_values_bulk_insert(fields_df, model, row, index, settings.django_prefix !== nothing)
      throw("Error in bulk_update, the row $(index) has a problem: $(e)")
    end
    push!(rows, "($(join(param_placeholders, ", ")))")
    count += 1
    if count == chunk_size || index == total      
      _bulk_update(model, settings, connection, joined_columns, rows, safe_set_clause, dinanic_filters, show_query, instruction)
      count = 0
      rows = String[]
      instruction.parameters = deepcopy(parameters_initial) # reset parameters to initial state
      param_placeholders = String[]
    end
  end

  return nothing
  
end

function _bulk_update(model::PormGModel,
  settings::SQLConn,
  connection::PormGPostgres, 
  fields::Vector{String}, 
  rows::Vector{String}, 
  safe_set_clause::String, 
  dinanic_filters::Vector{String}, 
  show_query::Bool,
  instruction::Union{SQLInstruction, Nothing})

  @infiltrate false
  if instruction !== nothing && instruction.join |> length > 0
    throw("Error in bulk_update, the join is not allowed in bulk_update")
  end

  # Security: Quote table name and field names
  safe_table_name = safe_table_identifier(model.name, connection)
  quoted_fields = [quote_identifier(field, connection) for field in fields]

  # Security: Build safe WHERE conditions with quoted identifiers
  safe_where_conditions::Vector{String} = []
  for filter in dinanic_filters
    quoted_tb_field = quote_identifier(filter, connection)
    quoted_source_field = quote_identifier(filter, connection)
    field_type = model.fields[filter].type |> lowercase
    push!(safe_where_conditions, "\"Tb\".$quoted_tb_field = source.$quoted_source_field::$field_type")
  end
  # # Construct the bulk update SQL.
  # _where::Vector{String} = []
  # for filter in dinanic_filters
  #   push!(_where, "Tb.$(filter) = source.$(filter)::$(model.fields[filter].type |> lowercase)")
  # end
  if instruction !== nothing    
    for filter in instruction._where
      push!(safe_where_conditions, filter)
    end
  end

  sql = """
  UPDATE $safe_table_name AS "Tb"
  SET $(safe_set_clause)
  FROM (VALUES $(join([join(split(row, ", "), ", ") for row in rows], ","))) AS source ($(join(quoted_fields, ",")))
  WHERE $(join(safe_where_conditions, " AND \n   "))
  """

  @infiltrate false

  if show_query 
    @info sql
  else 
    # Execute the query for the given connection type.
    # @infiltrate false
    fetch(connection, sql, instruction.parameters)
  end  
end

# ---
# Django like function to build a delete query with cascade, restrict, set null, set default and set value (AI please don't delete this code)
#


import PormG: CASCADE, RESTRICT, SET_NULL, SET_DEFAULT, SET, PROTECT

export delete

mutable struct DeletionCollector{T}
  model::PormGModel  # The main model being deleted from
  settings::SQLConn  # Connection settings
  connection::Union{PormGPostgres, SQLite.DB}  # Database connection
  objects::Dict{PormGModel, Vector{Dict{Symbol, T}}}  # Models and their objects to delete
  dependencies::Dict{PormGModel, Set{PormGModel}}  # Model dependencies
  field_updates::Dict{Tuple{String, Any}, Dict{PormGModel, Dict{Symbol, T}}}  # Field updates for SET_NULL etc.
  fast_deletes::Dict{PormGModel, Vector{Dict{Symbol, T}}}  # Objects that can be deleted directly
  sorted_models::Vector{PormGModel}  # Models in deletion order
  
  DeletionCollector(model, settings) = new{Union{String, SQLObjectHandler}}(
    model,
    settings,
    settings.connections,
    Dict{PormGModel, Vector{Dict{Symbol, Union{String, SQLObjectHandler}}}}(),
    Dict{PormGModel, Set{PormGModel}}(),
    Dict{Tuple{String, Any}, Dict{PormGModel, Dict{Symbol, String}}}(),
    Dict{PormGModel, Dict{Symbol, String}}(),
    Vector{PormGModel}()
  )
end

"""
Delete objects from the database with proper handling of foreign key relationships and cascading operations.

## Arguments
- `objct::SQLObjectHandler`: The SQL object handler containing the query and model information
- `show_query::Bool=false`: If `true`, displays the generated SQL queries instead of executing them
- `allow_delete_all::Bool=false`: If `true`, allows deletion without WHERE clause filters (dangerous operation)

## Returns
- `Tuple{Integer, Dict{String, Integer}}`: A tuple containing:
  - Total number of deleted objects
  - Dictionary mapping model names to their respective deletion counts

## Behavior
- Validates that the connection allows data modification operations
- Requires WHERE clause filters unless `allow_delete_all` is explicitly set to `true`
- Handles foreign key relationships by building a deletion dependency graph
- Processes SET_NULL, SET_DEFAULT, and cascading delete operations appropriately
- Executes all operations within a database transaction for data integrity

## Examples

```julia
# Delete objects from a model with a specific filter
query = M.Status |> object
query.filter("status" => "Engine")
total, dict = delete(query)

# Show the SQL query without executing it
query = M.Just_a_test_deletion |> object
query.filter("test_result__constructorid__name" => "Williams")
total, dict = delete(query, show_query = true)

# Delete related tables (cascading delete)
query = M.Result |> object
query.filter("resultid" => 1)
total, dict = delete(query, show_query = false)

# Delete all objects from a model (use with caution)
query = M.Just_a_test_deletion |> object
total, dict = delete(query; allow_delete_all = true)


```
"""
function delete(objct::SQLObjectHandler; 
    table_alias::Union{Nothing, SQLTableAlias} = nothing, 
    connection::Union{Nothing, PormGPostgres, SQLite.DB} = nothing, 
    show_query::Bool = false,
    allow_delete_all::Bool = false)
  model = objct.object.model
  settings = config[model.connect_key]
  connection === nothing && (connection = settings.connections) # TODO -- i need create a mode to handle with pools and create a function to this
    
  # check if is allowed to delete
  !settings.change_data && throw(ArgumentError("Error in delete, the connection \e[4m\e[31m$(model.connect_key)\e[0m not allowed to delete"))

  # don't allow to delete without filter
  !allow_delete_all && objct.object.filter  |> isempty && throw("Error in delete, the delete must have a filter")
  
  # If no objects to delete, return early
  if objct |> !do_exists
    return 0, Dict{String, Integer}()
  end

  # We'll track deletion counts
  deleted_counter = Dict{String, Integer}()
  
  # Collect related models that need special handling
  collector = DeletionCollector(model, settings)
  
  # Add the primary objects to delete
  add_objects_to_collector!(collector, objct |> deepcopy, model)
  
  # Build and sort the deletion graph
  process_collector!(collector)

  @infiltrate false
 
  # Execute the deletion in a transaction
  if connection isa PormGPostgres
    @infiltrate false
    # Start transaction
    # TODO: Check if the connection is in a transaction already
    # TODO: deal with connection pools
    if show_query 
      conn = nothing
    else
      result, conn = with_transaction(settings, "BEGIN;")
    end
    
    try
      # Process fast deletes first (objects that can be deleted directly)
      for (model, keys) in collector.fast_deletes
        delete_objects(connection, model, keys, show_query, deleted_counter, conn)
        # Remove from objects to prevent double deletion
        delete!(collector.objects, model)
      end

      
      # Process field updates (for SET_NULL, SET_DEFAULT, etc.)
      for ((field, value), affected_models) in collector.field_updates
        @infiltrate false
        for (affected_model, keys) in affected_models
          update_field(connection, affected_model, field, value, keys, show_query, conn)
        end
      end
      
      # Execute deletions in the sorted order
      for model_to_delete in collector.sorted_models
        @infiltrate false
        _array = get(collector.objects, model_to_delete, [])        
        if !isempty(_array)
          @infiltrate false
          delete_objects(connection, model_to_delete, _array, show_query, deleted_counter, conn)
        end
      end
        
      # Commit transaction
      show_query || with_transaction(settings, "COMMIT;", conn=conn, release_conn=true)
    catch e
      # Rollback on error
      show_query || with_transaction(settings, "ROLLBACK;", conn=conn, release_conn=true)
      rethrow(e)
    end
  else
    # Similar implementation for SQLite
    # ...
  end

  total_deleted = sum(values(deleted_counter))
  if total_deleted == 0
    @warn("Warning in delete, no objects were deleted")  
  end
  
  return total_deleted, deleted_counter
end

function add_objects_to_collector!(collector::DeletionCollector, objct::SQLObjectHandler, model::PormGModel)
  # Extract IDs from objects - handle NamedTuples or Dict structures
  @infiltrate false
  pk_field = get_model_pk_field(model) |> string |> lowercase
  objct.values(pk_field);
  add_objects_to_collector!(collector, model, pk_field, objct)
end


function add_objects_to_collector!(collector::DeletionCollector, model::PormGModel, key::String, objct::SQLObjectHandler)
  # Add to collector
  # @info objct |> query
  @infiltrate false
  if !haskey(collector.objects, model)
    collector.objects[model] = []
  end
 
  push!(collector.objects[model], Dict(:key => key, :objct => objct))
  
  # Add model to the list of models to process
  if !haskey(collector.dependencies, model)
    collector.dependencies[model] = Set{PormGModel}()
  end
end


function process_collector!(collector::DeletionCollector)
  # Process each model and its objects
  for (model, keys) in collector.objects
    # Find related objects through foreign keys    
    find_related_objects!(collector, model, keys)
  end

  # Identify objects that can be fast-deleted
  collect_fast_deletes!(collector)
  
  # Topologically sort models for deletion
  collector.sorted_models = topological_sort(collector.dependencies)
end

function find_related_objects!(collector::DeletionCollector, model::PormGModel, dict::Vector{Dict{Symbol, Union{String, SQLObjectHandler}}})
  # For each foreign key in the model (model has FK -> related_model)
  @infiltrate false
  _django = collector.settings.django_prefix === nothing ? false : true
    
  # For models with foreign keys pointing to this model (related_model has FK -> model)
  for (related_name, (field_name, pk_field, related_model_name, pk_model)) in model.related_objects
    _django && (related_model_name = replace(string(related_model_name), collector.settings.django_prefix * "_" => "") |> Symbol)
    related_model = getfield(model._module, related_model_name |> capitalize_symbol);

    _query = related_model |> object;
    if size(dict, 1) == 1
      _query.filter("$(field_name)__@in" => dict[1][:objct]);
    else
      or_object = Qor("$(field_name)__@in" => dict[1][:objct])
      push!(or_object, "$(field_name)__@in" => dict[1][:objct])
      for (index, dict_) in enumerate(dict)
        if index == 1
          continue # already added
        end
        push!(or_object, "$(field_name)__@in" => dict_[:objct])
      end
      _query.filter(or_object)
    end
    
    @infiltrate false
    _query |> do_exists || continue # No related objects, skip
     
    # @info _query |> query

    # THE ORDER IS correctly set?
    if !haskey(collector.dependencies, related_model)
      collector.dependencies[related_model] = Set{PormGModel}()
    end  
    push!(collector.dependencies[related_model], model)

    _keys = Dict{Symbol, Union{String, SQLObjectHandler}}()
    _keys[:key] = pk_model |> string |> lowercase
    _keys[:objct] = _query    

    field = related_model.fields[String(field_name)]
    handle_on_delete!(collector, field_name, field, model, _keys, related_model)

  end
end

function handle_on_delete!(collector::DeletionCollector, field_name::Union{String, Symbol}, field::PormGField, model::PormGModel, 
  keys::Dict{Symbol, Union{String, SQLObjectHandler}}, related_model::PormGModel)
  @infiltrate false
  if field.on_delete == CASCADE
    pk_field = get_model_pk_field(related_model) |> string |> lowercase
    @infiltrate false
    _query = deepcopy(keys[:objct])
    _query.values(pk_field) 
    _keys = Dict{Symbol, Union{String, SQLObjectHandler}}()
    _keys[:key] = pk_field
    _keys[:objct] = _query
    
    # @info _query |> query
    add_objects_to_collector!(collector, related_model, pk_field, _query) 
    @infiltrate false
    find_related_objects!(collector, related_model, [_keys]) # Recursively find related objects for the related model
  elseif field.on_delete in [PROTECT, RESTRICT]    
    # More descriptive error with field name, constraint type, and sample IDs
    constraint_type = field.on_delete == PROTECT ? "PROTECT" : "RESTRICT"
    throw(ArgumentError("Cannot delete \e[4m\e[31m$(related_model.name)\e[0m because it is referenced by \e[4m\e[31m$(model.name).$(field_name)\e[0m with ON DELETE \e[4m\e[31m$(constraint_type)\e[0m constraint"))
  elseif field.on_delete == SET_NULL
    # TODO : I dont check if this works
    @infiltrate false
    # check if the field allow null
    if !field.null
      throw(ArgumentError("Error in delete, the field \e[4m\e[31m$(field_name)\e[0m not allow null"))
    end

    # Add field update to set field to NULL
    if !haskey(collector.field_updates, (field_name |> string, nothing))
      @infiltrate false
      collector.field_updates[(field_name |> string, nothing)] = Dict{PormGModel, Dict{Symbol, Union{String, SQLObjectHandler}}}()
    end
    
    @infiltrate false
    # Add to field updates using _query object like CASCADE
    pk_field = get_model_pk_field(related_model) |> string |> lowercase
    _query = deepcopy(keys[:objct])
    _query.values(pk_field)
    _keys = Dict{Symbol, Union{String, SQLObjectHandler}}()
    _keys[:key] = pk_field
    _keys[:objct] = _query
    collector.field_updates[(field_name |> string, nothing)][related_model] = _keys

  elseif field.on_delete == SET_DEFAULT
    # TODO : I dont check if this works
    # Add field update to set field to default value
    default_value = field.default
    if !haskey(collector.field_updates, (field_name |> string, default_value))
      collector.field_updates[(field_name |> string, default_value)] = Dict{PormGModel, Dict{Symbol, Union{String, SQLObjectHandler}}}()
    end    
    
    # Add to field updates using _query object like CASCADE
    pk_field = get_model_pk_field(related_model) |> string |> lowercase
    _query = deepcopy(keys[:objct])
    _query.values(pk_field)
    _keys = Dict{Symbol, Union{String, SQLObjectHandler}}()
    _keys[:key] = pk_field
    _keys[:objct] = _query
    @infiltrate
    collector.field_updates[(field_name |> string, default_value)][related_model] = _keys
  end
end

function topological_sort(dependencies::Dict{PormGModel, Set{PormGModel}})
  result = Vector{PormGModel}()
  temp_mark = Set{PormGModel}()
  perm_mark = Set{PormGModel}()
  
  function visit(node)
    if node in temp_mark
      throw(ArgumentError("Circular dependency detected in model relationships"))
    end
    
    if !(node in perm_mark)
      push!(temp_mark, node)
      for dep in get(dependencies, node, Set{PormGModel}())
        visit(dep)
      end
      delete!(temp_mark, node)
      push!(perm_mark, node)
      push!(result, node)
    end
  end
  
  for node in keys(dependencies)
    if !(node in perm_mark)
      visit(node)
    end
  end
  
  return reverse(result)
end

function collect_fast_deletes!(collector::DeletionCollector)
  # Find models that have no dependencies (nothing depends on them)
  
  # First, identify all models that have something depending on them
  models_with_dependents = Set{PormGModel}()  
  # A model is a dependent if it appears as a key in the dependencies dict
  # AND has a non-empty set of dependencies
  for (model, dependencies) in collector.dependencies
    if !isempty(dependencies)
      # This model depends on something, so it's not a leaf node
      push!(models_with_dependents, model)
      
      # Also add the models it depends on (they have dependents)
      union!(models_with_dependents, dependencies)
    end
  end
  
  # Models that can be fast-deleted are those that:
  # 1. Have objects to delete
  # 2. Don't appear in models_with_dependents
  for (model, keys) in collector.objects
    if !(model in models_with_dependents)
      @infiltrate false
      collector.fast_deletes[model] = keys
    end
  end
end

function delete_objects(connection::Union{PormGPostgres, SQLite.DB}, model::PormGModel, keys::Vector{Dict{Symbol, Union{String, SQLObjectHandler}}},
   show_query::Bool, deleted_counter::Dict{String, Integer}, conn::Union{Nothing, LibPQ.Connection})
  @infiltrate false
  # Execute the actual deletion SQL
  _where = String[]
  parameters = get_parameter(connection)
  # @info keys[1][:objct] |> query
  for key in keys
    pk_field = key[:key]
    push!(_where, """"$(pk_field)" IN ($(query(key[:objct], parameters=parameters)))""")
  end
  sql::String = ""
  if size(keys, 1) == 1
    deleted_counter[model.name] = keys[1][:objct] |> do_count
    sql = "DELETE FROM $(model.name |> lowercase) WHERE $(join(_where, " OR "))"
  else
    # TODO : this code has not been tested, I need to check if it works    
    pk_field = get_model_pk_field(model) |> string |> lowercase
    _query = model |> object;
    or_object = Qor("$(pk_field)__@in" => keys[1][:objct])
    for (index, key) in enumerate(keys)
      if index == 1
        continue # already added
      end
      push!(or_object, "$(pk_field)__@in" => key[:objct])
    end
    _query.filter(or_object)
    deleted_counter[model.name] = _query |> do_count
    _query.values(pk_field) # Ensure the query is built
    @infiltrate false
    sql = "DELETE FROM $(model.name |> lowercase) WHERE $(pk_field) IN ($(query(_query, parameters=parameters)))"
  end

  sql == "" && throw("Error in delete, the SQL query is empty, this should not happen")
      
  if show_query
    @info sql
    return deleted_counter  # Return count of deleted objects
  end
  @infiltrate false
  result, conn = with_transaction(connection, sql, conn=conn, params=parameters)
  return deleted_counter  # Return count of deleted objects
end

function update_field(connection::PormGPostgres, model::PormGModel, field::String, value::Any, keys::Dict{Symbol, Union{String, SQLObjectHandler}}, show_query::Bool, conn::Union{Nothing, LibPQ.Connection})
  # Update field values using query object like CASCADE
  @infiltrate false
  pk_field = keys[:key]
  _query = keys[:objct]
  parameters = get_parameter(connection)
  value_sql = value === nothing ? "NULL" : model.fields[field].formater(value)
  sql = "UPDATE $(model.name |> lowercase) SET $(field) = $(value_sql) WHERE $(pk_field) IN ($(query(_query, parameters=parameters)))"
  if show_query
    @info sql
    return
  end
  # LibPQ.execute(connection, sql)
  with_transaction(connection, sql, conn=conn, params=parameters)
end


end