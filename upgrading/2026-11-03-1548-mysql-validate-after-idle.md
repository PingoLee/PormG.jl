## MySQL pings a connection idle past `validate_after_idle` before using it; the key above 0 raises on PostgreSQL and SQLite (#1548)

- **Version**: Unreleased
- **PormG ref**: #1548, #1618 ; `src/ConnectionPool.jl`, `src/Configuration.jl`, `ext/PormGMySQLExt.jl`
- **Recorded**: 2026-11-03
- **Severity**: behavior. On MySQL a statement that raised now runs, and an unreachable server after an idle period raises `PoolConnectError` instead of `OperationalError`. A `connection.yml` that sets `validate_after_idle` above 0 on PostgreSQL or SQLite, which loaded with an "unrecognised key" warning, now raises at `load`.

### What changed

A MySQL server closes a connection that sat idle longer than its `wait_timeout` without telling the
client, and MySQL's checkout probe (`isopen`) still answers that the connection is open. So after a
quiet period, the first statement on such a pooled connection raised `OperationalError`, and the pool
renewed the connection after it.

A new `connection.yml` key, `validate_after_idle` (seconds), makes a checkout ping (COM_PING) a
connection that sat in the pool longer than that, and open a new one in its slot if the ping fails,
**before** the statement is sent. It defaults to 60 on MySQL. `0` turns it off.

PostgreSQL's and SQLite's checkout probe already sees a connection the server closed, so there the
key takes only `0`. A value above `0` raises `BackendCapabilityError` (`idle_validation`).

| call | before | now |
|---|---|---|
| MySQL: the first query after the pool sat idle past the server's `wait_timeout` | `OperationalError`, then the slot is renewed | the slot is renewed, the query returns its rows |
| MySQL: a checkout of a connection returned more than 60 s ago | no round trip | one COM_PING round trip first |
| MySQL: the first query after an idle period, with the server unreachable | `OperationalError` at once | `PoolConnectError` (a `PoolError`, not a `DatabaseError`) at the checkout's deadline (`pool_timeout`), after retrying the connect |
| MySQL: the first query after an idle period, over a network path that drops packets silently | `acquire_connection` returns at once, the statement waits until the kernel gives up | the checkout's ping gives up at the checkout's deadline (`timeout_seconds`, or `pool_timeout`; at least one second, #1618), then the slot is renewed; the new connection is bounded by `connect_timeout`, unset by default |
| PostgreSQL / SQLite: `load` of a `connection.yml` with `validate_after_idle: 30` | loads, warns "unrecognised connection key; ignored" | `BackendCapabilityError` |
| PostgreSQL / SQLite: `validate_after_idle: 0` | loads, warns | loads, no warning |

### Who this affects

- A PostgreSQL or SQLite `connection.yml` that sets `validate_after_idle` above 0. It never did
  anything there.
- A MySQL application that catches the `OperationalError` from the first query after an idle period
  to retry it: that query now succeeds. The catch is harmless.
- A MySQL deployment that counts round trips: a checkout after more than 60 s idle sends one ping.
- MySQL code that handles an unreachable server by catching `DatabaseError` or `OperationalError`
  around the first query after an idle period: that case now raises `PoolConnectError`. Catch
  `PormGError`, or both.

### How to find the calls to migrate

```bash
grep -rn 'validate_after_idle' --include=*.yml --include=*.jl .
# MySQL code that recognises a lost connection by its database error type
grep -rnE 'OperationalError|DatabaseError' --include=*.jl .
```

### Migrate your app

```yaml
# ✗ before: on PostgreSQL, accepted with a warning and ignored
dev:
  adapter: PostgreSQL
  database: 'formula1'
  validate_after_idle: 30

# ✓ after: leave the key out on PostgreSQL and SQLite; on MySQL keep it below the server's wait_timeout
dev:
  adapter: MySQL
  database: 'formula1'
  validate_after_idle: 30
```
