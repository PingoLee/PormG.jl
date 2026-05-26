# Field Expressions (F Objects)

`F()` expressions enable database-side field references and arithmetic. They let you compare fields to other fields, perform calculations in SQL, and create computed columns — all without pulling data into Julia.

> [!NOTE]
> **For Django users:** PormG's `F()` is inspired by Django but leverages Julia's operator overloading (e.g., `F("a") + F("b")`). It also allows seamless mixing with aggregate functions like `Sum()` and `Count()`, and the engine automatically detects aggregates to generate `HAVING` clauses.

---

## When to Use F Expressions

| Task | Preferred Style | F Expression |
| :--- | :--- | :--- |
| Compare field to a **constant** | `"points__@gt" => 10` | Avoid — use the filter suffix API |
| Compare **field to field** | — | `F("grid") == F("positionOrder")` |
| **Arithmetic** in SELECT | — | `F("points") * 0.1` |
| **Aggregate ratios** | — | `Sum("points") / Count("resultId")` |
| **Atomic updates** | — | `F("points") + 1` |

> [!TIP]
> Reserve `F()` for column-to-column or column-to-expression operations. For scalar comparisons like `points > 10`, prefer the suffix syntax `"points__@gt" => 10` — it's clearer and idiomatic.

---

## Core Syntax

```julia
using PormG: F, Count, Sum

# Field reference
F("grid")

# Arithmetic
F("points") + 5                   # Addition
F("points") - F("grid")          # Subtraction
F("points") * F("laps")          # Multiplication
F("points") / 2.0                # Division
Sum("points") / Count("resultId") # Aggregate ratios
```

**Supported arithmetic operators:** `+`, `-`, `*`, `/`

---

## Comparison Operators

`F()` expressions support standard Julia comparison operators, translated directly to SQL:

| Julia | SQL | Use Case |
| :--- | :--- | :--- |
| `==` | `=` | Field-to-field equality |
| `!=` | `<>` | Field-to-field inequality |
| `>` | `>` | Greater than |
| `<` | `<` | Less than |
| `>=` | `>=` | Greater than or equal |
| `<=` | `<=` | Less than or equal |

These are most useful when the comparison involves **two columns** or a **computed expression** — cases where the suffix filter API cannot help.

---

## F Expressions in Filters

### Field-to-Field Comparison

Find results where the starting grid position matches the finishing position:

```julia
query = M.Result.objects
query.filter(F("grid") == F("positionOrder"))
df = query |> DataFrame
```

Generated SQL:
```sql
WHERE "Tb"."grid" = "Tb"."positionorder"
```

### Relationship-Aware Comparison

Compare fields across joined tables. Find results where the driver's birth month matches the race month:

```julia
query = M.Result.objects
query.filter(
    F("driverId__dob__@month") == F("raceId__date__@month")
)
df = query |> DataFrame
```

PormG resolves the `__` paths, creates the necessary joins, and applies the `EXTRACT(MONTH FROM ...)` transform on both sides.

### Mixing F and Standard Filters

Combine `F()` comparisons with ordinary filter pairs when only part of the predicate needs an expression:

```julia
query = M.Result.objects
query.filter(
    F("driverId__dob__@day") == F("raceId__date__@day"),
    F("driverId__dob__@month") == F("raceId__date__@month"),
    "positionOrder__@lte" => 10,   # Standard scalar filter
)
df = query |> DataFrame
```

### Date Arithmetic

Find results within 30 days of the driver's birthday:

```julia
query = M.Result.objects
query.filter(
    F("raceId__date") > F("driverId__dob"),
    F("raceId__date") <= F("driverId__dob") + 30
)
```

### When NOT to Use F

For plain scalar comparisons, always prefer the suffix filter API:

```julia
# ✅ Preferred
query.filter("points__@gt" => 20, "grid" => 1)

# ❌ Works but not idiomatic
query.filter(F("points") > 20, F("grid") == 1)
```

---

## F Expressions in `values()`

Use `F()` inside `values()` to create **computed columns** directly in the SQL `SELECT`:

```julia
query = M.Result.objects
query.filter("statusId__status" => "Finished")
query.values(
    "driverId__surname",
    "points",
    "bonus" => F("points") * 0.1,
    "total" => F("points") + (F("points") * 0.1)
)
df = query |> DataFrame
```

This generates:
```sql
SELECT
    "Tb_1"."surname" as driverid__surname,
    "Tb"."points" as points,
    "Tb"."points" * 0.1 as bonus,
    "Tb"."points" + ("Tb"."points" * 0.1) as total
FROM ...
```

