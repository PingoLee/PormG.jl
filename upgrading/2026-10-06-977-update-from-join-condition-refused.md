## `update()` setting a column from a join — an `on()` / `cjoin(filters = …)` condition raises (#977)

- **Version**: Unreleased
- **PormG ref**: #977 ; `src/querybuilder/execution.jl` (`_get_join_condition_list`)
- **Recorded**: 2026-10-06
- **Severity**: breaking (narrow). An `update()` that sets a column from a joined table renders a correlated `UPDATE … FROM`, which joins on the key columns only. A join condition on such a query was dropped from the statement, so the UPDATE was wider than the query described. It now raises `QueryBuildError` when the statement is built, on both engines — as `cjoin_on` (#45) and a CTE (#394) already did there.

### What changed

| query | before | after |
|---|---|---|
| `on("driverid", "code" => "HAM").filter("grid" => 3).update("number" => F("driverid__number"))` | the `code` predicate is not in the statement: every row with `grid = 3` is updated | raises `QueryBuildError` |

An `update()` whose SET values are literals or base-row columns is unaffected: its rows are scoped
through a subquery that renders join conditions correctly. So is a `cjoin(...)` with no `filters`.

### Who this affects

Apps that combine `on()` or `cjoin(filters = …)` with an `update()` reading a joined column.

### How to find the calls to migrate

Run the app's tests. Every remaining call raises with this message:

```
cannot be carried into a correlated UPDATE ... FROM
```

### Migrate your app

Move the condition into `.filter(...)`. That is what scopes the rows an UPDATE writes, and it is
what the old statement should have done.

```julia
# ✗ before: the code predicate was dropped, so every grid-3 result was updated
M.Result.objects.
    on("driverid", "code" => "HAM").
    filter("grid" => 3).
    update("number" => F("driverid__number"))

# ✓ after
M.Result.objects.
    filter("grid" => 3, "driverid__code" => "HAM").
    update("number" => F("driverid__number"))
```
