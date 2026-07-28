module QueryBuilder

import DataFrames, Tables, JSON, CSV, OrderedCollections
using Dates, TimeZones, Decimals, UUIDs

import PormG.Models: CharField, IntegerField, get_model_pk_field, capitalize_symbol, sForeignKey, sManyToManyField
import PormG: Dialect, Models
import PormG: config
import PormG: SQLType, PormGSettings, PormGSQLite, PormGPostgres, PormGSQLiteParam, PormGPostgresParam, AbstractPormGParam, SQLInstruction, SQLTypeF, SQLTypeFunction, SQLTypeOper, SQLTypeQ, SQLTypeQor, SQLObjectHandler, SQLObject, SQLTableAlias, SQLTypeText, SQLTypeOrder, SQLTypeField, SQLTypeArrays, PormGModel, PormGField, PormGTypeField
# Semantic error taxonomy (#231, #239). The types are defined in `src/exceptions.jl`, included by
# `Kernel` (layer 1) so every subsystem can reach them; only the throw funnels (`_argerr`,
# `_unsupported_conn`, `_write_not_allowed`) still live in `querybuilder/exceptions.jl`.
import PormG: PormGError, FieldAccessError, UnknownFieldError, LazyTraversalError, FilterError,
  QueryBuildError, UnsafeMutationError, InvalidValueError, PermissionError, UnsupportedConnectionError,
  DoesNotExist, MultipleObjectsReturned
import PormG: PormGsuffix, PormGtransform, JSON_CONTAINMENT_OPERATORS, run_in_transaction
import PormG: backend_num_affected_rows  # PG matched-row count (driver body in the weakdep extension)
import PormG: backend_sqlite_version  # SQLite library-version probe for the bind-parameter limit (#84)
import PormG: _emsg  # shared TTY-aware error-message strip helper (tools.jl)
import PormG.ConnectionPool: fetch, fetch_copy, with_transaction, with_savepoint, with_sqlite_write_lock, current_task, finalize_transaction_connection!
import PormG.Configuration: with_tx_context, ensure_model_transaction_scope, transaction_connection_for,
	get_sqlite_reserved_primary_key_max, register_sqlite_reserved_primary_key_max!,
	in_transaction_context,
	get_settings as get_configuration_settings
import PormG: @pormg_debug
import Base: first, last, get

#
# SQL Sanitization
include("querybuilder/types.jl")

include("querybuilder/exceptions.jl")

include("querybuilder/sanitization.jl")

#
# Parameters
include("querybuilder/parameters.jl")

include("querybuilder/functions.jl")

include("querybuilder/object_manager.jl")

include("querybuilder/many_to_many.jl")

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
# `OP` is intentionally internal (#202): not exported and not documented. The string-lookup
# form `"field__@op" => value` is the public way to build operator predicates; `OP` is a
# low-level builder used inside the date-bucketing helpers (QUADRIMESTER/QUARTER). Reach it
# as `PormG.QueryBuilder.OP` if ever needed — it stays defined, just off the public surface.
export Q, Qor
export Sum, Avg, Count, Max, Min, When, F, Exists, OuterRef, Subquery, Case, Cast, Concat, Extract, ToChar, Value, Interval
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

export object
export get
# `page`, `query`, `update` are intentionally NOT exported (#202): they are generic names
# that pollute scope on a bare `using PormG.QueryBuilder`. The fluent `.page()`/`.update()`
# methods and explicit `import PormG.QueryBuilder: page`/`query`/`update` are unaffected —
# export status only governs the bare-`using` dump.
export PormGRow, pk, DoesNotExist, MultipleObjectsReturned
# Semantic error taxonomy (#231): every query-builder misuse throws a PormGError subtype.
export PormGError, FieldAccessError, UnknownFieldError, LazyTraversalError, FilterError,
  QueryBuildError, UnsafeMutationError, InvalidValueError, PermissionError, UnsupportedConnectionError
# do_count and do_exists are now strictly used as functors (query.count(), query.exists())
export bulk_insert, bulk_update, bulk_copy, allocate_primary_keys

include("documentation/querybuilder.jl")

end