# Database Configuration

PormG uses a flexible configuration system designed for Julia's asynchronous environment. Whether you are building a simple script or a complex multi-tenant server, PormG provides the tools to manage your database connections reliably.

---

## Quick Start: The Setup Sequence

For most applications, the bootstrap sequence is:

1.  **Define** your environment (e.g., `dev`, `prod`, `test`).
2.  **Load** the database configuration folder.
3.  **Import** your models.

```julia
using PormG

# 1. Load the configuration (e.g., from folder 'db')
# This must happen BEFORE importing models to ensure correct settings.
PormG.Configuration.load("db"; env="dev")

# 2. Import your models into a module
PormG.@import_models "db/models.jl" models
import .models as M

# 3. Use the models
query = M.Driver.objects.filter("surname" => "Senna")
df = query |> DataFrame
```

---

## Core Concepts

### 1. Configuration Folders
In PormG, a **Configuration Folder** (like `db/` or `db_sch/`) is the unit of connection management. Each folder contains a `connection.yml` file that defines how to connect to the database (PostgreSQL or SQLite).

- **Default Folder**: If you don't specify a path, PormG often looks for `db/`.
- **Multiple Databases**: You can have multiple folders (e.g., `db_primary`, `db_analytics`) to manage different connections in the same app.

### 2. Environments (`app_env`)
PormG supports multiple environments within the same `connection.yml`. Common values are `dev`, `test`, and `prod`. You can specify the environment globally via `ENV["PORMG_ENV"]` or explicitly in the `load` call.

---

## Static Configuration (File-based)

### Supported Adapters
- **PostgreSQL**: Primary adapter using `LibPQ.jl`. Supports high-performance async operations.
- **SQLite**: Fully supported via `SQLite.jl`. PormG uses a unique **Contextual Buckets Strategy** to enable complex joins and CTEs that are normally difficult in SQLite.

### Creating a Configuration
The easiest way to start is using the interactive setup tool:
```julia
using PormG
PormG.setup() # Guides you through folder and connection.yml creation
```

Alternatively, run `PormG.Configuration.load("your_folder")`. If the folder is empty, PormG will generate a template `connection.yml` for you.

---

## Server & App Patterns

When building a server (e.g., with **Nitro.jl** or **Genie.jl**), you need robust ways to initialize databases and check their health.

### Using `load_many` for Multi-DB Servers
If your server talks to multiple static databases, load them all at once:

```julia
db_dirs = ["db", "db_analytics", "db_tenants"]
PormG.Configuration.load_many(db_dirs; env="prod")

# Then import models for each
PormG.@import_models "db/models.jl" app_models
PormG.@import_models "db_analytics/models.jl" ana_models

import .app_models as M
import .ana_models as AM
```

### Health & Connectivity Checks
PormG provides high-level functions for monitoring connection status without leaking implementation details.

- **Check if Registered**: `PormG.Configuration.is_loaded("db")`
- **Check if Reachable**: `PormG.Configuration.ping("db")` (returns `Bool`)
- **Detailed Status**: `PormG.Configuration.status("db")`

Example health check for a Nitro.jl handler:
```julia
function health_check()
    db_status = PormG.Configuration.status("db")
    if db_status.reachable
        return (status="ok", db=db_status.app_env)
    else
        return (status="error", message="Database unreachable")
    end
end
```

---

## Dynamic Multi-Tenancy

For applications that connect to databases on the fly (e.g., per user or subdomain), use the dynamic registration API.

### Runtime Registration
Register a connection pool manually at any time using a connection string:

```julia
# PostgreSQL
PormG.register_connection("tenant_01", "postgres://user:pass@localhost/db_01")

# SQLite
PormG.register_connection("temp_cache", "cache.db"; adapter="SQLite")
```

### Lazy Connection Resolution (Recommended)
You can provide a **resolver function** that PormG calls automatically whenever it encounters an unknown database key.

```julia
PormG.Configuration.set_connection_resolver() do key
    # Fetch connection details from a master DB or Vault
    if startswith(key, "client_")
        client_id = split(key, "_")[2]
        url = "postgres://user:pass@server/db_$(client_id)"
        return (url, "PostgreSQL", 5) # (url, adapter, pool_size)
    end
    return nothing
end

# Use the key! PormG loads it lazily.
results = M.Driver.objects.db("client_42").list()
```

---

## Public API Reference (Configuration)

