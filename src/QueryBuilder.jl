module QueryBuilder

import DataFrames, Tables
using Dates, TimeZones, Intervals
using SQLite, LibPQ

import PormG.Models: CharField, IntegerField, get_model_pk_field, capitalize_symbol, sForeignKey
import PormG: Dialect, Models
import PormG: config
import PormG: SQLType, SQLConn, SQLInstruction, SQLTypeF, SQLTypeOper, SQLTypeQ, SQLTypeQor, SQLObjectHandler, SQLObject, SQLTableAlias, SQLTypeText, SQLTypeOrder, SQLTypeField, SQLTypeArrays, PormGModel, PormGField, PormGTypeField
import PormG: PormGsuffix, PormGtrasnform
import PormG.Infiltrator: @infiltrate

#
# SQLTypeArrays Objects
#
@kwdef mutable struct SQLArrays <: SQLTypeArrays # TODO -- check if I need to use this
  count::Int64 = 1
  array_string::Array{String, 2} = Array{String, 2}(undef, 20, 3)
  array_int::Array{Int64, 2} = Array{Int64, 2}(undef, 20, 3)
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
  array_join::Array{String, 2} = Array{String, 2}(undef, 30, 8) # array to be used in join query (meaby the best way to do this)
  connection::Union{SQLite.DB, LibPQ.LibPQ.Connection, Nothing} = nothing
  array_defs::SQLTypeArrays = SQLArrays()
  cache::Dict{String, SQLTypeField} = Dict{String, SQLTypeField}()
  django::Union{Nothing, String} = nothing
end

# Store information to decide the name from table alias in subquery
mutable struct SQLTbAlias <: SQLTableAlias
  count::Int64
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
Base.copy(x::SQLTypeText) = SQLTypeText(x.field, x._as)


# Return a field to sql query
mutable struct SQLField <: SQLTypeField
  field::Union{SQLTypeText, SQLTypeF, String}
  _as::Union{String, Nothing}
end
SQLField(field::String; _as::Union{String, Nothing} = nothing) = SQLField(field, _as)
Base.copy(x::SQLTypeField) = SQLField(x.field, x._as)

# Return a order of field to sql query
mutable struct SQLOrder <: SQLTypeOrder
  field::Union{SQLTypeField, String}
  order::Union{Int64, Nothing}
  orientation::String
  _as::Union{String, Nothing}
end
SQLOrder(field::Union{SQLTypeField, String}; order::Union{Int64, Nothing} = nothing, orientation::String = "ASC", _as::Union{String, Nothing} = nothing) = SQLOrder(field, order, orientation, _as)
Base.copy(x::SQLTypeOrder) = SQLOrder(x.field, x.order, x.orientation, x._as)

#
# SQLObject Objects (main object to build a query)
#

mutable struct SQLObjectQuery <: SQLObject
  model::PormGModel
  values::Vector{Union{SQLTypeText, SQLTypeField}}
  filter::Vector{Union{SQLTypeQ, SQLTypeQor, SQLTypeOper}}
  insert::Dict{String, Any} # values to be used to create or insert
  limit::Int64
  offset::Int64
  order::Vector{SQLTypeOrder}
  group::Vector{String}
  having::Vector{String}
  list_joins::Vector{String} # is ther a better way to do this?
  row_join::Vector{Dict{String, Any}}  

  SQLObjectQuery(; model=nothing, values = [],  filter = [], insert = Dict(), limit = 0, offset = 0,
        order = [], group = [], having = [], list_joins = [], row_join = []) =
    new(model, values, filter, insert, limit, offset, order, group, having, list_joins, row_join)
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
- `values::Union{String, Int64, Bool}`: the value(s) to be used with the operator.
- `column::Union{String, SQLTypeF}`: the column to be used with the operator.

