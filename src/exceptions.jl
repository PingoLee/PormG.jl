# ── Semantic error taxonomy (#231, #239) ────────────────────────────────────
# Every PormG misuse throws a subtype of `PormGError` so a consuming app catches a TYPE, not a
# message substring. This extends the #197 lineage (throw real Exceptions, not raw Strings).
# The subtypes are deliberately **NOT** `<: ArgumentError` — a clean pre-publish break.
#
# This file is included by `Kernel` (layer 1), not by `QueryBuilder`. #231 originally put the
# subtypes in `src/querybuilder/exceptions.jl`, included at step 11 of PormG.jl's chain, which
# meant `Models`, `Configuration`, `ConnectionPool` and `Dialect` — all included earlier — could
# not name a single one of them. Defining the taxonomy in layer 1 is what lets #239 retype those
# subsystems at all. The query-builder throw funnels (`_argerr`, `_unsupported_conn`,
# `_write_not_allowed`) stay behind in `src/querybuilder/exceptions.jl`, next to their call sites.
#
# `_emsg` (defined above in Kernel) strips ANSI escape codes whenever Julia is not in color mode,
# so coloured error tokens render in the REPL and as plain text in every non-TTY sink (CI output,
# file logs, `sprint(showerror, e)`). Each subtype's inner constructor applies `_emsg` at
# construction, so `.msg` is clean off-TTY (several tests read `err.msg`).

# ── Query-builder errors (#231) ─────────────────────────────────────────────

"""
    FieldAccessError <: PormGError  (abstract)

Umbrella for field/accessor lookup failures — `catch` it to get both
[`UnknownFieldError`](@ref) ("no such field") and [`LazyTraversalError`](@ref)
("unsupported lazy traversal").
"""
abstract type FieldAccessError <: PormGError end

"""
    UnknownFieldError(msg) <: FieldAccessError <: PormGError

A field, alias, column, or `__` lookup path does not exist on the model or the projected row.
"""
struct UnknownFieldError <: FieldAccessError
  msg::String
  UnknownFieldError(msg::AbstractString) = new(_emsg(msg))
end

"""
    LazyTraversalError(msg) <: FieldAccessError <: PormGError

An unprojected `ForeignKey` was read off a fetched row. PormG has no lazy FK traversal; the
message steers the caller to up-front `values(...)` projection (#204).
"""
struct LazyTraversalError <: FieldAccessError
  msg::String
  LazyTraversalError(msg::AbstractString) = new(_emsg(msg))
end

"""
    FilterError(msg) <: PormGError

An invalid filter argument/shape, or an operator misused on a JSON/subquery column.
"""
struct FilterError <: PormGError
  msg::String
  FilterError(msg::AbstractString) = new(_emsg(msg))
end

"""
    QueryBuildError(msg) <: PormGError

Structural/API misuse while building a query — joins, CTEs, projection, ordering, window and
bulk configuration, and the like. The default bucket for query-builder misuse that isn't one of
the sharper categories below.
"""
struct QueryBuildError <: PormGError
  msg::String
  QueryBuildError(msg::AbstractString) = new(_emsg(msg))
end

"""
    UnsafeMutationError(msg) <: PormGError

An UPDATE or DELETE was requested without a filter (or in another unsafe shape) and refused.
"""
struct UnsafeMutationError <: PormGError
  msg::String
  UnsafeMutationError(msg::AbstractString) = new(_emsg(msg))
end

"""
    InvalidValueError(msg) <: PormGError

A value failed coercion/type validation on insert/update, an identifier failed the fail-closed
safety check, or an interval/duration literal could not be parsed. Also raised by the
`Models.format_*_sql` coercion helpers, which the insert/update path calls (#239).
"""
struct InvalidValueError <: PormGError
  msg::String
  InvalidValueError(msg::AbstractString) = new(_emsg(msg))
end

"""
    PermissionError(msg) <: PormGError

The connection is not permitted to insert/update/delete — its settings carry `change_data=false`.
"""
struct PermissionError <: PormGError
  msg::String
  PermissionError(msg::AbstractString) = new(_emsg(msg))
end

"""
    UnsupportedConnectionError(msg) <: PormGError

A connection that is neither a PostgreSQL nor a SQLite pool (or a model not bound to a
connection) reached an execution path, or a lookup/function requires a backend the active
connection is not. The catchable replacement for the internal `ErrorException` from #197.
"""
struct UnsupportedConnectionError <: PormGError
  msg::String
  UnsupportedConnectionError(msg::AbstractString) = new(_emsg(msg))
