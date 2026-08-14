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
`src/querybuilder/exceptions.jl` (included at step 11; that file is now `error_funnels.jl` and holds
only message-composing funnels), so `Models`, `Configuration`, `Dialect` and
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
"""
    PormGBackend <: PormGAbstractType

The backend/dialect marker — the dispatch key for SQL rendering and driver selection.

Its two subtypes, `PormGPostgres` and `PormGSQLite`, are what every dialect method dispatches
on, so a function that renders SQL differently per backend is written as a pair of methods on
them rather than as a runtime branch. The values you actually hold are the concrete connection
pools: `PostgresConnectionPool <: PormGPostgres` and `SQLiteConnectionPool <: PormGSQLite`.

Deliberately **not** `<: PormGSettings`: that is the configuration/`Settings` type, and a pool
carries none of its fields (#186).

Adding a backend means defining `PormG.backend_*` methods in a package extension — see
[Extending PormG](@ref).
"""
abstract type PormGBackend <: PormGAbstractType end
abstract type PormGPostgres <: PormGBackend end
abstract type PormGSQLite <: PormGBackend end
abstract type AbstractPormGParam <: PormGAbstractType end  # Base type for all parameterized queries
abstract type PormGPostgresParam <: AbstractPormGParam end  # PostgreSQL numbered params ($1, $2...)
abstract type PormGSQLiteParam <: AbstractPormGParam end    # SQLite positional params with contextual buckets

"""
    PormGBytes(bytes::Vector{UInt8})

A binary payload on its way to the database — the wrapper `BinaryField`'s formatter puts around
a byte vector so the parameter collectors can recognize it (#296).

It exists because a bare `Vector{UInt8}` is indistinguishable from "a list of values", and both
backends get that wrong in opposite ways:

- **PostgreSQL** — `add_parameter!(::PormGPostgresParam, ::AbstractArray)` pushes the vector
  through to LibPQ, which binds *every* parameter in text format and renders any vector as a
  PostgreSQL **array literal**. `UInt8[0x00, 0xFF]` reaches the server as the five characters
  `{0,255}`, and `bytea`'s escape-format input parser accepts that string literally — so the
  column silently stores the ASCII of `{0,255}` instead of the two bytes. No error is raised.
- **SQLite** — `add_parameter!(::PormGSQLiteParam, ::AbstractArray)` expands an array into one
  `?` per element, so an *n*-byte payload becomes *n* placeholders and the statement fails on
  a column-count mismatch.

Dispatching on the wrapper instead of on `Vector{UInt8}` keeps `filter("x__in" => UInt8[1, 2])`
expanding into an `IN` list as it always has — only values that came through a binary field are
treated as one opaque blob.

Layer 1 on purpose: `Models` produces it and `QueryBuilder` consumes it, so neither can own it.
"""
struct PormGBytes <: PormGAbstractType
  bytes::Vector{UInt8}
end
"""
    SQLObject <: PormGAbstractType

Base type for the query state itself — the accumulated filters, projections, joins and
ordering that a query is built from.

The concrete type you hold is `SQLObjectQuery`. You rarely name `SQLObject` in application
code; it appears when a helper accepts "the underlying query object", e.g. the `mq.object`
handed to a subquery or CTE constructor.

See also [`SQLObjectHandler`](@ref), [Architecture & Request Flow](@ref).
"""
abstract type SQLObject <: PormGAbstractType end

"""
    SQLObjectHandler <: SQLObject

Base type for the chainable wrapper around a query — the thing `Model.objects` returns and
`.filter(...)`, `.values(...)`, `.list()` hang off.

The concrete type is `ObjectHandler`; its fluent methods are synthesized by `getproperty`, so
they have no bindings of their own and `?query.filter` cannot work — the full method reference
lives on `object` instead (`?object`).

See also [`SQLObject`](@ref) (the state it wraps).
"""
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


"""
    PormGModel <: PormGAbstractType

Base type for model definitions — one table, its fields, and its relations.

Instances are produced by `Models.Model("table_name", field = FieldType(...), ...)` and
collected by `@import_models` / `set_models`. Dispatch on it when you are writing code that
takes "any model", such as a framework extension that registers its own tables.

See also [`PormGField`](@ref), [Defining Models in PormG](@ref), [Extending PormG](@ref).
"""
abstract type PormGModel <: PormGAbstractType end

