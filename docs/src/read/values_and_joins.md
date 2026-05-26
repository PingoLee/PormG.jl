# Values and Joins

This page covers column selection, relation traversal with `__`, join types, reverse joins, wildcard selection, aliases, and common patterns.

---

## How Joins Work in PormG

PormG uses the double-underscore `__` notation (inspired by Django) to traverse relationships. When you reference a field like `driverId__surname`, PormG:

1. **Resolves** `driverId` as a ForeignKey relationship on the model.
2. **Creates** the appropriate SQL `JOIN` automatically.
3. **Selects** the `surname` column from the joined `Driver` table.

You never write raw `JOIN` statements — PormG builds them from your model definitions.

---

## Basic Field Selection

Select specific columns from the main table:

```julia
query = M.Result.objects
query.filter("statusId__status" => "Engine")
query.values("resultId", "statusId")
df = query |> DataFrame
```

This generates a simple `SELECT ... FROM ... WHERE` without any joins, since `resultId` and `statusId` are local columns on the `Result` table.

---

## Joined Field Selection

Select columns from related tables using `__`:

```julia
query = M.Result.objects
query.filter("statusId__status" => "Engine")
query.values(
    "resultId",
    "driverId__forename",
    "constructorId__name",
    "statusId__status",
    "grid",
    "laps"
)
df = query |> DataFrame
```

PormG generates:

```sql
SELECT 
    "Tb"."resultid" as resultid,
    "Tb_1"."forename" as driverid__forename,
    "Tb_2"."name" as constructorid__name,
    "Tb_3"."status" as statusid__status,
    "Tb"."grid" as grid,
    "Tb"."laps" as laps
FROM "result" as "Tb"
    INNER JOIN "driver" AS "Tb_1" ON "Tb"."driverid" = "Tb_1"."driverid"
    INNER JOIN "constructor" AS "Tb_2" ON "Tb"."constructorid" = "Tb_2"."constructorid"
    INNER JOIN "status" AS "Tb_3" ON "Tb"."statusid" = "Tb_3"."statusid"
WHERE "Tb_3"."status" = $1
```

> [!NOTE]
> PormG uses table aliases (`Tb`, `Tb_1`, `Tb_2`, …) automatically. You never need to manage aliases yourself. Each joined table gets a sequential alias.

---

## Multi-Level Joins

Chain `__` segments to traverse multiple relationships:

```julia
query = M.Result.objects
query.filter("raceId__circuitId__country" => "Monaco")
query.values(
    "driverId__forename",
    "raceid__circuitId__name",
    "raceId__year"
)
df = query |> DataFrame
```

This traverses `Result → Race → Circuit` and `Result → Driver`, producing three joins:

```sql
SELECT 
    "Tb_1"."forename" as driverid__forename,
    "Tb_3"."name" as raceid__circuitid__name,
    "Tb_2"."year" as raceid__year
FROM "result" as "Tb"
INNER JOIN "driver" AS "Tb_1" ON "Tb"."driverid" = "Tb_1"."driverid"
INNER JOIN "race" AS "Tb_2" ON "Tb"."raceid" = "Tb_2"."raceid"
INNER JOIN "circuit" AS "Tb_3" ON "Tb_2"."circuitid" = "Tb_3"."circuitid"
WHERE "Tb_3"."country" = $1
```

PormG deduplicates joins — if the same relationship is used in both `filter()` and `values()`, it creates only one `JOIN`.

---

## Reverse Joins

When Model B has a `ForeignKey` pointing to Model A, you can traverse the relationship **backwards** from A to B:

```julia
# Constructor → Result (reverse: Result has FK to Constructor)
query = M.Constructor.objects
query.values("constructorId", "name", "result__points")
query.filter("result__positionOrder" => 1) # Filter for winning constructors
df = query |> DataFrame
```

### Naming Reverse Relations

By default, the name used to traverse backwards is the **lowercase name of the source model** (e.g., `result` for `Result`). 

If you have multiple `ForeignKey`s pointing to the same target model, or if you simply prefer a more descriptive name, define a `related_name` on the `ForeignKey`:

```julia
# Model definition snippet
# "test_deletion" becomes the reverse traversal key from Result
test_result = Models.ForeignKey(Result, pk_field="resultId", related_name="test_deletion")
```

```julia
# Querying using the related_name
query = M.Result.objects
query.values("resultId", "test_deletion__name")
```

### Chained Multi-Hop Reverse Joins

