# Filters and Aggregates

This page covers lookup operators, regular filtering, grouping, and `HAVING` clauses.

## Functions vs Operators in Filters

PormG uses `__@` suffixes for both transforms and comparisons:

- `field__@operator`: compare a field with a value.
- `field__@function`: transform a field before comparing or selecting it.

Common operators:

- `@lt`, `@lte`, `@gt`, `@gte`
- `@range`
- `@in`, `@nin`
- `@contains`, `@icontains`
- `@isnull`
- `@ne`

Common modifier functions:

- Date: `@year`, `@month`, `@day`, `@quarter`, `@quadrimester`, `@date`, `@yyyy_mm`
- Math: `@round`, `@floor`, `@ceil`, `@sqrt`, `@abs`, `@power`, `@mod`

## Basic Comparisons

```julia
query = M.Result.objects
query.filter("positionorder__@lt" => 3)
df = query |> DataFrame
```

## Range Filters

`@range` translates to SQL `BETWEEN` and accepts exactly two bounds.

```julia
query = M.Driver.objects.filter("driverid__@range" => [1, 5])
df = query |> DataFrame

query = M.Driver.objects.filter("driverid__@range" => (10, 15))
df = query |> DataFrame
```

## String Matching

```julia
query = M.Result.objects
query.filter("raceid__circuitid__name__@contains" => "Monaco")
count = query.count()

query = M.Result.objects
query.filter("raceid__circuitid__name__@icontains" => "monaco")
count = query.count()
```

## In and Not In

```julia
query = M.Result.objects
query.filter("raceid__circuitid__name__@in" => ["Circuit de Monaco", "monaco"])

query = M.Result.objects
query.filter("raceid__circuitid__name__@nin" => ["Circuit de Monaco", "monaco"])
```

## Multiple Filters

Multiple pairs inside one `filter()` call use `AND` semantics.

```julia
query = M.Result.objects
query.filter("statusid__status" => "Finished", "resultid" => 26745)
query.values(
    "resultid",
    "raceid__circuitid__name",
    "driverid__forename",
    "constructorid__name",
    "statusid__status",
    "grid",
    "laps"
)
results = query |> list
results = query.list()
```

For exclusion-like logic, prefer `@nin` when you truly mean a set exclusion:

```julia
query = M.Driver.objects
query.filter("nationality__@nin" => ["British", "German"])
```

## Aggregations and Grouping

```julia
using PormG.QueryBuilder: Count, Max, Min

query = M.Result.objects
query.values(
    "statusid__status",
    "raceid__circuitid__name",
    "driverid__forename",
    "constructorid__name",
    "count_grid" => Count("grid"),
    "max_grid" => Max("grid"),
    "min_grid" => Min("grid")
)
query.filter("statusid__status" => "Finished", "driverid__forename" => "Ayrton")
query.order_by("raceid__circuitid__name")
df = query |> DataFrame
```

Once aggregated values appear in `values()`, PormG groups by the non-aggregated selected columns.

## HAVING Clauses

Aggregated filters are promoted to `HAVING` automatically.

```julia
query = M.Result.objects
query.values(
    "raceid__circuitid__name",
    "driverid__forename",
    "constructorid__name",
    "count_grid" => Count("grid")
)
query.filter("statusid__status" => "Finished", "count_grid__@lte" => 3)
df = query |> DataFrame
```

The generated SQL uses `WHERE` for row-level conditions and `HAVING` for aggregate conditions:

```sql
SELECT
   "Tb_2"."name" as raceid__circuitid__name,
   "Tb_3"."forename" as driverid__forename,
   "Tb_4"."name" as constructorid__name,
   COUNT("Tb"."grid") as count_grid
FROM "result" as "Tb"
 INNER JOIN "race" AS "Tb_1" ON "Tb"."raceid" = "Tb_1"."raceid"
 INNER JOIN "circuit" AS "Tb_2" ON "Tb_1"."circuitid" = "Tb_2"."circuitid"
 INNER JOIN "driver" AS "Tb_3" ON "Tb"."driverid" = "Tb_3"."driverid"
 INNER JOIN "constructor" AS "Tb_4" ON "Tb"."constructorid" = "Tb_4"."constructorid"
 INNER JOIN "status" AS "Tb_5" ON "Tb"."statusid" = "Tb_5"."statusid"
WHERE "Tb_5"."status" = $1
GROUP BY 1, 2, 3
HAVING COUNT("Tb"."grid") <= 3
```

For more complex aggregate expressions such as `Sum("points") / Count("resultid")`, see [Field Expressions](field_expressions.md) and [Q Objects](q_objects.md).