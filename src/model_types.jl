import Base.string
import Base.print
import Base.show
import Base.convert
import Base.length
import Base.==
import Base.hash

import Base.|

import Dates, Intervals

export Q, Qor

function hash(a::T) where {T<:AbstractModel}
  Base.hash(string(typeof(a)) * string(getfield(a, pk(a) |> Symbol)))
end

function ==(a::A, b::B) where {A<:AbstractModel,B<:AbstractModel}
  hash(a) == hash(b)
end


Base.@kwdef mutable struct QObject <: SQLTypeQ
  filters::Vector{Union{Pair{String, String}, Pair{String, Int64}, Pair{String, Bool}, SQLTypeQ, SQLTypeQor}}
end

Base.@kwdef mutable struct QorObject <: SQLTypeQor
  or::Vector{Union{SQLTypeQ, SQLTypeQor}}
end

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


#
# SQLJoin
#


# """
# Builds and manipulates SQL `join` expressions.
# """
# struct SQLJoin{T<:AbstractModel} <: SQLType
#   model_name::Type{T}
#   on::Vector{SQLOn}
#   join_type::SQLJoinType
#   outer::Bool
#   where::Vector{SQLWhereEntity}
#   natural::Bool
#   columns::Vector{SQLColumn}
# end

# SQLJoin(model_name::Type{T},
#         on::Vector{SQLOn};
#         join_type = SQLJoinType("INNER"),
#         outer = false,
#         where = SQLWhereEntity[],
#         natural = false,
#         columns = SQLColumn[]) where {T<:AbstractModel} = SQLJoin{T}(model_name, on, join_type, outer, where, natural, columns)

# SQLJoin(model_name::Type{T},
#         on_column_1::Union{String,SQLColumn},
#         on_column_2::Union{String,SQLColumn};
#         join_type = SQLJoinType("INNER"),
#         outer = false,
#         where = SQLWhereEntity[],
#         natural = false,
#         columns = SQLColumn[]) where {T<:AbstractModel} = SQLJoin(model_name, SQLOn(on_column_1, on_column_2), join_type = join_type, outer = outer, where = where, natural = natural, columns = columns)

# function string(j::SQLJoin)


#
# SQLQuery
#


mutable struct SQLQuery <: SQLType
  model_name::Union{String, Missing}
  values::Vector{String}
  filter::Vector{Union{SQLTypeQ, SQLTypeQor, Pair{String, String}, Pair{String, Int64}, Pair{String, Bool}}}
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
  query::Function = () -> query(object)
end


replace("teste", "teste" => "teste2")

export object

function object(model_name::String)
  return Object(object = SQLQuery(model_name = model_name))
end


# string(q::SQLQuery, m::Type{T}) where {T<:AbstractModel} = to_fetch_sql(m, q)