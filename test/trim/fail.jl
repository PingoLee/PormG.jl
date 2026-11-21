# The juliac --trim entry that runs a statement SQLite refuses (#1599): the fixture app's boot, then the
# step in `tools/failing.jl`, which prints the error the caller catches. A trimmed image used to replace
# that error with a `MethodError` from the error path itself (README.md, "The error path").
#   JIT:  julia --project=test/trim test/trim/fail.jl <run dir>
#   exe:  <build dir>/fail <run dir>
# Its own entry, not a step of `read.jl`: the read-only binary is what the `Trim (juliac)` workflow checks.
using TrimF1, PormG, SQLite
# The roots a trimmed build needs (the render's run-time re-entries, upstream's), a no-op under the JIT (#1599).
PormG.trim_entrypoints(PormG.ConnectionPool.SQLiteConnectionPool)

say(step::String, detail::String) = (println(Core.stdout, "step\t", step, "\t", detail); nothing)

include(joinpath(@__DIR__, "tools", "failing.jl"))

function (@main)(args::Vector{String})::Cint
    say("main", "entered")
    dir = abspath(args[1])
    say("ext", string(Base.get_extension(PormG, :PormGSQLiteExt) !== nothing))
    try
        TrimF1.boot!(dir, 0)
        say("boot", "ok")
    catch e
        report_failure(e); return Cint(1)
    end
    pool = PormG.Configuration.get_settings(TrimF1.KEY).connections::PormG.ConnectionPool.SQLiteConnectionPool
    fail_step(pool) || return Cint(6)
    return Cint(0)
end
