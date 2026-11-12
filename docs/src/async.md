# Async & Concurrency

PormG is **async-first internally**: every terminal — `list()`, `count()`, `create()`, a `DataFrame` pipe — runs through the asynchronous core (`fetch_async` → `await_result`) and **yields to the Julia scheduler** while the database round-trip is in flight. The "synchronous" API parks the *task*, never the thread.

That has a powerful consequence: **there is no separate async query API to learn.** Julia functions are not colored — any query can be made concurrent by wrapping the ordinary call in a task:

```julia
t = Threads.@spawn M.Driver.objects.filter("nationality" => "Brazilian").list()
# ... other work overlaps the database round-trip ...
rows = fetch(t)          # Base.fetch on a Task — same Vector{PormGRow} as calling list() directly
```

This is the same contract Elixir's Ecto (`Task.async`) and Go's `database/sql` (goroutines) chose, and it is guaranteed by regression tests on PostgreSQL, SQLite and MySQL: a task-wrapped query returns exactly what the sync call returns.

!!! note "Two `fetch`es"
    `fetch(t)` above is `Base.fetch` on a `Task`. PormG's low-level `fetch(settings, sql)` escape hatch is *also* a method of `Base.fetch` — same name, different arguments. Application code rarely needs the latter; prefer the fluent terminals.

## How it works

`list()` → `fetch()` → `fetch_async()` → `await_result()`. On PostgreSQL the round-trip is real non-blocking I/O (`LibPQ.async_execute` on the LibPQ driver, a task per statement on Postgres.jl); on MySQL each statement runs on a task of its own; on SQLite every statement is funnelled through one serialized worker task. Every path *yields* while waiting, so concurrency is always safe — but only PostgreSQL and MySQL execute queries in parallel across connections. See the [Architecture](architecture.md) guide's *"Async-first" is backend-specific* note for the full picture.

## `@async` vs `Threads.@spawn`

Both overlap database waits, because the wait is a scheduler yield either way:

- **`Threads.@spawn`** (recommended default) — the task may run on any thread, so CPU-bound work after the query (row processing, aggregation) also parallelizes when Julia has threads (`julia -t auto`). Under `julia -t 1` it simply schedules on the sole thread and still overlaps I/O.
- **`@async`** — pins the task to the current thread. Fine for pure I/O overlap; no CPU parallelism.

!!! warning "Collect results from tasks, don't mutate shared state"
    With `Threads.@spawn`, tasks run in parallel. A shared counter like `hits[] += 1` on a `Ref` is a data race that silently loses updates. Return values from the task and collect them with `fetch` (as in every example on this page), or use `Base.Threads.Atomic` / a lock when you genuinely need shared state.

## Fan-out patterns

Run independent queries concurrently and collect results in input order:

```julia
years = 2010:2019

# One task per season — all round-trips in flight together
tasks = [Threads.@spawn M.Race.objects.filter("year" => y).count() for y in years]
counts = fetch.(tasks)   # [19, 19, 20, 19, 19, 19, 21, 20, 21, 21]
```

The same shape as a one-liner with `asyncmap`:

```julia
counts = asyncmap(y -> M.Race.objects.filter("year" => y).count(), collect(years))
```

For side-effecting fan-out where you only need completion, use a `@sync` block:

```julia
@sync for y in years
    Threads.@spawn begin
        n = M.Race.objects.filter("year" => y).count()
        @info "season loaded" year = y races = n
    end
end
```

Results arrive in *input* order with `fetch.(tasks)` / `asyncmap` — tasks may *complete* in any order.

## Connection-pool interplay

Each in-flight query leases one pooled connection for its duration; a 10-way fan-out briefly holds up to 10 connections. The pool starts at `pool_size` and grows lazily to a `pool_size × 10` ceiling; beyond that, callers park until a connection frees, and a genuine saturation raises a catchable `PoolTimeoutError` (tune with `pool_timeout`). Diagnose with `pool_stats("db")`. Details and YAML examples live in [Advanced Configuration](configuration/advanced.md).

