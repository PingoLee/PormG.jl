# Server & App Patterns

When building a server (e.g., with **Nitro.jl** or **Genie.jl**), you need robust ways to initialize databases and check their health.

## Using `load_many` for Multi-DB Servers

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
db_dirs = [dirname(settings["source_path"]) for settings in values(config.db)]
PormG.Configuration.load_many(db_dirs; env=config.env)

db_ok = all(PormG.Configuration.ping, db_dirs)
db_status = db_ok ? "connected" : "unavailable"
```

This is better DX than calling `get_settings(dirname(...))` from the app because it makes the contract explicit:
- `load_many(...)` is for bootstrapping.
- `is_loaded(...)` is for registration checks.
- `ping(...)` or `status(...)` is for health checks.
