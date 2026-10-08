## `fetch` — a dropped connection is retried only when the statement never ran (#1042)

- **Version**: Unreleased
- **PormG ref**: #1042 ; `src/ConnectionPool.jl` (`fetch`), `src/Backend.jl` (`backend_is_retry_safe`), `ext/PormGLibPQExt.jl`, `ext/PormGPostgresExt.jl`
- **Recorded**: 2026-10-08
- **Severity**: behavior change. A statement whose connection drops with no error code raises `OperationalError` where it used to be re-run silently.

### What changed

Outside a transaction, `fetch` handled every lost connection the same way. It renewed the failed
connection, retired the pool's idle ones, and ran the statement again. Most lost connections carry
no error code: `server closed the connection unexpectedly`, `SSL SYSCALL error: EOF detected`, a
reset, a timeout. Those mean only that the socket went away, and the socket can go away after the
server received the statement. An autocommit `INSERT`, `UPDATE` or `DELETE` that had already
committed then ran a second time.

The pool still recovers from every lost connection exactly as before: the failed slot is renewed and
the idle ones are retired. The statement is now re-run only when it provably never ran, which means
one of these:

- the server reported the backend gone with an error code: `57P01`, `57P02`, `57P03`, `57P05`, or
  class `08` except `08007` / `08P01`;
- the driver refused to send because the connection was already closed.

Any other lost connection reaches the caller as `OperationalError`, with the driver's error on
`.cause`. Both PostgreSQL drivers follow the same rule. The Postgres.jl driver also now treats a
socket timeout or an unreachable host as a lost connection, so the pool recovers from it as the
LibPQ driver already did. SQLite retries no lost connection: its one signal, a disk I/O error, can
come from a commit whose outcome is unknown.

Most dead connections are still caught before any statement is sent, by the liveness probe at
checkout (#442). What reaches your code is a connection that dropped while a statement was in
flight, or a silently broken network path.

### Who this affects

Apps that relied on `fetch` hiding a mid-statement drop. Measured on 2026-10-08: the consuming
apps have **0** handlers for `OperationalError` (or `DatabaseError` / `PormGError`), and their
background task runners already run with retries off. So the error propagates to the request or task
that ran the statement, where it used to be absorbed.

### How to find the calls to migrate

There is no call pattern: any statement can meet a dropped connection. Look at the places that
already handle database failures, and at the jobs where a transient failure should be retried:

```bash
grep -rnE 'OperationalError|DatabaseError|PormGError' --include=*.jl .
```

The warning `Lost connection to database. Retrying the statement…` in your logs now appears only for
the retried kinds. A drop that is not retried logs `Lost connection to database. The pool was
recovered, but the statement is not retried…` and raises the `OperationalError`.

### Migrate your app

Retry at the level that knows whether the work is safe to repeat, never around an arbitrary write:

```julia
# ✗ before — relied on fetch re-running a statement after any dropped connection
standings = M.Result.objects.
    filter("raceid__year" => 2024).
    values("driverid__surname", "points").
    list()

# ✓ after — a read is safe to repeat, so retry it once on an operational failure
function with_one_retry(f)
  try
    return f()
  catch e
    e isa PormG.OperationalError || rethrow()
    return f()
  end
end

standings = with_one_retry() do
  M.Result.objects.
    filter("raceid__year" => 2024).
    values("driverid__surname", "points").
    list()
end
```

For a write, retry only when a second run cannot change the outcome. One example is an upsert keyed
on a natural key. Another is a whole `run_in_transaction` block whose effects are checked before it
is repeated.
