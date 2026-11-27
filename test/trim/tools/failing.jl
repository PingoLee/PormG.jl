# A statement that fails on the server, and what the caller sees of it (#1599). Included by the server
# variants' `main.jl` and by the SQLite `fail.jl` entry, after each defines `say`.
#
# In a trimmed image a failing statement surfaced as whatever the error path itself could not run: the
# classifiers and the cause walks call `hasproperty`, `string` and `showerror` on an untyped exception,
# and a call the image has no code for raises a `MethodError` that replaces the server's error. The step
# runs one statement against a table no fixture creates and prints the error a caller catches: its type,
# and for a `DatabaseError` its SQLSTATE, its message and its cause's type. The JIT control prints the
# same lines. The statement binds nothing, so the server's message quotes no value.

const FAIL_SQL = "SELECT raceid FROM pormg_trim_missing"

# `true` when the statement raised the server's error: a `DatabaseError` whose cause is the driver's,
# not a `MethodError` from the error path. `false` (the entry exits 6) when it returned or raised anything
# else, so a binary that still masks the error fails the step, not only its printed lines.
function fail_step(pool)::Bool
    try
        PormG.ConnectionPool.fetch(pool, FAIL_SQL)
        say("fail", "no error")
        return false
    catch e
        report_failure(e)
        return _is_server_error(e)
    end
end

_is_server_error(@nospecialize(e))::Bool =
    e isa PormG.StatementError ? !(_db_fields(e)[3] isa MethodError) :
    e isa PormG.OperationalError ? !(_db_fields(e)[3] isa MethodError) :
    e isa PormG.IntegrityError ? !(_db_fields(e)[3] isa MethodError) : false

_text(::Nothing) = "-"
_text(s::String) = s

# The fields a `DatabaseError` stores, read at the concrete type (the abstract type has no fields).
_db_fields(e::PormG.StatementError) = (e.sqlstate, e.message, e.cause)
_db_fields(e::PormG.OperationalError) = (e.sqlstate, e.message, e.cause)
_db_fields(e::PormG.IntegrityError) = (e.sqlstate, e.message, e.cause)

@noinline function report_failure(@nospecialize(e))
    say("fail", string("threw ", nameof(typeof(e))))
    showerror_line("fail", e)   # the full message at the error's type (#1613)
    if e isa MethodError
        Core.println("  missed: ", typeof(e.f))
        Core.println("  args: ", typeof(e.args))
        return nothing
    end
    fields = e isa PormG.StatementError ? _db_fields(e) :
             e isa PormG.OperationalError ? _db_fields(e) :
             e isa PormG.IntegrityError ? _db_fields(e) : nothing
    fields === nothing && return nothing
    sqlstate, message, cause = fields
    Core.println("  sqlstate: ", _text(sqlstate))
    Core.println("  message: ", _text(message))
    Core.println("  cause: ", string(nameof(typeof(cause))))
    cause isa MethodError && Core.println("  cause missed: ", typeof(cause.f))
    cause isa MethodError && Core.println("  cause args: ", typeof(cause.args))
    return nothing
end
