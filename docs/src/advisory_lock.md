# Advisory Locks

Advisory locks are a unique feature of PostgreSQL that allows applications to define their own locking semantics. Unlike row-level or table-level locks, advisory locks have no inherent meaning to the database; they are simply a mechanism for application-level synchronization.

PormG provides high-level support for advisory locks through the `with_advisory_lock` function.

## Why use Advisory Locks?

In a distributed environment (especially with the **Async-First** architecture of PormG), you might need to ensure that only one task or one process is performing a specific action at a time.

Common use cases include:
- Generating unique report files.
- Synchronizing access to external non-SQL APIs.
- Preventing race conditions in complex logic that spans multiple tables but doesn't have a single "parent" row to lock.

## Usage

The `with_advisory_lock` function requires a **connection key** (pointing to a PostgreSQL database) and a **key string**.

```julia
# Load your models (preferred: hot-reload-friendly, self-registering)
PormG.@import_models "db/models.jl" models
import .models as M

# Example: Ensuring only one task updates a specific Driver's statistics
driver_id = 1
lock_key = "driver_update_$(driver_id)"

PormG.with_advisory_lock("db_2", lock_key; wait=true, timeout_ms=10000) do
  # Critical section code here
  # While inside this block, no other process using this lock_key 
  # can enter its own with_advisory_lock block.
  
  driver = M.Driver.objects.filter("driverid" => driver_id) |> DataFrame
  @info "Updating stats for $(driver[1, :surname])"
  sleep(2) # Simulate work
end
```

## Configuration and Strategies

### Waiting Strategies

When a lock is already held by another session, you can choose how PormG should behave:

1.  **Non-blocking (`wait=false`)**: Immediately raises [`OperationalError`](errors.md) if the lock cannot be acquired. The same type is raised when a `:poll` or `:block` acquisition exceeds `timeout_ms`.
2.  **Client Polling (`strategy=:poll`)**: (Default) PormG will try to acquire the lock, wait for a few milliseconds, and try again until the `timeout_ms` is reached.
3.  **Server Blocking (`strategy=:block`)**: PormG tells PostgreSQL to block the connection until the lock is granted. This is more efficient as it reduces network traffic, but it ties up a database connection from the pool.

### Timeouts

The `timeout_ms` parameter ensures your application doesn't hang indefinitely. 
- In `:poll` strategy, the timeout is managed by Julia.
- In `:block` strategy, PormG temporarily sets the PostgreSQL `statement_timeout` for that specific acquisition.

## Implementation Details

- **PostgreSQL**: Implementation uses `pg_try_advisory_lock` (non-blocking) or `pg_advisory_lock` (blocking).
- **SQLite**: `with_advisory_lock` is a **no-op** — see the warning below.
- **Async Safety**: `with_advisory_lock` uses `LibPQ.async_execute` and `fetch()` to ensure that the Julia task yields while waiting for the database, keeping the event loop unblocked.

!!! warning "Advisory locks are a no-op on SQLite"
    On a SQLite connection the body of `with_advisory_lock` runs with **no mutual exclusion at
    all**. `wait`, `timeout_ms`, `strategy` and `interval_ms` are accepted and ignored, and the
    contention path cannot fire, so code that reacts to `OperationalError` never sees one there.

    SQLite's own writer serialization (`BEGIN IMMEDIATE`) is per-database-file and per-process; it
    is not a substitute for a named application lock, and it protects nothing for the non-SQL
    critical sections this page recommends locks for — report generation, external API calls,
    scheduled jobs. Treat SQLite as single-instance, exactly as
    [migrations do](migrations/index.md), and rely on advisory locks only where PostgreSQL is the
    production backend.

### Choosing what SQLite does: `on_missing_lock`

The no-op stays the default — it is what lets one codebase run PostgreSQL in production and SQLite
in tests. But because what degrades here is a *guarantee* rather than a query, the SQLite path is
not silent, and `on_missing_lock` lets you pick (#277):

| `on_missing_lock` | On SQLite | Use it when |
| :--- | :--- | :--- |
| `:warn` (default) | Body runs; **warns once per key** | You want to be told, but not stopped |
| `:ignore` | Body runs, silently | You have read this page and accepted the no-op |
| `:error` | Raises [`BackendCapabilityError`](errors.md); the body does **not** run | The exclusion is genuinely required for correctness |

The same call site works on both backends — that is the point of the keyword:

```julia
# Default: a real lock on PostgreSQL, a warning once per key on SQLite.
PormG.with_advisory_lock(connection_key, "driver_update_$(driver_id)") do
    # rebuild this driver's standings
end

# SQLite gives no protection here and that is acceptable — stay quiet.
PormG.with_advisory_lock(connection_key, "circuit_cache_warm"; on_missing_lock = :ignore) do
    # …
end

# This MUST be exclusive. Refuse to run on a backend that cannot promise it.
PormG.with_advisory_lock(connection_key, "season_points_recalc"; on_missing_lock = :error) do
    # never reached on SQLite — BackendCapabilityError is raised instead
end
```

On PostgreSQL `on_missing_lock` is accepted and ignored: a real lock is always taken, so there is
no missing-lock case to have a policy about. An unrecognised value raises `InvalidValueError` on
**both** backends, so a typo cannot lie in wait until you happen to run on SQLite.

The warning fires once per distinct lock key, tracked in-process and independently of the logger in
use, so a scheduled job taking the same lock in a loop logs one line rather than one per iteration.
Tracking is capped at 64 distinct keys — a fair ceiling for a genuinely per-entity key like
`"driver_update_$(driver_id)"` — and the warning that reaches the cap says so rather than going
quiet without telling you.

## API Reference

```@docs
PormG.AdvisoryLock.with_advisory_lock
```
