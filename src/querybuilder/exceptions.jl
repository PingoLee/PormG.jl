# ── Semantic error taxonomy (#231) ──────────────────────────────────────────
# Every query-builder misuse throws a subtype of `PormGError` (defined in the top PormG module,
# `<: Exception`) so a consuming app catches a TYPE, not a message substring. This extends the
# #197 lineage (throw real Exceptions, not raw Strings). The subtypes are deliberately **NOT**
# `<: ArgumentError` — a clean pre-publish break (see UPGRADING.md, `## Unreleased` → next 0.3.0).
#
# `_emsg` (the single shared definition in `tools.jl`, imported via QueryBuilder's
# `import PormG: … _emsg`) strips ANSI escape codes whenever Julia is not in color mode, so
# coloured error tokens render in the REPL and as plain text in every non-TTY sink (CI output,
# file logs, `sprint(showerror, e)`). Each subtype's inner constructor applies `_emsg` at
# construction, so `.msg` is clean off-TTY (several tests read `err.msg`).

# Field/accessor lookup failures share an abstract mid-node so `catch FieldAccessError` catches
# both "no such field" and "unsupported lazy traversal". Everything else in the taxonomy is flat.
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
safety check, or an interval/duration literal could not be parsed.
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
connection) reached an execution path. The catchable replacement for the internal
`ErrorException` introduced in #197.
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

# One `showerror` covers every `msg`-carrying subtype. DoesNotExist / MultipleObjectsReturned
# override with their field-built messages (a more specific method wins on dispatch).
Base.showerror(io::IO, e::PormGError) = print(io, e.msg)

Base.showerror(io::IO, e::DoesNotExist) =
  print(io, "$(e.model_name).DoesNotExist: No record found matching filters: $(e.filters)")

Base.showerror(io::IO, e::MultipleObjectsReturned) =
  print(io, "$(e.model_name).MultipleObjectsReturned: Expected 1 record, got $(e.count) for filters: $(e.filters)")

# ── Throw-site funnels ──────────────────────────────────────────────────────
# `_argerr` is the long-tail default: a call site changes only `ArgumentError(` → `_argerr(` and
# lands on `QueryBuildError`. Sharper categories (Field/Filter/Permission/UnsafeMutation/…) are
# chosen explicitly at their sites. The subtype constructor applies `_emsg`, so there is no
# double-strip and no raw ANSI leaks into non-TTY sinks.
_argerr(msg::AbstractString) = QueryBuildError(msg)

# Internal dispatch fallback (#197, retyped in #231): a connection object that is neither a
# PostgreSQL nor a SQLite pool reached an execution path — now a catchable `PormGError` subtype.
# Throws directly (call sites invoke it bare, not wrapped in `throw`).
_unsupported_conn(op::AbstractString, conn) = throw(UnsupportedConnectionError(
  "PormG internal error in $(op): unsupported connection type $(typeof(conn)) — expected a PostgreSQL or SQLite connection pool."))

# Standard actionable error for a write blocked by `change_data: false` (#205), typed as
# `PermissionError` (#231). Every DML entry point (insert, update, delete, update_or_create,
# bulk_*, many-to-many add/remove/clear, primary-key allocation) shares this one message so a user
# hitting any of them gets the same fix — writes are disabled by default (safety-first, the common
# first-`create` trap), and the message names where to fix it: the `config:` block of the active
# environment in connection.yml.
_write_not_allowed(operation::AbstractString, conn_key) = PermissionError(
  "Error in $(operation): the connection \e[4m\e[31m$(conn_key)\e[0m is not allowed to write. " *
  "Writes are disabled by default — set \e[1mchange_data: true\e[0m under the `config:` block of the active " *
  "environment in connection.yml to enable creates, updates, and deletes.")
