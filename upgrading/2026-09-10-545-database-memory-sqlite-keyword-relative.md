## `database: ":memory:"` is a SQLite keyword, no longer a relative path (#545)

- **Version**: 0.6.0
- **PormG ref**: #545 ; `src/Configuration.jl`
- **Recorded**: 2026-09-10
- **Severity**: behavior change

### What changed

`Configuration.load` resolved every SQLite `database:` value against the config folder. Its
in-memory arm was gated on the key being **absent**, so an explicit `database: ":memory:"` never
reached it and was joined onto the folder like an ordinary relative path.

The corruption stayed invisible for years because it landed differently on each platform:

| platform | before | after |
|---|---|---|
| POSIX | an on-disk file literally **named** `:memory:` inside the config folder | a real in-memory database |
| Windows, Julia < 1.13 | `:memory:` — `splitdrive(":memory:")` reported a drive, so `joinpath` discarded the prefix and the result was right **by accident** | unchanged |
| Windows, Julia ≥ 1.13 | `<config folder>\:memory:` → `SQLiteException("unable to open database file")` on first connect | a real in-memory database |

`file:` URI filenames are passed through for the same reason: they are URIs, not paths.

### Who this affects

Only a configuration that spells `database: ":memory:"` (or `host: ":memory:"`) under
`adapter: SQLite`. Any other value behaves exactly as before — relative paths still resolve inside
the config folder, and their parent directories are still created.

On **POSIX** such a configuration changes in two ways, because it was never actually in-memory
there:

1. **Data no longer survives the process.** It was being written to a file named `:memory:`; that
   file is no longer read or created. Anything that must persist needs a real path.
2. **Pool connections no longer share data.** A bare `:memory:` database is private to the
   connection that opened it, and `pool_size` defaults to 3 — so a table created through one slot is
   invisible from the next, surfacing as `no such table`. Use the shared-cache URI form for a pool.

### How to find the calls to migrate

```bash
grep -rn "memory:" --include="connection.yml" .
```

### Migrate your app

```yaml
# ✗ before — on POSIX this was silently an on-disk file named ":memory:", shared by the pool
test:
  adapter: SQLite
  database: ":memory:"

# ✓ after — one in-memory database shared across every pool connection, nothing written to disk
test:
  adapter: SQLite
  database: "file:pormg_test?mode=memory&cache=shared"
```

Keep the bare `":memory:"` only where a single connection is intended:

```yaml
test:
  adapter: SQLite
  database: ":memory:"
  pool_size: 1
```