"""
@kwdef mutable struct OperObject <: SQLTypeOper
  operator::String
  values::Union{String, Int64, Bool, SQLObjectHandler}
  column::Union{SQLTypeField, SQLTypeF, String, Vector{String}} # Vector{String} is need 
end
OP(column::String, value) = OperObject(operator = "=", values = value, column = SQLField(column))
OP(column::SQLTypeF, value) = OperObject(operator = "=", values = value, column = column)
OP(column::String, operator::String, value) = OperObject(operator = operator, values = value, column = SQLField(column))
OP(column::SQLTypeF, operator::String, value) = OperObject(operator = operator, values = value, column = column)

#
# SQLTypeQ and SQLTypeQor Objects
#

export Q, Qor

@kwdef mutable struct QObject <: SQLTypeQ
  filters::Vector{Union{SQLTypeOper, SQLTypeQ, SQLTypeQor}}
end

@kwdef mutable struct QorObject <: SQLTypeQor
  or::Vector{Union{SQLTypeOper, SQLTypeQ, SQLTypeQor}}
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
  colect = [isa(v, Pair) ? _check_filter(v) : isa(v, Union{SQLTypeQor, SQLTypeQ, SQLTypeOper}) ? v : throw("Invalid argument: $(v); please use a pair (key => value)") for v in x]
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
  colect = [isa(v, Pair) ? _check_filter(v) : isa(v, Union{SQLTypeQor, SQLTypeQ, SQLTypeOper}) ? v : throw("Invalid argument: $(v); please use a pair (key => value)") for v in x]
  return QorObject(or = colect)
end

#
# SQLTypeF Objects (functions from sql)
#

export Sum, Avg, Count, Max, Min, When
@kwdef mutable struct FObject <: SQLTypeF
  function_name::String
  column::Union{String, SQLTypeField, N, Vector{N}, Vector{String}, SQLTypeOper, SQLTypeQ, SQLTypeQor, Vector{M}} where {N <: SQLTypeF, M <: SQLType} # TODO Vector{M} is needed?
  agregate::Bool = false
  _as::Union{String, Nothing} = nothing
  kwargs::Dict{String, Any} = Dict{String, Any}()
end

function Sum(x; distinct::Bool = false)
  return FObject(function_name = "SUM", column = x, agregate = true, kwargs = Dict{String, Any}("distinct" => distinct))
end  
function Avg(x; distinct::Bool = false)
  return FObject(function_name = "AVG", column = x, agregate = true, kwargs = Dict{String, Any}("distinct" => distinct))
end
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

function Cast(x::Union{String, SQLTypeText, SQLTypeF}, type::String)
  return FObject(function_name = "CAST", column = x, kwargs = Dict{String, Any}("type" => type))
end
function Cast(x::Union{String, SQLTypeText, SQLTypeF}, type::PormGField)
  return Cast(x, type.type)
end
function Concat(x::Union{Vector{String}, Vector{N}} where N <: SQLType; output_field::Union{N, String, Nothing} where N <: PormGField = nothing, _as::String="")
  if isa(output_field, PormGField)
    output_field = output_field.type
  end
  return FObject(function_name = "CONCAT", column = x, kwargs = Dict{String, Any}("output_field" => output_field, "as" => _as))
end
function Extract(x::Union{String, SQLTypeF, Vector{String}}, part::String)
  return FObject(function_name = "EXTRACT", column = x, kwargs = Dict{String, Any}("part" => part))
end
function Extract(x::Union{String, SQLTypeF, Vector{String}}, part::String, format::String)
  return FObject(function_name = "EXTRACT", column = x, kwargs = Dict{String, Any}("part" => part, "format" => format))
end
function When(x::NTuple{N, Union{Pair{String, Int64}, Pair{String, String}}} where N; then::Union{String, Int64, Bool, SQLTypeF} = 0, _else::Union{String, Int64, Bool, SQLTypeF, Missing} = missing)
  return When(Q(x), then = then, _else = _else)
end
function  When(x::Union{Pair{String, Int64}, Pair{String, Int64}}; then::Union{String, Int64, Bool, SQLTypeF} = 0, _else::Union{String, Int64, Bool, SQLTypeF, Missing} = missing)
  return FObject(function_name = "WHEN", column = x |> _get_pair_to_oper, kwargs = Dict{String, Any}("then" => then, "else" => _else))
end
function When(x::Union{SQLTypeQ, SQLTypeQor}; then::Union{String, Int64, Bool, SQLTypeF} = 0, _else::Union{String, Int64, Bool, SQLTypeF, Missing} = missing)
  return FObject(function_name = "WHEN", column = x, kwargs = Dict{String, Any}("then" => then, "else" => _else))
end
function When(x::Union{SQLTypeOper, SQLTypeF}; then::Union{String, Int64, Bool, SQLTypeF} = 0, _else::Union{String, Int64, Bool, SQLTypeF, Missing} = missing)
  return FObject(function_name = "WHEN", column = x, kwargs = Dict{String, Any}("then" => then, "else" => _else))
end
function Case(conditions::Vector{N} where N <: SQLTypeF; default::Any = "NULL", output_field::Union{N, String, Nothing} where N <: PormGField = nothing)
  if isa(output_field, PormGField)
    output_field = output_field.type
  end  
  return FObject(function_name = "CASE", column = conditions, kwargs = Dict{String, Any}("else" => default, "output_field" => output_field)) 
end
function Case(conditions::SQLTypeF; default::Any = "NULL", output_field::Union{N, String, Nothing} where N <: PormGField = nothing)
  if isa(output_field, PormGField)
    output_field = output_field.type
  end  
  return FObject(function_name = "CASE", column = conditions, kwargs = Dict{String, Any}("else" => default, "output_field" => output_field)) 
end
function To_char(x::Union{String, SQLTypeF, Vector{String}}, format::String)
  return FObject(function_name = "EXTRACT_DATE", column = x, kwargs = Dict{String, Any}("format" => format))
end

MONTH(x) = Extract(x, "MONTH")
YEAR(x) = Extract(x, "YEAR")
DAY(x) = Extract(x, "DAY")
Y_M(x) = To_char(x, "YYYY-MM")
DATE(x) = To_char(x, "YYYY-MM-DD")
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
function up_values!(q::SQLObject, values::NTuple{N, Union{String, Symbol, SQLTypeF, SQLTypeText, SQLTypeField, Pair{String, T}}} where N where T <: SQLTypeF)
  # every call of values, reset the values
  q.values = []
  for v in values 
    isa(v, Symbol) && (v = String(v))
    if isa(v, SQLTypeText) || isa(v, SQLTypeField)
      push!(q.values, _check_function(v))
    elseif isa(v, SQLTypeF)
      push!(q.values, SQLField(_check_function(v), v._as))
    elseif isa(v, Pair) && isa(v.second, SQLTypeF)
      push!(q.values, SQLField(_check_function(v.second), v.first))
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

function up_update!(q::SQLObject, values::NTuple{N, Union{Pair{String, String}, Pair{String, Int64}}} where N)
  q.insert = Dict()
  for (k,v) in values   
    q.insert[k] = v 
  end  

  return update(q)
end

function up_filter!(q::SQLObject, filter)
  for v in filter   
    if isa(v, SQLTypeQ) || isa(v, SQLTypeQor) 
      push!(q.filter, v) # TODO I need process the Qor and Q with _check_filter
    elseif isa(v, Pair)
      push!(q.filter, _check_filter(v))
    else
      error("Invalid argument: $(v) (::$(typeof(v)))); please use a pair (key => value) or a Q(key => value...) or a Qor(key => value...)")
    end
  end
  return q
end

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

  # Constructor with keyword arguments
  function ObjectHandler(; object::SQLObject, 
                          values::Function = (x...) -> up_values!(object, x), 
                          filter::Function = (x...) -> up_filter!(object, x), 
                          create::Function = (x...) -> up_create!(object, x), 
                          update::Function = (x...) -> up_update!(object, x), 
                          order_by::Function = (x...) -> order_by!(object, x))
      return new(object, values, filter, create, update, order_by)
  end
end

export object

function object(model::PormGModel)
  return ObjectHandler(object = SQLObjectQuery(model = model))
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


"""
  _get_pair_to_oper(x::Pair)

  Converts a Pair object to an OperObject. If the Pair's key is a string, it checks if it contains an operator suffix (e.g. "__@gte", "__@lte") and returns an OperObject with the corresponding operator. If the key does not contain an operator suffix, it returns an OperObject with the "=" operator. If the key is not a string, it throws an error.

  ## Arguments
  - `x::Pair`: A Pair object to be converted to an OperObject.

  ## Returns
  - `OperObject`: An OperObject with the corresponding operator and values.

