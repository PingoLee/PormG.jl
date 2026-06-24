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