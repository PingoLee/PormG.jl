# Subqueries and CTEs

This page covers nested queries with `IN (SELECT ...)`, Common Table Expressions (`WITH`), CTE join types, deep join paths, and mixing CTEs with custom joins.

---

## Subqueries in Filters

Pass a query object to `@in` to create a server-side `IN (SELECT ...)` predicate:

```julia
# Build the subquery
subquery = M.Status.objects
subquery.filter("status" => "Engine")
subquery.values("statusid")

# Use it in the main query
query = M.Result.objects
query.filter("statusid__@in" => subquery)
query.values("resultid", "statusid", "statusid__status", "grid", "driverid")
df = query |> DataFrame
```

This generates:

```sql
SELECT ... FROM "result" as "Tb" ...
WHERE "Tb"."statusid" IN (SELECT "Tb"."statusid" FROM "status" as "Tb" WHERE "Tb"."status" = $1)
```

> [!TIP]
> Subqueries run entirely on the server — PormG does not materialize the subquery in Julia. This is much more efficient for large datasets.

---

## Subquery Column Constraint

An `@in` subquery **must project exactly one column**. PormG validates this before generating SQL and throws an `ArgumentError` if the subquery selects more than one field.

```julia
# Wrong — two columns will throw ArgumentError
bad_sub = M.Status.objects.values("statusid", "status")
query.filter("statusid__@in" => bad_sub)
# ERROR: 'statusid__@in' requires a subquery that returns exactly one column
#        (currently selects 2 columns: statusid, status)
#        call .values("field_name") on the subquery to narrow it to one column.

# Correct — exactly one column
good_sub = M.Status.objects.filter("status" => "Engine").values("statusid")
query.filter("statusid__@in" => good_sub)
```

### SQL Function Projections

You can use a SQL function alias as the single column. PormG counts a `"alias" => Function(...)` pair as one column, so the validator accepts it:

```julia
using PormG.Functions: Max

# Subquery that returns the single highest driver id
top_id_sub = M.Driver.objects.values("top_id" => Max("driverid"))

# Returns only the driver whose id equals the maximum id
query = M.Driver.objects.filter("driverid__@in" => top_id_sub)
df = query |> DataFrame
```

Generated SQL:
```sql
SELECT * FROM "drivers" AS "Tb"
WHERE "Tb"."driverid" IN (
    SELECT MAX("R1"."driverid") AS top_id FROM "drivers" AS "R1"
)
```

> [!NOTE]
> SQL function projections (like `Max`, `Min`, `Count`) compile to inline SQL with no bind parameters. `result[:parameters]` will be empty for such subqueries.

---

## Subqueries with Additional Filters

Combine subquery `@in` with other filter conditions:

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

---

## Common Table Expressions (CTEs)

CTEs (SQL `WITH` clauses) are useful when a query becomes easier to reason about in stages. PormG supports CTEs through the `.with()` method.

### Why Use CTEs?

- **Readability** — Break complex queries into named stages.
- **Aggregation** — Pre-compute aggregates and join them back to the main query.
- **Reuse** — Reference the same subquery multiple times without duplication.

---

## Basic CTE with JOIN

Define a subquery, give it a name, and join it to the main query via `join_field`:

```julia
using PormG.Functions: Count

# Define the CTE: count results per driver (where status = 1)
driver_stats = M.Result.objects
driver_stats.filter("statusid" => 1)
driver_stats.values("driverid", "total_results" => Count("resultid"))

# Main query: join the CTE to Result via driverid
main_query = M.Result.objects
main_query.with("stats" => driver_stats, join_field="driverid" => "driverid")

main_query.filter("resultid__@lte" => 100)
main_query.values("resultid", "driverid", "stats__total_results")
df = main_query |> DataFrame
```

The `.with()` method:
1. Emits the subquery as a `WITH stats AS (SELECT ...)` clause.
2. Creates a `LEFT JOIN stats ON result.driverid = stats.driverid`.
3. Makes `stats__total_results` available for selection via `values()`.

