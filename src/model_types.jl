import Base.string
import Base.print
import Base.show
import Base.convert
import Base.length
import Base.==
import Base.hash

import Dates, Intervals



function hash(a::T) where {T<:AbstractModel}
  Base.hash(string(typeof(a)) * string(getfield(a, pk(a) |> Symbol)))
end

function ==(a::A, b::B) where {A<:AbstractModel,B<:AbstractModel}
  hash(a) == hash(b)
end

# function Base.print(io::IO, t::T) where {T<:PormGAbstractType}
#   props = []
#   for (k,v) in to_string_dict(t)
#     push!(props, "$k=$v")
#   end
#   print(io, string("$(typeof(t))(", join(props, ','), ")"))
# end

# Base.show(io::IO, t::T) where {T<:PormGAbstractType} = print(io, PormGAbstractType_to_print(t))

# """
#     PormGAbstractType_to_print{T<:PormGAbstractType}(m::T) :: String

# Pretty printing of SearchLight types.
# """
# function PormGAbstractType_to_print(m::T) :: String where {T<:PormGAbstractType}
#   string(typeof(m), "\n", Millboard.table(to_string_dict(m)), "\n")
# end



#
# SQLColumn
#


"""
Represents a SQL column when building SQL queries.
"""
mutable struct SQLColumn <: SQLType
  value::String
  escaped::Bool
  raw::Bool
  table_name::String
  column_name::String
end
SQLColumn(v::Union{String,Symbol}; escaped = false, raw = false, table_name = "", column_name = "") = begin
  SQLColumn(string(v), escaped, raw, string(table_name), string(v))
end
# SQLColumn(a::Array) = map(x -> SQLColumn(x), a)
# SQLColumn(t::Tuple) = SQLColumn([t...])
# ==(a::SQLColumn, b::SQLColumn) = a.value == b.value



#
# SQLLogicOperator
#

#
# SQLWhere
#

"""
Represents the `ON` operator used in SQL `JOIN`
"""
# struct SQLOn <: SQLType
#   column_1::SQLColumn
#   column_2::SQLColumn
#   conditions::Vector{SQLWhereEntity}

#   SQLOn(column_1, column_2; conditions = SQLWhereEntity[]) = new(column_1, column_2, conditions)
# end
# function string(o::SQLOn)
#   on = " ON $(o.column_1) = $(o.column_2) "
#   if ! isempty(o.conditions)
#     on *= " AND " * join( map(x -> string(x), o.conditions), " AND " )
#   end

#   on
# end

# convert(::Type{Vector{SQLOn}}, j::SQLOn) = [j]




"""
Provides functionality for building and manipulating SQL `WHERE` conditions.
"""
struct SQLWhere <: SQLType
  column::SQLColumn
  value::Union{String, Int64, Float64, Bool}
  condition::String
  operator::String

  SQLWhere(column::SQLColumn, value::Union{String, Int64, Float64, Bool}, condition::String, operator::String) =
    new(column, value, condition, operator)
end



#
# SQLJoin - SQLJoinType
#

struct InvalidJoinTypeException <: Exception
  jointype::String
end

Base.showerror(io::IO, e::InvalidJoinTypeException) = print(io, "Invalid join type $(e.jointype)")

"""
Wrapper around the various types of SQL `join` (`left`, `right`, `inner`, etc).
"""
struct SQLJoinType <: SQLType
  join_type::String

  function SQLJoinType(t::Union{String,Symbol})
    t = string(t)
    accepted_values = ["inner", "INNER", "left", "LEFT", "right", "RIGHT", "full", "FULL"]
    if in(t, accepted_values)
      new(uppercase(t))
    else
      @error  """Accepted JOIN types are $(join(accepted_values, ", "))"""
      throw(InvalidJoinTypeException(t))
    end
  end
end

convert(::Type{SQLJoinType}, s::Union{String,Symbol}) = SQLJoinType(s)

string(jt::SQLJoinType) = jt.join_type

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
#   sql = """ $(j.natural ? "NATURAL " : "") $(string(j.join_type)) $(j.outer ? "OUTER " : "") JOIN $( escape_column_name(table(j.model_name), SearchLight.connection())) $(join(string.(j.on), " AND ")) """
#   sql *=  if ! isempty(j.where)
#           SearchLight.to_where_part(j.where)
#         else
#           ""
#         end

#   sql = replace(sql, "  " => " ")

#   replace(sql, " AND ON " => " AND ")
# end

# convert(::Type{Vector{SQLJoin}}, j::SQLJoin) = [j]


#
# SQLQuery
#


mutable struct SQLQuery <: SQLType
  model_name::Union{String, Missing}
  values::Vector{String}
  filter::Dict{String,Union{Int64, String}} 
  create::Dict{String,Union{Int64, String}}
  limit::Int64
  offset::Int64
  order::Vector{String}
  group::Vector{String}
  having::Vector{String}

  SQLQuery(; model_name=missing, values = [],  filter = Dict(), create = Dict(), limit = 0, offset = 0,
        order = [], group = [], having = []) =
    new(model_name, values, filter, create, limit, offset, order, group, having)
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
  for (k,v) in filter   
    q.filter[k] = v 
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