---

## Aliasing and Calculated Columns

In PormG, you don't need a separate `.annotate()` method (like Django). Aliases and computed columns are both created in `values()` using the `"alias" => expression` pair syntax.

### Simple Column Alias (Rename)

```julia
query = M.Driver.objects
query.values(
    "full_name" => "surname",   # Rename "surname" to "full_name"
    "code"
)
df = query |> DataFrame
# DataFrame columns: :full_name, :code
```

### Calculated Column (Expression)

```julia
query = M.Result.objects
query.values(
    "driverId__surname",
    "bonus_pts" => F("points") * 0.1   # Computed in the database
)
df = query |> DataFrame
```

### Reference vs. Calculation

| Syntax | What It Does | SQL |
| :--- | :--- | :--- |
| `"alias" => "field"` | Rename column | `SELECT "surname" AS "full_name"` |
| `"alias" => F("field") * 1.5` | Compute value | `SELECT "points" * 1.5 AS "alias"` |
| `"alias" => Sum("field")` | Aggregate | `SELECT SUM("points") AS "alias"` |

> [!TIP]
> Aliasing happens at the SQL level. This is significantly more efficient than renaming columns in a Julia DataFrame after the query finishes.

---

## Aggregate Arithmetic

Aggregate functions (`Sum`, `Count`, `Avg`, `Max`, `Min`) can participate in arithmetic. PormG automatically handles the `GROUP BY` and `HAVING` implications.

### In Projections

```julia
query = M.Result.objects
query.values(
    "driverId__surname",
    "points_per_result" => Sum("points") / Count("resultId")
)
df = query |> DataFrame
```

### In Filters (Auto-HAVING)

When a filter references an aggregate alias, PormG moves it to the `HAVING` clause:

```julia
query = M.Result.objects
query.values(
    "constructorId__name",
    "avg_perf" => Sum("points") / Count("resultId")
)
query.filter("avg_perf__@gt" => 5)
df = query |> DataFrame
```

PormG generates:
```sql
SELECT "constructorid__name", SUM("points") / COUNT("resultid") as avg_perf
FROM ...
GROUP BY 1
HAVING SUM("points") / COUNT("resultid") > $1
```

---

## F Expressions in Updates (Write Side)

F expressions are essential for **atomic updates** — modifying a column based on its current value without a read-modify-write cycle. This prevents race conditions and is usually more performant.

### Simple Arithmetic

```julia
# Increment points by 1
M.Result.objects.filter("resultId" => 1).update("points" => F("points") + 1)

# Apply a 10% penalty
M.Result.objects.filter("points__@gt" => 10).update("points" => F("points") * 0.9)
```

### Copy Column Values

Set one column equal to another column in the same row:

```julia
M.Just_a_test_deletion.objects.
    filter("id" => 5).
    update("test_result2" => F("test_result"))
```

### Complex Expressions

Combine multiple `F()` expressions in a single update:

```julia
M.Just_a_test_deletion.objects.update(
    "test_result2" => (F("test_result2") * 2) + F("test_result")
)
```

### Updates with Join-Based Filters

Filter by joined fields while updating the main table:

```julia
# Add 10 bonus points for all British drivers in result 1
M.Result.objects.filter(
    "driverId__nationality" => "British",
    "resultId" => 1
).update("points" => F("points") + 10)
```

> [!WARNING]
> You can **filter** by joined fields during an update, but you generally cannot **set** a column using a value from a joined table (e.g., `update("col" => F("joined__col"))`). Stick to expressions involving columns from the table being updated for maximum cross-database compatibility.

---

## Summary

| Feature | Example | Where |
| :--- | :--- | :--- |
| Field comparison | `F("grid") == F("positionOrder")` | `filter()` |
| Cross-join comparison | `F("driverId__dob__@month") == F("raceId__date__@month")` | `filter()` |
| Arithmetic column | `"bonus" => F("points") * 0.1` | `values()` |
| Aggregate ratio | `Sum("points") / Count("resultId")` | `values()` |
| Aggregate filter | `"avg__@gt" => 5` on an aggregate alias | `filter()` → HAVING |
| Column alias | `"name" => "surname"` | `values()` |
| Atomic update | `F("points") + 1` | `update()` |
| Column copy | `F("other_field")` | `update()` |

---

## Next Steps

- **[Q Objects](q_objects.md)** — Complex AND/OR logic with `Q()` and `Qor()`.
- **[Filters and Aggregates](filters_and_aggregates.md)** — Lookup operators and grouping.
- **[Writing: Updating Records](../write/update.md)** — Full update documentation.
