module QueryBuilder

import DataFrames, Tables, JSON, CSV, OrderedCollections
# `DataFrame` by name, not just the module: `query |> DataFrame` has its docstring attached here, and
# the `public DataFrame` below (#289) needs a BINDING to mark — `public` on a name this module cannot
# resolve creates a public-but-undefined entry, which Aqua's `test_undefined_exports` rightly fails.
import DataFrames: DataFrame
using Dates, TimeZones, Decimals, UUIDs

import PormG.Models: CharField, IntegerField, get_model_pk_field, sForeignKey, sManyToManyField, sBinaryField
import PormG: Dialect, Models
import PormG: config
import PormG: SQLType, PormGSettings, PormGSQLite, PormGPostgres, PormGSQLiteParam, PormGPostgresParam, AbstractPormGParam, SQLInstruction, SQLTypeF, SQLTypeFunction, SQLTypeOper, SQLTypeQ, SQLTypeQor, SQLObjectHandler, SQLObject, SQLTableAlias, SQLTypeText, SQLTypeOrder, SQLTypeField, SQLTypeArrays, PormGModel, PormGField, PormGTypeField
import PormG: PormGBytes  # binary payloads bind as one blob, not as an array of values (#296)
# Semantic error taxonomy (#231, #239). The types are defined in `src/exceptions.jl`, included by
# `Kernel` (layer 1) so every subsystem can reach them; only the message-composing funnels
# (`_unsupported_conn`, `_write_not_allowed`) live in `querybuilder/error_funnels.jl`.
import PormG: PormGError, FieldAccessError, UnknownFieldError, LazyTraversalError, FilterError,
  QueryBuildError, UnsafeMutationError, InvalidValueError, WritesDisabledError, UnsupportedConnectionError, BackendCapabilityError, ProtectedError,
  InvalidConfigurationError,   # thrown by the model-not-bound guards (audit: was UnsupportedConnectionError)
  DoesNotExist, MultipleObjectsReturned,
  # Not thrown here — CAUGHT here: last()/save()/delete() convert Models' composite-pk failure
  # into an actionable QueryBuildError (#239).
  ModelDefinitionError,
  # Also CAUGHT, not thrown (#344): the two abstract roots `_update_sequence` allowlists when it
  # decides whether a failed sequence repair is tolerable. Everything outside them propagates.
  DatabaseError, PoolError
import PormG: PormGsuffix, PormGtransform, JSON_CONTAINMENT_OPERATORS, run_in_transaction
import PormG: backend_num_affected_rows  # PG matched-row count (driver body in the weakdep extension)
import PormG: backend_sqlite_version  # SQLite library-version probe for the bind-parameter limit (#84)
import PormG: _emsg  # shared TTY-aware error-message strip helper (tools.jl)
import PormG.ConnectionPool: fetch, fetch_copy, with_transaction, with_savepoint, with_sqlite_write_lock, current_task, finalize_transaction_connection!
# #344: "was this failure a cancellation?" — sees through the DatabaseError wrapper the pool applies,
# which a bare `e isa InterruptException` test cannot (every driver error crosses `_as_database_error`).
import PormG.ConnectionPool: _await_abandoned
import PormG.Configuration: with_tx_context, ensure_model_transaction_scope, transaction_connection_for,
	get_sqlite_reserved_primary_key_max, register_sqlite_reserved_primary_key_max!,
	in_transaction_context,
	get_settings as get_configuration_settings
import PormG: @pormg_debug
import Base: first, last, get

#
# SQL Sanitization
include("querybuilder/types.jl")

include("querybuilder/error_funnels.jl")

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

import PormG: CASCADE, RESTRICT, SET_NULL, SET_DEFAULT, PROTECT

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
  QueryBuildError, UnsafeMutationError, InvalidValueError, WritesDisabledError, UnsupportedConnectionError, BackendCapabilityError, ProtectedError
# _count and _exists are un-exported (#202); the public form is the fluent query.count() /
# query.exists(). They still have internal callers — deletion.jl uses both.
export bulk_insert, bulk_update, bulk_copy, allocate_primary_keys

# ---
# `public` (Julia 1.11+) — user-facing but deliberately NOT exported (#289).
#
# These are real API: `docs/src/api.md` gives them tables and headings, and users reach them through
# the fluent surface (`query.delete()`, `query.list()`, `q |> DataFrame`) rather than by importing a
# name, which is why exporting them would only pollute a bare `using`. `public` says "this is API"
# without changing what `using` dumps into scope.
#
# It is also load-bearing for the docs build: `docs/src/api.md`'s `@autodocs` sets `Private = false`,
# and Documenter decides public/private with `Base.ispublic(mod, name)` against the module the
# docstring was attached in — never PormG's export list. Anything user-facing here that is not
# `public` silently vanishes from the API reference. `show_query`/`inspect_query` are the sharp case:
# exported from `PormG`, but defined here, so only this declaration keeps them on the page.
public delete, list, save, earliest, latest, ObjectHandler, inspect_query, show_query

# Foreign bindings whose docstrings live in this module's meta: the `.first()` / `.last()` terminals
# and `query |> DataFrame`. `public` works on an imported name (it marks the binding in THIS module),
# and does not touch `Base`/`DataFrames`.
public first, last, DataFrame


end