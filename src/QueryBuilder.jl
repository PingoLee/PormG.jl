module QueryBuilder

import PornG
import DataFrames

import Base: (+) #, select
# TODO: Base.isequal and Base.hash

export from, select, where, limit, offset, order, group, having, prepare

struct MissingModel <: PornG.AbstractModel
end

struct QueryPart{T<:PornG.AbstractModel}
  model::Type{T}
  query::PornG.SQLQuery
end


function from(model::Type{T})::QueryPart{T} where {T<:PornG.AbstractModel}
  QueryPart(model, PornG.SQLQuery())
end


function select(columns::Vararg{Union{Symbol,String,PornG.SQLColumn,PornG.SQLRaw}}) :: QueryPart
  QueryPart(MissingModel, PornG.SQLQuery(columns = PornG.SQLColumn([columns...])))
end


function where(sql_expression::String)::QueryPart
  QueryPart(MissingModel, PornG.SQLQuery(where = [PornG.SQLWhereExpression(sql_expression)]))
end
function where(sql_expression::String, values::Vararg{Any})::QueryPart
  QueryPart(MissingModel, PornG.SQLQuery(where = [PornG.SQLWhereExpression(sql_expression, [values...])]))
end


function limit(lim::Int)
  QueryPart(MissingModel, PornG.SQLQuery(limit = PornG.SQLLimit(lim)))
end


function offset(off::Int)
  QueryPart(MissingModel, PornG.SQLQuery(offset = off))
end


function order(ordering::Union{Symbol,String})
  QueryPart(MissingModel, PornG.SQLQuery(order = PornG.SQLOrder(ordering)))
end
function order(column::Union{Symbol,String}, direction::Union{Symbol,String})
  QueryPart(MissingModel, PornG.SQLQuery(order = PornG.SQLOrder(column, direction)))
end


function group(columns::Vararg{Union{Symbol,String}})
  QueryPart(MissingModel, PornG.SQLQuery(group = PornG.SQLColumn([columns...])))
end


function having(sql_expression::String)::QueryPart
  QueryPart(MissingModel, PornG.SQLQuery(having = [PornG.SQLWhereExpression(sql_expression)]))
end
function having(sql_expression::String, values::Vararg{Any})::QueryPart
  QueryPart(MissingModel, PornG.SQLQuery(having = [PornG.SQLWhereExpression(sql_expression, [values...])]))
end


function prepare(qb::QueryPart{T}) where {T<:PornG.AbstractModel}
  (qb.model::Type{T}, qb)
end
function prepare(model::Type{T}, qb::QueryPart) where {T<:PornG.AbstractModel}
  prepare(from(model) + qb)
end


function (+)(q::PornG.SQLQuery, r::PornG.SQLQuery)
  PornG.SQLQuery(
    columns = vcat(q.columns, r.columns),
    where   = vcat(q.where, r.where),
    limit   = r.limit.value == PornG.SQLLimit_ALL ? q.limit : r.limit,
    offset  = r.offset != 0 ? r.offset : q.offset,
    order   = vcat(q.order, r.order),
    group   = vcat(q.group, r.group),
    having  = vcat(q.having, r.having)
  )
end


function (+)(q::QueryPart, r::QueryPart)
  QueryPart(
    r.model == MissingModel ? q.model : r.model,
    q.query + r.query
  )
end


### API


function DataFrames.DataFrame(m::Type{T}, qp::QueryBuilder.QueryPart, j::Union{Nothing,Vector{PornG.SQLJoin}} = nothing)::DataFrames.DataFrame where {T<:PornG.AbstractModel}
  PornG.DataFrame(m, qp.query, j)
end


function PornG.find(m::Type{T}, qp::QueryBuilder.QueryPart,
                      j::Union{Nothing,Vector{PornG.SQLJoin}} = nothing)::Vector{T} where {T<:PornG.AbstractModel}
  PornG.find(m, qp.query, j)
end


function PornG.first(m::Type{T}, qp::QueryBuilder.QueryPart)::Union{Nothing,T} where {T<:PornG.AbstractModel}
  PornG.find(m, qp + QueryBuilder.limit(1)) |> onereduce
end


function PornG.last(m::Type{T}, qp::QueryBuilder.QueryPart)::Union{Nothing,T} where {T<:PornG.AbstractModel}
  PornG.find(m, qp + QueryBuilder.limit(1)) |> onereduce
end


function PornG.count(m::Type{T}, qp::QueryBuilder.QueryPart)::Int where {T<:PornG.AbstractModel}
  PornG.count(m, qp.query)
end


function PornG.sql(m::Type{T}, qp::QueryBuilder.QueryPart)::String where {T<:PornG.AbstractModel}
  PornG.sql(m, qp.query)
end

end