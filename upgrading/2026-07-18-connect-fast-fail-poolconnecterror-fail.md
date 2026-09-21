## Connect fast-fail (`PoolConnectError`, `fail_fast_on_connect`)

- **PormG ref**: issue #72 (AC2; follow-up to #37/#124) ; `src/ConnectionPool.jl`, `src/Configuration.jl`,
  `src/Backend.jl`, `ext/PormGLibPQExt.jl`, `ext/PormGSQLiteExt.jl`, `src/PormG.jl`
- **Recorded**: 2026-07-18
- **Severity**: **mostly additive** (new exported `PoolConnectError`, opt-in `fail_fast_on_connect`, default
  on). **One behavior change to check:** an unopenable pool now raises `PoolConnectError`, not
  `PoolTimeoutError`. Only apps that *catch `PoolTimeoutError` specifically* around a connection failure
  need a look.

### What changed

`acquire_connection` used to treat "can't open a connection" (bad password, missing role/database,
unopenable SQLite path) the same as "healthy pool saturated": it waited the full `pool_timeout` (~30 s),
then threw `PoolTimeoutError` ("raise pool_size"). It now:

- **classifies** the driver error via a new backend hook (`backend_is_permanent_connect_error`): permanent
  = PostgreSQL auth / missing role|database, SQLite `unable to open database file`;
- **fast-fails** a permanent error immediately with a new catchable **`PoolConnectError`** (exported)
  carrying the driver `cause` + a redacted connection string (remedy: fix credentials, not `pool_size`);
- surfaces `PoolConnectError` (not `PoolTimeoutError`) for *any* connect failure that reaches the deadline,
  including ambiguous host/DNS errors (which are still waited out, not fast-failed);
- adds a `fail_fast_on_connect` config key (`connection.yml` + `register_connection` kwarg; default `true`)
  to opt out;
- (fix) redacts the connection string in SQLite pool logs, matching the PostgreSQL path.

A healthy-but-saturated pool still raises `PoolTimeoutError` — unchanged.

### How to find the calls to migrate

Grep each app for a `catch` that special-cases pool saturation on a connection acquire/fetch:

```
rg -n "PoolTimeoutError" <app>/src
```

If a handler means "the database is unreachable / misconfigured", widen it to also catch
`PoolConnectError` (or catch both). If it only means "pool is saturated, back off and retry", leave it —
`PoolConnectError` is intentionally a *different*, non-retryable signal.
