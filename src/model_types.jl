import Base.string
import Base.print
import Base.show
import Base.convert
import Base.length
import Base.==
import Base.hash

import Base.|

import Dates, Intervals


#
# SQLTypeOper Objects (operators from sql)
#

# export In, NotIn, Between, NotBetween, Like, NotLike, ILike, NotILike, SimilarTo, NotSimilarTo, IsNull, IsNotNull

@kwdef mutable struct OperObject <: SQLTypeOper
  operator::String
  values::Union{String, Int64, Bool, SQLTypeF}
  column::Union{String, SQLTypeF}
end

function _get_pair_to_oper(x::Pair)
  if isa(x.first, String)
    check = split(x.first, "__")
    # check if exist operators
    if check in PormGsuffix
      return OperObject(operator = PormGsuffix[check], values = x.second, column = check[1])
    else
      return OperObject(operator = "=", values = x.second, column = x.first)
    end

  else
    throw()
end
 

#
# SQLTypeQ and SQLTypeQor Objects
#

export Q, Qor

@kwdef mutable struct QObject <: SQLTypeQ
  filters::Vector{Union{SQLTypeOper, SQLTypeQ, SQLTypeQor}}
end

@kwdef mutable struct QorObject <: SQLTypeQor
  or::Vector{Union{SQLTypeQ, SQLTypeQor}}
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
  colect = []
  for v in x
    if isa(v, Pair) || isa(v, SQLTypeQor)
      push!(colect, v)
    else
      error("Invalid argument: $(v); please use a pair (key => value)")
    end
  end
  println(colect)
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
  colect = []
  for v in x
    if isa(v, SQLTypeQ) || isa(v, SQLTypeQor)
      push!(colect, v)
    elseif isa(v, Pair)
      push!(colect, Q(v))
    else
      error("Invalid argument: $(v); please use a pair (key => value) or a Q(key => value...)")
    end
  end
  println(colect)
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




mutable struct SQLQuery <: SQLType
  model_name::Union{String, Missing}
  values::Vector{String}
  filter::Vector{Union{SQLTypeQ, SQLTypeQor, SQLTypeOper}}
  create::Dict{String,Union{Int64, String}}
  limit::Int64
  offset::Int64
  order::Vector{String}
  group::Vector{String}
  having::Vector{String}
  list_joins::Vector{String}

  SQLQuery(; model_name=missing, values = [],  filter = [], create = Dict(), limit = 0, offset = 0,
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

function up_values(q::SQLType, values::Tuple{String, Vararg{String}})
  for v in values   
    push!(q.values, v)
  end 
  unique!(q.values)
  
  return Object(object =q)
end
  
function up_create(q::SQLType, values::Tuple{Pair{String, Int64}, Vararg{Pair{String, Int64}}})
  for (k,v) in values   
    q.values[k] = v 
  end
end

function up_filter(q::SQLType, filter)
  for v in filter
    if ~isa(v, SQLTypeQ) && ~isa(v, SQLTypeQor) && ~isa(v, Pair)
      error("Invalid argument: $(v) (::$(typeof(v)))); please use a pair (key => value) or a Q(key => value...) or a Qor(key => value...)")
    else
      push!(q.filter, v)
      _get_pair_list_joins(q, v)
    end
  end
  return Object(object =q)
end


function query(q::SQLType) 
  build(q) 
end
  
Base.@kwdef mutable struct Object <: SQLObject
  object::SQLType
  values::Function = (x...) -> up_values(object, x) 
  filter::Function = (x...) -> up_filter(object, x) 
  create::Function = (x...) -> up_create(object, x) 
  annotate::Function = (x...) -> annotate(object, x) 
  query::Function = () -> query(object)
end


replace("teste", "teste" => "teste2")

export object

function object(model_name::String)
  return Object(object = SQLQuery(model_name = model_name))
end


# string(q::SQLQuery, m::Type{T}) where {T<:AbstractModel} = to_fetch_sql(m, q)