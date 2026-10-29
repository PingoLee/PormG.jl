## `Configuration.load` of a key `register_offline` holds raises instead of replacing it (#1451)

- **Version**: Unreleased
- **PormG ref**: #1451 ; `src/Configuration.jl` (`load`, `_offline_load_error`)
- **Recorded**: 2026-10-29
- **Severity**: behavior change, every engine. `load` of a key registered offline used to replace the offline entry with a live pool, with only a reload warning. It now raises `InvalidConfigurationError`, `force = true` included, and leaves the offline entry as it was.

### What changed

`register_offline(key)` already refused a key that `load` or `register_connection` registered. The
reverse did not hold. `Configuration.load(key; env)` of an offline key closed its placeholder pool,
read `connection.yml` and built a live one; the only signal was the warning every reload logs.

The case this mattered for is a golden-SQL suite that registers its keys offline and then runs
`using App`, whose module body or `__init__` calls `load("db"; env = …)`. The suite believed itself
offline and reached a database.

`load` now refuses the key, under its own spelling and under another spelling of the same folder (the
absolute path, say). The `InvalidConfigurationError` names the key and the two ways out:
`unregister_connection(key)` first, or another key. `force = true` does not override it: `force`
rebuilds a configuration, and it does not turn one kind of entry into another, as it does not for a
key `register_connection` holds (#620).

| call | before | now |
|---|---|---|
| `register_offline("db")`, then `load("db"; env = "dev")` | warning, then a live pool | `InvalidConfigurationError` (#1451) |
| the same, with `force = true` | a live pool | `InvalidConfigurationError` (#1451) |
| `unregister_connection("db")`, then `load("db"; env = "dev")` | a live pool | a live pool, unchanged |

### Who this affects

A test suite or script that registers a key offline and later loads a configuration under the same
key, directly or through a package's `__init__`.

### How to find the calls to migrate

```bash
grep -rln 'register_offline' --include=*.jl test/ src/ | xargs grep -n 'Configuration.load\|using '
```

For each file that registers a key offline, check whether it later loads that key, or `using`s a
module whose body or `__init__` does.

### Migrate your app

```julia
# ✗ before — the offline entry was replaced by a live pool; now raises InvalidConfigurationError (#1451)
PormG.Configuration.register_offline("db")
using App                                   # its __init__ calls Configuration.load("db"; env = "test")

# ✓ an offline suite imports the model files, not the application
PormG.Configuration.register_offline("db")
PormG.@import_models "db/models.jl" models

# ✓ a file that needs the database loads it, in its own process, with no offline key
PormG.Configuration.load("db"; env = "test")
```

A process that needs both in turn calls `PormG.Configuration.unregister_connection("db")` before the
`load`.
