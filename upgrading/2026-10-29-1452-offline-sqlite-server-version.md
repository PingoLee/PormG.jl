## An offline SQLite key renders for the `server_version` it states, and needs no driver (#1452)

- **Version**: Unreleased
- **PormG ref**: #1452 ; `src/Configuration.jl` (`register_offline`, `_offline_server_version`), `src/ConnectionPool.jl` (`_server_version` for `SQLiteConnectionPool`), `src/querybuilder/execution_bulk.jl` (`_backend_parameter_limit`)
- **Recorded**: 2026-10-29
- **Severity**: behavior change, SQLite offline keys only. A query whose SQL depends on the SQLite version used to render for the SQLite library of the process, with `using SQLite`, and raise without it. It now renders for `register_offline(…; server_version)`, and raises `InvalidConfigurationError` when no version was stated, with the driver loaded or not.

### What changed

A few clauses PormG renders for SQLite depend on its version: `NULLS FIRST`/`LAST` is native from
3.30.0 and emulated below it, window functions are refused below 3.25.0, `RIGHT`/`FULL` joins below
3.39.0, and a bulk statement is chunked by the bind-parameter limit (999 below 3.32.0, 32766 from it).
An offline SQLite key asked the library of the process for that version. Without `using SQLite` the
query raised. With it, the pinned SQL followed whichever library the machine resolved, so two CI
images could pin different SQL for the same query.

`register_offline` takes `server_version`, SQLite's packed version number (`3_045_000` for 3.45.0).
An offline SQLite key renders the version-dependent clauses for it and never asks the library, so the
SQL is the same on every machine, and no driver is needed. Without `server_version`, a query that
needs the version raises `InvalidConfigurationError` naming it, `using SQLite` or not; a query that
does not need it renders as before.

`server_version` is for `adapter = :sqlite`: the SQL PormG renders for PostgreSQL depends on no
server version, so `server_version` with `:postgres` raises `InvalidConfigurationError`. The 0.9.0
entry for #1232 says an offline key "needs none" (no driver); that now holds for SQLite too, once its
version is stated.

| on `register_offline("db"; adapter = :sqlite)` | before | now |
|---|---|---|
| `order_by("-points")`, window functions, `RIGHT`/`FULL` joins, a bulk statement — with `using SQLite` | rendered for the process's library | `InvalidConfigurationError` naming `server_version` (#1452) |
| the same, without `using SQLite` | `InvalidConfigurationError` (load the driver) | `InvalidConfigurationError` naming `server_version` (#1452) |
| the same, with `server_version = 3_045_000` | — | rendered for SQLite 3.45.0, driver or not |
| a query with no version-dependent clause | rendered | rendered, unchanged |

### Who this affects

A golden-SQL suite that registers a SQLite key offline and pins a query with an `order_by`, a window
function, a `RIGHT`/`FULL` join or a bulk write.

### How to find the calls to migrate

```bash
grep -rn 'register_offline(.*:sqlite' --include=*.jl test/ src/
```

### Migrate your app

```julia
# ✗ before — rendered for the SQLite library of the machine; now raises at the first ordered query (#1452)
PormG.Configuration.register_offline("db"; adapter = :sqlite)

# ✓ state the SQLite version production runs; the pins then follow it on every machine
PormG.Configuration.register_offline("db"; adapter = :sqlite, server_version = 3_045_000)
```

Re-pin any SQL that changes: it changes only when the stated version differs from the library the
pins were recorded on.