"""
function _get_pair_to_oper(x::Pair{Vector{String}, T}) where T <: Union{String, Int64, Bool}
  if haskey(PormGsuffix, x.first[end])
    return OperObject(operator = PormGsuffix[x.first[end]], values = x.second, column = SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else    
    return OperObject(operator = "=", values = x.second, column = SQLField(_check_function(x.first), join(x.first, "__"))) # TODO, maybe I need to check if the column is valid and process the function before store
  end  
end
function _get_pair_to_oper(x::Pair{String, T}) where T <: Union{String, Int64, Bool}
  return _get_pair_to_oper(String.(split(x.first, "__@")) => x.second)
end
# Store SQLObject, to use __@in operator
function _get_pair_to_oper(x::Pair{Vector{String}, T}) where T <: SQLObjectHandler
  if x.first[end] == "in"
    return OperObject(operator = "in", values = x.second, column = SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    throw("Invalid operator $(x.first[end]), only 'in' is allowed with a object")
  end

end
  

function _check_filter(x::Pair)
  if isa(x.first, String)
    check = String.(split(x.first, "__@"))
    return _get_pair_to_oper(check => x.second)  
  end
end


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

function _get_join_query(x::Tuple{Pair{String, Int64}, Vararg{Pair{String, Int64}}}; array_store::Vector{String} = String[])
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
function _get_join_query(x::Dict{String,Union{Int64, String}}; array_store::Vector{String} = String[])
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
  if size(row_join, 1) == 0
    push!(row_join, row)
    return row["alias_b"]
  else
    check = filter(r -> r["a"] == row["a"] && r["b"] == row["b"] && r["key_a"] == row["key_a"] && r["key_b"] == row["key_b"], row_join)
    if size(check, 1) == 0
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
    throw("Error in _build_row_join, the field $(field) not found in $(model.name): $(join(model.field_names, ", "))")
  end
  (instruct.django !== nothing && hasfield(model.fields[field] |> typeof, :to)) && (field = string(field, "_id"))
  return field
end
_solve_field(field::String, _module::Module, model_name::Symbol, instruct::SQLInstruction) = _solve_field(field, getfield(_module, model_name), instruct) 
_solve_field(field::String, _module::Module, model_name::String, instruct::SQLInstruction) = _solve_field(field, _module, Symbol(model_name), instruct)
_solve_field(field::String, _module::Module, model_name::PormGModel, instruct::SQLInstruction) = _solve_field(field, model_name, instruct)

"build a row to join"
function _build_row_join(field::Vector{SubString{String}}, instruct::SQLInstruction; as::Bool=true)
  # convert the field to a vector of string
  vector = String.(field)
  _build_row_join(vector, instruct, as=as)  
end
function _build_row_join(field::Vector{String}, instruct::SQLInstruction; as::Bool=true)
  vector = copy(field) 
  foreign_table_name::Union{String, PormGModel, Nothing} = nothing
  foreing_table_module::Module = instruct.object.model._module::Module
  row_join = Dict{String,String}()

  # fields_model = instruct.object.model.field_names
  last_column::String = ""

  @infiltrate false

  if vector[1] in instruct.object.model.field_names # vector moust be a field from the model
    last_column = vector[1]
    row_join["a"] = instruct.django !== nothing ? string(instruct.django, instruct.object.model.name |> lowercase) : instruct.object.model.name |> lowercase
    row_join["alias_a"] = instruct.alias
    how = instruct.object.model.fields[last_column].how
    if how === nothing
      row_join["how"] = instruct.object.model.fields[last_column].null == "YES" ? "LEFT" : "INNER"
    else
      row_join["how"] = how
    end
    foreign_table_name = instruct.object.model.fields[last_column].to
    if foreign_table_name === nothing
      throw("Error in _build_row_join, the column $(last_column) does not have a foreign key")
    elseif isa(foreign_table_name, PormGModel)
      row_join["b"] = instruct.django !== nothing ? string(instruct.django, foreign_table_name.name |> lowercase) : foreign_table_name.name |> lowercase
    else
      row_join["b"] = instruct.django !== nothing ? string(instruct.django,  foreign_table_name |> lowercase) : foreign_table_name |> lowercase
    end
    # row_join["alias_b"] = _get_alias_name(instruct.df_join) # TODO chage by row_join and test the speed
    row_join["alias_b"] = _get_alias_name(instruct.row_join, instruct.alias)
    row_join["key_b"] = instruct.object.model.fields[last_column].pk_field::String
    row_join["key_a"] = instruct.django !== nothing ? string(last_column, "_id") : last_column
  elseif haskey(instruct.object.model.related_objects, vector[1])
    reverse_model = getfield(foreing_table_module, instruct.object.model.related_objects[vector[1]][3])
    length(vector) == 1 && throw("Error in _build_row_join, the column $(vector[1]) is a reverse field, you must inform the column to be selected. Example: ...filter(\"$(vector[1])__column\")")
    # !(vector[2] in reverse_model.field_names) && throw("Error in _build_row_join, the column $(vector[2]) not found in $(reverse_model.name)")
    last_column = vector[2]
    row_join["a"] = instruct.django !== nothing ?  string(instruct.django, instruct.object.model.name |> lowercase) : instruct.object.model.name |> lowercase
    row_join["alias_a"] = instruct.alias
    how = reverse_model.fields[instruct.object.model.related_objects[vector[1]][1] |> String].how
    if how === nothing
      row_join["how"] = instruct.object.model.fields[instruct.object.model.related_objects[vector[1]][4] |> String].null == "YES" ? "LEFT" : "INNER"
    else
      row_join["how"] = how
    end
    foreign_table_name = instruct.object.model.related_objects[vector[1]][3] |> String
    if foreign_table_name === nothing
      throw("Error in _build_row_join, the column $(foreign_table_name) does not have a foreign key")
    elseif isa(foreign_table_name, PormGModel)
      row_join["b"] = instruct.django !== nothing ? string(instruct.django, foreign_table_name.name |> lowercase) : foreign_table_name.name |> lowercase
    else
      row_join["b"] = instruct.django !== nothing ? string(instruct.django,  foreign_table_name |> lowercase) : foreign_table_name |> lowercase
    end

    row_join["alias_b"] = _get_alias_name(instruct.row_join, instruct.alias)
    row_join["key_b"] = instruct.object.model.related_objects[vector[1]][1] |> String
    row_join["key_a"] = instruct.django !== nothing ? string(instruct.object.model.related_objects[vector[1]][4] |> String, "_id") : instruct.object.model.related_objects[vector[1]][4] |> String
  else
    throw(ArgumentError("the column \e[4m\e[31m$(vector[1])\e[0m not found in \e[4m\e[32m$(instruct.object.model.name)\e[0m, that contains the fields: \e[4m\e[32m$(join(instruct.object.model.field_names, ", "))\e[0m and the related objects: \e[4m\e[32m$(join(keys(instruct.object.model.related_objects), ", "))\e[0m"))
  end
  
  vector = vector[2:end]  

  tb_alias = _insert_join(instruct.row_join, row_join)
  while size(vector, 1) > 1
    row_join2 = Dict{String,String}()
    # get new object
    @infiltrate false
    new_object = foreign_table_name isa PormGModel ? foreign_table_name : getfield(foreing_table_module, foreign_table_name |> Symbol)

    if vector[1] in new_object.field_names
      field = new_object.fields[vector[1]]
      !hasfield(typeof(field), :to) && throw("Error in _build_row_join, the column $(vector[1]) is a field from $(new_object.name), but this field has not a foreign key")
      last_column = vector[2]
      row_join2["a"] = row_join["b"]
      row_join2["alias_a"] = tb_alias
      how = new_object.fields[vector[1]].how
      if how === nothing
        row_join2["how"] = new_object.fields[vector[1]].null == "YES" ? "LEFT" : "INNER"
      else
        row_join2["how"] = how
      end
      foreign_table_name = new_object.fields[vector[1]].to
      if foreign_table_name === nothing
        throw("Error in _build_row_join, the column $(vector[2]) does not have a foreign key")
      elseif isa(foreign_table_name, PormGModel)
        row_join2["b"] = instruct.django !== nothing ? string(instruct.django, foreign_table_name.name |> lowercase) : foreign_table_name.name |> lowercase
      else
        row_join2["b"] = instruct.django !== nothing ? string(instruct.django,  foreign_table_name |> lowercase) : foreign_table_name |> lowercase
      end
      row_join2["alias_b"] = _get_alias_name(instruct.row_join, instruct.alias) # TODO chage by row_join and test the speed
      row_join2["key_b"] = new_object.fields[vector[1]].pk_field::String
      row_join2["key_a"] = instruct.django !== nothing ? string(vector[1], "_id") : vector[1]
      tb_alias = _insert_join(instruct.row_join, row_join2)
    
    elseif haskey(new_object.related_objects, vector[1])
      reverse_model = getfield(foreing_table_module, new_object.related_objects[vector[1]][3])
      length(vector) == 1 && throw("Error in _build_row_join, the column $(vector[1]) is a reverse field, you must inform the column to be selected. Example: ...filter(\"$(vector[1])__column\")")
      !(vector[2] in reverse_model.field_names) && throw("Error in _build_row_join, the column $(vector[2]) not found in $(reverse_model.name)")
      last_column = vector[2]
      row_join2["a"] = row_join["b"]
      row_join2["alias_a"] = tb_alias
      how = reverse_model.fields[new_object.related_objects[vector[1]][1] |> String].how
      if how === nothing
        row_join2["how"] = new_object.fields[new_object.related_objects[vector[1]][4] |> String].null == "YES" ? "LEFT" : "INNER"
      else
        row_join2["how"] = how
      end
      foreign_table_name = new_object.related_objects[vector[1]][3] |> String
      if foreign_table_name === nothing
        throw("Error in _build_row_join, the column $(foreign_table_name) does not have a foreign key")
      elseif isa(foreign_table_name, PormGModel)
        row_join2["b"] = instruct.django !== nothing ? string(instruct.django, foreign_table_name.name |> lowercase) : foreign_table_name.name |> lowercase
      else
        row_join2["b"] = instruct.django !== nothing ? string(instruct.django,  foreign_table_name |> lowercase) : foreign_table_name |> lowercase
      end

      row_join2["alias_b"] = _get_alias_name(instruct.row_join, instruct.alias)
      row_join2["key_b"] = new_object.related_objects[vector[1]][1] |> String
      row_join2["key_a"] = instruct.django !== nothing ? string(new_object.related_objects[vector[1]][4] |> String, "_id") : new_object.related_objects[vector[1]][4] |> String
      tb_alias = _insert_join(instruct.row_join, row_join2)
      vector = vector[2:end]

    else
      throw("Error in _build_row_join, the column $(vector[1]) not found in $(new_object.name)")
    end
    vector = vector[2:end]
  end

  # tb_alias is the last table alias in the join ex. tb_1
  # last_column is the last column in the join ex. last_login
  # vector is the full path to the column ex. user__last_login__date (including functions (except the suffix))

  # functions must be processed here
  return string(tb_alias, ".", _solve_field(vector[end], foreing_table_module, foreign_table_name, instruct))
  
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
function _get_select_query(v::SQLText, instruc::SQLInstruction)  
  return Dialect.VALUE(v.field, instruc.connection)
end

function _get_select_query(v::Vector{SQLObject}, instruc::SQLInstruction)
  resp = []
  for v in v
    push!(resp, _get_select_query(v, instruc))
  end
  return resp
end
function _get_select_query(v::Vector{SQLType}, instruc::SQLInstruction)
  resp = []
  for v in v
    push!(resp, _get_select_query(v, instruc))
  end
  return resp
end
function _get_select_query(v::Vector{FObject}, instruc::SQLInstruction)
  resp = []
  for v in v
    push!(resp, _get_select_query(v, instruc))
  end
  return resp
end
# I think that is not the local to build the select query
function _get_select_query(v::String, instruc::SQLInstruction)
  parts = split(v, "__")  
  if size(parts, 1) > 1
    return _build_row_join(parts, instruc)
  else
    return string(instruc.alias, ".", _solve_field(v, instruc.object.model, instruc))
  end 
  
end
function _get_select_query(v::SQLField, instruc::SQLInstruction)
  return _get_select_query(v.field, instruc)
end
function _get_select_query(v::SQLTypeOper, instruc::SQLInstruction)
  if isa(v.column, SQLTypeF) && haskey(PormGTypeField, v.column.function_name)
    value = getfield(Models, PormGTypeField[v.column.function_name])(v.values)
  else
    if isa(v.values, String)
      value = "'" * v.values * "'"
    else
      value = string(v.values)
    end
  end
  column = _get_select_query(v.column, instruc)
 
  if v.operator in ["=", ">", "<", ">=", "<=", "<>", "!="]   
    return string(column, " ", v.operator, " ", value)
  elseif v.operator in ["in", "not in"]
    return string(column, " ", v.operator, " (", join(value, ", "), ")")
  elseif v.operator in ["ISNULL"]
    return getfield(QueryBuilder, Symbol(v.operator))(column, v.values)
  elseif v.operator in ["contains", "icontains"]
    return getfield(Dialect, Symbol(v.operator))(instruc.connection, column, value)
  else
    throw("Error in operator, $(v.operator) is not a valid operator")
  end
end
function _get_select_query(v::SQLTypeF, instruc::SQLInstruction)  
  value = getfield(Dialect, Symbol(v.function_name))(_get_select_query(v.column, instruc), v.kwargs, instruc.connection)
  return value # getfield(Dialect, Symbol(v.function_name))(_get_select_query(v.column, instruc), v.kwargs, instruc.connection)
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
    v_copy = copy(values[i])
    if isa(v_copy.field, SQLTypeF) 
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
      v_copy.field = _get_select_query(v_copy.field, instruc)
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
    v_field_copy = copy(v.field)
    if haskey(instruc.cache, v_field_copy._as)
      v_field_copy.field = instruc.cache[v_field_copy._as].field # TODO how can i recover the order of the field in select, maybe is better thar use the function in order by
    else
      v_field_copy.field = _get_select_query(v_field_copy.field, instruc)
    end     
    push!(instruc.order, string(v_field_copy.field, " ", v.orientation))
    instruc.cache[v_field_copy._as] = v_field_copy   

    # check if the field is in the select
    for value in object.values
      if isa(value, SQLTypeF) && value.field.agregate == true
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
  # for loop from end to start exept the first
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

# PAREI AQUI
function _get_filter_query(v::String, instruc::SQLInstruction)
  # V does not have be suffix
  contains(v, "@") && return _get_filter_query(split(v, "__@"), instruc)
  parts = split(v, "__")  
  if size(parts, 1) > 1
    return _build_row_join(parts, instruc, as=false)
  else
    return string(instruc.alias, ".", _solve_field(v, instruc.object.model, instruc))  
  end
  
end
# function _get_filter_query(v::SQLTypeF, instruc::SQLInstruction)
#   return _get_select_query(v, instruc) 
# end
# function _get_filter_query(v::SQLTypeText, instruc::SQLInstruction)
#   return _get_select_query(v, instruc)
# end
function _get_filter_query(v::SQLTypeField, instruc::SQLInstruction)
  # check if SQLTypeField exists in cache
  if haskey(instruc.cache, v._as)
    return instruc.cache[v._as].field
  else
    v_copy = copy(v)
    v_copy.field = _get_select_query(v_copy.field, instruc)
    instruc.cache[v_copy._as] = v_copy
    return v_copy.field
  end
end
function _get_filter_query(v::SQLTypeOper, instruc::SQLInstruction)
  if isa(v.column, SQLTypeF) && haskey(v.column.function_name, PormGTypeField)
    value = getfield(Models, PormGTypeField[v.column.function_name])(v.values)
  elseif isa(v.values, SQLObjectHandler)
    if !(v.operator in ["in", "not in"])
      throw("Error in values, $(v.values) is not a SQLObjectHandler")
    end
    value = query(v.values, table_alias=instruc.table_alias, connection=instruc.connection)
    return string(_get_filter_query(v.column, instruc), " ", v.operator, " ($value)")
  else
    if v.operator in ["contains", "icontains"]
      value = v.values
    elseif isa(v.values, String)
      value = "'" * v.values * "'"
    else
      value = string(v.values)
    end
  end

  column = _get_filter_query(v.column, instruc)
  
  if v.operator in ["=", ">", "<", ">=", "<=", "<>", "!="]   
    return string(column, " ", v.operator, " ", value)
  elseif v.operator in ["in", "not in"]
    return string(column, " ", v.operator, " (", join(value, ", "), ")")
  elseif v.operator in ["ISNULL"]    
    return getfield(QueryBuilder, Symbol(v.operator))(column, v.values)
  elseif v.operator in ["contains", "icontains"]
    return getfield(Dialect, Symbol(v.operator))(instruc.connection, column, value)
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
  for v in object.filter
    if isa(v, Union{SQLTypeQor, SQLTypeQ, SQLTypeOper})
      push!(instruc._where, _get_filter_query(v, instruc))
    else      
      throw("Error in values, $(v) is not a SQLTypeQor, SQLTypeQ or SQLTypeOper")
    end
  end  
  return nothing
end

function build_row_join_sql_text(instruc::SQLInstruction)
  # for row in eachrow(instruc.df_join)
  #   push!(instruc.join, """ $(row.how) JOIN $(row.b) $(row.alias_b) ON $(row.alias_a).$(row.key_a) = $(row.alias_b).$(row.key_b) """)
  # end
  for value in instruc.row_join
    push!(instruc.join, """ $(value["how"]) JOIN $(value["b"]) $(value["alias_b"]) ON $(value["alias_a"]).$(value["key_a"]) = $(value["alias_b"]).$(value["key_b"]) """)
  end
end

function build(object::SQLObject; table_alias::Union{Nothing, SQLTableAlias} = nothing, connection::Union{Nothing, LibPQ.Connection, SQLite.DB} = nothing)
  settings = config[object.model.connect_key]
  connection === nothing && (connection = settings.connections) # TODO -- i need create a mode to handle with pools
  table_alias === nothing && (table_alias = SQLTbAlias())
  instruct = InstrucObject(text = "", 
    object = object,
    table_alias = table_alias === nothing ? SQLTbAlias() : table_alias,
    alias = get_alias(table_alias),
    connection = connection,
    django = settings.django_prefix === nothing ? nothing : settings.django_prefix * "_",
  )   
  
  get_select_query(object.values, instruct)
  get_filter_query(object, instruct)
  build_row_join_sql_text(instruct)
  get_order_query(object, instruct)
  
  return instruct
end

# ---
# Pagination functions
#

export page

function page(object::SQLObjectHandler; limit::Int64 = 10, offset::Int64 = 0)
  object.object.limit = limit
  object.object.offset = offset
  return object
end
function page(object::SQLObjectHandler, limit::Int64)
  object.object.limit = limit
  return object
end
function page(object::SQLObjectHandler, limit::Int64, offset::Int64)
  object.object.limit = limit
  object.object.offset = offset
  return object
end

# ---
# Execute the query
#

export query

function query(q::SQLObjectHandler; table_alias::Union{Nothing, SQLTableAlias} = nothing, connection::Union{Nothing, LibPQ.Connection, SQLite.DB} = nothing) # TODO -- i need create a mode to change
  instruction = build(q.object, table_alias=table_alias, connection=connection) 
  respota = """
    SELECT
      $(_query_select(instruction.select ))
    FROM $(instruction.django !== nothing ? string(instruction.django, q.object.model.name |> lowercase) : q.object.model.name |> lowercase) as $(instruction.alias)
    $(join(instruction.join, "\n"))
    $(instruction._where |> length > 0 ? "WHERE" : "") $(join(instruction._where, " AND \n   "))
    $(instruction.agregate ? "GROUP BY $(join(instruction.group, ", ")) \n" : "") 
    $(instruction.order |> length > 0 ? "ORDER BY" : "") $(join(instruction.order, ", \n  "))
    $(q.object.limit !== 0 ? "LIMIT $(q.object.limit) \n" : "")
    $(q.object.offset !== 0 ? "OFFSET $(q.object.offset) \n" : "")
    """
  # @info respota
  return respota
end

# ---
# Count or check if exists
#

export do_count, do_exists

function do_count(q::SQLObjectHandler; table_alias::Union{Nothing, SQLTableAlias} = nothing)::Int64
  connection = config[q.object.model.connect_key].connections
  instruction = build(q.object, table_alias=table_alias, connection=connection) 
  resposta = """
    SELECT
      COUNT(*)
    FROM $(instruction.django !== nothing ? string(instruction.django, q.object.model.name |> lowercase) : q.object.model.name |> lowercase) as $(instruction.alias)
    $(join(instruction.join, "\n"))
    $(instruction._where |> length > 0 ? "WHERE" : "") $(join(instruction._where, " AND \n   "))
    $(instruction.agregate ? "GROUP BY $(join(instruction.group, ", ")) \n" : "") 
    """
  query_result = LibPQ.execute(connection, resposta)
  return query_result[1, 1]
end

function do_exists(q::SQLObjectHandler; table_alias::Union{Nothing, SQLTableAlias} = nothing)
  count = do_count(q, table_alias=table_alias)
  return count > 0
end

function insert(objct::SQLObject; table_alias::Union{Nothing, SQLTableAlias} = nothing, connection::Union{Nothing, LibPQ.Connection, SQLite.DB} = nothing)
  model = objct.model
  settings = config[model.connect_key]
  connection === nothing && (connection = settings.connections) # TODO -- i need create a mode to handle with pools and create a function to this
  
  # colect name of the fields
  fields = model.field_names
  
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
  end

  # insert
  fields_columns = join([field for field in keys(objct.insert)], ", ")

  # values
  values_insert = join([objct.insert[field] |> model.fields[field].formater for field in keys(objct.insert)], ", ")

  # TODO: insert a function to handle with the different types of connection and modulate the code

  # construct the SQL statement
  sql = """
  INSERT INTO $(string(model.name)) (
    $(fields_columns)
  ) VALUES (
    $(values_insert)
  )
  """

  # @info sql

  # execute the SQL statement
  if connection isa LibPQ.Connection
    result = LibPQ.execute(connection, sql * " RETURNING *;")
  elseif connection isa SQLite.DB
    SQLite.execute(connection, sql)
    # Assuming the table has an auto-increment primary key named "id"
    last_id = SQLite.last_insert_rowid(connection)
    result = SQLite.Query(connection, "SELECT * FROM $(string(model.name)) WHERE id = $last_id;")
  else
    throw("Unsupported connection type")
  end

  pk_exist && _update_sequence(model, connection, pk_field, settings)

  return Tables.rowtable(result) |> first |> x -> Dict(Symbol(k) => v for (k, v) in pairs(x))

end

function _update_sequence(model::PormGModel, connection::LibPQ.Connection, pk_field::Vector{String}, settings::SQLConn)
  @infiltrate
  for field in pk_field
    if settings.change_db
      try
        LibPQ.execute(connection, "SELECT setval('$(string(model.name |> lowercase))_$(field)_seq', (SELECT MAX($(field)) + 1 FROM $(string(model.name |> lowercase))), true);")
      catch e
        if occursin("does not exist", e |> string)        
          _fix_sequence_name(connection, model)
          LibPQ.execute(connection, "SELECT setval('$(string(model.name |> lowercase))_$(field)_seq', (SELECT MAX($(field)) + 1 FROM $(string(model.name |> lowercase))), true);")
        end
      end
    elseif settings.django_prefix !== nothing
      @infiltrate
      try
        # For Django prefixed tables, try with django prefix pattern
        sequence_name = "$(settings.django_prefix)_$(model.name |> lowercase)_$(field)_seq"
        LibPQ.execute(connection, "SELECT setval('$(sequence_name)', (SELECT MAX($(field)) + 1 FROM $(settings.django_prefix)_$(model.name |> lowercase)), true);")
      catch e
        if occursin("does not exist", e |> string)
          # # Try to find the actual sequence name
          # sequences = LibPQ.execute(connection, """
          #   SELECT sequence_name 
          #   FROM information_schema.sequences 
          #   WHERE sequence_name LIKE '%$(settings.django_prefix)_$(model.name |> lowercase)%'
          #   AND sequence_schema = 'public';
          # """) |> DataFrames.DataFrame
          
          # if size(sequences, 1) > 0
          #   sequence_name = sequences[1, :sequence_name]
          #   LibPQ.execute(connection, "SELECT setval('$(sequence_name)', (SELECT MAX($(field)) + 1 FROM $(settings.django_prefix)_$(model.name |> lowercase)), true);")
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

