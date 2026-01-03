module PormG

__precompile__()

using Revise
using Infiltrator

import DataFrames, OrderedCollections, Distributed, Dates, Logging, Millboard, YAML

using SQLite
using LibPQ

abstract type PormGAbstractType end
abstract type SQLConn <: PormGAbstractType end
abstract type PormGPostgres <: SQLConn end
abstract type PormGSQLite <: SQLConn end
abstract type PormGPostgresParam <: PormGPostgres end
abstract type PormGSQLiteParam <: PormGSQLite end
abstract type SQLObject <: PormGAbstractType end
abstract type SQLObjectHandler <: SQLObject end
abstract type SQLTableAlias <: SQLObject end # Manage the name from table alias
abstract type SQLInstruction <: PormGAbstractType end # instruction to build a query
abstract type SQLType <: PormGAbstractType end
abstract type SQLTypeQ <: SQLType end
abstract type SQLTypeQor <: SQLType end
abstract type SQLTypeF <: SQLType end
abstract type SQLTypeFunction <: SQLType end # Function to be used in the query
abstract type SQLTypeOper <: SQLType end
abstract type SQLTypeText <: SQLType end # raw texgt to be used in the query
abstract type SQLTypeArrays <: SQLType end # Arrays to orgnize the query informations 
abstract type SQLTypeField <: SQLType end # Field to be used in the query (values, filters, etc)
abstract type SQLTypeOrder <: SQLTypeField end # Order to be used in the query
abstract type SQLTypeCTE <: SQLType end # Common Table Expression (WITH clause)


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

include("AdvisoryLock.jl")
using .AdvisoryLock

include("QueryBuilder.jl")
import .QueryBuilder: object, show_query, list, list_json, page, bulk_insert, bulk_update, delete, do_count, do_exists, With, cjoin

export object, show_query, list, list_json, bulk_insert, bulk_update, delete, do_count, do_exists, With, cjoin
export with_advisory_lock, try_advisory_lock, release_advisory_lock
export fetch_async, await_result, FetchTask, run_in_transaction  # Async-first API
export with_tx_context, in_transaction_context  # Transaction context helpers

include("Migrations.jl")
using .Migrations

atexit(Configuration.__cleanup__)


end # module PormG
