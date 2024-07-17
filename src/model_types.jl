import Dates, Intervals

#
# SQLInstruction Objects (instructions to build a query)
#

@kwdef mutable struct InstrucObject <: SQLInstruction
  text::String # text to be used in the query
  select::Vector{String}  # values to be used in select query
  join::Vector{String}  # values to be used in join query
  _where::Vector{String}  # values to be used in where query
  group::Vector{String}  # values to be used in group query
  having::Vector{String} # values to be used in having query
  order::Vector{String} # values to be used in order query
  df_join::Union{Missing, DataFrames.DataFrame} = missing # dataframe to be used in join query
  df_object::Union{Missing, DataFrames.DataFrame} = missing # dataframe to be used in join query
  df_pks::Union{Missing, DataFrames.DataFrame} = missing # dataframe to be used in join query
  df_columns::Union{Missing, DataFrames.DataFrame} = missing # dataframe to be used in join query
end

#
# SQLTypeOper Objects (operators from sql)
#

export OP

"""
  OperObject <: SQLTypeOper

  Mutable struct representing an SQL operator object for using in the filter and annotate.
  That is a internal function, please do not use it.

  # Fields
  - `operator::String`: the operator used in the SQL query.
  - `values::Union{String, Int64, Bool}`: the value(s) to be used with the operator.
  - `column::Union{String, SQLTypeF}`: the column to be used with the operator.

"""
@kwdef mutable struct OperObject <: SQLTypeOper
  operator::String
  values::Union{String, Int64, Bool}
  column::Union{String, SQLTypeF}
end
OP(column::String, value) = OperObject(operator = "=", values = value, column = column)
OP(column::String, operator::String, value) = OperObject(operator = operator, values = value, column = column)

# talvez eu não precise dessa função no inicio, mas pode ser útil na hora de processar o query
function _check_function(x::Vector{SubString{String}})
  vect = copy(x)
  if length(x) == 1
    return string(x[1])
  else
    # get keys from PormGtrasnform (that is a dict)
    keyS = collect(keys(PormGtrasnform))
    column = join(filter(x -> !(x in keyS), x), "__")
    countS = count(x -> x in keyS, x)
    resp = missing
    if countS > 0      
      while count(x -> x in keyS, x) > 0
        if ismissing(resp)
          resp = getfield(PormG, Symbol(PormGtrasnform[x[end]]))(column)
        else
          resp = getfield(PormG, Symbol(PormGtrasnform[x[end]]))(resp)
        end
        x = x[1:end-1]
      end
      resp.kwargs["as"] = join(vect, "__")

      print(resp)
      return resp
    else 
      return join(x, "__")
    end            
  end  
end
_check_function(x::String) = _check_function(split(x, "__"))

"""
  _get_pair_to_oper(x::Pair)

  Converts a Pair object to an OperObject. If the Pair's key is a string, it checks if it contains an operator suffix (e.g. "__gte", "__lte") and returns an OperObject with the corresponding operator. If the key does not contain an operator suffix, it returns an OperObject with the "=" operator. If the key is not a string, it throws an error.

  # Arguments
  - `x::Pair`: A Pair object to be converted to an OperObject.

  # Returns
  - `OperObject`: An OperObject with the corresponding operator and values.

  # Throws
  - `Error`: If the key is not a string or if it contains more than one operator suffix.

  # Wharning
  - That is a internal function, please do not use it.
"""
function _get_pair_to_oper(x::Pair)
  if isa(x.first, String)
    check = split(x.first, "__")
    # check if exist operators
    countS = count(x -> x in keys(PormGsuffix), check) 
    if countS > 1
      throw("Invalid argument: $(x.first); please use only one operator __gte, __lte ...")    
    elseif countS == 1
      if haskey(PormGsuffix, check[end])
        return OperObject(operator = PormGsuffix[check[end]], values = x.second, column = join(first(check, length(check)-1), "__"))
      else
        throw("Invalid argument: $(x.first); please use a valid operator __gte, __lte ... in last position of the string")
      end
    else
      return OperObject(operator = "=", values = x.second, column = x.first)
    end
  else
    throw(ArgumentError("Invalid argument: $(x.first) (::$(typeof(x.first)))); please use a string"))
  end
end
 

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
  colect = [isa(v, Pair) ? _get_pair_to_oper(v) : isa(v, Union{SQLTypeQor, SQLTypeQ, SQLTypeOper}) ? v : throw("Invalid argument: $(v); please use a pair (key => value)") for v in x]
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
  colect = [isa(v, Pair) ? _get_pair_to_oper(v) : isa(v, Union{SQLTypeQor, SQLTypeQ, SQLTypeOper}) ? v : throw("Invalid argument: $(v); please use a pair (key => value)") for v in x]
  return QorObject(or = colect)
end

#
# SQLTypeF Objects (functions from sql)
#

export Sum, Avg, Count, Max, Min, When
@kwdef mutable struct FObject <: SQLTypeF
  function_name::String
  kwargs::Dict{}
end


function Sum(x)
  return FObject(function_name = "SUM", kwargs = Dict("column" => x))
