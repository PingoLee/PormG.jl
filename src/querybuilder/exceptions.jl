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