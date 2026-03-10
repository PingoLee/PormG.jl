# Field Expressions (F Objects)

This page documents advanced query tools for database-side expressions and arithmetic.

- `F()`: Database-side field references and arithmetic.

!!! note "Disclaimer for Django Users"
    While PormG's `F()` is inspired by Django, there are key differences:
    - **Native Operators**: PormG leverages Julia's operator overloading (e.g., `F("a") + F("b")`), whereas Django often requires specific methods or internal expression objects.
    - **Aggregate Integration**: PormG allows seamless mixing of `F()` with aggregate functions like `Sum()` or `Count()` directly in arithmetic expressions (e.g., `Sum("points") / Count("id")`).
    - **Logic Placement**: PormG's engine automatically detects when an expression involves aggregates and moves it to the `HAVING` clause, simplifying query construction.

## Why Field Expressions?

Standard queries compare fields to constant values (e.g., `points == 10`). `F` (Field) expressions allow you to:
1. **Compare fields to other fields** in the same row or related rows.
2. **Perform arithmetic in the database** (e.g., incrementing values, calculating ratios).
3. **Reference related fields** across joins without manual SQL.

Use `F()` when the right-hand side is another field or a derived database expression. For plain scalar comparisons, prefer the normal filter syntax such as `"points__@gt" => 20`.

### F() vs Constant Filters

| Task | Preferred Form | F Expression |
| :--- | :--- | :--- |
| **Scalar comparison** | `"points__@gt" => 10` | N/A |
| **Field-to-field comparison** | N/A | `F("points") == F("grid")` |
| **Arithmetic** | N/A (Julia-side only) | `F("points") + 5` |

!!! tip "Prefer suffix filters for scalar values"
    `F("points") > 10` currently works, but it is not the idiomatic public style in PormG. Reserve `F()` comparisons for column-to-column or column-to-expression predicates, and use `"field__@operator" => value` for scalar filters.

## Core Syntax and Arithmetic

```julia
using PormG.QueryBuilder: F, Count, Sum

# Field reference
F("grid")

# Arithmetic in the database
F("points") + 5                   # Addition
F("points") * F("laps")           # Multiplication
F("points") / 2.0                 # Division
Sum("points") / Count("resultid") # Aggregate ratios
```

Supported arithmetic operators: `+`, `-`, `*`, `/`.

## Comparison Operators

Left-side `F()` expressions support standard Julia comparison operators that are translated to SQL:

| Operator | SQL Equivalent |
| :--- | :--- |
| `==` | `=` |
| `!=` | `<>` |
| `>` | `>` |
| `<` | `<` |
| `>=` | `>=` |
| `<=` | `<=` |

These operators are most useful when the comparison cannot be written cleanly with the standard suffix filter API.

## Using F Expressions in Filters

### 1. Field-to-Field Comparison
Find records where the starting grid position was exactly the finishing position.

```julia
query = M.Result.objects
query.filter(F("grid") == F("positionorder"))
```

### 2. Relationship-Aware Comparison
Find results where the driver's birth month matches the race month.

```julia
query = M.Result.objects
query.filter(
    F("driverid__dob__@month") == F("raceid__date__@month")
)
```

### 2b. Mixed F and Standard Filters
Mix `F()` comparisons with ordinary filters when only part of the predicate needs an expression.

```julia
query = M.Result.objects
query.filter(
    F("driverid__dob__@day") == F("raceid__date__@day"),
    F("driverid__dob__@month") == F("raceid__date__@month"),
    "min_grid__@gt" => 0,
)
```

### 3. Date Arithmetic
Find results within 30 days of the driver's birthday.

```julia
query = M.Result.objects
query.filter(
    F("raceid__date") > F("driverid__dob"),
    F("raceid__date") <= F("driverid__dob") + 30
)
```

### 4. Prefer Standard Filters for Scalars

```julia
query = M.Result.objects
query.filter(
    "points__@gt" => 20,
    "grid" => 1,
)
```