"""
    PormGField <: PormGAbstractType

Base type for field definitions — `CharField`, `IntegerField`, `ForeignKey`, and the rest.

A field is a **component** of a model, not a kind of model: `PormGField` is a *sibling* of
[`PormGModel`](@ref), not a subtype, so it deliberately does not satisfy `::PormGModel`
signatures, which all read model-only attributes (#186).

Fields own their validation — a value is checked here, before any SQL is generated — and
carry the formatter that coerces a Julia value on its way *into* the database (inserts, bulk
writes, bound filter parameters). Values read back are not decoded through the field type.

See also [PormG Field Types Reference](@ref).
"""
abstract type PormGField <: PormGAbstractType end # define the type of the column from the model

abstract type Migration <: PormGAbstractType end

# Physical SQL table for `model` (#59) — `db_table` when the model declares a non-empty one, else
# `model.name` unchanged. The table-level mirror of `Models.field_db_column`.
#
# Lives in Kernel, not Models, because layer-2 `Configuration` needs it (the SQLite reserved-PK
# overlay keys on the physical table) and is included BEFORE Models — the shared-vocabulary rule.
# It is pure property access with a fallback, so it carries no dependency on anything in Models.
#
# A model that never sets `db_table` resolves to `model.name` exactly as before this option existed,
# so every call site is a no-op on the common path. `hasproperty` keeps it safe for any PormGModel
# implementation that does not carry the field at all.
function model_table_name(model::PormGModel)::String
  hasproperty(model, :db_table) || return String(model.name)
  dbt = getproperty(model, :db_table)
  dbt isa AbstractString && !isempty(dbt) && return String(dbt)
  return String(model.name)
end

# True when `model` declares a non-empty db_table (#59) — fast-path gate for call sites that want to
# branch without building the resolved string. Mirrors `Models.model_has_db_column`'s shape.
function model_has_db_table(model::PormGModel)::Bool
  hasproperty(model, :db_table) || return false
  dbt = getproperty(model, :db_table)
  return dbt isa AbstractString && !isempty(dbt)
end

"""
    PormGError <: Exception

Root of PormG's semantic error taxonomy (#231). Every error PormG raises for a *domain* failure —
an unknown field, an invalid value, a refused write, a pool timeout, a database rejection — is a
subtype, so one `catch` clause covers the whole surface:

```julia
try
    M.Driver.objects.get("driverref" => "nobody")
catch e
    e isa PormGError || rethrow()
    @error "query failed" msg=error_message(e)
end
```

Use [`error_message`](@ref) to read a caught error: the structured subtypes carry typed fields
rather than a `.msg` string.

Catch a narrower type when you want to act on one failure — `DoesNotExist`, `IntegrityError`,
`PoolTimeoutError` — and the umbrellas (`FieldAccessError`, `PoolError`, `DatabaseError`,
`ConfigurationError`, `MigrationError`, `DefinitionError`) to group a family.

These are deliberately **not** `<: ArgumentError`: a clean break so callers match a type instead
of string-matching a message. Plain Julia-level misuse (a missing kwarg, a missing path) still
raises the stock Julia exception, because it is not a PormG domain error.

The type lives in `PormG.Kernel` — layer 1 — so every submodule can name it and its subtypes
regardless of include order (#239). The full list is in the
[API reference](api.md#Error-taxonomy).
"""
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
# BinaryField's byte-length CHECK (#296). A separate generic from `get_constraints_check`, which
# matches only the `>= 0` clause of a positive-integer field — the two constraints can coexist on
# one table and must never be mistaken for each other when a column type transitions.
function get_constraints_byte_length_check end

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
# SECTION: Typo suggestion helpers (#365)
#
# Shared string-distance / nearest-match candidate resolution used across layers
# (operator typos in QueryBuilder, configuration typos in Configuration).
#═══════════════════════════════════════════════════════════════════════════════

"""
    _levenshtein(a::AbstractString, b::AbstractString) -> Int

Iterative Levenshtein edit distance (two-row, O(min(m,n)) memory). Runs only when
building a typo suggestion, never on the happy path.
"""
function _levenshtein(a::AbstractString, b::AbstractString)::Int
  av, bv = collect(a), collect(b)
  m, n = length(av), length(bv)
  m == 0 && return n
  n == 0 && return m
  prev = collect(0:n)
  curr = Vector{Int}(undef, n + 1)
  for i in 1:m
    curr[1] = i
    @inbounds for j in 1:n
      cost = av[i] == bv[j] ? 0 : 1
      curr[j + 1] = min(curr[j] + 1, prev[j + 1] + 1, prev[j] + cost)
    end
    prev, curr = curr, prev
  end
  return prev[n + 1]
