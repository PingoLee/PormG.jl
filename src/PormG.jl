module PormG

using PrecompileTools

"""
    @pormg_debug
    @pormg_debug condition

Contributor-facing breakpoint hook, scattered through PormG's source. It expands to `nothing`, so
it costs a package user exactly nothing at runtime.

To make the call sites live while debugging PormG itself, `]dev PormG`, load `Revise` and
`Infiltrator` before PormG, then redefine the macro to expand to a real breakpoint and edit the
target file so Revise re-parses it — macros expand at parse time, so redefining the macro without
touching the call site has no effect. The step-by-step recipe is in
[Contributing & Debugging](contributing.md).

```julia
@pormg_debug false                  # inert; flip to `true` (or a real condition) to fire
@pormg_debug model.name == "result" # fires only for that model, once wired up
```
"""
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

# ── Layer 1: shared vocabulary ───────────────────────────────────────────────
# Abstract types, constants, the `PormGError` root, `_emsg` and `config`. Kernel imports nothing
# from PormG and is included first, so every submodule below can name any of it regardless of its
# own position in this chain. See the `PormG.Kernel` docstring for why that ordering is load-bearing.
#
# `using .Kernel` BINDS Kernel's exports here (so `PormG.PormGModel`, `PormG.config`, … keep
# resolving) but does NOT re-export them — this module's own `export` lines below remain the single
# definition of the public surface.
include("Kernel.jl")
using .Kernel
# Underscore-private members are not exported by Kernel; import those reached across
# submodules or pinned by tests (e.g. `PormG._emsg`, `PormG._EXTRA_IGNORE_TABLES`, `PormG._suggest_name`).
import .Kernel: _emsg, _EXTRA_IGNORE_TABLES, _levenshtein, _suggest_name
# Physical-table-name resolution (#59). Deliberately NOT exported — internal plumbing reached as
# `PormG.model_table_name`, so it stays off the public surface guard. Lives in Kernel because
# layer-2 `Configuration` needs it and is included before `Models`.
import .Kernel: model_table_name, model_has_db_table
# Part of the documented downstream-extension surface (Nitro et al. call it from an ext `__init__`).
export register_ignore_tables!

# ── Layer 2: behavior owned by PormG ─────────────────────────────────────────
# Backend interface (empty generics + friendly fallbacks); driver bodies live in the
# weakdep extensions. Must precede Configuration/ConnectionPool, which call the generics.
# Deliberately NOT in Kernel: the extensions define `PormG.backend_*(…) = …`, and Julia only
# accepts a qualified method definition on the module that owns the binding.
include("Backend.jl")

# ── Layer 3: submodules ──────────────────────────────────────────────────────
include("Generator.jl")
using .Generator

include("Configuration.jl")
using .Configuration

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
  pool === nothing && throw(InvalidConfigurationError("Connection '$(key)' has no pool yet (not built / not connected)."))
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
import .QueryBuilder: object, get, PormGRow, pk, Q, Qor, F, Exists, OuterRef, Subquery, CTE, Joined, Interval, show_query, inspect_query, bulk_insert, bulk_update, bulk_copy, allocate_primary_keys, resync_sequences
# The error taxonomy needs no bridge line: since #239 every subtype (including `DoesNotExist` /
# `MultipleObjectsReturned`) is defined in `Kernel` and already bound here by `using .Kernel` above.
# QueryBuilder imports the same names from `PormG`, so both modules see one set of types.

