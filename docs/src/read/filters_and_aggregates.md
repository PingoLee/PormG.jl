# Filters and Aggregates

This page covers lookup operators, filtering, exclusion patterns, grouping, and `HAVING` clauses.

---

## The `__@` Suffix System

PormG uses the `__@` suffix on field names for both **comparison operators** and **transform functions**:

- `field__@operator` — Compare a field to a value (e.g., `"points__@gt" => 10`).
- `field__@function` — Transform a field before comparing or selecting (e.g., `"dob__@year" => 1960`).

These work in both `filter()` and `values()`.

---

## Comparison Operators

| Operator | SQL | Description | Example |
| :--- | :--- | :--- | :--- |
| *(none)* | `= value` | Exact match | `"nationality" => "British"` |
| `@gt` | `> value` | Greater than | `"points__@gt" => 10` |
| `@gte` | `>= value` | Greater than or equal | `"points__@gte" => 10` |
| `@lt` | `< value` | Less than | `"positionOrder__@lt" => 3` |
| `@lte` | `<= value` | Less than or equal | `"positionOrder__@lte" => 10` |
| `@ne` | `<> value` | Not equal | `"status__@ne" => "Retired"` |
| `@in` | `IN (...)` | Value in set | `"nationality__@in" => ["British", "French"]` |
| `@nin` | `NOT IN (...)` | Value not in set | `"nationality__@nin" => ["British", "German"]` |
| `@range` | `BETWEEN a AND b` | Between two bounds | `"driverId__@range" => [1, 50]` |
| `@isnull` | `IS NULL / IS NOT NULL` | Null check | `"dob__@isnull" => true` |
| `@contains` | `LIKE '%val%'` | Case-sensitive substring | `"name__@contains" => "Monaco"` |
| `@icontains` | `ILIKE '%val%'` | Case-insensitive substring | `"name__@icontains" => "monaco"` |

### Transform Functions (Modifiers)

| Transform | Description | Use in `filter()` | Use in `values()` |
| :--- | :--- | :--- | :--- |
| `@year` | Extract year from date | `"dob__@year" => 1960` | `"dob__@year"` |
| `@month` | Extract month | `"dob__@month" => 3` | `"dob__@month"` |
| `@day` | Extract day | `"date__@day" => 21` | `"date__@day"` |
| `@quarter` | Extract quarter (1-4) | `"date__@quarter" => 1` | `"date__@quarter"` |
| `@quadrimester` | Extract quadrimester (1-3) | `"date__@quadrimester" => 2` | `"date__@quadrimester"` |
| `@date` | Extract date from datetime | `"created__@date" => Date(...)` | `"created__@date"` |
| `@yyyy_mm` | Year-month string | `"date__@yyyy_mm" => "1991-10"` | `"date__@yyyy_mm"` |
| `@round` | Round numeric value | — | `"points__@round"` |
| `@floor` | Floor numeric value | — | `"points__@floor"` |
| `@ceil` | Ceiling numeric value | — | `"points__@ceil"` |
| `@sqrt` | Square root | — | `"driverId__@sqrt"` |
| `@abs` | Absolute value | — | `"points__@abs"` |
| `@power` | Power function | — | see `Power()` |
| `@mod` | Modulo | — | see `Mod()` |

---

## Basic Comparisons

### Exact Match

```julia
df = M.Driver.objects.filter("nationality" => "Brazilian") |> DataFrame
```

### Greater Than / Less Than

```julia
query = M.Result.objects
query.filter("positionOrder__@lt" => 3)
df = query |> DataFrame
```

### Not Equal

```julia
query = M.Result.objects
query.filter("statusId__status__@ne" => "Retired")
```

---

## Range Filters

`@range` translates to SQL `BETWEEN` and accepts exactly two bounds (as a Vector or Tuple):

```julia
# Vector syntax
query = M.Driver.objects.filter("driverId__@range" => [1, 5])
df = query |> DataFrame

# Tuple syntax
query = M.Driver.objects.filter("driverId__@range" => (10, 15))
df = query |> DataFrame
```

---

## String Matching

### Case-Sensitive (`@contains`)

```julia
query = M.Result.objects
query.filter("raceId__circuitId__name__@contains" => "Monaco")
count = query.count()
```

### Case-Insensitive (`@icontains`)

```julia
query = M.Result.objects
query.filter("raceId__circuitId__name__@icontains" => "monaco")
count = query.count()
```

> [!NOTE]
> `@icontains` uses `ILIKE` on PostgreSQL. On SQLite (which is case-insensitive for ASCII by default), it uses `LIKE`.

---

## IN and NOT IN

### Value In Set

```julia
query = M.Result.objects
query.filter("raceId__circuitId__name__@in" => ["Circuit de Monaco", "Silverstone"])
```

