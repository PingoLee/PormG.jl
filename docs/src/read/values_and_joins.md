# Values and Joins

This page covers column selection, relation traversal, aliases, and the way PormG turns `__` paths into joins.

## Basic Field Selection

```julia
query = M.Result.objects
query.filter("statusid__status" => "Engine")
query.values("resultid", "statusid")
df = query |> DataFrame
```

## Joined Field Selection

```julia
query = M.Result.objects
query.filter("statusid__status" => "Engine")
query.values(
    "resultid",
    "driverid__forename",
    "constructorid__name",
    "statusid__status",
    "grid",
    "laps"
)
df = query |> DataFrame
```

When PormG encounters `driverid__forename`, it:

1. Resolves `driverid` as a relationship on `Result`.
2. Creates the needed join.
3. Selects `forename` from the joined table.

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

## Reverse Joins

```julia
query = M.Constructor.objects
query.values("result__resultid")
query.filter("result__resultid" => 1)
df = query |> DataFrame
```

Reverse traversal works the same way. PormG follows the relation graph and builds the corresponding join path.

## Multi-Level Joins

```julia
query = M.Result.objects
query.filter("raceid__circuitid__country" => "Monaco")
query.values("driverid__forename", "raceid__circuitid__name", "raceid__year")
df = query |> DataFrame
```

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

## Join Types

PormG chooses join types from model metadata:

- `INNER JOIN`: default for non-nullable foreign keys.
- `LEFT JOIN`: used when the relationship allows nulls.
- Join direction: inferred from the relation path.

PormG does not currently support arbitrary boolean logic inside automatic join conditions. For custom join conditions, use the custom join APIs documented elsewhere.

## Common Patterns

### Filter by Related Fields

```julia
query = M.Result.objects
query.filter("driverid__nationality" => "British")
```

### Select Across Relations

```julia
query = M.Result.objects
query.values(
    "position",
    "driverid__forename",
    "driverid__surname",
    "constructorid__name",
    "raceid__name"
)
```

### Combine Multiple Joins in One Filter

```julia
query = M.Result.objects
query.filter(
    "driverid__nationality" => "British",
    "raceid__circuitid__name__@icontains" => "monaco"
)
```

### Aggregate Across Joins

```julia
query = M.Result.objects
query.filter("positionorder" => 1)
query.values("constructorid__name", "wins" => Count("resultid"))
```

## Aliases in values()

You can rename output columns with `=>`.

```julia
query = M.Result.objects
query.filter("statusid__status" => "Finished", "resultid" => 26745)
query.values("resultid", "circuit" => "raceid__circuitid__name")
df = query |> DataFrame
```

You can also alias transformed fields:

```julia
query = M.Result.objects
query.filter("statusid__status" => "Finished", "resultid" => 26745)
query.values(
    "resultid",
    "circuit" => "raceid__circuitid__name",
    "quarter" => "raceid__date__@quarter"
)
df = query |> DataFrame
```