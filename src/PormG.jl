module PormG

using PrecompileTools

# Internal debug hook — no-op in production.
#
# HOW TO USE BREAKPOINTS (requires dev + Revise, because macros are compile-time):
#
#   Step 1 — switch to source in your project:
#     ]dev PormG
#
#   Step 2 — load Revise + Infiltrator before PormG in your REPL/startup.jl:
#     using Revise, Infiltrator
#     using PormG   # Revise now tracks PormG source
#
#   Step 3 — redefine the macro (before editing any source file):
#     PormG.eval(:(macro pormg_debug(ex); :(Infiltrator.@infiltrate($(esc(ex)))); end))
#
#   Step 4 — edit the target .jl file (e.g. change `@pormg_debug false` → `@pormg_debug true`).
#     Revise re-parses the file and the macro now expands to a real breakpoint.
#
# NOTE: redefining the macro alone (without Revise re-parsing the call site) has no effect,
# because macro expansion happens at parse time, not at runtime.
macro pormg_debug()
  return nothing
end
macro pormg_debug(ex)
  return nothing
end
export @pormg_debug

import DataFrames, OrderedCollections, Dates, Logging, YAML

# NOTE: LibPQ and SQLite are weak dependencies (Project.toml `[weakdeps]`). Core never
# names a concrete driver type; all driver work goes through the backend generics in
# `Backend.jl`, whose methods live in `ext/PormGLibPQExt.jl` / `ext/PormGSQLiteExt.jl`
# and load on `using LibPQ` / `using SQLite`.

abstract type PormGAbstractType end
abstract type PormGSettings <: PormGAbstractType end
# Backend/dialect markers: the dispatch key for SQL rendering and driver selection. NOT <: PormGSettings —
# PormGSettings is the Settings/config type, and a pool carries none of its fields (#186). Concrete pools are
# PostgresConnectionPool <: PormGPostgres and SQLiteConnectionPool <: PormGSQLite.
abstract type PormGBackend <: PormGAbstractType end
abstract type PormGPostgres <: PormGBackend end
abstract type PormGSQLite <: PormGBackend end
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


abstract type PormGModel <: PormGAbstractType end
# A field is a COMPONENT of a model, not a kind of model — a sibling, not a subtype, so it does not
# satisfy ::PormGModel signatures (which all read model-only attributes) (#186).
abstract type PormGField <: PormGAbstractType end # define the type of the column from the model

abstract type Migration <: PormGAbstractType end

# Root of the semantic error taxonomy (#231). Subtypes <: Exception (NOT <: ArgumentError — a
# clean break, so callers catch a type instead of string-matching a message). Declared at the top
# module level so every submodule can `import PormG: PormGError`; the concrete query-builder
# subtypes live in `src/querybuilder/exceptions.jl`. Extends the #197 typed-exception lineage.
abstract type PormGError <: Exception end

const config::Dict{String,PormGSettings} = Dict()

include("constants.jl")

# Backend interface (empty generics + friendly fallbacks); driver bodies live in the
# weakdep extensions. Must precede Configuration/ConnectionPool, which call the generics.
include("Backend.jl")

# upper functions
function get_constraints_pk end
function get_constraints_unique end
function get_constraints_check end

include("Generator.jl")
using .Generator

include("Configuration.jl")
using .Configuration

include("tools.jl")

include("ConnectionPool.jl")
using .ConnectionPool

# Convenience overload: `pool_stats` by connection key/path (#127). The pool-struct method lives in
# ConnectionPool; extend the SAME function here, where both it and `Configuration.get_settings` are in
# scope. `import` (not just the `using` above) is required to add a method rather than shadow the name.
import .ConnectionPool: pool_stats
function pool_stats(key::AbstractString)
  # String(key): get_settings is ::String-only, so a SubString/other AbstractString key would
  # otherwise die with a raw MethodError instead of resolving. Throwing (rather than the silent
  # no-op close_pool!(::String) uses for teardown) is deliberate for a stats query: a zeroed
  # snapshot for a never-built pool would read as a healthy empty pool.
  pool = Configuration.get_settings(String(key)).connections
  pool === nothing && throw(ArgumentError("Connection '$(key)' has no pool yet (not built / not connected)."))
  return pool_stats(pool)
end

include("Models.jl")
using .Models

include("Utils.jl")
using .Utils
# Re-export the Utils submodule macros at top level. NOT a duplicate of Utils's own
# `export`: `using .Utils` imports the names but does not re-export them, so this line
# is what makes `using PormG; @import_models` work (and it's pinned in
# test_public_exports.jl). Removing either export breaks the public macros.
export @models_module, @import_models

include("Dialect.jl")
import .Dialect

include("AdvisoryLock.jl")
using .AdvisoryLock

