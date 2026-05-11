module QueryBuilder

import DataFrames, Tables, JSON, CSV
using Dates, TimeZones, Intervals, Decimals, UUIDs
using SQLite, LibPQ

import PormG.Models: CharField, IntegerField, get_model_pk_field, capitalize_symbol, sForeignKey
import PormG: Dialect, Models
import PormG: config
import PormG: SQLType, SQLConn, PormGSQLite, PormGPostgres, PormGSQLiteParam, PormGPostgresParam, AbstractPormGParam, SQLInstruction, SQLTypeF, SQLTypeFunction, SQLTypeOper, SQLTypeQ, SQLTypeQor, SQLObjectHandler, SQLObject, SQLTableAlias, SQLTypeText, SQLTypeOrder, SQLTypeField, SQLTypeArrays, PormGModel, PormGField, PormGTypeField
import PormG: PormGsuffix, PormGtransform, run_in_transaction
import PormG.ConnectionPool: fetch, fetch_copy, with_transaction, with_savepoint, current_task
import PormG.Configuration: with_tx_context, ensure_model_transaction_scope, transaction_connection_for,
	get_sqlite_reserved_primary_key_max, register_sqlite_reserved_primary_key_max!,
	get_settings as get_configuration_settings
import PormG: @pormg_debug
import Base: first

#
# SQL Sanitization
include("querybuilder/types.jl")

include("querybuilder/sanitization.jl")

#
# Parameters
include("querybuilder/parameters.jl")

include("querybuilder/functions.jl")

include("querybuilder/object_manager.jl")

include("querybuilder/operators.jl")

include("querybuilder/build_helpers.jl")

include("querybuilder/build_joins.jl")

include("querybuilder/build_query.jl")

include("querybuilder/execution.jl")

include("querybuilder/execution_bulk.jl")

import PormG: CASCADE, RESTRICT, SET_NULL, SET_DEFAULT, SET, PROTECT

include("querybuilder/deletion.jl")

include("querybuilder/ctes.jl")


#
# SQLTypeOper Objects (operators from sql)
#
export OP
export Q, Qor
export Sum, Avg, Count, Max, Min, When, F, Exists, OuterRef, Case, Cast, Concat, Extract, To_char, Value
export WindowOver, WindowSpec, Rank, DenseRank, RowNumber, Lag, Lead, FirstValue, LastValue, NthValue
export Coalesce, Greatest, Least, Lower, Upper, Length, Abs, Round, NullIf, Replace, Trim, LTrim, RTrim
export Floor, Ceil, Sqrt, Exp, Ln, Power, Mod
export With


# TODO: finish this function to get the joins from filters
# function _get_pair_list_joins(q::SQLObject, v::Pair)
#   push!(q.list_joins, v[1])
#   unique!(q.list_joins)
# end
# function _get_pair_list_joins(q::SQLObject, v::SQLTypeQ)
#   for v in v.filters
#     _get_pair_list_joins(q, v)
#   end
# end
# function _get_pair_list_joins(q::SQLObject, v::SQLTypeQor)
#   for v in v.or
#     _get_pair_list_joins(q, v)
#   end
# end

export cjoin
export object
export page
export query
export update
# do_count and do_exists are now strictly used as functors (query.count(), query.exists())
export bulk_insert, bulk_update, bulk_copy, allocate_primary_keys

include("documentation/querybuilder.jl")

end