#### Explicit environment loading

```julia
PormG.Configuration.load(path::String; env::Union{Nothing,String}=nothing)
```

Behavior:

- `env=nothing` preserves the current fallback behavior based on `ENV["PORMG_ENV"]`.
- `env="dev" | "test" | "prod" | ...` sets `settings.app_env` explicitly for that load operation.
- reloading an already-known path with a different `env` must refresh `settings.app_env`, re-read `connection.yml`, and rebuild the pool if required.

This removes the need for server code to rely on global `ENV` mutation as the main contract.

#### Multi-folder bootstrap

```julia
PormG.Configuration.load_many(paths::AbstractVector{<:AbstractString}; env::Union{Nothing,String}=nothing)
```

Behavior:

- loads each static configuration folder in order,
- returns the normalized connection keys that were loaded,
- throws a structured error if any path fails,
- keeps the app layer responsible only for deciding which folders belong to the current deployment.

Recommended server usage:

```julia
db_dirs = ["db", "db_sch"]
loaded = PormG.Configuration.load_many(db_dirs; env=config.env)
```

#### Loaded-state probe

```julia
PormG.Configuration.is_loaded(path_or_key::String)::Bool
```

Behavior:

- returns `true` if PormG has already registered the connection settings for the given folder path or key,
- returns `false` if the configuration has not been loaded,
- does not open a new connection and does not count as a health check.

This gives apps a correct primitive for "is this registered?" without abusing `get_settings(...)` for control flow.

#### Connectivity probe

```julia
PormG.Configuration.ping(path_or_key::String)::Bool
PormG.Configuration.status(path_or_key::String)::NamedTuple
```

Behavior:

- `ping(...)` answers the narrow question: "is this database reachable right now?"
- `status(...)` returns a richer payload, for example:

```julia
(
   key = "db",
   loaded = true,
   reachable = true,
   adapter = "PostgreSQL",
   app_env = "prod",
)
```

`status(...)` should distinguish at least three cases:

- not loaded,
- loaded but unreachable,
- loaded and reachable.

That distinction matters in HTTP health handlers and worker boot diagnostics.

### Recommended Responsibility Split

The server application should keep:

- mapping `AppConfig` to a set of database folders,
- deciding whether one failed database should fail startup or only degrade features,
- formatting HTTP health responses.

PormG should own:

- loading and reloading database folders,
- environment-aware configuration selection,
- mapping folder paths to connection keys,
- answering loaded-state and connectivity questions.

This keeps application code policy-focused while PormG owns its own configuration lifecycle.

### Environment-Order Hazard

There is an important boot-time hazard when using `@import_models` in a server module.

`@import_models` eventually calls `Models.set_models(...)`. If the corresponding configuration path is not loaded yet, `set_models(...)` can trigger `Configuration.load(path)` implicitly. If that happens before the server has selected the intended environment, PormG may initialize that settings object using the default environment and retain it for the rest of the process.

Because of this, server-facing loading APIs should prefer explicit environment arguments over implicit `ENV["PORMG_ENV"]` discovery.

### Recommended Server Pattern

Target ergonomics for a server app:

```julia
db_dirs = [dirname(settings["source_path"]) for settings in values(config.db)]
PormG.Configuration.load_many(db_dirs; env=config.env)

db_ok = all(PormG.Configuration.ping, db_dirs)
db_status = db_ok ? "connected" : "unavailable"
```

This is better DX than calling `get_settings(dirname(...))` from the app because it makes the contract explicit:

- `load_many(...)` is for bootstrapping,
- `is_loaded(...)` is for registration checks,
- `ping(...)` or `status(...)` is for health checks.

---

## Connection Pooling & Async-First Design
- Use `with_advisory_lock(settings, "my_job_name") do ... end` to ensure long-running tasks (migrations, seeds, imports) do not run in parallel across processes.
- Choose strategy: default `strategy = :poll` retries every `interval_ms`; use `strategy = :block` to let Postgres block with a `statement_timeout = timeout_ms` (avoids client-side polling).
- Keys are hashed to a 64-bit bigint via MD5 to reduce collisions vs. `hashtext`.
- If the session drops, Postgres releases the lock automatically; a subsequent unlock on a new session returns `false` but is harmless.
- SQLite does not support advisory locks; the helper will no-op with a warning on that backend.

---
For more details, see the [PormG Documentation](index.md) or the example scripts in the `test/integration/` folder.
