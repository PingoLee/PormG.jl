## `count()`, `exists()` and `Exists(...)` answer for the rows a `values()` projection returns (#1066, #1074, #1082)

- **Version**: Unreleased
- **PormG ref**: #1066, #1074, #1082 ; `src/querybuilder/execution_read.jl` (`_projection_shapes_rows`, `_filters_name_alias`, `_degenerate_aggregate`, `_refuse_degenerate_probe`, `_count`, `_exists`), `src/querybuilder/filter_nodes.jl` (`_build_exists_query`)
- **Recorded**: 2026-10-09
- **Severity**: behavior change. Two counts return a different number, alias filters that used to raise now run, and two shapes raise a different error.

### What changed

`count()`, `exists()` and `Exists(...)` used to clear a `values()` projection before they built, so
they always asked about the matching model rows, whatever `list()` returned. That is still right for a
plain column list, which returns one row per matching row either way. It was wrong for a projection
that changes the row set, and it made every filter on a projection alias fail. The three terminals
now keep such a projection and agree with `list()`:

- a **grouped** projection (a column beside an aggregate) is counted per group, the way
  `length(list())` counts it;
- a **distinct** projection is counted per distinct projected row, not per model row;
- a **filter on an alias** resolves as it does in `list()`: a row alias in `WHERE`, an aggregate alias
  in `HAVING`, and a window alias reaches the same `QueryBuildError` (#685) `list()` raises.

One shape is deliberately left as it was: an aggregate with no grouping and no `HAVING`
(`values("n" => Count("resultid"))`) is one row whatever matched, so its literal answer would be a
constant. The three terminals still ask about the matched rows there, as Django's `Exists` does, so
`exists() == (count() > 0)` holds.

| call | before | after |
|---|---|---|
| `M.Result.objects.values("driverid", "wins" => Count("resultid")).count()` | every matching result | the number of drivers (groups), `== length(list())` |
| `M.Driver.objects.values("nationality").distinct().count()` (or `count(distinct = true)`) | every matching driver (`SELECT DISTINCT *` over whole rows) | the number of distinct nationalities, `== length(list())` |
| `M.Result.objects.values("next_grid" => F("grid") + 1).filter("next_grid__@gt" => 20).count()`, `.exists()`, `Exists(...)` | `UnknownFieldError` | runs, `== length(list())` |
| `M.Result.objects.values("driverid", "wins" => Count("resultid")).filter("wins__@gte" => 10).count()` | `UnknownFieldError` | the drivers with at least 10 results (`HAVING`) |
| a filter on a window alias, `values("r" => Rank(…)).filter("r" => 1).count()` | `UnknownFieldError` | `QueryBuildError` (#685), as `list()` raises |
| `M.Result.objects.values("points" => Sum("points")).filter("points__@gt" => 5).count()` | the results whose `points` **column** is above 5 | `AmbiguousFieldError` (#703), as `list()` raises |
| an aggregate beside a filtered literal, `values("n" => Count("resultid"), "k" => Value(1)).filter("k" => 1).count()` | `UnknownFieldError` | `QueryBuildError` (#1082) |
| `M.Result.objects.values("n" => Count("resultid")).count()`, `.exists()`, `Exists(...)` | the matched rows | unchanged: the matched rows |

The last row but one is the fail-closed check: a kept aggregate projection that builds with no
`GROUP BY` and no `HAVING` would answer a constant, so it is refused rather than answered. The
`AmbiguousFieldError` row was silent before: the filter quietly meant the column, not the alias.

### Who this affects

Code that calls `count()` or `exists()` on a handler that already has `values(...)` set with an
aggregate or with `distinct()`, or passes such a handler to `Exists(...)`. The usual case is a
grouped or distinct report query whose total is taken with `count()` on the same handler: that total
is now the number of groups or distinct rows, which is what `list()` returns. A filter on a
`values()` alias that used to raise from these terminals is not a migration — it now runs.

### How to find the calls to migrate

```bash
grep -rnE '\.(count|exists)\(|Exists\(' --include=*.jl src/ test/
```

For each hit, check whether the same handler has `values(...)` with an aggregate (`Count`, `Sum`,
`Avg`, `Max`, `Min`) or `distinct()`. The two errors are loud: run the app's tests and look for
`AmbiguousFieldError` or a `QueryBuildError` ending in `(#1082)`.

### Migrate your app

```julia
# ✗ before: count() ignored the grouping and returned the number of results
n = M.Result.objects.values("driverid", "wins" => Count("resultid")).count()

# ✓ after: that now counts drivers. To count the results, count without the projection
n = M.Result.objects.count()
```

```julia
# ✗ before: count() ignored values("nationality") and counted every driver
n = M.Driver.objects.values("nationality").distinct().count()

# ✓ after: that now counts nationalities. To count the drivers, drop the projection
n = M.Driver.objects.count()
```

```julia
# ✗ before: "points" silently meant the column, so this counted results above 5 points
n = M.Result.objects.values("points" => Sum("points")).filter("points__@gt" => 5).count()

# ✓ after: name the alias apart from the column, and say which one the filter means
n = M.Result.objects.filter("points__@gt" => 5).count()                                    # the column
n = M.Result.objects.values("total" => Sum("points")).filter("total__@gt" => 5).count()    # the sum: 0 or 1
```