This is clearer than writing `F("points") > 20` or `F("grid") == 1`, because the predicate is still just field-versus-literal filtering.

## F Expressions in `values()`

Use `F()` inside `values()` to create derived columns directly in the SELECT clause.

```julia
query = M.Result.objects
query.filter("statusid__status" => "Finished")
query.values(
    "driverid__surname",
    "points",
    # Dynamic calculation
    "bonus" => F("points") * 0.1,
    "total" => F("points") + (F("points") * 0.1)
)
df = query |> DataFrame
```

## Aliasing and Calculated Columns

In PormG, you don't need a separate method like Django's `.annotate()`. You create new columns or rename existing ones directly within `.values()` or `.list()` using pairs.

### Simple Column Aliasing
You can rename any field by providing a `"new_name" => "field_name"` pair.

```julia
query = M.Driver.objects
query.values(
    "full_name" => "surname",  # Rename database column 'surname' to 'full_name' in results
    "code"
)
df = query |> DataFrame
# Resulting DataFrame has columns: :full_name, :code
```

### Calculated Columns (Expressions)
When using `F()` for a calculation, you provide an alias to name the resulting column.

```julia
query = M.Result.objects
query.values(
    "driverid__surname",
    # Creates a 'bonus_pts' column calculated in the database
    "bonus_pts" => F("points") * 0.1
)
df = query |> DataFrame
```

### Reference vs. Calculation
- **String reference**: `"alias" => "field"` (Simple rename).
- **F-Expression**: `"alias" => F("field") * 1.5` (Calculated value).

!!! tip "Performance Note"
    PormG's aliasing happens at the SQL level (`SELECT "surname" AS "full_name"`). This is significantly more efficient than renaming columns in a Julia DataFrame after the query finishes.

## Aggregate Arithmetic (HAVING)

Aggregates can participate in arithmetic. If used in a filter, PormG automatically moves the condition to the `HAVING` clause.

### Calculation in Projections
```julia
query = M.Result.objects
query.values(
    "driverid__surname",
    "points_per_result" => Sum("points") / Count("resultid")
)
```

### Filtering on Aggregate Calculation (HAVING)
```julia
query = M.Result.objects
query.values(
    "constructorid__name",
    "avg_perf" => Sum("points") / Count("resultid")
)
query.filter("avg_perf__@gt" => 5) # Filter on the calculated aggregate result
```

## Field Expressions in Updates (Write Side)

F expressions are essential for performing **atomic updates** directly in the database. This prevents race conditions (read-modify-write) and is usually more performant.

### 1. Simple Arithmetic Updates
Increment, decrement, or scale values based on their current state.

```julia
# Increment points by 1 for a specific result
M.Result.objects.filter("resultid" => 1).update("points" => F("points") + 1)

# Apply a 10% penalty to points
M.Result.objects.filter("points__@gt" => 10).update("points" => F("points") * 0.9)
```

### 2. Copying Columns
You can set a column's value to match another column in the same row.

```julia
# Sync 'results' with another field
M.Just_a_test_deletion.objects.filter("id" => 5).update("test_result2" => F("test_result"))
```

### 3. Complex Expressions in Updates
PormG supports combining multiple `F()` expressions and constants in a single update.

```julia
# Set result to (current_val * 2) + offset
M.Just_a_test_deletion.objects.update(
    "test_result2" => (F("test_result2") * 2) + F("test_result")
)
```

### 4. Updates with Join Filters
You can use join-based filters to target which rows to update, even if the update itself targets the main table.

```julia
# Increase points for all British drivers in a specific result
M.Result.objects.filter(
    "driverid__nationality" => "British", 
    "resultid" => 1
).update("points" => F("points") + 10)
```

!!! warning "Limitations on Joins"
    While you can **filter** by joined fields (FK-traversal) during an update, you generally cannot update a column using a value from a joined table directly (e.g., `update("col" => F("joined__col"))`) in all dialects. Stick to expressions involving columns of the table being updated for maximum compatibility.