---

## Correlating a CTE with `F()` (no `join_field`)

When you omit `join_field`, the CTE is emitted but not keyed to the main table. Referencing one
of its columns with `F("<cte>__col")` then **`CROSS JOIN`s** the CTE, and the `F()` filter you
write supplies the correlation verbatim in `WHERE` — the natural, Django-flavored way to express
a correlated CTE:

```julia
# Races from the 1991 season
races_91 = M.Race.objects.filter("year" => 1991).values("raceid")

# Winners of those races — correlate Result.raceid with the CTE's raceid via F()
q = M.Result.objects
q.with("r91" => races_91)                       # no join_field
q.filter("raceid" => F("r91__raceid"),          # ← the correlation
         "positionorder" => 1)
q.values("resultid", "raceid")
df = q |> DataFrame
```

renders (SQLite shown; PostgreSQL uses `$N` placeholders):

```sql
WITH "r91" AS (SELECT "raceid" FROM "race" WHERE "year" = ?)
SELECT "R1"."resultid", "R1"."raceid"
FROM "result" AS "R1"
CROSS JOIN "r91" AS "R1_1"
WHERE "R1"."raceid" = "R1_1"."raceid" AND "R1"."positionorder" = ?
```

Notes:
- **`CROSS JOIN + WHERE` is inner by nature** — only rows the correlation matches are returned.
  To keep unmatched main-table rows (a *nullable* left join against a CTE), use an explicit
  `join_field` (+ `join_type="LEFT"`) as shown above instead.
- The correlation is ordinary `F()`, so multiple correlations and inequality/range predicates
  work too, e.g. `filter("date__@gte" => F("r91__start"), "date__@lte" => F("r91__end"))`.
- **Cartesian-product guard.** Referencing a CTE column with *no* constraining filter is a
  Cartesian product; PormG emits a `@warn` naming the CTE. Add a correlating `filter(...)`, or
  pass `join_field`.

---

## CTE with Multiple Aggregated Fields

```julia
using PormG.Functions: Count, Sum

# CTE with multiple aggregates
stats = M.Result.objects
stats.filter("raceid__@lte" => 100)
stats.values(
    "driverid",
    "total_results"         => Count("resultid"),
    "total_grid_positions"  => Sum("grid")
)

# Join CTE to Driver model
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

---

## Multiple CTEs

Attach multiple CTEs to the same query:

```julia
# CTE 1: Recent races
recent_races = M.Race.objects
recent_races.filter("year__@gte" => 2020)
recent_races.values("raceid", "name", "year")

# CTE 2: Top drivers
top_drivers = M.Driver.objects
top_drivers.filter("driverid__@lte" => 100)
top_drivers.values("driverid", "forename", "surname")

# Main query with both CTEs
query = M.Result.objects
query.with("recent" => recent_races, join_field="raceid" => "raceid")
query.with("top_d" => top_drivers, join_field="driverid" => "driverid")

query.values("resultid", "recent__name", "top_d__forename", "points")
query.filter("recent__name__@isnull" => false, "top_d__forename__@isnull" => false)
df = query |> DataFrame
```

Each `.with()` call adds another `WITH` clause and `JOIN` to the final SQL.

---

## Choosing Join Types for CTEs

By default, CTEs use `LEFT JOIN`. Use `join_type="INNER"` to filter out non-matching rows:

```julia
using PormG.Functions: Sum

high_scorers = M.Result.objects
high_scorers.filter("points__@gte" => 10)
high_scorers.values("driverid", "max_points" => Sum("points"))

query = M.Driver.objects
query.with(
    "high_scorers" => high_scorers,
    join_field="driverid" => "driverid",
    join_type="INNER"   # Only include drivers who have high scores
)