include("QueryBuilder.jl")
# Query primitives only. The SQL function constructors are NOT imported into PormG — they
# live solely in `PormG.Functions` (below). There is intentionally no `PormG.Sum`: the
# function library has exactly one home, reached via `using PormG.Functions` / `PormG.Functions.X`.
import .QueryBuilder: object, get, PormGRow, pk, DoesNotExist, MultipleObjectsReturned, Q, Qor, F, Exists, OuterRef, Subquery, Interval, show_query, inspect_query, bulk_insert, bulk_update, bulk_copy, allocate_primary_keys
# Semantic error taxonomy concrete subtypes (#231); the abstract `PormGError` root is defined
# above in this module. Bridge the QueryBuilder-defined subtypes up so `using PormG` exposes them.
import .QueryBuilder: FieldAccessError, UnknownFieldError, LazyTraversalError, FilterError, QueryBuildError, UnsafeMutationError, InvalidValueError, PermissionError, UnsupportedConnectionError

"""
    PormG.Functions

The SQL function library — aggregate (`Sum`, `Avg`, `Count`, `Max`, `Min`), conditional
(`Case`, `When`), window (`WindowOver`, `Rank`, `Lag`, …), string (`Lower`, `Replace`,
`Trim`, …) and math (`Round`, `Floor`, `Power`, …) constructors.

These are **not** exported into `Main` by `using PormG`: the names are generic enough to
collide with `Base` and user code (`Sum`, `Count`, `Max`, `Replace`, `Round`, `Length`…).
Opt in explicitly:

```julia
using PormG, PormG.Functions          # brings Sum, Count, … into scope
# or qualify without importing:
M.Result.objects.values("n" => PormG.Functions.Count("resultid"))
```
"""
module Functions
  import ..QueryBuilder: Sum, Avg, Count, Max, Min, Case, When, Cast, Concat, Extract,
    ToChar, Value, Coalesce, Greatest, Least, Lower, Upper, Length, Abs, Round, NullIf,
    Replace, Trim, LTrim, RTrim, Floor, Ceil, Sqrt, Exp, Ln, Power, Mod, WindowOver,
    WindowSpec, Rank, DenseRank, RowNumber, Lag, Lead, FirstValue, LastValue, NthValue
  export Sum, Avg, Count, Max, Min, Case, When, Cast, Concat, Extract,
    ToChar, Value, Coalesce, Greatest, Least, Lower, Upper, Length, Abs, Round, NullIf,
    Replace, Trim, LTrim, RTrim, Floor, Ceil, Sqrt, Exp, Ln, Power, Mod, WindowOver,
    WindowSpec, Rank, DenseRank, RowNumber, Lag, Lead, FirstValue, LastValue, NthValue
end

# Curated top-level surface: query primitives only. The SQL function constructors above
# live in `PormG.Functions` and are reached via `using PormG.Functions` / `PormG.Functions.X`.
export object, get, PormGRow, pk, DoesNotExist, MultipleObjectsReturned, Q, Qor, F, Exists, OuterRef, Subquery, Interval, show_query, inspect_query, bulk_insert, bulk_update, bulk_copy, allocate_primary_keys
# Semantic error taxonomy (#231): catch `PormGError` for any query-builder misuse, or a specific subtype.
export PormGError, FieldAccessError, UnknownFieldError, LazyTraversalError, FilterError, QueryBuildError, UnsafeMutationError, InvalidValueError, PermissionError, UnsupportedConnectionError
export with_advisory_lock  # try_advisory_lock / release_advisory_lock removed (not implemented)
export fetch_async, await_result, FetchTask, run_in_transaction, atomic, with_savepoint  # Async-first API
export PoolTimeoutError  # thrown by acquire_connection when the pool is saturated (#37)
export PoolConnectError  # thrown by acquire_connection when a connection can't be opened (#72)
export pool_stats  # connection-pool health snapshot (#127)
export with_tx_context, in_transaction_context  # Transaction context helpers
# setup / install_ai_skills are deliberately NOT exported (#201): maximally generic names for
# one-off lifecycle helpers — call them qualified (`PormG.setup()`, `PormG.install_ai_skills()`),
# which is how every doc and README example already shows them.
export upgrade_guide  # version-scoped UPGRADING.md emitter (#216)

include("Migrations.jl")
using .Migrations

include("precompile.jl")

function __init__()
    # Runtime side effects belong in __init__, NOT the module body: with cached precompilation the
    # module body runs only in the precompile worker, so a top-level `atexit` was never registered at
    # runtime and connection pools were never closed at process exit — issue #203. See the
    # "no module-body side effects" non-negotiable in .github/instructions/general.instructions.md.
    atexit(Configuration.__cleanup__)
end

end # module PormG
