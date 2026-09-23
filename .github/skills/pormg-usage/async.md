# PormG Usage — Async & Concurrency

Supporting file for [`SKILL.md`](SKILL.md). Read it when **running queries concurrently**, reaching
for `fetch_async`, or spawning tasks inside a transaction. Full detail:
[Async & Concurrency](https://pingolee.github.io/PormG.jl/stable/async/).

## There is no separate async query API

Every terminal (`list()`, `count()`, `create()`, `|> DataFrame`) already runs through PormG's async
core and **yields to the scheduler** while the database round-trip is in flight. To make a query
concurrent, wrap the ordinary call in a task:

```julia
t = Threads.@spawn M.Driver.objects.filter("nationality" => "Brazilian").list()
# … other work overlaps the round-trip …
rows = fetch(t)                   # Base.fetch on a Task — the same Vector{PormGRow}
```

Fan out independent queries and collect the results in input order:

```julia
tasks  = [Threads.@spawn M.Race.objects.filter("year" => y).count() for y in 2010:2019]
counts = fetch.(tasks)

counts = asyncmap(y -> M.Race.objects.filter("year" => y).count(), 2010:2019)   # same thing
```

- **Return values from tasks; do not mutate shared state.** `hits[] += 1` from parallel tasks is a
  data race that loses updates.
- Each in-flight query leases one pooled connection. The pool grows lazily to `pool_size × 10`.
  Past that, callers wait, and a real saturation raises `PoolTimeoutError`. Watch it with
  `pool_stats("db")` (see [`debugging.md`](debugging.md)).
- PostgreSQL runs concurrent queries in parallel across connections. SQLite funnels every
  statement through one worker, so concurrency is safe there but not faster.

## Inside a transaction: correctness, not speed

The transaction context is a `ScopedValue`, so **tasks spawned inside `atomic`/`run_in_transaction`
join the transaction** and run on its one pinned connection:

```julia
atomic("db") do
    t = Threads.@spawn begin
        in_transaction_context()                  # true — the task inherited the transaction
        M.Driver.objects.filter("driverid" => 1).update("code" => "HAM")
    end
    fetch(t)                                       # rolled back with the transaction on error
end
```

Their statements serialize on that connection, so fanning out *inside* a transaction buys no speed.
For concurrent transactional work, **fan out whole transactions**. Each task then pins its own
connection:

```julia
@sync for year in 2010:2019
    Threads.@spawn atomic("db") do
        M.Driver_standings.objects.filter("raceid__year" => year).delete()
        bulk_insert(M.Driver_standings.objects, standings_for(year))   # your own DataFrame
    end
end
```

A task created *outside* a transaction and merely awaited inside it does **not** join it.

`with_tx_context(f, pool, conn)` binds an already-open connection as the ambient transaction
connection. It does **not** issue `BEGIN`, so it is only for hand-rolled lifecycles. Use `atomic`
for ordinary work.

## Raw SQL: `fetch_async` / `await_result` / `FetchTask`

The one PormG-specific async API is the raw-SQL escape hatch. Use it only for static SQL the ORM
cannot express:

```julia
settings = PormG.Configuration.get_settings("db")

task = fetch_async(settings, "SELECT count(*) FROM driver WHERE nationality = \$1", ["Brazilian"])
# … other work …
result = await_result(task)          # a FetchTask; releases its pooled connection when awaited
```

- **Always await every `FetchTask`.** `fetch_async` checks a connection out immediately, and only
  `await_result` returns it. `await_result` is idempotent.
- **Bind values through the params array, never string interpolation.** Placeholders are
  backend-native and not translated: `$1, $2` on PostgreSQL, `?` on SQLite. The same string is
  therefore not portable across backends.
- The array bypasses the ORM's field formatting (datetime canonicalization and the like), so
  pre-format such values yourself.
- `fetch(settings, sql, params)` is the synchronous twin — a method of `Base.fetch`.

## Ctrl+C

Interrupting a query is safe: PormG cancels it and recovers the connection in the background. An
interrupt currently reaches you wrapped in a `StatementError` (a `DatabaseError`). Do not build
logic on `e.cause isa InterruptException`, because that wrapping is expected to change.
