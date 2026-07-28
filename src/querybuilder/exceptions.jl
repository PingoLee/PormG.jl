# ── Query-builder throw-site funnels ────────────────────────────────────────
# The taxonomy TYPES live in `src/exceptions.jl`, included by `Kernel` (layer 1) — see the header
# there for why. What stays here is the query-builder's own throw funnels, next to the call sites
# that use them.

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
