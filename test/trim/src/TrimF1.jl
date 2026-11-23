# The juliac --trim fixture app (#1616, #1599): the package boot of docs/src/configuration/setup.md
# with the connection built in code. The module body includes the models file; `boot!` registers the connection and
# binds the models by key at run time. No YAML is read at run time: a trimmed binary cannot parse `connection.yml`
# (#1599 round 2, YAML.jl). Only `Imported`, below, reads one, while the package is precompiled.
module TrimF1

using PormG, SQLite

const MODELS_FILE = joinpath(@__DIR__, "..", "db", "models.jl")
include(MODELS_FILE)
import .models as M

const KEY = "f1"

# The application shape most PormG apps have today (#1599 layer 3): connections read from `connection.yml` and models
# loaded with `@import_models`, both in the module body. A module body runs when the package is precompiled, under
# the JIT, where YAML can be read; a package image saves none of PormG's state, so nothing read here is in the
# binary. What it keeps is the models, each bound to the key their folder had (`db`, from `../db/connection.yml`): the
# binding is a field of the model. At run time a trimmed binary cannot read YAML, so it registers that key in code
# (`imported_step`, `../steps.jl`), and the models' first `.objects` finds it registered.
module Imported
using PormG, SQLite
include_dependency(joinpath(@__DIR__, "..", "db", "connection.yml"))   # an edit to it re-precompiles the package
PormG.Configuration.load_many(["db"]; root = normpath(joinpath(@__DIR__, "..")), env = "prod")
PormG.@import_models "../db/models.jl" models
const KEY = "db"
end

"""Register the SQLite connection under `KEY` and bind the models to it (#1606). A positive
`idle_timeout` (seconds) opts the pool into idle reaping, as `connection.yml`'s `idle_timeout` does;
the read-only entry's `tasks` run uses it."""
function boot!(dir::String, idle_timeout::Int = 0)
    PormG.Configuration.register_connection(KEY, joinpath(dir, "f1.sqlite");
        adapter = "SQLite", env = "prod", pool_size = 1, change_db = true, change_data = true,
        idle_timeout = idle_timeout)
    # The set, passed by the application: a trimmed image keeps only the bindings its code references,
    # so PormG cannot look `MODEL_SET` up by name there (#1606).
    PormG.Models.set_models(models.MODEL_SET; key = KEY)
    return nothing
end

"""Register `key` on the same SQLite file with writes off (`change_data = false`, the default): a second, read-only
connection beside `KEY`, as an application with a read-only connection has (`keys_step`, #1599 layer 1)."""
function register_readonly!(dir::String, key::String)
    PormG.Configuration.register_connection(key, joinpath(dir, "f1.sqlite"); adapter = "SQLite", env = "prod",
                                            pool_size = 1)
    return nothing
end

end