A task-wrapped terminal **cannot leak** a connection: the query acquires and releases its connection inside the task, even if you never `fetch` the task.

## Under a web server's load

A web server runs each request as a task, and Julia does not preempt a task that computes. So what matters under load is where each driver waits for the database. The numbers below come from `test/performance/async_concurrency_probe.jl` (#1280): Julia 1.13.3, PostgreSQL 18 on the same machine, two runs each, on a machine shared with other work. They show the shape, not a benchmark. MySQL 8.4 was measured only for the `:interactive` caller (#1577).

- **On PostgreSQL, a waiting query frees its thread.** On 8 threads, 32 tasks each waiting on a 200 ms statement completed about 158 statements per second. If each wait held a thread, the most would be 40. Meanwhile a 10 ms heartbeat on the same threads woke with a p99 lateness of at most 2.3 ms, against 1.2 ms when idle. Its single worst wake was 4.5 ms late. A server can have many more queries in flight than it has threads.
- **A statement runs in the caller's threadpool, except on SQLite.** LibPQ runs it on the caller's thread, and Postgres.jl and MySQL run it in a task in the caller's pool (#1577). So an `:interactive` task, such as a heartbeat or a lease renewal, reaches the database while every `:default` thread computes: its primary-key lookups ran 59–60 times in 6 s with a median under 1 ms, on Postgres.jl and on MySQL alike. Before #1577, both drivers ran the statement on `:default` and managed one lookup in 6 s.
  - **SQLite still needs a free `:default` thread.** Its single worker task lives there, so with every `:default` thread computing, an `:interactive` task's lookup waits until the computation ends: one lookup in 6 s instead of 60. With one `:default` thread free, the lookups ran at their normal pace. On SQLite, keep at least one `:default` thread out of long CPU-bound work if an `:interactive` task must reach the database on time.
  - **The driver decodes the rows on the caller's pool too.** A statement from an `:interactive` task uses that thread for as long as its rows take to decode. On Julia 1.13 the main task (a script's top level, the REPL) runs on the interactive thread, unless Julia was started without one (`-t 1`, `-t N,0`), so its statements decode there. That was already so on LibPQ. To keep the interactive thread free during a large read, run the query from a `:default` task (`Threads.@spawn`).
- **SQLite runs one statement at a time per process.** Every statement goes through one worker task, so once a few tasks keep that worker busy, neither more tasks nor more threads raise the statement rate:
  - **Raw statements:** primary-key lookups stayed between about 9 and 31 thousand per second at `-t 1`, `-t 4` and `-t 8`. Going from 1 task to 8 raised the rate, because a single task leaves the worker idle between its own statements. Beyond 8 tasks, nothing raised it.
  - **ORM lookups:** they gain from threads, up to that ceiling, because the query is built on the caller's thread before it reaches the worker. That was about 3–4.5 thousand per second at `-t 1`, and 4–15 thousand (most runs above 7) at `-t 4` and `-t 8` with 8 or more tasks.
  - **A long statement delays every other:** with one 200 ms statement always in flight, the median concurrent lookup took as long as that statement (200–260 ms) at every thread count, against under 2 ms without it.

  Serve concurrent web traffic from PostgreSQL or MySQL. On SQLite, keep long statements out of a process that serves requests.

## Raw SQL: `fetch_async`, `await_result`, `FetchTask`

The only PormG-specific async API is the low-level escape hatch, and it takes **raw SQL only** — not query-builder objects:

```julia
settings = PormG.Configuration.get_settings("db")

task = fetch_async(settings, "SELECT count(*) FROM driver")   # returns a FetchTask
# ... do other work ...
result = await_result(task)                                   # rows; releases the pooled connection
```

`await_result` is idempotent — a second call returns the cached result without touching the pool.

### Binding values — a manual-params array

The hatch **does** bind parameters: pass a plain values array (or tuple) and write the placeholder your backend uses. PormG performs **no** placeholder translation — you write `$1, $2, …` on PostgreSQL and `?` on SQLite and MySQL — the same low-level convention as Go's `database/sql`, Python's DB-API, and Julia's `DBInterface`:

