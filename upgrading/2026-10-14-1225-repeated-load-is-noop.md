## `Configuration.load` — loading a folder already loaded with the same environment is a no-op (#1225)

- **Version**: Unreleased
- **PormG ref**: #1225 ; `src/Configuration.jl` (`load`, `load_many`, `_already_loaded`)
- **Recorded**: 2026-10-14
- **Severity**: behavior change. A second `load` of a folder that is already loaded with the same
  environment no longer reads `connection.yml` again and no longer rebuilds the pool. `force = true`
  restores the old behavior.

### What changed

`Configuration.load(path; env)` on a key that was already loaded used to close the entry's pool and
build a new one every time, without checking whether anything had changed. The documented package
bootstrap calls `load` in the module body and again in `__init__`, a script often loads a folder and
then does `using` on a package that loads it too, and Julia can run an `__init__` more than once.
Each of those rebuilt the pool, and closed any connection a request had checked out of it.

Now, when the folder (compared as a canonical path, so `"db"` and its absolute spelling are the same
folder) is already loaded with the same environment, `load` returns the key it is registered under
and does nothing else. `load_many` does the same for each folder.

| call, with `db` already loaded under `env = "prod"` | before | after |
|---|---|---|
| `load("db"; env = "prod")` | file read again, pool closed and rebuilt | no-op, returns `"db"` |
| `load(abspath("db"); env = "prod")` | `@warn`, file read again, pool rebuilt | no-op, returns `"db"`, no warning |
| `load("db"; env = "dev")` | file read again, pool rebuilt, silently | file read again, pool rebuilt, with a `@warn` |
| `load("db"; env = "prod", force = true)` | — | file read again, pool rebuilt |

Unchanged: an entry minted by the implicit load is still migrated to the key an explicit `load`
names (#550), and `register_connection` is not affected.

### Who this affects

Code that edits `connection.yml` in a running session and calls `load` again with the same
environment to pick up the edit. That call now keeps the old settings. The same holds after a
`close_pool!(key)`: the entry, and its pool object, are still there, so a `load(key)` that follows
is a no-op and does not read the rewritten file. A `load` of the same relative key from another
working directory is a different folder, and still reloads.

### How to find the calls to migrate

```bash
grep -rnE 'Configuration\.load(_many)?\(' --include=*.jl .
```

For each match, check whether the same folder is loaded again later in the same session, after
`connection.yml` changed, with the same `env` (or the same `PORMG_ENV`) — including a
`close_pool!(key)` followed by `load(key)` to "reconnect" with new settings.

### Migrate your app

```julia
# ✗ before — the second call re-read the edited connection.yml
PormG.Configuration.load("db"; env = "dev")
# … connection.yml edited …
PormG.Configuration.load("db"; env = "dev")              # now a no-op

# ✓ after — ask for the re-read explicitly
PormG.Configuration.load("db"; env = "dev", force = true)
```
