module PormG

using Revise

import DataFrames, OrderedCollections, Distributed, Dates, Logging, Millboard, YAML
import DataFrames.DataFrame

abstract type PormGAbstractType end
abstract type SQLConn <: PormGAbstractType end
abstract type SQLType <: PormGAbstractType end
abstract type SQLObject <: PormGAbstractType end
abstract type AbstractModel <: PormGAbstractType end

function build()
end

include("constants.jl")

haskey(ENV, "PORMG_ENV") || (ENV["PORMG_ENV"] = "dev")

import Inflector

include("Configuration.jl")
using .Configuration

include("model_types.jl")
# includet("model_types.jl")


const config =  Configuration.Settings(app_env = ENV["PORMG_ENV"])

export object



include("QueryBuilder.jl")
using .QueryBuilder

function build(object::SQLType; conection=config) 
  if ismissing(object.model_name )
    throw("""You new to set a object before build a query (ex. object("table_name"))""")
  end
  println(object)
  println(typeof(object))
  # if !isa(conection, SQLConn) 
  #   throw("""You need load() before build a query (ex. PormG.Configuration.load())""")
  # end
  
  df_join = QueryBuilder.get_join_query(object, conection)
  
  if length(object.values) > 0
    for v in object.object.values
      if !haskey(model.columns, v)
        throw("Column not found")
      end
    end
  end
  
  if length(object.filter) > 0
    for (k,v) in object.object.filter
      if !haskey(model.columns, k)
        throw("Column not found")
      end
    end
  end
  
  # if length(object.object.create) > 0
  #   for (k,v) in object.object.create
  #     if !haskey(model.columns, k)
  #       throw("Column not found")
  #     end
  #   end
  # end
  
  # if length(object.object.order) > 0
  #   for v in object.object.order
  #     if !haskey(model.columns, v)
  #       throw("Column not found")
  #     end
  #   end
  # end
  
  # if length(object.object.group) > 0
  #   for v in object.object.group
  #     if !haskey(model.columns, v)
  #       throw("Column not found")
  #     end
  #   end
  # end
  
  # if length(object.object.having) > 0
  #   for v in object.object.having
  #     if !haskey(model.columns, v)
  #       throw("Column not found")
  #     end
  #   end
  # end
  
  query = "SELECT "
  
  if length(object.object.values) > 0
    query = query * join(object.object.values, ", ")
  else
    query = query * "*"
  end
  
  query = query * " FROM " * model.table_name
  
  # if length(object.object.filter) > 0
  #   query = query * " WHERE "
  #   for (k,v) in object.object.filter
  #     query = query * k * " = " * string(v) * " AND "
  #   end
  #   query = query[1:end-4]
  # end
  
  # if length(object.object.order) > 0
  #   query = query * " ORDER BY " * join(object.object.order, ", ")
  # end
  
  # if object.object.limit >

  
end
# function build(object::SQLType)
#   build(object, config)
# end





end # module PormG