```julia
# PostgreSQL — numbered placeholders
task = fetch_async(settings, "SELECT count(*) FROM driver WHERE nationality = \$1", ["Brazilian"])
n    = await_result(task)

# SQLite and MySQL — positional placeholders (same values array, backend-native marker)
rows = fetch(settings, "SELECT * FROM driver WHERE nationality = ?", ["Brazilian"])
```

The driver binds each value as **data**, so a user value can never change the statement's structure. Write a NULL as `missing` (a bare `nothing` is normalized to it). The array bypasses the ORM's field formatters (datetime canonicalization, float precision, `bool`→`int`), which is expected for a raw hatch — pre-format any such values yourself.

The one check the hatch does apply: a string containing a NUL character (`'\0'`) — anywhere in the array, nested or not, or in the SQL text itself — raises `InvalidValueError` before the statement is sent, on every backend, exactly as an ORM filter or write does. PostgreSQL text cannot store a NUL, and the drivers would otherwise truncate the value at it or fail with a driver error; binary values (`Vector{UInt8}`) are not affected.

Because the placeholder style is backend-native, a manual-params string is **not portable** across backends. For portable queries — and for row post-processing and connection management — prefer the ORM surface (`list()` / `count()` / `filter(...)` wrapped in a task, as above). Reach for the values-array hatch only for static SQL you own that the ORM can't express.

!!! danger "Never interpolate user input into the SQL string"
    `fetch_async(settings, "... $uservalue ...")` is a SQL-injection hole. Pass user values as the
    `params` **array** instead — `fetch_async(settings, "... = \$1", [uservalue])` on PostgreSQL,
    `"... = ?"` with `[uservalue]` on SQLite and MySQL — so the driver binds them as data. Never build the SQL
    string from user input, even with the values-array path available.

