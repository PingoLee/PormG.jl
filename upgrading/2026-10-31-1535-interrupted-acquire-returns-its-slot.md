## An acquire cut short by an exception gives its pool slot back (#1535)

- **Version**: Unreleased
- **PormG ref**: #1535 ; `src/ConnectionPool.jl` (`acquire_connection`, `_abandon_wait!`, `_drop_owned!`)
- **Recorded**: 2026-10-31
- **Severity**: behavior change (bug fix). Nothing raises differently; a pool no longer loses a slot.

### What changed

A caller waiting in `acquire_connection` for a connection (every connection leased, or the pool
retrying a connect while the server is down) could leave the pool one slot short for the life of the
process. Three ways led there:

- a `Ctrl+C` while it waited, which since #1512 reaches a caller on the main thread;
- a `Ctrl+C` just after a release had handed it a connection;
- a `before_connect` hook that refused the connection after a discard had handed it an empty slot.
  This one needs no `Ctrl+C`, and is older than #1512.

The next release handed the slot to that caller, who was gone. The slot stayed checked out with no
borrower. Now the caller leaves the queue, and a slot handed to it goes to the next waiting caller or
back to the pool. The exception the caller sees is unchanged: `InterruptException`, or
`PoolConnectError` for the refused hook.

| Call | before | now |
|---|---|---|
| `pool_stats().in_use` after such an acquire | one higher, for good | back to the real count |
| `pool_stats().waiting` after an interrupted wait | could stay at 1 | 0 |
| A later `acquire_connection` on a pool that lost every slot that way | `PoolTimeoutError` | a connection |
| What the interrupted or refused acquire raises | `InterruptException` / `PoolConnectError` | unchanged |

### How to find the calls to migrate

Code that reads the pool counters, or works around a pool that runs dry after a `Ctrl+C` or a
refused hook:

```bash
grep -rnE 'pool_stats|in_use|before_connect|set_before_connect_hook' --include=*.jl .
```

### Migrate your app

Nothing to change. A health check that alerted on `in_use` creeping up after interrupts or refused
hooks will stop seeing it. A workaround that called `close_pool!` to recover the lost slots can go.
