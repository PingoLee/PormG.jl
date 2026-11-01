## `Ctrl+C` during a query — cancels the statement under Postgres.jl and SQLite instead of waiting for it (#1512)

- **Version**: Unreleased
- **PormG ref**: #1512, #1534 ; `src/ConnectionPool.jl` (`_fetch_interruptible`, `_cancel_at_abandon!`), `src/AdvisoryLock.jl`
- **Recorded**: 2026-10-31
- **Severity**: behavior change. The error raised is the same; what happens to the interrupted statement is not. LibPQ is unchanged.

### What changed

A `Ctrl+C` while a query ran waited for the statement to finish on the database before it raised,
under `postgres_driver: Postgres` and on SQLite. The statement ran to the end, so an interrupted
write committed. Julia delivers the interrupt to its main thread at once only while that thread
waits on libuv, which LibPQ's socket wait does and Postgres.jl's and SQLite's waits did not. PormG
now keeps libuv waiting for the length of every await on a driver handle on the main thread, so the
interrupt arrives at once. Outside a transaction block the statement is then cancelled, as it
already was under LibPQ. Inside one, the interrupted statement still runs to its end before the
`ROLLBACK`. On SQLite the caller sends the cancel itself (#1534): the recovery task that used to
send it needs a free worker thread, and under plain `julia` the only one is running the statement,
so the cancel arrived after the statement ended and the next query waited for it. A COPY, which runs on the caller's own task, is not covered. MySQL is unchanged: a real
`Ctrl+C` is lost there (#1520).

| Call | before | now |
|---|---|---|
| `Ctrl+C` during a query under Postgres.jl (`SELECT pg_sleep(30)`, interrupted at 1 s) | raised after 30.5 s; the statement ran to the end | raises after about 1.3 s; the statement is cancelled on the server |
| `Ctrl+C` during a long SQLite query, Julia started with two or more threads (plain `julia`, `-t 2,1`, `-t auto`) | raised when the statement finished (43 s in the measured case) | raises after about 1.05 s, the statement is interrupted and the next query runs at once (5 runs per layout, #1534) |
| `Ctrl+C` during an autocommit write outside a transaction block, under Postgres.jl or SQLite with two or more threads | the write committed | the write is cancelled and normally does not commit (a cancel that arrives after the server committed is too late) |
| What is raised | `StatementError` with the `InterruptException` as its `cause` | unchanged |
| SQLite under `julia -t 1` | waited for the statement | unchanged: the statement runs on the only thread |

### How to find the calls to migrate

Nothing calls this; it is what an interactive session sees. The setups it applies to:

```bash
grep -rnE 'postgres_driver|PORMG_POSTGRES_DRIVER|adapter[:=] *"?SQLite' --include=*.yml --include=*.jl --include=*.toml .
```

### Migrate your app

Nothing to change in code. A long write you start from the REPL, outside a transaction block, now
stops when you press `Ctrl+C` and normally does not commit; if it must finish, wait for it rather
than interrupting it. A plain `julia script.jl` is unchanged: `Ctrl+C` exits the process.