### Value Not In Set

```julia
query = M.Driver.objects
query.filter("nationality__@nin" => ["British", "German"])
```

### Subquery IN

You can also pass a query object to `@in` for a server-side `IN (SELECT ...)`:

```julia
engine_statuses = M.Status.objects.filter("status" => "Engine").values("statusId")

query = M.Result.objects
query.filter("statusId__@in" => engine_statuses)
```

See [Subqueries and CTEs](subqueries_and_ctes.md) for more details.

---

## Null Checks

```julia
# Find drivers with no date of birth recorded
query = M.Driver.objects.filter("dob__@isnull" => true)

# Find drivers that DO have a date of birth
query = M.Driver.objects.filter("dob__@isnull" => false)
```

---

## Multiple Filters (AND Logic)

Multiple pairs inside one `filter()` call are combined with `AND`:

```julia
query = M.Result.objects
query.filter("statusId__status" => "Finished", "resultId" => 26745)
query.values(
    "resultId",
    "raceId__circuitId__name",
    "driverId__forename",
    "constructorId__name",
    "statusId__status",
    "grid",
    "laps"
)
results = query.list()
```

Successive `.filter()` calls also use AND — they are additive:

```julia
query = M.Result.objects
query.filter("statusId__status" => "Finished")
query.filter("positionOrder" => 1)   # Adds another AND condition
```

For OR logic, use [`Qor()`](q_objects.md):

```julia
using PormG: Qor

query = M.Result.objects
query.filter(Qor("constructorId" => 1, "constructorId" => 9))
```

---

## Aggregations and Grouping

PormG provides five aggregate functions: `Count`, `Sum`, `Avg`, `Max`, and `Min`.

When aggregate values appear in `values()`, PormG **automatically groups by the non-aggregated columns**.

```julia
using PormG: Count, Sum, Max, Min

query = M.Result.objects
query.values(
    "statusId__status",
    "raceId__circuitId__name",
    "driverId__forename",
    "constructorId__name",
    "count_grid" => Count("grid"),
    "max_grid"   => Max("grid"),
    "min_grid"   => Min("grid")
)
query.filter("statusId__status" => "Finished", "driverId__forename" => "Ayrton")
query.order_by("raceId__circuitId__name")
df = query |> DataFrame
```

### How Grouping Works

PormG detects which columns in `values()` are aggregates and which are plain fields. It generates:

```sql
SELECT ..., COUNT("Tb"."grid") as count_grid, ...
FROM "result" as "Tb" ...
GROUP BY 1, 2, 3, 4   -- groups by non-aggregate columns
```

You do **not** write `GROUP BY` manually — PormG handles it.

---

## HAVING Clauses

When you filter on an aggregate alias, PormG automatically promotes the condition to `HAVING`:

```julia
query = M.Result.objects
query.values(
    "raceId__circuitId__name",
    "driverId__forename",
    "constructorId__name",
    "count_grid" => Count("grid")
)
query.filter("statusId__status" => "Finished", "count_grid__@lte" => 3)
df = query |> DataFrame
```

PormG generates:

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

Notice how PormG separates:
- **`WHERE`** — row-level conditions (`status = 'Finished'`)
- **`HAVING`** — aggregate conditions (`COUNT(grid) <= 3`)

### Aggregate Arithmetic in HAVING

You can filter on computed aggregate expressions too:

```julia
query = M.Result.objects
query.values(
    "constructorId__name",
    "avg_perf" => Sum("points") / Count("resultId")
)
query.filter("avg_perf__@gt" => 5)
```

For more complex expressions, see [Field Expressions](field_expressions.md).

---

## Common Aggregation Patterns

### Wins Per Constructor

```julia
df = M.Result.objects
    .filter("positionOrder" => 1)
    .values("constructorId__name", "wins" => Count("resultId"))
    .order_by("-wins") |> DataFrame
```

### Total Points Per Driver

```julia
df = M.Result.objects
    .values("driverId__surname", "total_pts" => Sum("points"))
    .order_by("-total_pts")
    .limit(20) |> DataFrame
```

### Best Finish Per Driver at a Specific Circuit

```julia
df = M.Result.objects
    .filter("raceId__circuitId__name" => "Circuit de Monaco")
    .values(
        "driverId__surname",
        "best_finish" => Min("positionOrder"),
        "races" => Count("resultId")
    )
    .order_by("best_finish") |> DataFrame
```

---

## Next Steps

- **[Functions and Dates](functions_and_dates.md)** — Use `Case`, `Coalesce`, `Concat`, date extraction, and math functions.
- **[Q Objects](q_objects.md)** — Build complex OR/AND logic beyond what `filter()` pairs support.
- **[Field Expressions](field_expressions.md)** — Field-to-field comparisons with `F()` and aggregate ratios.