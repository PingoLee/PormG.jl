# Advanced Configuration

PormG is designed for Julia's asynchronous task scheduling. This section covers connection pooling, advisory locks, and the performance implications of the async-first design.

## Connection Pooling & Async-First Design

- **Async-First API:** The synchronous `fetch()` API is a wrapper around the asynchronous `fetch_async()` core. This wrapper yields to the Julia scheduler while waiting for the database, ensuring compatibility with async frameworks.
- **Pooling Strategy:** The default strategy is `:poll`, which retries at configured intervals. Use `:block` for PostgreSQL to let the server-side manage the wait, often combined with a `statement_timeout`.
- **Sizing & capacity:** A pool starts at `pool_size` connections (default `3`) and grows **lazily, on demand,** up to `pool_size × 10` under concurrent load — so the idle footprint stays small while async fan-out still gets headroom. If every connection is busy and none frees within the retry/timeout budget, `acquire_connection` raises a catchable `PoolTimeoutError` (exported by PormG). Raise `pool_size` in your `connection.yml` to add capacity for genuinely high-concurrency workloads:

```yaml
dev:
  adapter: PostgreSQL
  database: 'formula1'
  # ...
  pool_size: 10   # base 10 → grows to 100 under burst
```
- **Thread Safety:** PormG uses `ReentrantLock` for pool management.

---

## Advisory Locks

Use advisory locks to ensure long-running tasks (migrations, seeds, imports) do not run in parallel across processes.

```julia
using PormG, LibPQ   # advisory locks are PostgreSQL-only

# Wrap multiple operations in an advisory lock
PormG.run_in_transaction("db") do
    with_advisory_lock(settings, "my_job_name") do
        # Long-running task
        M.Result.objects.create("year" => 2025, "name" => "New Race")
        bulk_insert(M.Result.objects, results_df)
    end
end
```

### Key Technical Details
- **Hashing:** Keys are hashed using MD5 to provide a 64-bit bigint identifier.
- **Cleanup:** PostgreSQL releases the lock automatically if the session drops.
- **SQLite Limitation:** SQLite does not support advisory locks; the helper will no-op with a warning on that backend.

---

## The Boot-Time Hazard

There is an important boot-time hazard when using `@import_models` in a server module.

`@import_models` eventually calls `Models.set_models(...)`. If the corresponding configuration path is not loaded yet, `set_models(...)` can trigger `Configuration.load(path)` implicitly. If that happens before the server has selected the intended environment, PormG may initialize that settings object using the default environment and retain it for the rest of the process.

**Recommendation:** Always call `Configuration.load(path; env="...")` explicitly before `@import_models` in server-side code.
