# The juliac --trim fixture app (#1616, #1599): the package boot of docs/src/configuration/setup.md
# with the connection built in code. The module body only includes the models file and reads no
# configuration; `boot!` registers the connection and binds the models by key at run time. No YAML
# is read anywhere: a trimmed binary cannot parse `connection.yml` (#1599 round 2, YAML.jl).
module TrimF1

using PormG, SQLite

const MODELS_FILE = joinpath(@__DIR__, "..", "db", "models.jl")
include(MODELS_FILE)
import .models as M

const KEY = "f1"

"""Register the SQLite connection under `KEY` and bind the models to it (#1606). A positive
`idle_timeout` (seconds) opts the pool into idle reaping, as `connection.yml`'s `idle_timeout` does;
the read-only entry's `reap` step uses it."""
function boot!(dir::String, idle_timeout::Int = 0)
    PormG.Configuration.register_connection(KEY, joinpath(dir, "f1.sqlite");
        adapter = "SQLite", env = "prod", pool_size = 1, change_db = true, change_data = true,
        idle_timeout = idle_timeout)
    # The set, passed by the application: a trimmed image keeps only the bindings its code references,
    # so PormG cannot look `MODEL_SET` up by name there (#1606).
    PormG.Models.set_models(models.MODEL_SET; key = KEY)
    return nothing
end

end
