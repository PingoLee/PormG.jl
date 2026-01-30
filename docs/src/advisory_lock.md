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
import PormG.models as M

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

1.  **Non-blocking (`wait=false`)**: Immediately throws an error if the lock cannot be acquired.
2.  **Client Polling (`strategy=:poll`)**: (Default) PormG will try to acquire the lock, wait for a few milliseconds, and try again until the `timeout_ms` is reached.
3.  **Server Blocking (`strategy=:block`)**: PormG tells PostgreSQL to block the connection until the lock is granted. This is more efficient as it reduces network traffic, but it ties up a database connection from the pool.

### Timeouts

The `timeout_ms` parameter ensures your application doesn't hang indefinitely. 
- In `:poll` strategy, the timeout is managed by Julia.
- In `:block` strategy, PormG temporarily sets the PostgreSQL `statement_timeout` for that specific acquisition.

## Implementation Details

- **PostgreSQL**: Implementation uses `pg_try_advisory_lock` (non-blocking) or `pg_advisory_lock` (blocking).
- **SQLite**: Since SQLite does not support advisory locks, `with_advisory_lock` is a **no-op** (it simply executes the function without any locking). This allows you to write database-agnostic code that behaves correctly on production PostgreSQL while still running on SQLite for simple tests.
- **Async Safety**: `with_advisory_lock` uses `LibPQ.async_execute` and `fetch()` to ensure that the Julia task yields while waiting for the database, keeping the event loop unblocked.

## API Reference

```@docs
PormG.AdvisoryLock.with_advisory_lock
```
