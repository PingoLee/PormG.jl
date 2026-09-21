## Connection errors inside `run_in_transaction` now propagate (no silent statement retry)

- **PormG ref**: issue #138 ; `src/ConnectionPool.jl`
- **Recorded**: 2026-07-13
- **Severity**: behavior change (error now surfaces instead of a silent, broken retry)

### What changed

`fetch()`'s lost-connection recovery (renew the pooled connection, re-run the statement once)
no longer fires **inside a transaction context** or on a caller-pinned `conn`. Previously a
connection drop during e.g. `q.create(...)` inside `run_in_transaction` silently re-ran the
statement on a **fresh autocommit session** — committing a write that should have died with the
transaction — and released the transaction's pooled connection to the pool mid-transaction. Now
the connection error propagates out of the transaction block like any other failure; the wrapper
rolls back and renews/discards the pooled connection (#71). Plain `fetch()` outside transactions
keeps the transparent one-shot retry. This matches Django / SQLAlchemy / Rails 7.1 /
Go `database/sql`: never retry a statement inside a transaction — the application retries the
whole transaction.

### How to find the calls to migrate

Nothing to grep — no API changed. Only code that (unknowingly) relied on the mid-transaction
retry is affected: if a transaction block now fails with a driver connection error where it
previously appeared to succeed (with silently corrupted transactional semantics), wrap the
**whole** `run_in_transaction` call in an application-level retry.

### Migrate your app

```julia
# ✗ before: a connection drop mid-block silently committed the create OUTSIDE the transaction
# ✓ after: the block raises; retry the whole transaction if the work must survive reconnects
for attempt in 1:3
  try
    PormG.run_in_transaction("db_2") do
      (M.Pit_stops.objects).create(
        "raceid" => 841, "driverid" => 153, "stop" => 3, "lap" => 42,
        "time" => "17:05:23", "duration" => "22.500", "milliseconds" => 22500,
      )
    end
    break   # committed
  catch e
    attempt == 3 && rethrow()
  end
end
```
