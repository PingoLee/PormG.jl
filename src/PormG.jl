module PormG

using PrecompileTools
using Infiltrator

import DataFrames, OrderedCollections, Distributed, Dates, Logging, Millboard, YAML

using SQLite
using LibPQ

abstract type PormGAbstractType end
abstract type SQLConn <: PormGAbstractType end
abstract type PormGPostgres <: SQLConn end
abstract type PormGSQLite <: SQLConn end
abstract type AbstractPormGParam <: PormGAbstractType end  # Base type for all parameterized queries
abstract type PormGPostgresParam <: AbstractPormGParam end  # PostgreSQL numbered params ($1, $2...)
abstract type PormGSQLiteParam <: AbstractPormGParam end    # SQLite positional params with contextual buckets
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

include("Passwords.jl")
using .Passwords

# upper functions
function get_constraints_pk end
function get_constraints_unique end

include("Generator.jl")
using .Generator

import Inflector

include("Configuration.jl")
using .Configuration

include("tools.jl")

include("ConnectionPool.jl")
using .ConnectionPool

include("Models.jl")
using .Models

include("Utils.jl")
using .Utils
export @models_module, @import_models

include("Dialect.jl")
import .Dialect

include("AdvisoryLock.jl")
using .AdvisoryLock

include("QueryBuilder.jl")
import .QueryBuilder: object, Q, Qor, F, Sum, Avg, Count, Max, Min, show_query, inspect_query, list, list_json, page, bulk_insert, bulk_update, bulk_copy, delete, do_count, do_exists, With, cjoin, Case, Cast, Concat, Extract, To_char, Value, Coalesce, Greatest, Least, Lower, Upper, Length, Abs, Round, NullIf, Replace, Trim, LTrim, RTrim, Floor, Ceil, Sqrt, Exp, Ln, Power, Mod

export object, Q, Qor, F, Sum, Avg, Count, Max, Min, show_query, inspect_query, list, list_json, bulk_insert, bulk_update, bulk_copy, delete, do_count, do_exists, With, cjoin, Case, Cast, Concat, Extract, To_char, Value, Coalesce, Greatest, Least, Lower, Upper, Length, Abs, Round, NullIf, Replace, Trim, LTrim, RTrim, Floor, Ceil, Sqrt, Exp, Ln, Power, Mod
export with_advisory_lock, try_advisory_lock, release_advisory_lock
export fetch_async, await_result, FetchTask, run_in_transaction  # Async-first API
export with_tx_context, in_transaction_context  # Transaction context helpers
export make_password, check_password, password_needs_upgrade, DEFAULT_PBKDF2_ITERATIONS # Password utilities
export validate_password, ValidationResult, PasswordValidator  # Password validation

export setup

include("Migrations.jl")
using .Migrations

include("precompile.jl")

atexit(Configuration.__cleanup__)


end # module PormG
