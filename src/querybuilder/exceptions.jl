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
# Many error messages embed ANSI SGR codes (`\e[31m…`) to highlight the offending
# token in the REPL. Those codes are nice on a color terminal but leak as raw
# `\e[..m` noise into non-TTY sinks (CI output, file logs, structured logging).
# `_emsg` strips them whenever Julia is not in color mode — the same flag Julia
# itself consults to colorize error displays — so messages render coloured in the
# REPL and as plain text everywhere else. `_argerr` wraps the common case so a
# call site only changes `ArgumentError(` → `_argerr(`.
_emsg(msg::AbstractString) = Base.have_color === true ? String(msg) : replace(msg, r"\e\[[0-9;]*m" => "")
_argerr(msg::AbstractString) = ArgumentError(_emsg(msg))