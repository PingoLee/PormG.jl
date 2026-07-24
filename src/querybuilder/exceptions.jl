struct DoesNotExist <: Exception
  model_name::String
  filters::String
end

struct MultipleObjectsReturned <: Exception
  model_name::String
  count::Int
  filters::String
end

Base.showerror(io::IO, e::DoesNotExist) =
  print(io, "$(e.model_name).DoesNotExist: No record found matching filters: $(e.filters)")

Base.showerror(io::IO, e::MultipleObjectsReturned) =
  print(io, "$(e.model_name).MultipleObjectsReturned: Expected 1 record, got $(e.count) for filters: $(e.filters)")

# ── Error-message colorization (TTY-aware) ──────────────────────────────────
# `_emsg` (the single shared definition in `tools.jl`, imported via QueryBuilder's
# `import PormG: … _emsg`) strips ANSI escape codes whenever Julia is not in color
# mode, so coloured error tokens render in the REPL and as plain text in every
# non-TTY sink (CI output, file logs, `sprint(showerror, e)`). `_argerr` wraps the
# common case so a call site only changes `ArgumentError(` → `_argerr(`.
_argerr(msg::AbstractString) = ArgumentError(_emsg(msg))

# Internal dispatch fallback (#197): a connection object that is neither a PostgreSQL nor a
# SQLite pool reached an execution path. Typed (ErrorException) so downstream
# `catch e; e isa Exception` works — these sites previously threw raw Strings, which are not
# Exceptions and escape every typed catch.
_unsupported_conn(op::AbstractString, conn) = error(_emsg(
  "PormG internal error in $(op): unsupported connection type $(typeof(conn)) — expected a PostgreSQL or SQLite connection pool."))

# Standard actionable error for a write blocked by `change_data: false` (#205). Every DML entry
# point (insert, update, delete, update_or_create, bulk_*, many-to-many add/remove/clear,
# primary-key allocation) shares this one message so a user hitting any of them gets the same fix —
# writes are disabled by default (safety-first), which is the common first-`create` trap, and the
# message must name where to fix it: the `config:` block of the active environment in connection.yml.
_write_not_allowed(operation::AbstractString, conn_key) = _argerr(
  "Error in $(operation): the connection \e[4m\e[31m$(conn_key)\e[0m is not allowed to write. " *
  "Writes are disabled by default — set \e[1mchange_data: true\e[0m under the `config:` block of the active " *
  "environment in connection.yml to enable creates, updates, and deletes.")