"""
    PormG.Functions

The SQL function library, and the index of it. Because these names are **not** exported into
`Main` by `using PormG`, `?Sum` answers nothing until you import them — so this docstring is
the entry point: it lists every constructor and where each family is documented.

**Aggregate** — [`Sum`](@ref), [`Avg`](@ref), [`Count`](@ref), [`Max`](@ref), [`Min`](@ref)
— see [Filters and Aggregates](@ref)

**Conditional** — [`Case`](@ref), [`When`](@ref) — see [Functions and Dates](@ref)

**Window** — [`WindowOver`](@ref), [`WindowSpec`](@ref), [`Rank`](@ref), [`DenseRank`](@ref),
[`RowNumber`](@ref), [`Lag`](@ref), [`Lead`](@ref), [`FirstValue`](@ref), [`LastValue`](@ref),
[`NthValue`](@ref) — see [Window Functions](@ref)

**String** — [`Concat`](@ref), [`Lower`](@ref), [`Upper`](@ref), [`Length`](@ref),
[`Replace`](@ref), [`Trim`](@ref), [`LTrim`](@ref), [`RTrim`](@ref)

**Math** — [`Abs`](@ref), [`Round`](@ref), [`Floor`](@ref), [`Ceil`](@ref), [`Sqrt`](@ref),
[`Exp`](@ref), [`Ln`](@ref), [`Power`](@ref), [`Mod`](@ref)

**Type / value** — [`Cast`](@ref), [`Extract`](@ref), [`ToChar`](@ref), [`Value`](@ref),
[`Coalesce`](@ref), [`Greatest`](@ref), [`Least`](@ref), [`NullIf`](@ref)

They live here rather than at the top level because the names are generic enough to collide
with `Base` and user code (`Sum`, `Count`, `Max`, `Replace`, `Round`, `Length`…), so the
library has exactly one home and you opt in explicitly:

```julia
using PormG, PormG.Functions          # brings Sum, Count, … into scope
using PormG.Functions: Sum, Count     # …or just the ones you use
# or qualify without importing:
M.Result.objects.values("n" => PormG.Functions.Count("resultid"))
```

`Q`, `Qor`, `F`, `Exists`, `OuterRef`, `Subquery`, `CTE` and `Interval` are **not** part of this
library — they are query primitives and stay on the top-level `using PormG` surface.
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
export object, get, PormGRow, pk, DoesNotExist, MultipleObjectsReturned, Q, Qor, F, Exists, OuterRef, Subquery, CTE, Joined, Interval, show_query, inspect_query, bulk_insert, bulk_update, bulk_copy, allocate_primary_keys, resync_sequences
# Semantic error taxonomy (#231): catch `PormGError` for any query-builder misuse, or a specific subtype.
export PormGError, FieldAccessError, UnknownFieldError, LazyTraversalError, FilterError, QueryBuildError, UnsafeMutationError, InvalidValueError, WritesDisabledError, UnsupportedConnectionError, BackendCapabilityError, ProtectedError
# Schema / configuration / migration errors (#239). These complete the taxonomy: `catch PormGError`
# now covers field-constructor and model-definition mistakes, connection config, and the migration
# engine — not just the query builder.
export FieldValidationError, ModelDefinitionError,
  ConfigurationError, InvalidConfigurationError,   # ConfigurationError is the abstract umbrella
  MigrationError, InvalidMigrationError            # MigrationError likewise
# Taxonomy edges (#261). `PoolError` is the connection-pool umbrella — the pool errors were the
# only concrete subtypes with neither a Kernel home nor an abstract one. `error_message` is the
# uniform way to read a caught PormGError: the structured subtypes have no `.msg` field.
export PoolError, error_message, DefinitionError
# The database-error boundary (#268). Every export above reports *misuse of PormG*, raised before a
# statement leaves the process; these report what the database itself refused once it got there, so
# `catch PormGError` finally covers constraint violations, rejected SQL and dropped connections
# without an app naming `SQLite.SQLiteException` / `LibPQ.Errors.*`. The driver exception stays
# reachable on `.cause`. `TransactionError` is transaction-API misuse — not a database failure.
export DatabaseError, IntegrityError, OperationalError, StatementError, TransactionError
export with_advisory_lock  # try_advisory_lock / release_advisory_lock removed (not implemented)
export fetch_async, await_result, FetchTask, run_in_transaction, atomic, with_savepoint  # Async-first API
export without_foreign_keys  # #276: suspend FK enforcement for a block (data repair, out-of-order loads)
export PoolTimeoutError  # thrown by acquire_connection when the pool is saturated (#37)
export PoolConnectError  # thrown by acquire_connection when a connection can't be opened (#72)
export pool_stats  # connection-pool health snapshot (#127)
export with_tx_context, in_transaction_context  # Transaction context helpers
# setup / install_ai_skills are deliberately NOT exported (#201): maximally generic names for
# one-off lifecycle helpers — call them qualified (`PormG.setup()`, `PormG.install_ai_skills()`),
# which is how every doc and README example already shows them. They ARE public API though, and
# `docs/src/api.md` says so — `public` (Julia 1.11+) records that without putting them in scope on
# a bare `using PormG`, and keeps them on the API page under `Private = false` (#289).
public setup, install_ai_skills
export upgrade_guide  # version-scoped UPGRADING.md emitter (#216)

include("Migrations.jl")
using .Migrations

# ── Layer 4: user-facing lifecycle helpers ───────────────────────────────────
# `setup`, `install_ai_skills`, `upgrade_guide` — consumers of everything above, depended on by
# nothing. (It used to sit between Configuration and ConnectionPool purely because it also held
# `_emsg`; that helper now lives in Kernel, so this file is free to land where it belongs.)
include("tools.jl")

include("precompile.jl")

function __init__()
    # Runtime side effects belong in __init__, NOT the module body: with cached precompilation the
    # module body runs only in the precompile worker, so a top-level `atexit` was never registered at
    # runtime and connection pools were never closed at process exit — issue #203. See the
    # "no module-body side effects" non-negotiable in .github/instructions/general.instructions.md.
    atexit(Configuration.__cleanup__)
end

end # module PormG
