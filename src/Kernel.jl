"""
    PormG.Kernel

**Layer 1 — the shared vocabulary.** Everything in here is a *noun*: abstract types, constants,
the error taxonomy root, and the two dependency-free helpers (`_emsg`, `config`) that the rest of
the package needs before it can define anything of its own.

## The invariant

`Kernel` imports **nothing** from `PormG`. Every other submodule may import from `Kernel`, and
`Kernel` is included first, so "may I use this name?" stops depending on where a file happens to sit
in `PormG.jl`'s include chain.

That ordering used to be implicit, and it bit: the `#231` error taxonomy was defined in
`src/querybuilder/exceptions.jl` (included at step 11), so `Models`, `Configuration`, `Dialect` and
`ConnectionPool` — all included earlier — could not name a single one of its types. Each submodule
resolves `import PormG: …` at include time, so "defined later in the module body" means "does not
exist yet".

## What does NOT belong here

**Behavior.** In particular `Backend.jl` stays in `PormG`, even though it looks like core: the weakdep
extensions define their methods as `PormG.backend_execute(…) = …`, and Julia only accepts a qualified
method definition on the module that *owns* the binding. Moving those generics here would break every
extension method with `function Kernel.backend_execute must be explicitly imported to be extended` —
and it would fail at `using LibPQ` / `using SQLite`, not at `using PormG`, so precompiling the package
would not catch it. The generics dispatch on the `PormGPostgres` / `PormGSQLite` markers defined below,
which works fine from where they are.

Rule of thumb: **Kernel holds the nouns, `PormG` keeps the verbs.**
"""
module Kernel

#═══════════════════════════════════════════════════════════════════════════════
# SECTION: Type hierarchy
#═══════════════════════════════════════════════════════════════════════════════

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
# clean break, so callers catch a type instead of string-matching a message). It lives in Kernel
# precisely so every submodule can reach it and its concrete subtypes; see the module docstring
# for why "defined later in PormG.jl" was not good enough. Extends the #197 typed-exception lineage.
abstract type PormGError <: Exception end

#═══════════════════════════════════════════════════════════════════════════════
# SECTION: Shared state
#═══════════════════════════════════════════════════════════════════════════════

const config::Dict{String,PormGSettings} = Dict()

# Introspection/DDL constraint readers. Declared here as empty generics because `Dialect` and
# `Migrations` both extend AND call them, so neither can own the binding.
function get_constraints_pk end
function get_constraints_unique end
function get_constraints_check end

#═══════════════════════════════════════════════════════════════════════════════
# SECTION: Error-message helper
#═══════════════════════════════════════════════════════════════════════════════

"""
    _emsg(msg; color = (Base.have_color === true))

TTY-aware error-message colorizer. Many PormG error strings embed ANSI SGR codes
(`\\e[31m…\\e[0m`) to highlight the offending token in the REPL. Those codes are
helpful on a color terminal but leak as raw `\\e[..m` noise into non-TTY sinks
(CI output, file logs, `sprint(showerror, e)`, structured logging).

`_emsg` keeps the codes when `color` is true and strips every `\\e[..m` sequence
otherwise. The default tracks `Base.have_color` — the same flag Julia consults to
colorize its own error displays, so it honors the `--color` flag and `NO_COLOR`.
The `color` keyword exists so tests can exercise both branches deterministically.

This is the single shared definition. It lives in `Kernel` rather than `tools.jl`
because the error taxonomy's constructors call it, and the taxonomy has to be
available to every submodule — see the `PormG.Kernel` docstring.
"""
_emsg(msg::AbstractString; color::Bool = (Base.have_color === true)) =
  color ? String(msg) : replace(msg, r"\e\[[0-9;]*m" => "")

"""
    _emsg(io, msg)

IO-aware variant of [`_emsg`](@ref) for use inside `show` / `print(io, …)` methods:
it keeps ANSI only when the destination stream advertises color via its `:color`
IOContext property. This is the correct signal for rendered output, because a
non-color buffer (`sprint`, `repr`, a captured string, a file) must stay ANSI-free
even when the process itself is attached to a color terminal.
"""
_emsg(io::IO, msg::AbstractString) = _emsg(msg; color = get(io, :color, false))

#═══════════════════════════════════════════════════════════════════════════════
# SECTION: Constants
#═══════════════════════════════════════════════════════════════════════════════

include("constants.jl")

#═══════════════════════════════════════════════════════════════════════════════
# SECTION: Exports
#
# Kernel exports its whole vocabulary — that is the module's entire purpose. `PormG` does
# `using .Kernel`, which BINDS these names in `PormG` (so `PormG.PormGModel` keeps resolving)
# without re-exporting them; `PormG`'s own `export` list stays the single definition of the
# public surface. Underscore-private names are deliberately NOT exported and are imported
# explicitly by the few places that need them.
#═══════════════════════════════════════════════════════════════════════════════

# Type hierarchy
export PormGAbstractType, PormGSettings, PormGBackend, PormGPostgres, PormGSQLite,
       AbstractPormGParam, PormGPostgresParam, PormGSQLiteParam,
       SQLObject, SQLObjectHandler, SQLTableAlias, SQLInstruction,
       SQLType, SQLTypeQ, SQLTypeQor, SQLTypeF, SQLTypeFunction, SQLTypeOper,
       SQLTypeText, SQLTypeArrays, SQLTypeField, SQLTypeOrder, SQLTypeCTE,
       PormGModel, PormGField, Migration, PormGError

# Shared state / generics
export config, get_constraints_pk, get_constraints_unique, get_constraints_check

# Paths and file-name constants
export DBDF_FOLDER_NAME, CONFIG_PATH, ENV_PATH, LOG_PATH, APP_PATH, RESOURCES_PATH,
       TEST_PATH, DB_PATH, MODEL_PATH, MODEL_FILE, DBDF_PATH,
       PORMG_DB_CONFIG_FILE_NAME, TEST_FILE_IDENTIFIER

# Behavior constants
export DEFAULT_POOL_TIMEOUT, LAST_INSERT_ID_LABEL, DATETIME_FORMAT, UTC_TIMEZONE,
       reserved_words

# Query-builder vocabulary
export PormGsuffix, PormGtransform, PormGTypeField, JSON_CONTAINMENT_OPERATORS

# Type maps and introspection ignore lists
export sqlite_type_map, postgres_type_map, sqlite_type_map_reverse, postgres_type_map_reverse,
       sqlite_date_format_map, sqlite_ignore_schema, postgres_ignore_table

# on_delete handlers
export CASCADE, RESTRICT, PROTECT, SET_NULL, SET_DEFAULT, SET, DO_NOTHING

# `register_ignore_tables!` is exported by constants.jl itself (it is part of the documented
# downstream-extension surface), so it needs no re-listing here.

end # module Kernel
