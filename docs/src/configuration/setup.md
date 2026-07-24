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
