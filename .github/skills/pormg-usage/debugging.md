# PormG Usage — Inspecting Queries & Diagnosing Problems

Supporting file for [`SKILL.md`](SKILL.md). Read it when a query returns the wrong thing, you need
the generated SQL, or the connection pool misbehaves. Full detail:
[API reference](https://pingolee.github.io/PormG.jl/stable/api/),
[Advanced Configuration](https://pingolee.github.io/PormG.jl/stable/configuration/advanced/).

## See the SQL without running it

Every terminal accepts `show_query`:

| `show_query =` | Returns |
| :--- | :--- |
| `:execute` | the result (default) |
| `:sql` | the SQL `String` |
| `:dict` | a `Dict` with `:sql_text`, `:parameters`, `:dialect`, `:operation` |
| `:params` | the bound parameters only |
| `:none` | `nothing` — builds the query and skips the round-trip, for benchmarking |

```julia
q = M.Result.objects.filter("driverid__surname" => "Senna").values("raceid__year", "points")

q.list(show_query = :sql)                                  # the SELECT
q.update("points" => 0, show_query = :dict)[:parameters]   # a mutation, inspected — never runs
q.delete(show_query = :sql)

info = inspect_query(q)            # or q.inspect(), or q |> inspect_query()
info[:sql_text]; info[:parameters]; info[:dialect]
```

Placeholders differ by backend: `$1, $2, …` on PostgreSQL, `?` on SQLite. Values are always
parameters. If a value appears inline in the SQL text, that is a bug worth reporting.

## When a query returns the wrong thing

- **No rows where you expected some:** check the case of every field path — lookups are
  case-sensitive, and a mistyped path raises `UnknownFieldError`, but a wrong *value* case simply
  matches nothing. Use `__@icontains`/`__@istartswith` when case should not matter. There is no
  `__@iexact`; asking for it raises an error naming the nearest lookups.
- **`QueryBuildError` naming the fan-out guard (PingoLee/PormG.jl#74):** an aggregate over a to-many join would be
  silently inflated, so PormG refuses it. Aggregate the related table's own column, pass
  `distinct = true`, or use one correlated `Subquery` per relation ([`advanced.md`](advanced.md)).
- **A `GROUP BY` you did not expect:** every non-aggregate column in `values()` is a grouping key.
  Remove a column, or move it into an aggregate.
- **`row.driverid` is an `Int`, or reading it raises `LazyTraversalError`:** a `ForeignKey` on a
  row is only the key, and only when projected. PormG never lazy-loads. Project the related columns
  — `values("driverid__surname")` — then read `row.driverid__surname`.
- **Results differ between PostgreSQL and SQLite:** check the
  [PostgreSQL guide](https://pingolee.github.io/PormG.jl/stable/postgres/) divergence list.

## Connection pool health

```julia
pool_stats("db")
# (pool_size = 5, size = 7, in_use = 7, available = 0, ceiling = 50, waiting = 3)
```

- `in_use` near `ceiling` with `waiting > 0` → the app is saturating the pool. The next symptom is
  a `PoolTimeoutError`. Raise `pool_size`/`pool_timeout` in `connection.yml`, or find the leak.
- `in_use` that never comes down → an un-awaited `FetchTask` ([`async.md`](async.md)), or a manual
  `acquire_connection` with no `release_connection` in a `finally`.
- `pool_stats` of a key whose pool was never built raises (a zeroed snapshot would look healthy).

## `@pormg_debug`

`@pormg_debug` is a **contributor** breakpoint hook scattered through PormG's own source. It
expands to `nothing` and costs an application nothing. Ignore it in app code. Wiring it up is for
debugging PormG itself (see the Contributing page of the PormG docs).
