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
import .QueryBuilder: get_join_query, get_select_query, get_filter_query

function build(object::SQLType; conection=config) 
  if ismissing(object.model_name )
    throw("""You new to set a object before build a query (ex. object("table_name"))""")
  end
  
  
  df_sels, df_join, text_on = QueryBuilder.get_join_query(object, conection)
  
  values = QueryBuilder.get_select_query(object, df_sels)

  filter = QueryBuilder.get_filter_query(object, df_sels)

  
  text_values = [] 
  for v in values
    push!(text_values, string(v["text"], " as ", v["value"]))
  end

  filter_Values = []
  for v in filter
    push!(filter_Values, v["text"])
  end
 
  return """SELECT $(join(text_values, ", ")) FROM $(object.model_name) as tb $text_on WHERE $(join(filter_Values, " AND ")))"""

  
end
# function build(object::SQLType)
#   build(object, config)
# end





end # module PormG