function _fix_sequence_name(connection::LibPQ.Connection, model::PormGModel) # TODO maby i need use Migration get_sequence_name aproach
  pk_field = [field for field in keys(model.fields) if model.fields[field].primary_key]
  sequences = LibPQ.execute(connection, """SELECT *
      FROM pg_sequences
      WHERE sequencename LIKE '$(model.name |> lowercase)%';""") |> DataFrames.DataFrame  
  for (index, row) in enumerate(eachrow(sequences))
    if index == 1 && row.sequencename != "$(model.name |> lowercase)_$(pk_field[1])_seq"
      if length(pk_field) == 0
        throw("Error in _fix_sequence_name, the model $(model.name) does not have a primary key")
      elseif length(pk_field) > 1
        throw("Error in _fix_sequence_name, the model $(model.name) has more than one primary key")
      end
      LibPQ.execute(connection, "ALTER SEQUENCE $(row.sequencename) RENAME TO $(model.name |> lowercase)_$(pk_field[1])_seq;")
    else
      LibPQ.execute(connection, "DROP SEQUENCE $(row.sequencename);")
    end
  end
end

# function _update_sequence(model::PormGModel, connection::LibPQ.Connection, pk_field::Vector{String})
#   sequences = LibPQ.execute(connection, """SELECT *
#       FROM pg_sequences
#       WHERE sequencename LIKE '$(model.name |> lowercase)%';""") |> DataFrames.DataFrame
#   for row in eachrow(sequences)
#     if row.sequenceowner == model.name
#       LibPQ.execute(connection, "SELECT setval('$(row.sequencename)', (SELECT MAX($(pk_field[1])) FROM $(model.name)), true);")
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