end  
function Avg(x)
  return FObject(function_name = "AVG", kwargs = Dict("column" => x))
end
function Count(x)
  return FObject(function_name = "COUNT", kwargs = Dict("column" => x))
end
function Max(x)
  return FObject(function_name = "MAX", kwargs = Dict("column" => x))
end
function Min(x)
  return FObject(function_name = "MIN", kwargs = Dict("column" => x))
end
function When(condition::Vector{Union{SQLTypeQ, SQLTypeQor}}; then::Vector{Union{String, Int64, Bool, SQLTypeF}} = [], else_result::Union{String, Int64, Bool, SQLTypeF, Missing} = missing)
  return FObject(function_name = "WHEN", kwargs = Dict("condition" => condition, "then" => then, "else_result" => else_result))
end
function When(condition::Union{SQLTypeQ, SQLTypeQor}; then::Union{String, Int64, Bool, SQLTypeF} = 1, else_result::Union{String, Int64, Bool, SQLTypeF, Missing} = missing)
  return FObject(function_name = "WHEN", kwargs = Dict("condition" => [condition], "then" => [then], "else_result" => else_result))
end

export TO_CHAR


TO_CHAR(x::Union{String, SQLTypeF}, format::String) = FObject(function_name = "TO_CHAR", kwargs = Dict("column" => x, "format" => format))
MONTH(x) = TO_CHAR(x, "MM")
YEAR(x) = TO_CHAR(x, "YYYY")
DAY(x) = TO_CHAR(x, "DD")
Y_M(x) = TO_CHAR(x, "YYYY-MM")
DATE(x) = TO_CHAR(x, "YYYY-MM-DD")



mutable struct SQLQuery <: SQLType
  model_name::Model
  values::Vector{String}
  filter::Vector{Union{SQLTypeQ, SQLTypeQor, SQLTypeOper}}
  create::Dict{String,Union{Int64, String}}
  limit::Int64
  offset::Int64
  order::Vector{String}
  group::Vector{String}
  having::Vector{String}
  list_joins::Vector{String}
  #distinct::Bool

  SQLQuery(; model_name=nothing, values = [],  filter = [], create = Dict(), limit = 0, offset = 0,
        order = [], group = [], having = [], list_joins = []) =
    new(model_name, values, filter, create, limit, offset, order, group, having, list_joins)
end

function _get_pair_list_joins(q::SQLType, v::Pair)
  push!(q.list_joins, v[1])
  unique!(q.list_joins)
end
function _get_pair_list_joins(q::SQLType, v::SQLTypeQ)
  for v in v.filters
    _get_pair_list_joins(q, v)
  end
end
function _get_pair_list_joins(q::SQLType, v::SQLTypeQor)
  for v in v.or
    _get_pair_list_joins(q, v)
  end
end

function up_values(q::SQLType, values)
  # every call of values, reset the values
  q.values = []
  for v in values 
    if isa(v, SQLTypeF)
      push!(q.values, v)
    elseif isa(v, String)
      if count(x -> x in collect(keys(PormGsuffix)), split(v, "__")) > 0
        throw("Invalid argument: $(v) does not must contain operators (lte, gte, contains ...)")
      else       
        push!(q.values, v)
      end     
    else
      throw("Invalid argument: $(v) (::$(typeof(v)))); please use a string or a function (TO_CHAR, Mounth, Year, Day, Y_M ...)")
    end    
  end 
  
  return Object(object =q)
end
  
function up_create(q::SQLType, values::Tuple{Pair{String, Int64}, Vararg{Pair{String, Int64}}})
  for (k,v) in values   
    q.values[k] = v 
  end
end

function up_filter(q::SQLType, filter)
  for v in filter
    if isa(v, SQLTypeQ) || isa(v, SQLTypeQor) 
      push!(q.filter, v)
    elseif isa(v, Pair)
      push!(q.filter, _get_pair_to_oper(v))
    else
      error("Invalid argument: $(v) (::$(typeof(v)))); please use a pair (key => value) or a Q(key => value...) or a Qor(key => value...)")
    end
  end
  return Object(object =q)
end


function query(q::SQLType) 
  instruction = build(q) 
  @info """ Query returned:
    SELECT
      $(length(instruction.select )> 0 ? join(instruction.select, ", \n  ") : "*" )
    FROM $(q.model_name) as tb
    $(join(instruction.join, "\n"))
    WHERE $(join(instruction._where, " AND \n   "))
    """
end
  
Base.@kwdef mutable struct Object <: SQLObject
  object::SQLType
  values::Function = (x...) -> up_values(object, x) 
  filter::Function = (x...) -> up_filter(object, x) 
  create::Function = (x...) -> up_create(object, x) 
  annotate::Function = (x...) -> annotate(object, x) 
  query::Function = () -> query(object)
end


export object

function object(model_name::Model)
  return Object(object = SQLQuery(model_name = model_name))
end
function object(model_name::String)
  return object(getfield(Models, Symbol(model_name)))
end
function object(model_name::Symbol)
  return object(getfield(Models, model_name))
end
 


### string(q::SQLQuery, m::Type{T}) where {T<:AbstractModel} = to_fetch_sql(m, q)
