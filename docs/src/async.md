# Async & Concurrency

PormG is **async-first internally**: every terminal — `list()`, `count()`, `create()`, a `DataFrame` pipe — runs through the asynchronous core (`fetch_async` → `await_result`) and **yields to the Julia scheduler** while the database round-trip is in flight. The "synchronous" API parks the *task*, never the thread.

That has a powerful consequence: **there is no separate async query API to learn.** Julia functions are not colored — any query can be made concurrent by wrapping the ordinary call in a task:

```julia
t = Threads.@spawn M.Driver.objects.filter("nationality" => "Brazilian").list()
# ... other work overlaps the database round-trip ...
rows = fetch(t)          # Base.fetch on a Task — same Vector{PormGRow} as calling list() directly
```

This is the same contract Elixir's Ecto (`Task.async`) and Go's `database/sql` (goroutines) chose, and it is guaranteed by regression tests on both PostgreSQL and SQLite: a task-wrapped query returns exactly what the sync call returns.

!!! note "Two `fetch`es"
    `fetch(t)` above is `Base.fetch` on a `Task`. PormG's low-level `fetch(settings, sql)` escape hatch is *also* a method of `Base.fetch` — same name, different arguments. Application code rarely needs the latter; prefer the fluent terminals.

## How it works

`list()` → `fetch()` → `fetch_async()` → `await_result()`. On PostgreSQL the round-trip is real non-blocking I/O (`LibPQ.async_execute`); on SQLite every statement is funnelled through one serialized worker task. Both paths *yield* while waiting, so concurrency is always safe — but only PostgreSQL executes queries in parallel across connections. See the [Architecture](architecture.md) guide's *"Async-first" is backend-specific* note for the full picture.

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

## Raw SQL: `fetch_async`, `await_result`, `FetchTask`

The only PormG-specific async API is the low-level escape hatch, and it takes **raw SQL only** — not query-builder objects:

```julia
settings = PormG.Configuration.get_settings("db")

task = fetch_async(settings, "SELECT count(*) FROM driver")   # returns a FetchTask
# ... do other work ...
result = await_result(task)                                   # rows; releases the pooled connection
```

`await_result` is idempotent — a second call returns the cached result without touching the pool.

This hatch runs the SQL string **as you supply it**, so reserve it for static, trusted statements — schema introspection, a fixed `COUNT(*)`, a maintenance command. It is not a parameterized-query path: the `params` keyword takes a parameter collector the ORM builds internally, not a plain vector of values you pass in. Any query that carries user-supplied values belongs on the ORM surface — wrap `list()` / `count()` / `filter(...)` in a task as shown above — which binds parameters, post-processes rows, and manages the connection for you.

!!! danger "Never interpolate user input into the SQL string"
    `fetch_async(settings, "... $uservalue ...")` is a SQL-injection hole. The raw-SQL hatch has no value-binding on the public surface by design; if you need user values, use the ORM query surface, which parameterizes every value.

!!! warning "An un-awaited `FetchTask` holds a pool connection"
    `fetch_async` checks its connection out *synchronously*; only `await_result` (or the owning transaction's cleanup) returns it. Always await every task you start — including fire-and-forget writes. The opt-in [`leak_detection_threshold`](configuration/advanced.md) logs a warning when a connection is held suspiciously long, which almost always means an un-awaited `FetchTask`.

## Transactions and concurrency

The transaction context is a `ScopedValue`, so tasks spawned **inside** `run_in_transaction` inherit it — every query they run targets the transaction's **single pinned connection** (see [Async Context Propagation](write/transaction.md#Async-Context-Propagation)). That is exactly what you want for *correctness*: child tasks participate in the same transaction.

It is **not** a way to speed anything up:

- All statements on one connection execute one at a time — fan-out inside a transaction **serializes** and buys zero concurrency.
- The serialization currently relies on driver-internal locking (LibPQ's per-connection lock, SQLite's global worker). It is safe today on both backends, but it is a property of the drivers, not a PormG contract — concurrent statements on one connection are a driver error class (e.g. PostgreSQL's *"another command is already in progress"*) that PormG does not promise to absorb.

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
