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
- **Acquire timeout (`pool_timeout`):** How long `acquire_connection` waits for a free connection before raising `PoolTimeoutError` — default **30 s**. Set `pool_timeout:` in `connection.yml` (seconds; fractional allowed) to *fail fast* instead of blocking a request while the pool is saturated:

  ```yaml
  dev:
    adapter: PostgreSQL
    database: 'formula1'
    pool_size: 10
    pool_timeout: 5   # give up after 5s waiting for a connection, then raise PoolTimeoutError
  ```

  An explicit per-call `acquire_connection(pool; timeout_seconds=…)` still overrides it, and `Configuration.register_connection` accepts the same `pool_timeout` kwarg. A value `≤ 0` falls back to the 30 s default (a "never wait" setting is ambiguous and a footgun). Absent means the historical 30 s — zero behavior change.
- **Connect failures (`PoolConnectError`, `fail_fast_on_connect`):** `pool_timeout` covers a *saturated healthy* pool. A pool that can never open a connection — a wrong password, a missing role/database, an unopenable SQLite path — is a different failure: waiting `pool_timeout` for it to "free up" is pointless, and blaming `pool_size` is misleading. `acquire_connection` therefore classifies the driver error: a **permanent** one (PostgreSQL auth / missing role or database; SQLite `unable to open database file`) **fails fast** with a catchable `PoolConnectError` (exported) that carries the underlying driver cause and a **redacted** connection string — remedy: fix credentials/host/database, not `pool_size`. Ambiguous errors (host/DNS/network — possibly a transient blip) are *not* fast-failed; they wait to the deadline as before and then also surface `PoolConnectError` (with the cause) rather than `PoolTimeoutError`. Set `fail_fast_on_connect: false` to opt out of the fast-fail and keep waiting the full `pool_timeout`:

  ```yaml
  dev:
    adapter: PostgreSQL
    database: 'formula1'
    pool_size: 10
    fail_fast_on_connect: false   # default true; false = wait pool_timeout even on a bad password
  ```

  Default is `true` (zero-config: a misconfigured deploy fails immediately instead of hanging every request for 30 s). `register_connection` accepts the same `fail_fast_on_connect` kwarg. Transient recovery is *not* retried inside the pool — retry the whole operation at the application layer (the same rule as lost connections inside a transaction).
- **Idle reaping & max-lifetime (opt-in):** By default the pool never shrinks after a burst and reuses connections indefinitely (a dropped connection is caught reactively by the liveness check on the next checkout). For long-lived services — or databases/proxies that drop idle connections — you can enable a background reaper via `connection.yml` (both in **seconds**, `0`/absent = off):

  ```yaml
  dev:
    adapter: PostgreSQL
    database: 'formula1'
    pool_size: 10
    idle_timeout: 60      # close *overflow* connections idle > 60s, trimming back toward pool_size
    max_lifetime: 1800    # retire connections older than 30 min (on return, and by the sweeper)
  ```

  Reaping is **overflow-only** and never drops below the base `pool_size` (those stay warm), and never closes an in-use connection. It closes the connection and clears its slot in place — the pool's slot layout is unchanged, so a reaped slot simply opens a fresh connection on next use. Disabled by default: unset means zero behavior change. Programmatic pools accept the same `idle_timeout` / `max_lifetime` kwargs via `Configuration.register_connection`.
- **Health snapshot (`pool_stats`):** `pool_stats` (exported) returns a `NamedTuple` for debugging saturation — pass a pool object or a connection key/path:

  ```julia
  using PormG
  pool_stats("db")   # => (; pool_size, size, in_use, available, ceiling, waiting)
  ```

  `pool_size` is the configured floor, `size` the slots allocated so far (`== in_use + available`), `ceiling` the maximum (`pool_size × 10`), and `waiting` the callers currently parked for a connection — a non-zero `waiting` with `in_use == ceiling` is the signature of saturation (see `PoolTimeoutError`). Counts are read under the pool lock for a coherent snapshot.
- **Leak detection (`leak_detection_threshold`, opt-in):** A connection acquired but never released (e.g. a `fetch_async` that's never awaited) is silently lost until the pool starves. Set `leak_detection_threshold` (**seconds**, `0`/absent = off) to have `acquire_connection` emit a single `@warn` — naming the slot and hold time — when a connection has been held past the threshold:

  ```yaml
  dev:
    adapter: PostgreSQL
    database: 'formula1'
    pool_size: 10
    leak_detection_threshold: 30   # warn when a connection is held > 30s without release
  ```

  The scan runs on the next `acquire_connection` (no background task), so a leak is flagged as the pool comes under pressure — pointing at the offending slot just before a `PoolTimeoutError`. Off by default; `register_connection` accepts the same `leak_detection_threshold` kwarg.
- **Thread Safety:** PormG uses `ReentrantLock` for pool management.
- **Failed-rollback self-healing:** If a transaction's `ROLLBACK` itself fails (e.g. the connection died mid-transaction), the pool never returns that connection as-is. It is renewed in its slot (PostgreSQL: `LibPQ.reset!`; SQLite: a fresh handle, with the old one closed so it releases the database file write-lock) or — if renewal also fails — closed and its slot cleared so the next borrower opens a fresh connection.

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
