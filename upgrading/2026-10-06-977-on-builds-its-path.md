## `on(path, …)` builds its join when nothing else in the query reaches the path (#977)

- **Version**: Unreleased
- **PormG ref**: #977 ; `src/querybuilder/build_query.jl` (the PATH loop in `build`), `src/querybuilder/join_conditions.jl` (`_join_path_columns`)
- **Recorded**: 2026-10-06
- **Severity**: behavior change. An `on()` whose path no `values()`, `filter()` or `order_by()` reached was dropped from the statement with no error, `join_type = "INNER"` included. It now joins that path, so the query returns different rows.

### What changed

`on(path, …)` used to only decorate a join that something else in the query had built. With nothing
else reaching the path, the predicate and any `join_type` were silently left out of the SQL:

| query | before | after |
|---|---|---|
| `on("constructorid", "name" => "Ferrari", join_type = "INNER").values("resultid")` | `SELECT … FROM "result"`: every result | `INNER JOIN "constructor" … AND "name" = $1`: only Ferrari's results |
| `on("constructorid", "name" => "Ferrari").values("resultid")` (no `join_type`) | no join | the join PormG derives for the relation, with the predicate: `INNER` for a `NOT NULL` ForeignKey (only Ferrari's results), `LEFT` for a nullable one (every result, once) |
| `on("test_deletion", "name" => "x").values("resultid")` (a reverse relation, nullable FK) | no join | `LEFT JOIN` the reverse table: a result repeats once per matching child, as `values("test_deletion__name")` would make it |
| `M.Driver.objects.on("result", "grid" => 1).values("driverid")` (a reverse relation, `NOT NULL` FK) | no join | `INNER JOIN` the results: a driver with no matching result is dropped, the rest repeat |

The join is the one traversal would build, with the type PormG derives — what `values()` through
the same path would produce. A query that also aggregates over a to-many path built this way now
meets the [#74](https://github.com/PingoLee/PormG.jl/issues/74) fan-out guard, as it would had
`values()` reached the path. An `on()` whose path the query already reaches renders exactly as before.

### Who this affects

Apps that call `on()` on a path the same query does not otherwise project, filter or order by.

### How to find the calls to migrate

List the `on()` calls, and check each one's path against the query's own `values()`, `filter()` and
`order_by()`. The pattern matches `q.on(` as well as an `on(` that a trailing-dot chain starts on its
own line:

```bash
grep -rnE '(^|[.[:space:]])on\("' --include='*.jl' <your-app>/src
```

### Migrate your app

Usually nothing: the query now does what the `on()` call says. Where the old, unjoined result was the
one you relied on, delete the `on()` call — it never contributed to the statement.

```julia
# before: the INNER on() was silently ignored, so this returned every result
M.Result.objects.
    on("constructorid", "name" => "Ferrari", join_type = "INNER").
    values("resultid")

# after: the same call returns only Ferrari's results; drop the on() to keep the old answer
M.Result.objects.
    values("resultid")
```
