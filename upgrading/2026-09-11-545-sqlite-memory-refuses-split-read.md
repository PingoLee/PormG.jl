## SQLite `:memory:` refuses split read/write, and warns when a pool opens a second connection (#545)

- **Version**: 0.6.0
- **PormG ref**: #545 ; `src/ConnectionPool.jl`
- **Recorded**: 2026-09-11
- **Severity**: behavior change

### What changed

Follows the `:memory:` keyword fix in the entry above. Once an in-memory configuration is genuinely
in-memory on every platform, a property of SQLite that had been masked becomes reachable: **a bare
`:memory:` database belongs to the connection that opened it.** A pool of more than one connection
is therefore a pool of more than one *database*.

Two cases, answered differently because they differ in kind:

| configuration | before | after |
|---|---|---|
| `:memory:` + `sqlite_split_read_write: true` (with `pool_size` > 1) | pool constructed; every write went to the writer slot's private database and every read to an empty one | **`InvalidConfigurationError` at construction** |
| `:memory:` + `pool_size` > 1 | silent | still constructed; a **warning** the first time a second slot is actually opened |

The split pairing cannot be made to work — no ordering and no amount of retrying makes a reader slot
see what the writer slot wrote — so it is refused rather than left to lose writes silently.

The plain multi-connection case *does* work until concurrency opens a second slot, so it warns
instead of failing. The warning fires at that moment rather than at construction: a shared pool
scans slots in ascending order and reuses slot 1 whenever it is free, so most `:memory:` pools never
open a second database and have nothing to be warned about. It is also better timed there — it is
issued exactly when it explains the `no such table` the caller is about to see.

`pool_size: 1` is unaffected in both cases: the pre-existing `effective_split` downgrade already
turns split mode off at that size, so there is no conflict to refuse and no second slot to warn
about.

### How to find the calls to migrate

```bash
grep -rn "memory:" --include="connection.yml" .    # then check pool_size / sqlite_split_read_write
```

### Migrate your app

```yaml
# ✗ before — constructed, then silently lost every write
test:
  adapter: SQLite
  database: ":memory:"
  sqlite_split_read_write: true

# ✓ after — one shared in-memory database, nothing written to disk, split mode works
test:
  adapter: SQLite
  database: "file:pormg_test?mode=memory&cache=shared"
  sqlite_split_read_write: true
```

A single-connection in-memory database needs no URI:

```yaml
test:
  adapter: SQLite
  database: ":memory:"
  pool_size: 1
```