!!! warning "An un-awaited `FetchTask` holds a pool connection"
    `fetch_async` checks its connection out *synchronously*; only `await_result` (or the owning transaction's cleanup) returns it. A connection you passed in as `conn = c` is the exception: it is borrowed, so `await_result` leaves it leased and you release it yourself (see [Who releases a connection](@ref)). Always await every task you start — including fire-and-forget writes. The opt-in [`leak_detection_threshold`](configuration/advanced.md) logs a warning when a connection is held suspiciously long, which almost always means an un-awaited `FetchTask`.

## Cancelling a query with `Ctrl+C`

Interrupting a running query in the REPL is safe: PormG asks the database to abandon the statement, waits for the driver to let go of the connection, and only then decides what to do with the pool slot. A connection that comes back clean is reused; one that does not is renewed or dropped, and a fresh connection takes its place. Either way the *next* query gets a healthy connection — the pool cannot be left in a state where every later query fails.

An interrupt that lands while the query is still **waiting for a connection** (every connection is leased, or the pool is retrying a connect while the server is down) also leaves the pool whole. The waiting caller leaves the queue, and a connection handed to it at that moment goes to the next waiting caller or back to the pool ([#1535](https://github.com/PingoLee/PormG.jl/issues/1535)).

On PostgreSQL under either driver and on SQLite, the interrupt reaches a query while its statement runs, so a statement interrupted outside a transaction block is cancelled rather than left to finish, and an interrupted autocommit write normally does not commit (a cancel that arrives after the server committed is too late). Inside a transaction block, the warning below applies instead. The limits come from how Julia delivers `Ctrl+C`:

- It interrupts only in the REPL, or in a script that calls `Base.exit_on_sigint(false)`. A plain `julia script.jl` exits on `Ctrl+C`, so nothing is sent to the database.
- It goes to Julia's main thread, so it interrupts a query the REPL awaits, not one awaited in a task spawned on `:default`. The main thread is the interactive one (plain `julia`, `-t N`, `-t auto`), and a statement runs in its caller's threadpool, so a query awaited by another `:interactive` task, such as a heartbeat, runs there too and can take the interrupt instead (#1577).
- On Postgres.jl the interrupt usually lands inside the driver's read, which closes the connection. PormG still asks the driver to cancel the statement, and since Postgres.jl 2.6 the driver sends that cancel itself, with the backend's cancel key on a separate connection, so the statement still stops on the server (#1577, [JuliaDatabases/Postgres.jl#45](https://github.com/JuliaDatabases/Postgres.jl/pull/45)).
- On SQLite the statement runs on a worker thread, and the interrupt needs a second thread to arrive while it runs. Plain `julia` (one worker thread plus the REPL's), `-t 2,1` and `-t auto` all have one: the interrupt arrives within about 0.1 s of `Ctrl+C`, the statement is interrupted, and the next query runs at once (measured 5 times per layout, [#1534](https://github.com/PingoLee/PormG.jl/issues/1534)). With one thread (`julia -t 1`) the interrupt arrives only when the statement finishes, and the next query then runs normally.
- `bulk_copy` and `fetch_copy` send the COPY from your own task and are not covered.
- On MySQL (MySQL.jl 2.2.2 or newer), the interrupt reaches the query while its statement runs, and PormG sends `KILL QUERY` for it on a second connection: under `-t 2,1` the query raised about 1.3 s after `Ctrl+C`, the statement left the server at once, and the next query ran (4 of 4 rounds, [#1520](https://github.com/PingoLee/PormG.jl/issues/1520)). It needs an interactive thread, as plain `julia`, `-t N`, `-t N,1` and `-t auto` give. With none (`julia -t 1`, `-t N,0`), one of MySQL.jl's or Julia's own background tasks can take the first `Ctrl+C` instead, and the query runs to its end. On macOS about 1 in 3 interrupts is dropped inside Julia's runtime, with or without MySQL ([MySQL Guide](mysql.md#Production-notes)).
- When the driver reports that a cancel did not reach the server or was refused, on PostgreSQL under either driver or on MySQL, PormG logs a warning (`PostgreSQL refused the cancel request; the statement may still be running on the server, holding its locks`, and the same for MySQL) with the driver's error: the statement you abandoned may run to its end. A MySQL `KILL QUERY` that finds the session already gone is not one of these, since its statement has ended too ([#1719](https://github.com/PingoLee/PormG.jl/issues/1719)).
- All of this needs the driver floors, Postgres.jl 2.6 and MySQL.jl 2.2.2. Julia does not check an extension's `[compat]` when it loads it, so a manifest resolved before PormG raised a floor still loads the older driver. PormG then warns once at `using`, naming the driver, the floor and what goes wrong below it; `Pkg.update()` resolves the newer driver.

!!! note "Recovery runs in the background"
    Control returns to the REPL immediately; the cancel-and-clean happens on its own task, and the pool slot stays checked out while it does — so a query issued in the meantime may be served by a different connection. If the database never releases the connection, the slot is dropped from the pool anyway after a few seconds and the next query opens a fresh one. Under `julia -t 1` the driver's cancel and reconnect calls block the single worker thread while they run, so a heavily-loaded single-threaded session may pause briefly — start Julia with `-t auto` if that matters.

The same recovery covers an interrupt while a transaction is being **opened** (`run_in_transaction` / `atomic`), and an interrupt during a `with_advisory_lock` lock or unlock query, with one difference: those connections are **renewed rather than reused**, even when they come back looking clean. PormG cannot tell from the connection whether the `BEGIN` landed before the interrupt, and an open transaction or a held advisory lock is invisible to the check that a plain query's connection passes. Replacing the connection settles both — a PostgreSQL advisory lock or a MySQL named lock is bound to the session, so reconnecting is what releases it. The cost is one reconnect per interrupted transaction; the alternative is a pooled connection that silently belongs to a transaction nobody will ever finish.

!!! warning "Interrupting a query *inside* an open transaction does not return promptly"
    A `Ctrl+C` while a query is in flight **within** a `run_in_transaction` body behaves differently. Every query inside the block on that database runs on the transaction's single pinned connection, whose lifecycle the transaction owns rather than the query — so the background recovery above deliberately does not run for it. Instead the cleanup `ROLLBACK` is issued on that same connection and waits behind the very query you interrupted: on PostgreSQL it blocks on the driver's per-connection lock, on SQLite it queues on the single worker. **Control comes back only once the interrupted query finishes on its own** — measured on PostgreSQL as almost exactly the query's remaining runtime.

    The wait is the whole cost. The `ROLLBACK` does run once it gets the connection, the transaction is undone, and the slot goes back to the pool clean on both backends — and pressing `Ctrl+C` again while you wait is safe: the connection leaves the pool at once so nothing else can pick it up, but its handle is not closed until the driver has let go of it. It will not make the wait any shorter, though.

    One exception: on Postgres.jl, an interrupt that lands inside the driver's read returns at once. That is the usual case for a transaction run by the main task or the REPL under plain `julia`, `-t N` and `-t auto` (#1577). The driver has then closed the connection, so the `ROLLBACK` fails immediately. Before renewing the slot, PormG asks the driver to cancel the interrupted statement, which it does with the backend's cancel key on a separate connection, as outside a transaction (#1588). The statement stops on the server, which rolls the transaction back and releases its locks once it sees the client gone, instead of after the statement's remaining runtime. The cancel adds one short connection to the return, beside the one the renewal opens. The same holds for the transactions PormG opens for you: a `delete()` outside a transaction, `migrate()`'s apply and its lossy pre-check (#1638).

    If the pause matters, avoid the situation rather than the keystroke: keep transactions short, and run a slow query before the block rather than inside it.

!!! warning "An interrupt currently arrives as a `StatementError`"
    Today the `InterruptException` reaches you wrapped in a `StatementError`, carried on its `cause` — so a `catch DatabaseError` around a query swallows your `Ctrl+C`. That wrapping is a known wart rather than a designed contract, and it is expected to change: a cancellation will propagate past `catch DatabaseError` altogether, which is what you want from `Ctrl+C`. So write the `catch` you would want *after* that change — let the interrupt escape — rather than reaching for `e.cause isa InterruptException` today, because that test will stop matching silently once the interrupt no longer arrives as a `DatabaseError` at all.

## Transactions and concurrency

The transaction context is a `ScopedValue`, so tasks spawned **inside** `run_in_transaction` inherit it — every query they run on that database targets the transaction's **single pinned connection** (see [Async Context Propagation](write/transaction.md#Async-Context-Propagation)). That is exactly what you want for *correctness*: child tasks participate in the same transaction.

It is **not** a way to speed anything up:

- All statements on one connection execute one at a time — fan-out inside a transaction **serializes** and buys zero concurrency.
- The serialization currently relies on driver-internal locking (LibPQ's per-connection lock, MySQL.jl's per-connection lock, SQLite's global worker). It is safe today on every backend, but it is a property of the drivers, not a PormG contract — concurrent statements on one connection are a driver error class (e.g. PostgreSQL's *"another command is already in progress"*) that PormG does not promise to absorb.

!!! warning "Fan out transactions, not queries inside one"
    For concurrent transactional work, spawn the *whole transaction* — each task pins its own pooled connection:

    ```julia
    # Recompute each season's driver standings in its own transaction. The seasons
    # are independent, so the transactions run concurrently — each on its own pooled
    # connection with its own BEGIN/COMMIT.
    @sync for year in 2010:2019
        Threads.@spawn PormG.run_in_transaction(settings) do
            new_standings = compute_driver_standings(year)   # your domain logic → DataFrame
            M.Driver_standings.objects.filter("raceid__year" => year).delete()
            bulk_insert(M.Driver_standings.objects, new_standings)
        end
    end
    ```

Also remember the retry rule from [Transactions](write/transaction.md): a connection error inside a transaction propagates — retry the whole transaction, never a single statement.
