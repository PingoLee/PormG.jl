module PormG

__precompile__()

using Revise
using Infiltrator

import DataFrames, OrderedCollections, Distributed, Dates, Logging, Millboard, YAML
import DataFrames.DataFrame


using SQLite
using LibPQ

abstract type PormGAbstractType end
abstract type SQLConn <: PormGAbstractType end
abstract type SQLObject <: PormGAbstractType end
abstract type SQLObjectHandler <: SQLObject end
abstract type SQLTableAlias <: SQLObject end # Manage the name from table alias
abstract type SQLInstruction <: PormGAbstractType end # instruction to build a query
abstract type SQLType <: PormGAbstractType end
abstract type SQLTypeQ <: SQLType end
abstract type SQLTypeQor <: SQLType end
abstract type SQLTypeF <: SQLType end
abstract type SQLTypeOper <: SQLType end
abstract type SQLTypeText <: SQLType end # raw texgt to be used in the query
abstract type SQLTypeArrays <: SQLType end # Arrays to orgnize the query informations 
abstract type SQLTypeField <: SQLType end # Field to be used in the query (values, filters, etc)
abstract type SQLTypeOrder <: SQLTypeField end # Order to be used in the query

abstract type AbstractModel <: PormGAbstractType end
abstract type PormGModel <: PormGAbstractType end
abstract type PormGField  <: PormGModel end # define the type of the column from the model

abstract type Migration <: PormGAbstractType end

const config::Dict{String,SQLConn} = Dict()

if !haskey(ENV, "PORMG_ENV")
  ENV["PORMG_ENV"] = "dev"
end

include("constants.jl")

# upper functions
function get_constraints_pk end
function get_constraints_unique end

include("Generator.jl")
using .Generator

import Inflector

include("Configuration.jl")
using .Configuration

include("Models.jl")
using .Models

include("Dialect.jl")
import .Dialect

export object, show_query, list

include("QueryBuilder.jl")
import .QueryBuilder: object, query, list, page
show_query = query

include("Migrations.jl")
using .Migrations



end # module PormG
