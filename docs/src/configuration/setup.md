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
- For a PostgreSQL adapter, asks which driver opens the connections: LibPQ (the default) or
  Postgres (Postgres.jl). The driver you type is written as `postgres_driver:` into each section.
  An empty answer writes no key, so the file is the same as before the question existed and the
  driver is chosen when the file is loaded (`PORMG_POSTGRES_DRIVER`, then LibPQ). See
  [Choosing the PostgreSQL driver](connection_yml.md#Choosing-the-PostgreSQL-driver) for what each
  choice costs.
- Creates a **customizable models file** (e.g., `models.jl` or `my_models.jl`) with the correct module boilerplate.
- Optionally installs AI-assisted developer skills (`pormg-usage`) into the project, under
  `.github/skills/` and `.claude/skills/`. The prompt names the folder it will write to.

### Setting up another project's folder
Without `root`, both the folder and the skills are relative to the working directory, so
`PormG.setup("db")` is meant to be run from the project root. An absolute path without `root`
puts the configuration there and still offers the skills to the working directory; the prompt
names that folder. A script that scaffolds a project
somewhere else passes that project's root instead of changing directory. `root` has the same meaning it has for
[`load`](#Loading-from-a-project-root):

```julia
const APP_ROOT = "/srv/race_control"

PormG.setup("db"; root = APP_ROOT)
# APP_ROOT/db/connection.yml, APP_ROOT/db/models.jl
# APP_ROOT/.github/skills/pormg-usage/ and APP_ROOT/.claude/skills/pormg-usage/SKILL.md
```

The folder is `joinpath(root, "db")` and the skills go into `root`, whatever the working directory
is. As with `load`, the path must be relative when `root` is given.

---

## Static Configuration (File-based)

If you already have a `connection.yml`, you can load it directly:

```julia
using PormG, LibPQ   # load SQLite or MySQL instead for those adapters

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

The sequence is always the same three steps:

1.  **Choose** the environment (`dev`, `prod`, `test`) — and pass it, see below.
2.  **Load** the database configuration folder.
3.  **Import** your models.

A **package or a service** binds its models at run time. The module body only `include`s the models
file, so precompiling reads no `connection.yml`. `__init__` loads the configuration and binds the
models. An explicit `root` keeps the key independent of the working directory:

```julia
module RaceControl

using PormG, LibPQ

const DB_DIRS     = ["db"]
const APP_ROOT    = normpath(joinpath(@__DIR__, ".."))
const MODELS_FILE = joinpath(APP_ROOT, "db", "models.jl")

include(MODELS_FILE)                              # defines `module models … end`; reads no configuration
import .models as M

function __init__()
    PormG.Configuration.load_many(DB_DIRS; root = APP_ROOT, env = get(ENV, "RACECONTROL_ENV", "dev"))
    PormG.Models.set_models(models, "db"; source = MODELS_FILE)
end

end
```

A connection built in code rather than read from `connection.yml` binds the same way, by its key:
`PormG.register_connection("f1", …)` and then `PormG.Models.set_models(models; key = "f1")`. See
[Dynamic Multi-Tenancy](dynamic.md#Binding-models-to-a-dynamic-connection).

The models file ends with `Models.@models Circuit Race …`, naming every model binding: `set_models`
reads that list, and refuses a module that does not write one (#1602). `generate_models_from_db`
writes it; see [Defining models](../models.md).

This is the default to write, and it is the same in development and production. `source` is the
models file. With [Revise.jl](https://github.com/timholy/Revise.jl) loaded, an edit to it is applied
before the next REPL command, and the models are bound again. Without Revise, `source` does nothing,
so a service or a compiled image runs this boot unchanged (#1487).

The snippet under *Static Configuration* above is the **REPL / script** form: one process, no
precompilation, so `@import_models` can bind the models where it stands, and it registers the same
reload. In a package, `@import_models` in the module body runs in the precompile worker. That needs
the configuration loaded at precompile time, and the reload is never registered in the session.
[One boot for development and production](advanced.md#One-boot-for-development-and-production)
says why the package does not switch between the two shapes.

The rules this sequence relies on:

- registering models never loads a folder outside a REPL — it refuses, naming the `load` call;
- outside a REPL the environment comes from `env=` or `PORMG_ENV`, never from `default_env:`;
- loading a folder again with the same environment is free;
- a restored package image rebinds its models to the key they were imported under, or refuses.

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

### Built images read their configuration at run time
A sysimage or a `juliac` executable saves the state of the process that built it. A configuration
loaded in that process would travel in the file, the database password included, and the running
program would serve the build machine's settings instead of the deployment's. So PormG reads
configuration at run time only:

- `load`, `load_many`, `register_connection`, `register_offline`, `set_connection_resolver` and
  `set_before_connect_hook` raise `InvalidConfigurationError` while an image is being written: at
  the top level of a `juliac` entry script, for example.
- When the program starts, PormG drops any connection the image still holds, with a warning naming
  the keys. The file itself may still contain that connection's settings: rebuild it without loading
  at build time, and rotate its credentials.

Load and bind your models in `main`, or in your package's `__init__` (which a build does not run):

```julia
function (@main)(args::Vector{String})::Cint
    PormG.Configuration.load("db"; root = APP_ROOT, env = "prod")
    PormG.Models.set_models(MyApp.models, "db")
    # … serve
    return 0
end
```

Binding models at the top level of the entry script fails too, but with a different error: with no
configuration loaded, `set_models` reports that the folder is not loaded.

A package image is not affected. Precompiling a package saves none of PormG's state, so a package
that loads in its module body loads again in its `__init__`, as above. What a package keeps in its
**own** globals is a different matter: a `const` holding a `Settings` (`const S = get_settings("db")`)
is saved in that package's image, credentials included. Read settings at run time instead.
