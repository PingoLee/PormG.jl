## A pool connect runs off the pool's lock, and a `Ctrl+C` during it reaches the caller (#1540)

- **Version**: Unreleased
- **PormG ref**: #1540 ; `src/ConnectionPool.jl` (`acquire_connection`, `_connect_reserved!`)
- **Recorded**: 2026-10-31
- **Severity**: behavior change. One exception changes for an interrupted connect; the rest is timing.

### What changed

`acquire_connection` used to open a new connection while holding the pool's lock. For as long as
the connect took, every other use of that pool waited: a `release_connection`, every other
`acquire_connection` (including one that would have found an idle connection), `pool_stats`, the
reaper and `close_pool!`. The waiting acquirer's `pool_timeout` did not bound that wait. Against a
host that drops packets, a connect lasts until the operating system's TCP connect timeout, about two
minutes on Linux's defaults.

The caller now reserves a slot under the lock, connects without it, and takes the lock again to
install the connection. Other callers release, borrow and time out while a connect is in progress,
and several callers can connect at the same time.

A `Ctrl+C` that lands during the connect used to be caught as a failed connect and retried, so it
never reached the caller. It now raises `InterruptException` at once, and the reserved slot goes
back to the pool.

| Call | before | now |
|---|---|---|
| `release_connection` while another caller connects | waits for the connect to finish | returns at once |
| `acquire_connection(…; timeout_seconds = t)` while another caller connects, pool at its ceiling | raises `PoolTimeoutError` when the connect ends, possibly long after `t` | raises `PoolTimeoutError` at about `t` |
| Callers connecting during an outage | one at a time, behind the lock | side by side, one attempt per caller at a time |
| `Ctrl+C` during `backend_connect` | caught as a failed connect and retried; the interrupt was lost | `InterruptException`; the slot is freed |
| `pool_stats().in_use` during a connect | counted as available (a new slot: not counted) until the connect ended | the reserved slot counts as `in_use` |
| Leak detection (`leak_detection_threshold`) | no warning while connecting | a connect slower than the threshold is reported like a held connection |

### How to find the calls to migrate

Code that catches around `acquire_connection` or a query, or that reads `pool_stats`:

```bash
grep -rnE 'acquire_connection|InterruptException|PoolConnectError|pool_stats|leak_detection_threshold' --include=*.jl .
```

### Migrate your app

Nothing to change for code that lets an `InterruptException` propagate. A `catch` that treats every
exception from `acquire_connection` as a connect failure now also sees the interrupt: let it
escape.

```julia
# before
try
    M.Result.objects.filter("raceid" => 18).list()
catch e
    e isa PoolConnectError || rethrow()
    # the database is unreachable
end

# after: unchanged. An InterruptException is not a PoolConnectError, so it propagates.
```

A health check that alerts on `pool_stats().in_use` sees a reserved slot as in use while its
connect runs. With leak detection on and a server slow to accept connections, a connect longer than
`leak_detection_threshold` logs the leak warning. Raise the threshold above your connect time.
