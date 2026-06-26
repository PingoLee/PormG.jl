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

import DataFrames, OrderedCollections, Dates, Logging, Millboard, YAML

# NOTE: LibPQ and SQLite are weak dependencies (Project.toml `[weakdeps]`). Core never
# names a concrete driver type; all driver work goes through the backend generics in
# `Backend.jl`, whose methods live in `ext/PormGLibPQExt.jl` / `ext/PormGSQLiteExt.jl`
# and load on `using LibPQ` / `using SQLite`.

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
abstract type PormGField <: PormGModel end # define the type of the column from the model

abstract type Migration <: PormGAbstractType end

const config::Dict{String,SQLConn} = Dict()

if !haskey(ENV, "PORMG_ENV")
  ENV["PORMG_ENV"] = "dev"
end

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
# Query primitives only. The SQL function constructors are NOT imported into PormG — they
# live solely in `PormG.Functions` (below). There is intentionally no `PormG.Sum`: the
# function library has exactly one home, reached via `using PormG.Functions` / `PormG.Functions.X`.
import .QueryBuilder: object, get, PormGRow, DoesNotExist, MultipleObjectsReturned, Q, Qor, F, Exists, OuterRef, show_query, inspect_query, bulk_insert, bulk_update, bulk_copy, allocate_primary_keys

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
    To_char, Value, Coalesce, Greatest, Least, Lower, Upper, Length, Abs, Round, NullIf,
    Replace, Trim, LTrim, RTrim, Floor, Ceil, Sqrt, Exp, Ln, Power, Mod, WindowOver,
    WindowSpec, Rank, DenseRank, RowNumber, Lag, Lead, FirstValue, LastValue, NthValue
  export Sum, Avg, Count, Max, Min, Case, When, Cast, Concat, Extract,
    To_char, Value, Coalesce, Greatest, Least, Lower, Upper, Length, Abs, Round, NullIf,
    Replace, Trim, LTrim, RTrim, Floor, Ceil, Sqrt, Exp, Ln, Power, Mod, WindowOver,
    WindowSpec, Rank, DenseRank, RowNumber, Lag, Lead, FirstValue, LastValue, NthValue
end

# Curated top-level surface: query primitives only. The SQL function constructors above
# live in `PormG.Functions` and are reached via `using PormG.Functions` / `PormG.Functions.X`.
export object, get, PormGRow, DoesNotExist, MultipleObjectsReturned, Q, Qor, F, Exists, OuterRef, show_query, inspect_query, bulk_insert, bulk_update, bulk_copy, allocate_primary_keys
export with_advisory_lock  # try_advisory_lock / release_advisory_lock removed (not implemented)
export fetch_async, await_result, FetchTask, run_in_transaction, with_savepoint  # Async-first API
export with_tx_context, in_transaction_context  # Transaction context helpers
export setup, install_ai_skills

# Fallback stub for the Tachikoma TUI extension.
# When `using Tachikoma`, PormGTachikomaExt overrides this with the real implementation.
"""
    tui(db_path::String; models_module=nothing, fps=30)

Launch the PormG terminal dashboard with Migrations and Query Inspection panes.
Requires `Tachikoma.jl` to be installed and loaded (`using Tachikoma`).

See `ext/PormGTachikomaExt.jl` for the full implementation.
"""
function tui(db_path::String; models_module::Union{Nothing,Module}=nothing, fps::Int=30)
  error("PormG.tui() requires Tachikoma.jl. Run `using Tachikoma` before calling PormG.tui().")
end
export tui

include("Migrations.jl")
using .Migrations

include("precompile.jl")

atexit(Configuration.__cleanup__)


end # module PormG
