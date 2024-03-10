module PormG

using Revise

import DataFrames, OrderedCollections, Distributed, Dates, Logging, Millboard, YAML
import DataFrames.DataFrame

abstract type PormGAbstractType end
abstract type SQLConn <: PormGAbstractType end
abstract type SQLType <: PormGAbstractType end
abstract type SQLInstruction <: PormGAbstractType end # instruction to build a query
abstract type SQLTypeQ <: SQLType end
abstract type SQLTypeQor <: SQLType end
abstract type SQLTypeF <: SQLType end
abstract type SQLTypeOper <: SQLType end
abstract type SQLObject <: PormGAbstractType end
abstract type AbstractModel <: PormGAbstractType end
abstract type Model <: PormGAbstractType end
abstract type Field  <: Model end # define the type of the column from the model

function build()
end

include("constants.jl")

haskey(ENV, "PORMG_ENV") || (ENV["PORMG_ENV"] = "dev")

import Inflector

include("Configuration.jl")
using .Configuration

include("model_types.jl")


include("Models.jl")
using .Models


const config =  Configuration.Settings(app_env = ENV["PORMG_ENV"])

export object

include("QueryBuilder.jl")
import .QueryBuilder: get_select_query, get_filter_query, build_row_join_sql_text

function build(object::SQLType; conection=config) 
  if ismissing(object.model_name )
    throw("""You new to set a object before build a query (ex. object("table_name"))""")
  end

  instruct = InstrucObject(text = "", 
    select = [], 
    join = [],
    _where = [],
    group = [],
    having = [],
    order = [],
    df_join = DataFrames.DataFrame(a=String[], b=String[], key_a=String[], key_b=String[], how=String[], 
    alias_b=String[], alias_a=String[]),
    df_object = DataFrames.subset(conection.columns, DataFrames.AsTable([:table_name]) => ( @. r -> r.table_name == object.model_name )),  
    df_pks = conection.pk, 
    df_columns = conection.columns)

   
  
  # df_sels, df_join, text_on = QueryBuilder.get_join_query(object, conection)
  
  QueryBuilder.get_select_query(object, instruct)
  QueryBuilder.get_filter_query(object, instruct)
  QueryBuilder.build_row_join_sql_text(instruct)

  # println("TESTE")
  # println(instruct.select)
  # println(instruct._where)
  # println(instruct.df_join)

  # filter = QueryBuilder.get_filter_query(object, df_sels)

  
  # text_values = [] 
  # for v in values
  #   push!(text_values, string(v["text"], " as ", v["value"]))
  # end

  # filter_Values = []
  # for v in filter
  #   push!(filter_Values, v["text"])
  # end
 
  # return """SELECT $(join(text_values, ", ")) FROM $(object.model_name) as tb $text_on WHERE $(join(filter_Values, " AND ")))"""

  return instruct
end
# function build(object::SQLType)
#   build(object, config)
# end





end # module PormG
