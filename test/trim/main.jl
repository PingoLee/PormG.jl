# The juliac --trim entry of the fixture app (#1616, #1599): boot, one write, one typed read.
#   JIT:  julia --project=test/trim test/trim/main.jl <run dir>
#   exe:  <build dir>/main <run dir>         (see README.md)
# Each step prints one line to `Core.stdout` (a trimmed binary's `Base.stdout` is stale and it prints
# no `@error` records). A caught exception prints its type; for a `MethodError`, the function it
# missed and the argument types; for a PormG refusal, its message.
using TrimF1, PormG, SQLite, Dates
const M = TrimF1.M

# Pasted unedited from `M.Race.objects.list(show_query = :struct)` on SQLite (#1632).
struct RaceRow
    raceid::Int64     # IDField
    year::Int64       # IntegerField
    round::Int64      # IntegerField
    circuitid::Int64  # ForeignKey
    name::String      # CharField
    date::Date        # DateField
end

say(step::String, detail::String) = (println(Core.stdout, "step\t", step, "\t", detail); nothing)

@noinline function failed(step::String, @nospecialize(e))
    say(step, string("threw ", nameof(typeof(e))))
    e isa MethodError && Core.println("  missed: ", typeof(e.f))
    e isa MethodError && Core.println("  args: ", typeof(e.args))
    e isa PormG.ModelDefinitionError && Core.println("  msg: ", (e::PormG.ModelDefinitionError).msg)
    e isa PormG.InvalidConfigurationError &&
        Core.println("  msg: ", (e::PormG.InvalidConfigurationError).msg)
    try   # the frames, when the trimmed image can symbolize them
        for fr in stacktrace(catch_backtrace())
            f = string(fr.file)
            (occursin("PormG", f) || occursin("trim", f)) &&
                Core.println("  at ", string(fr.func), " ", basename(f), ":", string(fr.line))
        end
    catch err
        # swallows a failed symbolization: the frames are a diagnostic, the step already reported.
        err isa Exception || rethrow()
        Core.println("  (no stacktrace)")
    end
    return nothing
end

function (@main)(args::Vector{String})::Cint
    t0 = time_ns()
    say("main", "entered")
    dir = abspath(args[1])
    say("ext", string(Base.get_extension(PormG, :PormGSQLiteExt) !== nothing))
    try
        TrimF1.boot!(dir)
        say("boot", "ok")
    catch e
        failed("boot", e); return Cint(1)
    end
    try
        M.Race.objects.create("year" => 2009, "round" => 6, "circuitid" => 1,
                              "name" => "Monaco Grand Prix", "date" => Date(2009, 5, 24))
        say("write", "ok")
    catch e
        failed("write", e); return Cint(2)
    end
    try
        rows = M.Race.objects.filter("circuitid__country" => "Monaco").list(RaceRow)
        say("query", string(length(rows), " rows"))
        for r in rows
            say("row", string(r.raceid, " ", r.year, " ", r.name, " ", r.date))
        end
    catch e
        failed("query", e); return Cint(3)
    end
    say("elapsed_ms", string(div(time_ns() - t0, 1_000_000)))
    return Cint(0)
end
