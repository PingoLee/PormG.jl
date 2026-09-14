# ── Query-builder error funnels ──────────────────────────────────────────────
# The taxonomy TYPES live in `src/exceptions.jl`, included by `Kernel` (layer 1) — see the header
# there for why. What stays here are the query-builder's message-composing funnels.
#
# ## The rule: a funnel RETURNS an exception; the call site THROWS it
#
# `throw(_write_not_allowed(op, key))`, never a funnel that throws internally. This is uniform with
# direct construction (`throw(QueryBuildError(...))`), so a reader never has to remember which of
# the two a given helper is — and the hazard it removes is real: a funnel that throws internally
# invites the mirror-image mistake at a *returning* funnel, where a forgotten `throw(` silently
# constructs an exception, discards it, and lets execution continue straight past the guard. No
# error raised, no test failure. `test_typed_exceptions.jl` pins the convention.
#
# ## What belongs here
#
# A funnel earns its place by **composing a message** from parameters, so that every call site
# reports the same wording and the same fix. A funnel that only maps a message to a type is not an
# abstraction — it is an alias that hides which type is thrown, and the call site should name the
# type itself.
#
# That is why `_argerr(msg) = QueryBuildError(msg)` was removed in #262: it was scaffolding for
# #231's mechanical `ArgumentError(` → `_argerr(` swap, spread across nine files, and reading
# `throw(_argerr("…"))` told you nothing about the resulting type. Its 71 call sites now say
# `throw(QueryBuildError("…"))`.
#
# Scope, so a fifth funnel has an obvious home: **shared** funnels live here; a funnel used by
# exactly one file lives beside its call sites. `_fielderr` in `src/models/fields.jl` is the latter
# — its call sites live in one file, one category, documented where it is used (#260 cut them from 248 to ~50).

# Internal dispatch fallback (#197, retyped in #231): a connection object that is neither a
# PostgreSQL nor a SQLite pool reached an execution path — a catchable `PormGError` subtype.
_unsupported_conn(op::AbstractString, conn) = UnsupportedConnectionError(
  "PormG internal error in $(op): unsupported connection type $(typeof(conn)) — expected a PostgreSQL or SQLite connection pool. This is a PormG bug; please report it.")

# Standard actionable error for a write blocked by `change_data: false` (#205), typed as
# `WritesDisabledError` (#231, renamed from `PermissionError` in the pre-publish naming pass). Every DML entry point (insert, update, delete, update_or_create,
# bulk_*, many-to-many add/remove/clear, primary-key allocation) shares this one message so a user
# hitting any of them gets the same fix — writes are disabled by default (safety-first, the common
# first-`create` trap), and the message names where to fix it: the `config:` block of the active
# environment in connection.yml.
_write_not_allowed(operation::AbstractString, conn_key) = WritesDisabledError(
  "Error in $(operation): the connection \e[4m\e[31m$(conn_key)\e[0m is not allowed to write. " *
  "Writes are disabled by default — set \e[1mchange_data: true\e[0m under the `config:` block of the active " *
  "environment in connection.yml to enable creates, updates, and deletes.")

# #536 — an `F(...)` / `Joined(...)` comparison against a value the operand vocabulary does not
# admit. Without this the call fell through to `Base.==` (identity) and evaluated to a bare `Bool`,
# so `q.filter(F("uid") == uuid)` reported *"Invalid filter argument: false"* — naming a value the
# user never wrote (#530's complaint, on every type the union omitted). Shared by the twelve
# catch-all methods in `types.jl` (six per family), which is what earns it a funnel: one wording,
# one fix, and the accepted list is read LIVE from `_CompareLiteral` so the text cannot drift from
# the union it describes.
function _unsupported_compare_operand(op::AbstractString, operand)
  accepted = join(string.(Base.uniontypes(_CompareLiteral)), ", ")
  hint = (operand === nothing || operand === missing) ?
    " To test for NULL, filter with \e[4m\e[32m\"col__@isnull\" => true\e[0m instead." : ""
  return QueryBuildError(
    "\e[4m\e[31m$(typeof(operand))\e[0m is not a supported right-hand side for an F/Joined comparison " *
    "(\e[4m\e[31m$(op)\e[0m). A comparison operand must be a literal of one of these types — " *
    "$(accepted) — or a column reference (\e[4m\e[32mF(...)\e[0m, \e[4m\e[32mCTE(...)\e[0m, " *
    "\e[4m\e[32mJoined(...)\e[0m)." * hint)
end
