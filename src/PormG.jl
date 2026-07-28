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
# Underscore-private members are not exported by Kernel; import the two that are reached as
# `PormG._emsg` / `PormG._EXTRA_IGNORE_TABLES` (both pinned by tests).
import .Kernel: _emsg, _EXTRA_IGNORE_TABLES
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
import .QueryBuilder: object, get, PormGRow, pk, Q, Qor, F, Exists, OuterRef, Subquery, Interval, show_query, inspect_query, bulk_insert, bulk_update, bulk_copy, allocate_primary_keys
# The error taxonomy needs no bridge line: since #239 every subtype (including `DoesNotExist` /
# `MultipleObjectsReturned`) is defined in `Kernel` and already bound here by `using .Kernel` above.
# QueryBuilder imports the same names from `PormG`, so both modules see one set of types.

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
# Schema / configuration / migration errors (#239). These complete the taxonomy: `catch PormGError`
# now covers field-constructor and model-definition mistakes, connection config, and the migration
# engine — not just the query builder.
export FieldValidationError, ModelDefinitionError,
  ConfigurationError, InvalidConfigurationError,   # ConfigurationError is the abstract umbrella
  MigrationError, InvalidMigrationError            # MigrationError likewise
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
