# Server & App Patterns

When building a server (e.g., with **Nitro.jl** or **Genie.jl**), you need robust ways to initialize databases and check their health.

## Using `load_many` for Multi-DB Servers

If your server talks to multiple static databases, load them all at once, from the project root
rather than from whatever the working directory happens to be:

```julia
const APP_ROOT = @__DIR__   # this server script sits at the project root

db_dirs = ["db", "db_analytics", "db_tenants"]
PormG.Configuration.load_many(db_dirs; root = APP_ROOT, env = "prod")

# Then import models for each
PormG.@import_models "db/models.jl" app_models
PormG.@import_models "db_analytics/models.jl" ana_models

import .app_models as M
import .ana_models as AM
```

`root` keeps the keys short (`"db"`, `"db_analytics"`, …) while the folders resolve under
`APP_ROOT`, so the same call works at precompile time, in `__init__` and at boot without a
`cd(APP_ROOT) do … end` around it. See
[Loading from a project root](setup.md#Loading-from-a-project-root).

---

## Health & Connectivity Checks

PormG provides high-level functions for monitoring connection status without leaking implementation details.

- **Check if Registered:** `PormG.Configuration.is_loaded("db")::Bool`
- **Check if Reachable:** `PormG.Configuration.ping("db")::Bool` (returns `Bool`)
- **Detailed Status:** `PormG.Configuration.status("db")::NamedTuple`

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

`status()` returns a named tuple that distinguishes between three cases:
- **Not loaded:** `loaded = false`, `reachable = false`
- **Loaded but unreachable:** `loaded = true`, `reachable = false`
- **Loaded and reachable:** `loaded = true`, `reachable = true`

---

## Recommended Server Pattern

Target ergonomics for a server app:

```julia
db_dirs = [relpath(dirname(settings["source_path"]), APP_ROOT) for settings in values(config.db)]
db_keys = PormG.Configuration.load_many(db_dirs; root = APP_ROOT, env = config.env)

db_ok = all(PormG.Configuration.ping, db_keys)   # the keys load_many registered, not the paths
db_status = db_ok ? "connected" : "unavailable"
```

This is better DX than calling `get_settings(dirname(...))` from the app because it makes the contract explicit:
- `load_many(...)` is for bootstrapping.
- `is_loaded(...)` is for registration checks.
- `ping(...)` or `status(...)` is for health checks.
