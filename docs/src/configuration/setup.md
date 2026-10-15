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
    calls `set_models(...)`, which binds the models to a configuration that is **already loaded**.
    When none matches the models folder, it raises `InvalidConfigurationError`, naming the `load`
    call to add. PormG does not load the folder itself, because that load would choose the
    environment for you. A REPL keeps that convenience: there the folder is loaded, with a warning
    (#1248). See [The Boot-Time Hazard](advanced.md#The-Boot-Time-Hazard) for the full explanation.

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
If `env` is not provided, PormG reads `ENV["PORMG_ENV"]` (a blank value counts as unset).

With neither, what happens depends on the session (#1228):

- **In a REPL** (`isinteractive()`), PormG falls back to a top-level `default_env:` key in
  `connection.yml`, then to `dev`, and logs at `@info` which of the two decided.
- **Anywhere else** — a service, a test, a script — `load` raises `InvalidConfigurationError`
  naming the call to fix. `default_env: dev` is production in many deployments, and a process
  nobody watches must not pick it.

A **package** passes `env` in its own `load` calls. Its `__init__` runs in whatever session loads
it, and `using RaceControl` at a REPL makes that session interactive: an env-less `load` there would
take the REPL fallback (with the `@info`) rather than fail.

The REPL check is the same one that decides the implicit load of an unloaded models folder (#1248),
so the bootstrap follows one rule: an interactive session gets the conveniences and is told when one
of them decided, and every other process gets only what was stated.

### Loading again
Calling `load` for a folder that is already loaded with the same environment does nothing: it
returns the key, keeps the pool and any connection checked out of it, and does not read
`connection.yml` again. So a bootstrap step that loads the configuration is safe to repeat. Two
cases do reload, closing the pool and building a new one:

```julia
PormG.Configuration.load("db"; env = "staging")             # another environment: reload, with a warning
PormG.Configuration.load("db"; env = "dev", force = true)   # re-read an edited connection.yml
```

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
