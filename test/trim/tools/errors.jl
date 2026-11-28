# Every PormG error the fixture provokes, printed in full through `showerror` (#1613): one `showerror` line per caught
# error, its text with each newline written as `\n`, so a job compares the trimmed binary's messages with its JIT
# control's line by line (`same_lines.sh`). Included by `../steps.jl` and by each server variant's `main.jl`, after
# `say`.
#
# `showerror` is called at the error's concrete type, one arm per type: a call on an exception whose type the compiler
# cannot see is a call a trimmed image may have no code for, the shape `docs/src/static_compilation.md` tells
# applications to avoid. A type outside the list prints its name only.
function showerror_text(e::T)::String where {T <: Exception}
    io = IOBuffer()
    showerror(io, e)
    return replace(String(take!(io)), "\n" => "\\n")
end

@noinline function showerror_line(step::String, @nospecialize(e))::Nothing
    text = e isa PormG.InvalidValueError ? showerror_text(e::PormG.InvalidValueError) :
           e isa PormG.BackendCapabilityError ? showerror_text(e::PormG.BackendCapabilityError) :
           e isa PormG.QueryBuildError ? showerror_text(e::PormG.QueryBuildError) :
           e isa PormG.UnknownFieldError ? showerror_text(e::PormG.UnknownFieldError) :
           e isa PormG.UnsafeMutationError ? showerror_text(e::PormG.UnsafeMutationError) :
           e isa PormG.FilterError ? showerror_text(e::PormG.FilterError) :
           e isa PormG.ProtectedError ? showerror_text(e::PormG.ProtectedError) :
           e isa PormG.WritesDisabledError ? showerror_text(e::PormG.WritesDisabledError) :
           e isa PormG.StatementError ? showerror_text(e::PormG.StatementError) :
           e isa PormG.OperationalError ? showerror_text(e::PormG.OperationalError) :
           e isa PormG.IntegrityError ? showerror_text(e::PormG.IntegrityError) :
           e isa PormG.ModelDefinitionError ? showerror_text(e::PormG.ModelDefinitionError) :
           e isa PormG.InvalidConfigurationError ? showerror_text(e::PormG.InvalidConfigurationError) :
           string("(not printed: ", nameof(typeof(e)), ")")
    say("showerror", string(step, ": ", text))
    return nothing
end
