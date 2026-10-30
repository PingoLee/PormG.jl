## Postgres.jl driver: statements run through the driver's prepared-statement cache (#1479)

- **Version**: Unreleased
- **PormG ref**: #1479 ; `ext/PormGPostgresExt.jl` (`_execute`, `_execute_prepared`)
- **Recorded**: 2026-10-29
- **Severity**: behavior change. Under `postgres_driver: Postgres` only. Inside a transaction, a cached statement that a schema change or a `DEALLOCATE ALL` made stale now raises a `StatementError`. A hand-written `fetch` with the wrong number of parameters raises a `StatementError` where it raised an `OperationalError`. LibPQ is unchanged.

### What changed

The Postgres.jl extension used to send every statement unnamed, so the server parsed and planned it
on every call. Each connection now keeps the statements it runs prepared, in the driver's
`statement_cache_maxsize` cache (100 by default). A two-join read on the F1 data took about a
quarter less time. A statement the connection has not seen yet costs two extra round trips the
first time (three once the cache is full).

What a call now does:

| Call | before | now |
|---|---|---|
| Any connection or process, this one included, changes the columns of a table (`ADD COLUMN`), then a statement this connection cached for it (a read's `SELECT *`: `get()`, `first()` or `list()` without `values()`) runs **outside** a transaction. Since #1490 an added column does not reach writes: `create()`, `get_or_create()` and `update_or_create()` return the model's columns by name. A type change to a column the model declares (`varchar(50)` to `varchar(100)`) still reaches a cached write or read | the statement ran | unchanged: the statement runs (the cache is cleared and the statement prepared again) |
| The same, **inside** a transaction | the statement ran | `StatementError` caused by SQLSTATE `0A000`, `cached plan must not change result type`. The transaction is aborted. That connection's cache is cleared, so each pooled connection that cached the statement fails at most one transaction |
| `DEALLOCATE ALL` or `DISCARD ALL` sent on the connection, then a cached statement runs inside a transaction (a `DEALLOCATE ALL` sent inside the transaction includes its own `COMMIT`) | the statement ran | `StatementError` caused by SQLSTATE `26000`, and the transaction is aborted; the connection's cache is cleared, so the next transaction on it prepares afresh. Outside a transaction the statement runs |
| `fetch` of a hand-written statement with more or fewer values than its `$n` markers | `OperationalError` (the server's protocol error `08P01`) | `StatementError`: the driver refuses the call before sending it |

### Who this affects

Apps that set `postgres_driver: Postgres` (or `PORMG_POSTGRES_DRIVER=Postgres`) and either migrate
a table while other processes are writing to it inside transactions, or connect through a PgBouncer
in transaction-pooling mode without `max_prepared_statements`, which cannot route a prepared
statement to the server connection that holds it. A query that turns slower after its fifth call
may have been given a generic plan; `docs/src/configuration/connection_yml.md` → *Prepared
statements under Postgres.jl* has the `plan_cache_mode` setting that avoids it.

### How to find the calls to migrate

```bash
grep -rnE 'postgres_driver|PORMG_POSTGRES_DRIVER' --include=*.yml --include=*.jl --include=*.toml .
```

### Migrate your app

Behind a PgBouncer in transaction mode whose `max_prepared_statements` is 0 or absent (it arrived
in 1.21), turn the cache off in the connection string:

```yaml
# ✗ before: prepared statements reach whichever server connection PgBouncer picks
dev:
  adapter: PostgreSQL
  postgres_driver: Postgres
  url: postgresql://my_user@pgbouncer:6432/f1

# ✓ after: every statement is sent unprepared, as before
dev:
  adapter: PostgreSQL
  postgres_driver: Postgres
  url: postgresql://my_user@pgbouncer:6432/f1?statement_cache_maxsize=0
```

A transaction that can meet a concurrent deploy's schema change should be retried as a whole
when it raises the `0A000` or `26000` above. A `catch e isa OperationalError` around a hand-written
`fetch` that counted on the old type should catch `PormG.DatabaseError`, the umbrella both types are
under.
