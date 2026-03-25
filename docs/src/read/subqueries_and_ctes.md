# Subqueries and CTEs

This page covers nested queries with `IN` and `WITH`-style common table expressions.

## Subqueries in Filters

```julia
subquery = M.Status.objects
subquery.filter("status" => "Engine")
subquery.values("statusid")

query = M.Result.objects
query.filter("statusid__@in" => subquery)
query.values("resultid", "statusid", "statusid__status", "grid", "driverid")
df = query |> DataFrame
```

This produces an `IN (SELECT ...)` predicate rather than materializing the subquery in Julia.

## Subqueries with Additional Main-Query Filters

```julia
subquery = M.Status.objects
subquery.filter("status" => "Engine")
subquery.values("statusid")

query = M.Result.objects
query.filter("statusid__@in" => subquery, "driverid__@lte" => 7)
query.values(
    "resultid",
    "statusid",
    "statusid__status",
    "grid",
    "driverid",
    "raceid__date__@quarter"
)
query.order_by("raceid__date__quarter")
df = query |> DataFrame
```

## Common Table Expressions

CTEs are useful when the query becomes easier to reason about in stages.

## Basic CTE with JOIN

```julia
using PormG.QueryBuilder: Count

duplicates = M.Result.objects
duplicates.filter("statusid" => 1)
duplicates.values("driverid", "dias" => Count("resultid"))

main_query = M.Result.objects
main_query.with("tb_dup" => duplicates, join_field="driverid" => "driverid")

main_query.filter("resultid__@lte" => 100)
main_query.values("resultid", "driverid", "tb_dup__dias")
df = main_query |> DataFrame
```

## CTE with Multiple Aggregated Fields

```julia
using PormG.QueryBuilder: Count, Sum

stats = M.Result.objects
stats.filter("raceid__@lte" => 100)
stats.values(
    "driverid",
    "total_results" => Count("resultid"),
    "total_grid_positions" => Sum("grid")
)

query = M.Driver.objects
query.with("driver_stats" => stats, join_field="driverid" => "driverid")

query.filter("driverid__@lte" => 50)
query.values(
    "driverid",
    "forename",
    "surname",
    "driver_stats__total_results",
    "driver_stats__total_grid_positions"
)
df = query |> DataFrame
```

## Multiple CTEs

```julia
recent_races = M.Race.objects
recent_races.filter("year__@gte" => 2020)
recent_races.values("raceid", "name", "year")

top_drivers = M.Driver.objects
top_drivers.filter("driverid__@lte" => 100)
top_drivers.values("driverid", "forename", "surname")

query = M.Result.objects
query.with("recent" => recent_races, join_field="raceid" => "raceid")
query.with("top_d" => top_drivers, join_field="driverid" => "driverid")

query.values("resultid", "recent__name", "top_d__forename", "points")
query.filter("recent__name__@isnull" => false, "top_d__forename__@isnull" => false)
df = query |> DataFrame
```

## Choosing Join Types for CTEs

```julia
using PormG.QueryBuilder: Sum

high_scorers = M.Result.objects
high_scorers.filter("points__@gte" => 10)
high_scorers.values("driverid", "max_points" => Sum("points"))

query = M.Driver.objects
query.with(
    "high_scorers" => high_scorers,
    join_field="driverid" => "driverid",
    join_type="INNER"
)

query.values("driverid", "forename", "max_points" => "high_scorers__max_points")
query.filter("driverid__@lte" => 100)
df = query |> DataFrame
```

Available join types:

- `"LEFT"` (default)
- `"INNER"`

The SQL builder can also render other join keywords such as `"RIGHT"` and `"FULL"`, but those paths are more backend-dependent and are not the primary documented workflow on this page.

## Deep Join Paths in CTE Links

```julia
using PormG.QueryBuilder: Count

nat_stats = M.Driver.objects
nat_stats.values("nationality", "driver_count" => Count("driverid"))

query = M.Result.objects
query.with("stats" => nat_stats, join_field="driverid__nationality" => "nationality")

query.filter("raceid__year" => 2023)
query.values("raceid__name", "driverid__surname", "stats__driver_count")
df = query |> DataFrame
```
When `join_field` contains a path like `driverid__nationality`, PormG builds the intermediate joins needed to connect the main query to the CTE.

## Omitting `join_field` — CTE Without a JOIN

If you call `.with("name" => subq)` without providing a `join_field`, PormG still emits the CTE in the `WITH` clause, but it does **not** produce any `JOIN` between the main table and the CTE. The CTE floats unattached.

```julia
subq = M.Status.objects.filter("status" => "Engine").values("statusid")

query = M.Result.objects
# No join_field — CTE is declared in WITH but NOT joined to the main table
query.with("engine_statuses" => subq)
```

This is valid SQL, but in the high-level ORM API it mainly means the CTE is emitted into SQL scope without being attached to the main query tree:

```julia
query = M.Result.objects
query.with("sub" => subq)
# You can still reuse the original subquery object in later filters:
query.filter("statusid__@in" => subq)
```

> [!TIP]
> Always provide `join_field` when you want CTE data accessible in `.values()`. Without it, the CTE is available in SQL scope but produces no additional columns you can directly project.

## Advanced Custom Joins (`cjoin`)

For straightforward additions of models to the query tree without using full-blown CTE logic, you can use `.cjoin()`.

### Chaining Multiple Joins with Multiple Filters

You can chain multiple `cjoin`s and even specify multiple conditions directly inside the join's `filters` array.

```julia
query = M.Result.objects
query.cjoin("driverid" => "Driver", filters=["nationality" => "Brazilian", "forename" => "Ayrton"])
query.cjoin("raceid" => "Race", filters=["year" => 1991])

query.filter("positionorder" => 1)
query.values("resultid", "driverid__surname", "raceid__name")
df = query |> DataFrame
```

### Mixing `with` (CTEs) and `cjoin`

PormG allows you to mix CTEs and Custom Joins in the same query. Parameter ordering is deterministic across these combinations:

```julia
# 1. Define the CTE
top_const = M.Constructor.objects.filter("constructorid__@lte" => 5).values("constructorid", "name")

query = M.Result.objects

# 2. Inject the CTE
query.with("tc" => top_const, join_field="constructorid" => "constructorid")

# 3. Inject a standard Custom Join
query.cjoin("driverid" => "Driver", filters=["nationality" => "German"])

# 4. Filter and select seamlessly across physical tables, custom joins, and CTEs
query.filter("positionorder" => 1)
query.values("resultid", "tc__name", "driverid__surname")
df = query |> DataFrame
```