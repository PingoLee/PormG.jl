# Quick Start & Setup

The easiest way to get PormG running in a new project is through the interactive setup tool.

## Interactive Setup

To create a new database configuration folder and connection file (defaults to `db` if no argument is provided):

```julia
using PormG

# Default (creates "db" folder)
PormG.setup()

# Custom folder
PormG.setup("db_bs")
```

### What Setup Does
- Creates the configuration folder (e.g., `db/` or `db_bs/`).
- Generates a template `connection.yml` with `dev`, `test`, and `prod` sections.
- Creates a **customizable models file** (e.g., `models.jl` or `my_models.jl`) with the correct module boilerplate.
- Optionally installs AI-assisted developer skills (`pormg-usage`).

---

## Static Configuration (File-based)

If you already have a `connection.yml`, you can load it directly:

```julia
using PormG, LibPQ   # load SQLite instead for a SQLite app

# Load the configuration folder (e.g., "db")
# This MUST happen BEFORE importing models!
PormG.Configuration.load("db"; env="dev")

# Now import your models
PormG.@import_models "db/models.jl" models
import .models as M

# Use the models
query = M.Driver.objects.filter("surname" => "Senna")
df = query |> DataFrame
```

---

!!! warning "`load()` must come before `@import_models`"
    The order in the snippet above is a requirement, not a style preference. `@import_models`
    calls `set_models(...)`, which triggers an implicit `Configuration.load(path)` if no
    configuration is loaded yet — and that implicit load picks the **default** environment and
    keeps it for the rest of the process. Nothing errors; the application just runs against the
    wrong database until it restarts. See
    [The Boot-Time Hazard](advanced.md#The-Boot-Time-Hazard) for the full explanation.

## The Bootstrap Sequence

For most applications, the bootstrap sequence is:

1.  **Define** your environment (e.g., `dev`, `prod`, `test`).
2.  **Load** the database configuration folder.
3.  **Import** your models.

### Environment Selection
PormG supports explicit environment loading via `env`:
```julia
PormG.Configuration.load("db"; env="prod")
```
This is the **preferred method** for server applications, as it avoids relying on global `ENV` state.
If `env` is not provided, PormG falls back to `ENV["PORMG_ENV"]`, then to a top-level `default_env:` key in `connection.yml`, then to `dev`.

### Loading from a project root
`load("db")` uses the string you pass for two things: the **connection key** your models bind to,
and the **folder** it reads `connection.yml` from, resolved against the working directory. That
works when you run from the project root. A server, a precompiled package or a test runner usually
does not, so pass the root explicitly:

```julia
const APP_ROOT = normpath(joinpath(@__DIR__, ".."))

PormG.Configuration.load("db"; root = APP_ROOT, env = "prod")
```

With `root`, the key is still `"db"` (the string as passed), and the folder is
`joinpath(APP_ROOT, "db")`, from any working directory. That folder is stored absolute as
`settings.db_def_folder`. Everything that reads it resolves against the root instead of `pwd()`:
`makemigrations` and `migrate`, the models file, and a relative SQLite `database:`. Leave `root` out
and `load` behaves exactly as before. The path must be relative when `root` is given. An absolute
one is refused, since `joinpath` would silently discard the root.