end

"""
    _suggest_name(input::AbstractString, candidates) -> Union{Nothing, String}

Nearest candidate in `candidates` to `input`, or `nothing` when nothing is close enough
to be a plausible typo (`2 * best_d <= length(input)`).
"""
function _suggest_name(input::AbstractString, candidates)::Union{Nothing,String}
  isempty(input) && return nothing
  best = nothing
  best_d = typemax(Int)
  for c in candidates
    cstr = string(c)
    d = _levenshtein(input, cstr)
    if d < best_d
      best_d = d
      best = cstr
    end
  end
  return (best !== nothing && 2 * best_d <= length(input)) ? best : nothing
end

#═══════════════════════════════════════════════════════════════════════════════
# SECTION: Error taxonomy
#
# Must follow `_emsg` above — every subtype's inner constructor calls it.
#═══════════════════════════════════════════════════════════════════════════════

include("exceptions.jl")

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
       AbstractPormGParam, PormGPostgresParam, PormGSQLiteParam, PormGBytes,
       SQLObject, SQLObjectHandler, SQLTableAlias, SQLInstruction,
       SQLType, SQLTypeQ, SQLTypeQor, SQLTypeF, SQLTypeFunction, SQLTypeOper,
       SQLTypeText, SQLTypeArrays, SQLTypeField, SQLTypeOrder, SQLTypeCTE,
       PormGModel, PormGField, Migration

# Error taxonomy (#231, #239) — root, the query-builder subtypes, and the schema/config/migration
# subtypes. `PormGError` first so `catch PormGError` is the one name a caller has to remember.
export PormGError,
       FieldAccessError, UnknownFieldError, LazyTraversalError,
       FilterError, QueryBuildError, UnsafeMutationError, InvalidValueError,
       WritesDisabledError, UnsupportedConnectionError,
       DoesNotExist, MultipleObjectsReturned,
       FieldValidationError, ModelDefinitionError,
       ConfigurationError, InvalidConfigurationError,
       MigrationError, InvalidMigrationError,
       PoolError, error_message,
       # Pre-publish naming pass (#268-era audit): narrowed/added members (WritesDisabledError
       # replaces PermissionError on the taxonomy line above).
       BackendCapabilityError, ProtectedError, DefinitionError,
       # The database-error boundary (#268): everything above reports misuse of PormG; these report
       # what the database itself refused, with the driver exception kept in `.cause`.
       DatabaseError, IntegrityError, OperationalError, StatementError,
       TransactionError

# Shared state / generics
export config, get_constraints_pk, get_constraints_unique, get_constraints_check,
       get_constraints_byte_length_check

# Paths and file-name constants
export DBDF_FOLDER_NAME, CONFIG_PATH, ENV_PATH, LOG_PATH, APP_PATH, RESOURCES_PATH,
       TEST_PATH, DB_PATH, MODEL_PATH, MODEL_FILE, DBDF_PATH,
       PORMG_DB_CONFIG_FILE_NAME, TEST_FILE_IDENTIFIER

# Behavior constants
export DEFAULT_POOL_TIMEOUT, LAST_INSERT_ID_LABEL, DATETIME_FORMAT, UTC_TIMEZONE,
       reserved_words, MODEL_OPTION_KWARGS

# Query-builder vocabulary
export PormGsuffix, PormGtransform, PormGTypeField, JSON_CONTAINMENT_OPERATORS

# Type maps and introspection ignore lists
export sqlite_type_map, postgres_type_map, sqlite_type_map_reverse, postgres_type_map_reverse,
       sqlite_date_format_map, sqlite_ignore_schema, postgres_ignore_table

# on_delete handlers
export CASCADE, RESTRICT, PROTECT, SET_NULL, SET_DEFAULT, DO_NOTHING

# Generated-module boilerplate registry (#338) — single source for Generator.jl's `import
# PormG.Models: ...` line and Model_to_str's per-file binding-collision dedup seed.
export GENERATED_MODULE_RESERVED_BINDINGS

# `register_ignore_tables!` is exported by constants.jl itself (it is part of the documented
# downstream-extension surface), so it needs no re-listing here.

end # module Kernel