query.values("driverid", "forename", "max_points" => "high_scorers__max_points")
query.filter("driverid__@lte" => 100)
df = query |> DataFrame
```

### Available CTE Join Types

| Join Type | Behavior |
| :--- | :--- |
| `"LEFT"` | Default. All main-table rows are kept; unmatched CTE columns are `missing`. |
| `"INNER"` | Only rows that match the CTE are returned. |

The SQL builder can also render `"RIGHT"` and `"FULL"` join keywords, but these are not the primary documented workflow.

---

## Deep Join Paths in CTE Links

The `join_field` can contain a multi-level path with `__`. PormG builds the intermediate joins needed to connect the main query to the CTE:

```julia
using PormG.Functions: Count

# CTE: count drivers per nationality
nat_stats = M.Driver.objects
nat_stats.values("nationality", "driver_count" => Count("driverid"))

# Main query: join CTE via a deep path (Result → Driver → nationality)
query = M.Result.objects
query.with("stats" => nat_stats, join_field="driverid__nationality" => "nationality")

query.filter("raceid__year" => 2023)
query.values("raceid__name", "driverid__surname", "stats__driver_count")
df = query |> DataFrame
```

PormG automatically:
1. Joins `Result → Driver` (via the `driverid` ForeignKey).
2. Links `Driver.nationality` to `stats.nationality` (the CTE join column).

---

## CTE Without a JOIN

If you call `.with("name" => subq)` without providing `join_field`, PormG still emits the CTE in the `WITH` clause but does **not** join it to the main table:

```julia
subq = M.Status.objects.filter("status" => "Engine").values("statusid")

query = M.Result.objects
query.with("engine_statuses" => subq)   # Declared but not joined
```

This is valid SQL, but the CTE data won't be accessible through `values()`. The main use case is combining a CTE declaration with a subquery filter:

```julia
query = M.Result.objects
query.with("sub" => subq)
query.filter("statusid__@in" => subq)   # Reuse the subquery in a filter
```

> [!TIP]
> Always provide `join_field` when you want CTE data accessible via `.values()`. Without it, the CTE is emitted but produces no additional projectable columns.

---

## Mixing CTEs and Custom Joins

PormG allows CTEs and custom joins (`.cjoin()`) in the same query. Parameter ordering is deterministic across these combinations:

```julia
# 1. Define the CTE
top_const = M.Constructor.objects.
    filter("constructorid__@lte" => 5).
    values("constructorid", "name")

# 2. Build the chain with CTE, cjoin, filters, and values
df = M.Result.objects.
    with("tc" => top_const, join_field="constructorid" => "constructorid").
    cjoin("driverid" => "Driver", filters=["nationality" => "German"]).
    filter("positionorder" => 1).
    values("resultid", "tc__name", "driverid__surname") |> DataFrame
```

### Chaining Multiple Custom Joins

```julia
df = M.Result.objects.
    cjoin("driverid" => "Driver", filters=["nationality" => "Brazilian", "forename" => "Ayrton"]).
    cjoin("raceid" => "Race", filters=["year" => 1991]).
    filter("positionorder" => 1).
    values("resultid", "driverid__surname", "raceid__name") |> DataFrame
```

See [Custom Joins](custom_joins.md) for the full `.cjoin()` and `.on()` documentation.

---

## Summary

| Feature | Syntax | Use Case |
| :--- | :--- | :--- |
| Subquery `IN` | `"field__@in" => subquery` | Filter by a set computed on the server. |
| CTE with JOIN | `.with("name" => subq, join_field=...)` | Pre-aggregate data and join it. |
| CTE without JOIN | `.with("name" => subq)` | Declare for use in filters only. |
| CTE INNER JOIN | `join_type="INNER"` | Only keep matching rows. |
| Deep join path | `join_field="a__b" => "field"` | Link CTE via multi-level relationships. |
| CTE + cjoin | `.with(...)` + `.cjoin(...)` | Combine all join strategies. |

---

## Next Steps

- **[Custom Joins](custom_joins.md)** — Full `cjoin()` and `on()` documentation.
- **[Field Expressions](field_expressions.md)** — Use `F()` for arithmetic and computed columns.
- **[Q Objects](q_objects.md)** — Complex boolean logic in filters.