function update(objct::SQLObject; table_alias::Union{Nothing, SQLTableAlias} = nothing, connection::Union{Nothing, LibPQ.Connection, SQLite.DB} = nothing)
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
  for field in keys(objct.insert)    
    # check if the create has a field that not exist in the model
    in(field, fields) || throw("""Error in update, the field "$(field)" not found in $(model.name)""")
    # check if field is a primary key and not allow to update
    model.fields[field].primary_key && throw("Error in update, the field \e[4m\e[31m$(field)\e[0m is a primary key and not allow to update")
    # check if the field has max_length and validate
    hasfield(typeof(model.fields[field]), :max_length) && length(objct.insert[field]) > model.fields[field].max_length && error("""Error in update, the field \e[4m\e[31m$(field)\e[0m has a max_length of \e[4m\e[32m$(model.fields[field].max_length)\e[0m, but the value has \e[4m\e[31m$(length(q.object.create[field]))\e[0m""")
    # check if the field has max_digits and validate
    if hasfield(typeof(model.fields[field]), :max_digits)
      value_str = string(objct.insert[field])
      integer_part, fractional_part = split(value_str, ".")
      total_digits = length(replace(integer_part, "-" => "")) + length(fractional_part)
      if total_digits > model.fields[field].max_digits
        error("""Error in update, the field \e[4m\e[31m$(field)\e[0m has a max_digits of \e[4m\e[32m$(model.fields[field].max_digits)\e[0m, but the value has \e[4m\e[31m$(total_digits)\e[0m""")
      end
    end
  end
   

  set_clause = join([ "$(field) = $(objct.insert[field] |> model.fields[field].formater)" for field in keys(objct.insert) ], ", ")

  # construct the SQL statement
  sql = """
    UPDATE $(string(model.name)) as $(instruction.alias)
    SET $(set_clause)
    WHERE $(join(instruction._where, " AND \n   "))
  """

  # @info sql

  # execute the SQL statement
  if connection isa LibPQ.Connection
    LibPQ.execute(connection, sql)
  elseif connection isa SQLite.DB
    SQLite.execute(connection, sql)
  else
    throw("Unsupported connection type")
  end

  return nothing
