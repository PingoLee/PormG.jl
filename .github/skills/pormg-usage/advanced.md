# PormG Usage — Subqueries, CTEs, Custom Joins, Window Functions, Multiple Databases

Supporting file for [`SKILL.md`](SKILL.md). Read it for anything beyond a filter-and-aggregate
query. Full detail:
[Subqueries and CTEs](https://pingolee.github.io/PormG.jl/stable/read/subqueries_and_ctes/),
[Custom Joins](https://pingolee.github.io/PormG.jl/stable/read/custom_joins/),
[Window Functions](https://pingolee.github.io/PormG.jl/stable/read/window_functions/).

PormG is **explicit where Django is implicit**. There is no `annotate()` that guesses a join, and no
correlation is ever inferred. You build the inner query as an ordinary handler and say how it
connects.

## Subqueries in a filter: `__@in`

Any handler that projects **exactly one column** can be the right side of `__@in` / `__@nin`:

```julia
engine = M.Status.objects.filter("status" => "Engine").values("statusid")

M.Result.objects.
    filter("statusid__@in" => engine, "raceid__year" => 1991).
    values("resultid", "driverid__surname", "statusid__status")
```

A two-column subquery raises `FilterError`. Narrow it with `values("one_field")`. A subquery may not
declare its own CTE (`QueryBuildError`).

## Correlated subqueries: `Subquery`, `OuterRef`, `Exists`

`OuterRef("field")` refers to a column of the **outer** row. `Subquery(q)` projects the inner
query's single value as a column, and `Exists(q)` projects a boolean:

```julia
using PormG.Functions: Count

wins = M.Result.objects.
    filter("driverid" => OuterRef("driverid"), "positionorder" => 1).
    values("n" => Count("resultid"))

M.Driver.objects.
    filter("nationality" => "Brazilian").
    values("surname",
           "wins"     => Subquery(wins),
           "has_wins" => Exists(wins))
```

**This is the fan-out-safe way to aggregate over two relations.** Two `Count`s over two different
reverse relations in one `values()` would multiply each other's rows, so PormG raises
`QueryBuildError` for that shape. Give each relation its own `Subquery` and every count stays exact.
For a latest value, order and limit the inner query:
`q.order_by("-driverstandingsid"); q.limit(1)`.

## CTEs: `.with(...)`

A CTE is a named sub-query joined into the main query. Its columns are reached as
`"<cte>__<column>"`:

```julia
using PormG.Functions: Count

per_driver = M.Result.objects.
    filter("statusid" => 1).
    values("driverid", "finishes" => Count("resultid"))

q = M.Result.objects
q.with("stats" => per_driver, join_field = "driverid" => "driverid")
q.filter("raceid__year" => 1991)
q.values("resultid", "driverid__surname", "stats__finishes")
```

- `join_field = "main_field" => "cte_field"` joins it. Leave `join_field` out and correlate it in a
  filter instead: `filter("raceid" => CTE("r91", "raceid"))`.
- **`CTE(name, path)` is the explicit form.** Use it when the CTE's name also names something on the
  model: then `"<name>__…"` is ambiguous and raises `AmbiguousFieldError`. It is also required on
  the **right** of a filter pair, where a plain string would be compared as a literal.
- Call `.with(...)` again to add a second CTE. `join_type = "LEFT"` keeps rows with no match.
- Aggregate first in a CTE, then window over it in the outer query — PormG has no
  `SUM(...) OVER (...)`.

## Custom joins: `.cjoin`, `.on`, `.cjoin_on` + `Joined`

For a relation the model does not declare, or an `ON` clause you need to shape yourself:

```julia
# Extra predicates on an existing FK join's ON clause
q = M.Result.objects
q.on("driverid", "nationality" => "Brazilian")
q.values("resultid", "driverid__surname", "points")

# The whole ON clause is yours: Joined(alias, col) = the joined copy, F(col) = the base table
q = M.Result.objects
q.cjoin_on(M.Driver; alias = "d", join_type = "INNER",
           on = [Joined("d", "driverid") == F("driverid")])
q.filter(Joined("d", "nationality") => "Brazilian")
q.values("points", "who" => Joined("d", "surname"))
```

- A query with a custom join **must** call `values(...)` before it runs. A bare `SELECT *` across
  joins is refused.
- `Joined` works in `values`, `filter`, `order_by` and window specs. The old dotted string
  `F("d.surname")` was removed.
- `cjoin_on` of a model bound to another connection raises `QueryBuildError`.

## Window functions

A window function takes an `over = WindowOver(partition_by = …, order_by = …)`:

```julia
using PormG.Functions: WindowOver, Rank, RowNumber, Lag, FirstValue

M.Result.objects.
    filter("raceid" => 306).
    values("driverid__surname", "constructorid", "points",
           "team_rank" => Rank(over = WindowOver(partition_by = ["constructorid"],
                                                 order_by     = ["-points"])),
           "row_no"    => RowNumber(over = WindowOver(order_by = ["positionorder"])),
           "win_pts"   => FirstValue("points", over = WindowOver(order_by = ["positionorder"]))).
    order_by("positionorder")

# Lap-to-lap delta
M.Lap_times.objects.
    filter("raceid" => 841, "driverid" => 1).
    values("lap", "milliseconds",
           "prev_ms" => Lag("milliseconds", over = WindowOver(order_by = ["lap"]))).
    order_by("lap")
```

| Function | Signature |
| :--- | :--- |
| `Rank`, `DenseRank`, `RowNumber` | `(; over)` |
| `Lag`, `Lead` | `(col; offset = 1, default = nothing, over)` |
| `FirstValue`, `LastValue` | `(col; over)` |
| `NthValue` | `(col, n; over)` — `n` positional, rendered as a literal |

- `WindowOver(...)` returns a `WindowSpec`, which you can build once and reuse across columns.
- `order_by` uses the `"-field"` convention.
- `LastValue`/`NthValue` under the default frame only see rows up to the current one. An explicit
  `frame = "ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING"` fixes that, but
  **`frame=` is PostgreSQL-only** and raises `BackendCapabilityError` on SQLite.
- `order_by` on a window alias works. **Do not `filter` on one**: PormG currently renders it as
  `HAVING`, which both engines reject at execution with a `StatementError` (PingoLee/PormG.jl#685). To keep, say,
  only the top-ranked row, compute the window and filter the rows in Julia.
- SQLite needs library ≥ 3.25 for any window function.

## Multiple databases and tenants

```julia
PormG.Configuration.load_many(["db", "db_reporting"])        # several static configs
M.Driver.objects.filter("nationality" => "British").db("db_reporting").list()

PormG.register_connection("tenant_42", "postgres://user:pass@host/tenant_42")  # at runtime
PormG.config["tenant_42"].change_data = true    # runtime connections start read-only
M.Driver.objects.db("tenant_42").list()
```

`PormG.Configuration.set_connection_resolver(key -> …)` registers a resolver that PormG calls for an
unknown key. That is the usual way to do per-tenant databases. See
[Dynamic & Multi-Tenancy](https://pingolee.github.io/PormG.jl/stable/configuration/dynamic/).

## Advisory locks (application-level mutual exclusion)

```julia
with_advisory_lock("db", "rebuild_standings_2024"; wait = true, timeout_ms = 10_000) do
    # only one process at a time runs this block
end
```

- `wait = false` raises `OperationalError` immediately when another session holds the lock. A
  timeout raises the same error.
- **On SQLite it is a no-op.** The block runs without any locking, and PormG warns once per key. Pass
  `on_missing_lock = :error` to raise `BackendCapabilityError` instead, or `:ignore` to accept the
  no-op silently.

## PostgreSQL-only features

`bulk_copy`, advisory locks, JSONB lookups, `unaccent` lookups, window `frame=`, `select_for_update`
and the full `ToChar` format set are PostgreSQL-only. Each has a defined SQLite behavior — an error,
a no-op, or a narrower subset. The
[PostgreSQL guide](https://pingolee.github.io/PormG.jl/stable/postgres/) lists every one with its
SQLite fallback. Read it before writing code that must run on both backends.
