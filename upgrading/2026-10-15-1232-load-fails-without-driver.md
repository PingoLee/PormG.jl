## `Configuration.load` — a configuration whose driver package is not loaded fails at `load`, not at the first query (#1232)

- **Version**: 0.9.0
- **PormG ref**: #1232 ; `src/Configuration.jl` (`load`, `_peek_driver`, `_require_driver_extension`), `src/Backend.jl` (`_DRIVER_EXTENSIONS`, `_driver_hint`)
- **Recorded**: 2026-10-15
- **Severity**: behavior change. `load` raises `MissingConfigurationError` where it used to succeed;
  the same missing driver used to raise on the first query.

### What changed

PormG's database drivers are weak dependencies: `LibPQ` (or `Postgres`) for PostgreSQL, `SQLite` for
SQLite. When the package was not loaded, `Configuration.load` still registered the configuration,
and the first query raised *"the PostgreSQL backend requires LibPQ"* — often long after boot, in a
request handler.

| | before | after |
|---|---|---|
| `load` of a PostgreSQL configuration, no `using LibPQ` | registered; the first query raises | `MissingConfigurationError` naming `using LibPQ`; nothing registered |
| the same with `postgres_driver: Postgres`, no `using Postgres` | registered; the first query raises | `MissingConfigurationError` naming `using Postgres` |
| `load` of a SQLite configuration, no `using SQLite` | registered; the first query raises | `MissingConfigurationError` naming `using SQLite` |
| `load` during precompilation | — | not checked; the runtime `load` (in `__init__`) is |

### Who this affects

A process that loads a configuration before (or without) loading its driver package. A script or
test that loads a configuration only to render SQL and never queries (`show_query`, `inspect_query`)
now needs the driver too, or `Configuration.register_offline(key; adapter)`, which needs none. A
package that loads its configuration in `__init__` must have the driver among its own dependencies
and `using` it in the module.

### How to find the calls to migrate

Run the application or the test suite: the error names the configuration key and the package to load.

```bash
grep -rnE 'cannot load ".*extension loads' <your logs>
```

### Migrate your app

```julia
# ✗ before — worked until the first query
using PormG
PormG.Configuration.load("db"; env = "prod")

# ✓ after — the driver is loaded with PormG
using PormG, LibPQ
PormG.Configuration.load("db"; env = "prod")

# ✓ a test that only renders SQL needs no driver at all
PormG.Configuration.register_offline("db"; adapter = :postgres)
```