end

function fetch(connection::LibPQ.Connection, sql::String)
  return LibPQ.execute(connection, sql)
end

export list
# create a function like a list from Django query
function list(objct::SQLObjectHandler)
  connection = config[objct.object.model.connect_key].connections

  sql = query(objct, connection=connection)
  return fetch(connection, sql)
end

# ---
# Execute bulk insert and update
#

export bulk_insert

function bulk_insert(objct::SQLObjectHandler, df::DataFrames.DataFrame; 
    columns::Vector{Union{String, Pair{String, String}}} = Union{String, Pair{String, String}}[], 
    chunk_size::Int64 = 1000
  ) 
  model = objct.object.model
  settings = config[model.connect_key]
  connection = settings.connections
  django_prefix = settings.django_prefix === nothing ? false : true

  

  # check if is allowed to insert
  !settings.change_data && throw(ArgumentError("Error in bulk_insert, the connection \e[4m\e[31m$(model.connect_key)\e[0m not allowed to insert"))

  # If no rows then nothing to do
  if size(df, 1) == 0
    @warn("Warning in bulk_insert, the DataFrame is empty")
    return nothing
  end

  # colect name of the fields
  fields = copy(model.field_names)

  if django_prefix
    for (i, field) in enumerate(fields)
      if hasfield(typeof(model.fields[field]), :to) && model.fields[field].to !== nothing
        # Field is a foreign key
        new_field = field * "_id"
        fields[i] = new_field        
      end
    end
  end
  
  fields_df::Vector{String} = []
  if !isempty(columns)   
    if length(columns) > 0
      for column in columns
        if column isa Pair
          rename!(df, column.first => column.second)
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
  for field in fields
    if !in(field, fields_df)
      if model.fields[field].default !== nothing
        df[!, field] = model.fields[field].default
        push!(fields_df, field)
      elseif model.fields[field].type == "TIMESTAMPTZ" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        df[!, field] = model.fields[field].formater(now(), settings.time_zone)
        push!(fields_df, field)
      elseif model.fields[field].type == "DATE" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        df[!, field] = model.fields[field].formater(today())
        push!(fields_df, field)
      elseif model.fields[field].null
        continue      
      elseif model.fields[field].primary_key
        push!(pk_field, field)
      else
        throw(ArgumentError("Error in bulk_insert, the field \e[4m\e[31m$(field)\e[0m not found in the DataFrame and not allow null"))
      end
    else
      _field::String = django_prefix ? replace(field, "_id" => "") : field
      if model.fields[_field].primary_key
        pk_exist = true
        push!(pk_field, field)
      end
    end
  end

  # check if the fields_df are not in fields
  for field in fields_df
    in(field, fields) || throw("""Error in bulk_insert, the field \e[4m\e[31m$(field)\e[0m not found in \e[4m\e[32m$(model.name)\e[0m""")
  end

  # Build a list of row value strings by applying each model field formatter.
  rows = String[]
  count::Int64 = 0
  total::Int64 = size(df, 1)
  for (index, row) in enumerate(eachrow(df))
    values = String[]
    try
      values = [model.fields[django_prefix ? replace(field, "_id" => "") : field].formater(row[field]) for field in fields_df]
    catch e
      _depuration_values_bulk_insert(fields, model, row, index, django_prefix)
      throw("Error in bulk_insert, the row $(index) has a problem: $(e)")
    end
    push!(rows, "($(join(values, ", ")))")
    count += 1
    if count == chunk_size || index == total
      bulk_insert(model, connection, fields_df, rows, pk_exist, pk_field, settings, django_prefix)
      count = 0
      rows = String[]
    end
  end  

  return nothing
  
end

function _depuration_values_bulk_insert(fields::Vector{String}, model::PormGModel, row::DataFrames.DataFrameRow, index::Int64, django_prefix::Bool)
  for field in fields
    # Check if field exists in the row before trying to format it
    if !(field in names(row))
      return nothing
    end
    _field::String = django_prefix ? replace(field, "_id" => "") : field
    try
      model.fields[_field].formater(row[field])
    catch e
      throw(ArgumentError("Error in bulk_insert, the field \e[4m\e[31m$(field)\e[0m in row \e[4m\e[31m$(index)\e[0m has a value that can't be formatted: \e[4m\e[31m$(row[field])\e[0m"))
    end
  end  
end

function bulk_insert(model::PormGModel, connection::LibPQ.Connection, fields::Vector{String}, rows::Vector{String}, pk_exist::Bool, pk_field::Vector{String}, settings::SQLConn, django_prefix::Bool)
  # Construct the bulk insert SQL.
  _table = django_prefix ? string(settings.django_prefix, "_", model.name |> lowercase) : model.name |> lowercase
  sql = """
  INSERT INTO $(_table) ($(join(fields, ", ")))
  VALUES $(join(rows, ", "))
  """

  # @info sql

  # Execute the query for the given connection type.
  if connection isa LibPQ.Connection
    try
      LibPQ.execute(connection, sql)
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

export bulk_update