PormG supports traversing multiple relationships in reverse, seamlessly chaining backward hops. Continuing from the previous example, if a `Just_a_nested_roll_back` model has a FK to `Just_a_test_deletion`:

```julia
# Result ← test_deletion (related_name) ← just_a_nested_roll_back (lowercase model name)
query = M.Result.objects
query.filter("test_deletion__just_a_nested_roll_back__description" => "nested-value")
query.values("resultId", "test_deletion__just_a_nested_roll_back__id")
```

---

## Wildcard Selection with `*`

Use `"*"` to select all columns from the main table, then add specific joined fields:

```julia
query = M.Result.objects
query.filter("driverId__nationality" => "Brazilian")
query.values("*", "driverId__surname", "driverId__forename")
df = query |> DataFrame
```

This selects every column from `Result` plus `surname` and `forename` from the joined `Driver` table.

> [!IMPORTANT]
> Queries that use `.cjoin()` **must** call `.values(...)` explicitly before execution. A bare `SELECT *` across joined tables causes `DataFrames.jl` to crash with `ArgumentError: Duplicate variable names`. Use `.values("*", "joined__field")` to safely include joined columns.

---

## Join Types

PormG selects join types based on your model's field definitions:

| Condition | Join Type |
| :--- | :--- |
| Non-nullable ForeignKey | `INNER JOIN` |
| Nullable ForeignKey (`null=true`) | `LEFT JOIN` |
| Custom join via `.cjoin()` | `LEFT JOIN` by default (configurable) |
| Override via `.on()` | Configurable: `"INNER"`, `"LEFT"`, etc. |

The join direction is always inferred from the relation path. For custom join behavior, see [Custom Joins](custom_joins.md).

---

## Aliases in `values()`

Rename output columns using the `"alias" => "field"` pair syntax:

### Simple Column Alias

```julia
query = M.Result.objects
query.filter("statusId__status" => "Finished", "resultId" => 26745)
query.values(
    "resultId",
    "circuit" => "raceId__circuitId__name"
)
df = query |> DataFrame
# DataFrame columns: :resultId, :circuit
```

### Alias with Date Transforms

```julia
query = M.Result.objects
query.filter("statusId__status" => "Finished", "resultId" => 26745)
query.values(
    "resultId",
    "circuit" => "raceId__circuitId__name",
    "quarter" => "raceId__date__@quarter"
)
df = query |> DataFrame
# DataFrame columns: :resultId, :circuit, :quarter
```

### Alias with Aggregates and F-Expressions

```julia
query = M.Result.objects
query.values(
    "driver" => "driverId__surname",
    "total_pts" => Sum("points"),
    "bonus" => F("points") * 0.1
)
```

> [!TIP]
> Aliasing happens at the SQL level (`SELECT "field" AS "alias"`). This is more efficient than renaming columns in a Julia DataFrame after the query.

---

## Common Patterns

### Filter by Related Fields

```julia
# All results for British drivers
query = M.Result.objects
query.filter("driverId__nationality" => "British")
```

### Select Across Multiple Relations

```julia
# Full race result detail
query = M.Result.objects
query.values(
    "positionOrder",
    "driverId__forename",
    "driverId__surname",
    "constructorId__name",
    "raceId__name",
    "raceId__circuitId__country"
)
```

### Combine Multiple Joins in One Filter

Multiple filter pairs involving different joins are ANDed together:

```julia
# British drivers at Monaco
query = M.Result.objects
query.filter(
    "driverId__nationality" => "British",
    "raceId__circuitId__name__@icontains" => "monaco"
)
```

### Aggregate Across Joins

```julia
# Wins per constructor
query = M.Result.objects
query.filter("positionOrder" => 1)
query.values("constructorId__name", "wins" => Count("resultId"))
query.order_by("-wins")
df = query |> DataFrame
```

### Join Path in Filters Only (No Explicit `values()`)

When you filter on a joined field but don't call `values()`, PormG still creates the join for the `WHERE` clause but selects `*` from the main table:

```julia
# Returns all Result columns, filtered by driver nationality
df = M.Result.objects.filter("driverId__nationality" => "British") |> DataFrame
```

---

## Next Steps

- **[Filters and Aggregates](filters_and_aggregates.md)** — Learn about lookup operators (`@gt`, `@in`, `@contains`, …) and grouping.
- **[Custom Joins](custom_joins.md)** — Use `.cjoin()` for non-FK joins and `.on()` for ON-clause predicates.