end

# get() cardinality errors — reparented from `Exception` to `PormGError` (#231) so
# `catch PormGError` catches them too. They keep their structured fields and field-built
# `showerror` (below), which is why they don't use the uniform `msg::String` shape.
struct DoesNotExist <: PormGError
  model_name::String
  filters::String
end

struct MultipleObjectsReturned <: PormGError
  model_name::String
  count::Int
  filters::String
end

# ── Schema, configuration and migration errors (#239) ───────────────────────

"""
    FieldValidationError(msg) <: PormGError

A field constructor was given an invalid argument — a kwarg of the wrong type, a `max_length`
outside its permitted range, a `default` that does not satisfy the field's own contract, a
`choices` shape that does not parse, or a field type that cannot serve as a primary key.

Raised while *defining* a model. Contrast [`InvalidValueError`](@ref), which is raised while
coercing a *value* on the insert/update path.
"""
struct FieldValidationError <: PormGError
  msg::String
  FieldValidationError(msg::AbstractString) = new(_emsg(msg))
end

"""
    ModelDefinitionError(msg) <: PormGError

A model or schema definition is invalid — more than one primary key, a duplicate `related_name`,
an illegal field name, a `UniqueConstraint` that names an unknown or many-to-many field, an
unresolvable `ForeignKey` / `ManyToManyField` target, or a `Model(...)` call given something
that is not a `PormGField`.
"""
struct ModelDefinitionError <: PormGError
  msg::String
  ModelDefinitionError(msg::AbstractString) = new(_emsg(msg))
end

"""
    ConfigurationError <: PormGError  (abstract)

Umbrella for connection-configuration failures — `catch` it to get every case below. Like
[`FieldAccessError`](@ref), this is an abstract mid-node rather than a throwable type, so the
pre-existing `MissingDatabaseConfigurationException` can live *inside* the bucket instead of
beside it. `catch ConfigurationError` must not have holes; that class of surprise is the reason
this taxonomy exists.

Subtypes: [`InvalidConfigurationError`](@ref), and `Configuration.MissingDatabaseConfigurationException`
(a missing folder/`connection.yml`, or a selected environment with no matching block).
"""
abstract type ConfigurationError <: PormGError end

"""
    InvalidConfigurationError(msg) <: ConfigurationError <: PormGError

Connection configuration is present but unusable or inconsistent — an unsupported adapter, an
unknown connection key, a malformed `extensions` setting, an unsupported PostgreSQL extension,
a model not bound to a connection, or an attempt to overwrite a static connection.
"""
struct InvalidConfigurationError <: ConfigurationError
  msg::String
  InvalidConfigurationError(msg::AbstractString) = new(_emsg(msg))
end

"""
    MigrationError <: PormGError  (abstract)

Umbrella for migration-engine failures — `catch` it to get every case below, including a refused
destructive plan.

Subtypes: [`InvalidMigrationError`](@ref), and `Migrations.DestructiveMigrationError` (a
destructive plan applied non-interactively without `destructive=true`).
"""
abstract type MigrationError <: PormGError end

"""
    InvalidMigrationError(msg) <: MigrationError <: PormGError

The migration engine refused or could not complete an operation — a duplicate index name in a
plan, an invalid answer to an interactive `makemigrations` prompt, an unimplemented
`migrate_to(version)` path, or an importer pointed at a non-SQLite connection.
"""
struct InvalidMigrationError <: MigrationError
  msg::String
  InvalidMigrationError(msg::AbstractString) = new(_emsg(msg))
end

# ── showerror ───────────────────────────────────────────────────────────────
# One `showerror` covers every `msg`-carrying subtype. DoesNotExist / MultipleObjectsReturned
# override with their field-built messages (a more specific method wins on dispatch); so do the
# reparented types that carry their own structured fields (PoolTimeoutError, PoolConnectError,
# MissingDatabaseConfigurationException, DestructiveMigrationError), each next to its definition.
Base.showerror(io::IO, e::PormGError) = print(io, e.msg)

Base.showerror(io::IO, e::DoesNotExist) =
  print(io, "$(e.model_name).DoesNotExist: No record found matching filters: $(e.filters)")

Base.showerror(io::IO, e::MultipleObjectsReturned) =
  print(io, "$(e.model_name).MultipleObjectsReturned: Expected 1 record, got $(e.count) for filters: $(e.filters)")