"""
Performs a bulk update operation on a database table using the provided `DataFrame` and a query object.

# Arguments
- `objct::SQLObjectHandler`: The database handler object.
- `df::DataFrames.DataFrame`: The DataFrame containing the data to be used for the update.
- `columns`: (Optional) Specifies which columns to update. Can be a `String`, a `Pair{String, String}`, or a `Vector` of these. If `nothing`, no columns are specified.
- `filters`: (Optional) Specifies the filters to apply for the update. Can be a `String`, a `Pair{String, T}` where `T` is `String`, `Int64`, `Bool`, `Date`, or `DateTime`, or a `Vector` of these. If `nothing`, no filters are applied.
- `show_query::Bool`: (Optional) If `true`, prints the generated SQL query. Defaults to `false`.
- `chunk_size::Int64`: (Optional) Number of rows to process per chunk. Defaults to `1000`.

# Example
```julia
# Update the columns of the DataFrame df if df contains the primary key of the table
bulk_update(objct, df)
# Update the name and dof columns for the security_id in the DataFrame df
bulk_update(objct, df, columns=["security_id", "name", "dof"], filters=["security_id"])
```
"""
function bulk_update(objct::SQLObjectHandler, df::DataFrames.DataFrame; 
    columns=nothing, 
    filters=nothing,
    show_query::Bool=false, 
    chunk_size::Int64=1000)

  _columns::Vector{Union{String, Pair{String, String}}} = []
  _filters::Vector{Union{String, Pair{String, <:Union{String, Int64, Bool, Date, DateTime}}}} = []
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
  elseif filter isa Pair{String, <:Union{String, Int64, Bool, Date, DateTime}}
    push!(_filters, filters)
  elseif filters isa Vector
    for filter in filters
      if filter isa AbstractString
        push!(_filters, filter)
      elseif filter isa Pair{String, <:Union{String, Int64, Bool, Date, DateTime}}
        push!(_filters, filter)
      else
        throw("Error in bulk_update, the filters must be a String or a Pair{String, T} where T<:Union{String, NumInt64ber, Bool, Date, DateTime}")
      end
    end
  else
    throw("Error in bulk_update, the filters must be a String or a Pair{String, T} where T<:Union{String, Int64, Bool, Date, DateTime}")
  end


  _bulk_update(objct, df, _columns, _filters, show_query, chunk_size)
  
end

function _bulk_update(objct::SQLObjectHandler, df::DataFrames.DataFrame,
  columns::Vector{Union{String, Pair{String, String}}},
  filters::Vector{Union{String, Pair{String, <:Union{String, Int64, Bool, Date, DateTime}}}},
  show_query::Bool,
  chunk_size::Int64=1000)

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
    if !in(field, fields_df)      
      if model.fields[field].type == "TIMESTAMPTZ" &&  model.fields[field].auto_now
        df[!, field] = model.fields[field].formater(now(), settings.time_zone)
        push!(fields_df, field)
      elseif model.fields[field].type == "DATE" && model.fields[field].auto_now
        df[!, field] = model.fields[field].formater(today())
        push!(fields_df, field)     
      end    
    else
      if model.fields[field].primary_key
        pk_exist = true
        push!(pk_field, field)
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

  instruction::Union{SQLInstruction, Nothing} = nothing

  objct.object.filter = [] # clear the filters
  if size(static_filters, 1) > 0
    for filter in static_filters
      objct.filter(filter)
    end
    instruction = build(objct.object, connection=connection) 
  end

  @infiltrate false

  # check if the fields_df are not in fields
  for field in fields_df
    in(field, fields) || @error("""Error in bulk_update, the field \e[4m\e[31m$(field)\e[0m not found in \e[4m\e[32m$(model.name)\e[0m""")
  end

  # Build a list of row value strings by applying each model field formatter.
  rows = String[]
  set_columns = join([ "$(field) = source.$(field)::$(model.fields[field].type |> lowercase)" for field in fields_df if !(field in pk_field) ], ", ")
  count::Int64 = 0
  total::Int64 = size(df, 1)
  for (index, row) in enumerate(eachrow(df))
    values = String[]
    try
      values = [model.fields[field].formater(row[field]) for field in fields_df]
    catch e
      _depuration_values_bulk_insert(fields_df, model, row, index)
      throw("Error in bulk_update, the row $(index) has a problem: $(e)")
    end
    push!(rows, "($(join(values, ", ")))")
    count += 1
    if count == chunk_size || index == total
      @infiltrate false
      _bulk_update(model, connection, fields_df, rows, set_columns, dinanic_filters, show_query, instruction)
      count = 0
      rows = String[]
    end
  end

  return nothing
  
end

function _bulk_update(model::PormGModel, 
  connection::LibPQ.Connection, 
  fields::Vector{String}, 
  rows::Vector{String}, 
  set_columns::String, 
  dinanic_filters::Vector{String}, 
  show_query::Bool,
  instruction::Union{SQLInstruction, Nothing})

  if instruction.join |> length > 0
    throw("Error in bulk_update, the join is not allowed in bulk_update")
  end
  # Construct the bulk update SQL.
  _where::Vector{String} = []
  for filter in dinanic_filters
    push!(_where, "Tb.$(filter) = source.$(filter)::$(model.fields[filter].type |> lowercase)")
  end
  for filter in instruction._where
    push!(_where, filter)
  end
  sql = """
  UPDATE $(instruction.django !== nothing ? string(instruction.django, model.name |> lowercase) : model.name |> lowercase) AS Tb
  SET $(set_columns)
  FROM (VALUES $(join([join(split(row, ", "), ", ") for row in rows], ","))) AS source ($(join(fields, ",")))
  WHERE $(join(_where, " AND \n   "))
  """

  @infiltrate false

  if show_query 
     @info sql
  else 
    # Execute the query for the given connection type.
    LibPQ.execute(connection, sql)   
  end  
end

# ---
# Execute delete query with cascade, restrict, set null, set default and set value
#

import PormG: CASCADE, RESTRICT, SET_NULL, SET_DEFAULT, SET, PROTECT

export delete

mutable struct DeletionCollector
  model::PormGModel  # The main model being deleted from
  connection::Union{LibPQ.Connection, SQLite.DB}  # Database connection
  objects::Dict{PormGModel, Vector{Int64}}  # Models and their objects to delete
  dependencies::Dict{PormGModel, Set{PormGModel}}  # Model dependencies
  field_updates::Dict{Tuple{String, Any}, Dict{PormGModel, Vector{Int64}}}  # Field updates for SET_NULL etc.
  fast_deletes::Dict{PormGModel, Vector{Int64}}  # Objects that can be deleted directly
  sorted_models::Vector{PormGModel}  # Models in deletion order
  
  DeletionCollector(model, connection) = new(
    model,
    connection,
    Dict{PormGModel, Vector{Int64}}(),
    Dict{PormGModel, Set{PormGModel}}(),
    Dict{Tuple{String, Any}, Dict{PormGModel, Vector{Int64}}}(),
    Dict{PormGModel, Vector{Int64}}(),
    Vector{PormGModel}()
  )
end

function delete(objct::SQLObjectHandler; table_alias::Union{Nothing, SQLTableAlias} = nothing, connection::Union{Nothing, LibPQ.Connection, SQLite.DB} = nothing, allow_delete_all::Bool = false)
  model = objct.object.model
  settings = config[model.connect_key]
  connection === nothing && (connection = settings.connections) # TODO -- i need create a mode to handle with pools and create a function to this

  instruction = build(objct.object, table_alias=table_alias, connection=connection)

  # check if is allowed to delete
  !settings.change_data && throw(ArgumentError("Error in delete, the connection \e[4m\e[31m$(model.connect_key)\e[0m not allowed to delete"))

  # don't allow to delete without filter
  !allow_delete_all && instruction._where |> isempty && throw("Error in delete, the delete must have a filter")

  # Collect all objects to delete (primary keys)
  objects_to_delete = Dialect.get_objects_to_delete(connection, model, instruction)
  
  # If no objects to delete, return early
  if isempty(objects_to_delete)
    return 0, Dict{String, Int64}()
  end

  # We'll track deletion counts
  deleted_counter = Dict{String, Int64}()
  
  # Collect related models that need special handling
  collector = DeletionCollector(model, connection)
  
  # Add the primary objects to delete
  add_objects_to_collector!(collector, objects_to_delete, model)
  
  # Build and sort the deletion graph
  process_collector!(collector)

  @infiltrate false
 
  # Execute the deletion in a transaction
  if connection isa LibPQ.Connection
    # Start transaction
    LibPQ.execute(connection, "BEGIN;")
    
    try
      # Process fast deletes first (objects that can be deleted directly)
      for (model, ids) in collector.fast_deletes
        delete_objects(connection, model, ids)
        deleted_counter[model.name] = length(ids)
      end
      
      # Process field updates (for SET_NULL, SET_DEFAULT, etc.)
      for ((field, value), affected_models) in collector.field_updates
        for (affected_model, ids) in affected_models
          update_field(connection, affected_model, field, value, ids) 
        end
      end
      
      # Execute deletions in the sorted order
      for model_to_delete in collector.sorted_models
        ids = get(collector.objects, model_to_delete, [])
        if !isempty(ids)
          count = delete_objects(connection, model_to_delete, ids)
          deleted_counter[model_to_delete.name] = count
        end
      end
      
      # Commit transaction
      LibPQ.execute(connection, "COMMIT;")
    catch e
      # Rollback on error
      LibPQ.execute(connection, "ROLLBACK;")
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

