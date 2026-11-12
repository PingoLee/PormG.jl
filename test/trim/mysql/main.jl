# The juliac --trim entry of the fixture's MySQL variant (#1599, #1614): `../main.jl`'s app with MySQL.jl
# in place of SQLite — boot, then one typed read, no write.
#   JIT:  julia --project=test/trim/mysql test/trim/mysql/main.jl
#   exe:  <build dir>/main                   (see ../README.md, "The MySQL variant")
#
# The boot is in this file, not in a package: `juliac` builds a package from a copy of its directory, so a
# package here could not include `../db/models.jl`, the models the SQLite app uses. It registers a
# `mysql://` URL (#1769), so no YAML is read, pointing at 127.0.0.1:1, where nothing listens: nothing is
# contacted at boot, and the read raises `PoolConnectError` under the JIT. The build measures the MySQL
# extension's verifier rows (layer 2), which no SQLite build reaches. Each step prints one line to
# `Core.stdout`, as in ../main.jl.
using PormG, MySQL, Dates

include(joinpath(@__DIR__, "..", "db", "models.jl"))
import .models as M

const KEY = "f1"

"Register the MySQL connection under `KEY` and bind the models to it (#1606, #1769)."
function boot!()
    PormG.Configuration.register_connection(KEY, "mysql://f1:f1@127.0.0.1:1/f1";
        adapter = "MySQL", env = "prod", pool_size = 1, change_db = true, change_data = true)
    PormG.Models.set_models(models.MODEL_SET; key = KEY)
    return nothing
end

# The struct of ../main.jl: `list(show_query = :struct)` writes the same fields on MySQL (#1632).
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
    say("ext", string(Base.get_extension(PormG, :PormGMySQLExt) !== nothing))
    try
        boot!()
        say("boot", "ok")
    catch e
        failed("boot", e); return Cint(1)
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
