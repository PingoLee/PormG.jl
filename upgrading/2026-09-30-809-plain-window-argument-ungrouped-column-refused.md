## A window function's plain argument beside an aggregate now raises unless that column is grouped (#809)

- **Version**: Unreleased
- **PormG ref**: #809 ; `src/querybuilder/build_query.jl`
- **Recorded**: 2026-09-30
- **Severity**: behavior change (narrow). The shape was wrong on SQLite and refused by PostgreSQL; it now raises at build time on both.

### What changed

A window function whose argument reads a plain column, in a query that aggregates, now raises
`QueryBuildError` unless the query already groups that column:
`values("constructorid", "t" => Sum("points"), "prev" => Lag("raceid", over = …))`. The same holds
for `Lead`, `FirstValue`, `LastValue` and `NthValue`, for an expression argument such as
`FirstValue(F("raceid") * 2)`, and for a `Lag`/`Lead` `default` that reads a column, such as
`default = F("grid")` or `default = Coalesce("grid", 0)`. (A `String` default is bound as a value
and reads no column.) The error names the projection, the column, and whether it sits in the
argument or the default.

The window is computed once per group, and nothing grouped its argument: #789 groups a window's
`partition_by` / `order_by` columns, never the argument, which matches Django's
`Window.get_group_by_cols`. #798 refused an argument that *mixes* a column with an aggregate; this
is the plain case beside it.

| before | after |
|---|---|
| PostgreSQL raised the driver's `GroupingError: column "Tb.raceid" must appear in the GROUP BY clause or be used in an aggregate function`, at execution | PormG raises `QueryBuildError` naming the column, before any SQL is sent |
| SQLite **ran it**, reading the argument from an arbitrary row of each group | the same `QueryBuildError`: the engines now agree |

A column grouped by any route satisfies the check: projected in `values(...)`, named in `order_by`,
or read by the window's own `partition_by` / `order_by`. An aggregated argument (`Lag(Sum(…))`,
`Lag(Max("raceid"))`) is unaffected, and so is a query that does not aggregate.

### Who this affects

- Apps on **SQLite** that project a window with a column argument beside an aggregate, without
  grouping that column. They were reading an arbitrary row's value per group.
- Apps on **PostgreSQL**: only the error type and its timing change, because the query already
  failed there.

Measured before the change: the consuming apps have **0** window-function call sites, so none
needs an edit.

### How to find the calls to migrate

```bash
grep -rnE '(Lag|Lead|FirstValue|LastValue|NthValue)\(' --include='*.jl' <your-app>/src
```

For each hit, check whether the same `values(...)` also holds `Sum`, `Count`, `Avg`, `Max` or
`Min`, and whether the window's argument column is projected there. The error message names each
refused projection at build time, so a test run surfaces the rest.

### Migrate your app

Either aggregate the argument, or project it so the query groups by it. The two answer different
questions: the second changes the grouping granularity.

```julia
# ✗ before — `raceid__round` is one race's round, but the query groups by season
M.Result.objects.values("raceid__year", "season_pts" => Sum("points"),
    "prev_round" => Lag("raceid__round", over = WindowOver(order_by = ["raceid__year"])))

# ✓ after — aggregate it: the last round of the season before
M.Result.objects.values("raceid__year", "season_pts" => Sum("points"),
    "prev_last_round" => Lag(Max("raceid__round"), over = WindowOver(order_by = ["raceid__year"])))

# ✓ or project it: one row per season and round, so order the window by both — ordered by season
#   alone, every round of a season ties and LAG would read an arbitrary one of them
M.Result.objects.values("raceid__year", "raceid__round", "season_pts" => Sum("points"),
    "prev_round" => Lag("raceid__round", over = WindowOver(order_by = ["raceid__year", "raceid__round"])))
```