function add_objects_to_collector!(collector::DeletionCollector, objects::Vector{NamedTuple}, model::PormGModel)
  # Extract IDs from objects - handle NamedTuples or Dict structures
  pk_field = get_model_pk_field(model)
  add_objects_to_collector!(collector, [getproperty(obj, pk_field) for obj in objects if !ismissing(getproperty(obj, pk_field))], model)
end


function add_objects_to_collector!(collector::DeletionCollector, ids::Vector{Int64}, model::PormGModel)
  # Add to collector
  collector.objects[model] = ids
  
  # Add model to the list of models to process
  if !haskey(collector.dependencies, model)
    collector.dependencies[model] = Set{PormGModel}()
  end
end


function process_collector!(collector::DeletionCollector)
  # Process each model and its objects
  for (model, ids) in collector.objects
    # Find related objects through foreign keys
    find_related_objects!(collector, model, ids)
  end

  # Identify objects that can be fast-deleted
  collect_fast_deletes!(collector)
  
  # Topologically sort models for deletion
  collector.sorted_models = topological_sort(collector.dependencies)
end

function find_related_objects!(collector::DeletionCollector, model::PormGModel, ids::Vector{Int64})
  # For each foreign key in the model (model has FK -> related_model)
  for (field_name, field) in model.fields
    if isa(field, sForeignKey) && field.on_delete !== nothing
      related_model = field.to isa PormGModel ? field.to : getfield(model._module, Symbol(field.to))
      
      # Model with FK depends on the target model (CORRECT)
      if !haskey(collector.dependencies, model)
        collector.dependencies[model] = Set{PormGModel}()
      end
      push!(collector.dependencies[model], related_model)
      
      handle_on_delete!(collector, field_name, field, model, ids, related_model)
    end
  end
  
  # For models with foreign keys pointing to this model (related_model has FK -> model)
  for (related_name, (field_name, pk_field, related_model_name, pk_model)) in model.related_objects
    related_model = getfield(model._module, related_model_name |> capitalize_symbol)
    
    # REVERSED: Model depended on by models with FKs pointing to it
    # Delete the referring models first, so the model can be deleted second
    if !haskey(collector.dependencies, related_model)
      collector.dependencies[related_model] = Set{PormGModel}()
    end
    # THIS is the fix - related_model depends on model (not the other way around)
    push!(collector.dependencies[related_model], model)
    
    # Find objects that refer to the ids we're deleting
    pk_field = get_model_pk_field(related_model)
    sql = """
      SELECT $(pk_field) FROM $(related_model.name |> lowercase)
      WHERE $(field_name) IN ($(join(ids, ",")))
    """    
    result = LibPQ.execute(collector.connection, sql)
    related_ids = [row[pk_field] for row in Tables.rowtable(result)]
    
    if !isempty(related_ids)
      # Get the field and handle its on_delete behavior
      field = related_model.fields[String(field_name)]
      handle_on_delete!(collector, field_name, field, related_model, related_ids, model)
    end
  end
end

function handle_on_delete!(collector::DeletionCollector, field_name::Union{String, Symbol}, field::PormGField, model::PormGModel, ids::Vector{Int64}, related_model::PormGModel)
  @infiltrate false
  if field.on_delete == CASCADE        
    # Add them to the collector for deletion
    if !isempty(ids)
      add_objects_to_collector!(collector, ids, model)
    end

  elseif field.on_delete in [PROTECT, RESTRICT]
    # Check if any related objects exist       
    if !isempty(ids)
      pk_field = get_model_pk_field(related_model)
      sql = """
        SELECT $(pk_field) FROM $(related_model.name |> lowercase)
        WHERE $(pk_field) IN ($(join(ids, ",")))
        LIMIT 5
      """
      sample_ids = LibPQ.execute(collector.connection, sql) |> Tables.rowtable
      sample_ids_str = join([row[pk_field] for row in sample_ids], ", ")
      
      # More descriptive error with field name, constraint type, and sample IDs
      constraint_type = field.on_delete == PROTECT ? "PROTECT" : "RESTRICT"
      throw(ArgumentError("Cannot delete \e[4m\e[31m$(related_model.name)\e[0m (ids: \e[4m\e[32m$(sample_ids_str)\e[0m...) because it is referenced by \e[4m\e[31m$(model.name).$(field_name)\e[0m with ON DELETE \e[4m\e[31m$(constraint_type)\e[0m constraint"))
    end
  elseif field.on_delete == SET_NULL
    # check if the field allow null
    if !field.null
      throw(ArgumentError("Error in delete, the field \e[4m\e[31m$(field_name)\e[0m not allow null"))
    end

    # Add field update to set field to NULL
    if !haskey(collector.field_updates, (field_name, nothing))
      collector.field_updates[(field_name, nothing)] = Dict{PormGModel, Vector{Int64}}()
    end
            
    # Add to field updates
    if !isempty(affected_ids)
      collector.field_updates[(field_name, nothing)][model] = ids
    end

  elseif field.on_delete == SET_DEFAULT
    # Add field update to set field to default value
    default_value = field.default
    if !haskey(collector.field_updates, (field_name, default_value))
      collector.field_updates[(field_name, default_value)] = Dict{PormGModel, Vector{Int64}}()
    end    
    
    # Add to field updates
    if !isempty(affected_ids)
      collector.field_updates[(field_name, default_value)][model] = ids
    end
  end
  # Other on_delete behaviors can be added here
end

function topological_sort(dependencies::Dict{PormGModel, Set{PormGModel}})
  # Implementation of topological sort algorithm
  @infiltrate false
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
  
  # Visit each node
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
  for (model, ids) in collector.objects
    if !(model in models_with_dependents)
      collector.fast_deletes[model] = ids
    end
  end
end

function delete_objects(connection::Union{LibPQ.Connection, SQLite.DB}, model::PormGModel, ids::Vector{Int64})
  # Execute the actual deletion SQL
  pk_field = get_model_pk_field(model)
  sql = "DELETE FROM $(model.name |> lowercase) WHERE $(pk_field) IN ($(join(ids, ",")))"
  result = LibPQ.execute(connection, sql)
  return length(ids)  # Return count of deleted objects
end

function update_field(connection::Union{LibPQ.Connection, SQLite.DB}, model::PormGModel, field::String, value::Any, ids::Vector{Int64})
  # Update field values
  pk_field = get_model_pk_field(model)
  value_sql = value === nothing ? "NULL" : model.fields[field].formater(value)
  sql = "UPDATE $(model.name |> lowercase) SET $(field) = $(value_sql) WHERE id IN ($(join(ids, ",")))"
  LibPQ.execute(connection, sql)
end



end