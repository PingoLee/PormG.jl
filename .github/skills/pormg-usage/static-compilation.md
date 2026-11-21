# Static compilation (`juliac --trim`, experimental)

Read this only when the app is built into a standalone executable with `juliac --trim`. Under the
ordinary JIT none of it applies. The full guide, with what has run trimmed on each driver, is
<https://pingolee.github.io/PormG.jl/stable/static_compilation/>.

## The entry file

```julia
# f1app.jl, the file juliac builds
using PormG, SQLite, Dates
PormG.trim_entrypoints(PormG.ConnectionPool.SQLiteConnectionPool)   # top level; a no-op under the JIT

include(joinpath(@__DIR__, "db", "models.jl"))
import .models as M

function (@main)(args::Vector{String})::Cint
    PormG.register_connection("f1", joinpath(abspath(args[1]), "f1.sqlite"); adapter = "SQLite", env = "prod")
    PormG.Models.set_models(models.MODEL_SET; key = "f1")
    try
        for r in M.Race.objects.filter("circuitid__country" => "Monaco").list(RaceRow)
            println(Core.stdout, r.name)
        end
    finally
        close_all!()   # a trimmed binary runs no atexit hook
    end
    return Cint(0)
end
```

- **`trim_entrypoints(P...)`** roots every method PormG reaches through a run-time call: the query
  render's nested re-entries, the driver's own roots (Postgres.jl's SCRAM methods) and the
  LazyJLLWrappers roots Libiconv_jll needs at start. Call it **once, at the top level** of the entry
  file, after `using` the driver, with one pool type per engine:
  `SQLiteConnectionPool`, `MySQLConnectionPool`, `PostgresConnectionPool{:postgres}` (all under
  `PormG.ConnectionPool`). Without it the binary stops before `main` or at the first nested read with
  `Core.MissingCodeError`. Never root PormG's internals by hand.
- **Register the connection inside `main`**, from the environment or the arguments. A literal at the
  top level is frozen into the binary; a trimmed binary cannot read `connection.yml` (no YAML).
- **Bind models with `set_models(models.MODEL_SET; key)`**.
- **Read with a declared type** (`list(T)`, `first(T)`): the row struct from `list(show_query = :struct)`.
- **PostgreSQL: use Postgres.jl** (`postgres_driver = "Postgres"`). A LibPQ binary aborts before `main`.
- **`close_all!()` before `main` returns**, in a `finally`.
- **Errors:** catch PormG's error types as usual and print their typed fields (`e.sqlstate`,
  `e.message`), never the exception or `e.cause` itself.
