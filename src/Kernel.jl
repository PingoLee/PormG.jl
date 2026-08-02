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
       AbstractPormGParam, PormGPostgresParam, PormGSQLiteParam,
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
export CASCADE, RESTRICT, PROTECT, SET_NULL, SET_DEFAULT, DO_NOTHING

# `register_ignore_tables!` is exported by constants.jl itself (it is part of the documented
# downstream-extension surface), so it needs no re-listing here.

end # module Kernel
