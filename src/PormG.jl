module PormG

using Revise

import DataFrames, OrderedCollections, Distributed, Dates, Logging, Millboard, YAML
import DataFrames.DataFrame


using SQLite

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
abstract type PormGModel <: PormGAbstractType end
abstract type PormGField  <: PormGModel end # define the type of the column from the model


function build()
end

include("constants.jl")

haskey(ENV, "PORMG_ENV") || (ENV["PORMG_ENV"] = "dev")

include("Generator.jl")
using .Generator

import Inflector

include("Configuration.jl")
using .Configuration

include("Models.jl")
using .Models


const config =  Configuration.Settings(app_env = ENV["PORMG_ENV"])

export object

include("QueryBuilder.jl")
import QueryBuilder: object



include("Migrations.jl")
using .Migrations



end # module PormG
