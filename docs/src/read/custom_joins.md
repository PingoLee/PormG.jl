# Custom Join Documentation

## Overview

PormG provides a way to create custom join conditions using the `cjoin()` function.

The `cjoin()` function is the recommended approach as it's more flexible and allows you to specify join conditions when building queries, rather than at model definition time.

## cjoin() Function 

The `cjoin()` function allows you to add custom conditions to JOIN clauses at query time. This is particularly useful for:

1. **Legacy databases** where foreign key constraints don't exist
2. **Joining on non-ID fields** (e.g., joining on codes, names, or other unique identifiers)
3. **Adding extra conditions to the ON clause** beyond simple equality
4. **Complex multi-field joins** (e.g., multi-tenant systems where you need to match both tenant_id and another field)

## Key Features

- **Runtime flexibility** - Add join conditions when building queries
- **ON clause conditions** - Restrict the joined table during the JOIN itself
- **Full Q/Qor/OP support** - Use the same filter syntax as .filter() for conditions that belong to the joined model
- **Automatic field prefixing** - Plain joined-model field names in join filters are automatically prefixed with the join path
- **F expressions** - Field-to-field comparisons in joins
- **Multi-tenant support** - Perfect for tenant isolation at join level
- **Nested joins** - Apply conditions to any level of join

## Installation

The `cjoin` function is included in PormG. Simply import it:

```julia
using PormG
import PormG: cjoin, Q, Qor, OP, F
```

## Basic Usage with cjoin()

### Setup: Create Test Data

First, let's set up some test data. The `New_join_position` model has a `result` field (IntegerField) that we'll join to the `Result` model:

```julia
# Clear and populate test data
delete(M.New_join_position.objects, allow_delete_all = true)

query = M.New_join_position.objects
query.create("result" => 1, "description" => "teste 1")
query.create("result" => 2, "description" => "teste 2")
query.create("result" => 3, "description" => "teste 3")
```

### Simple Join

Create a custom join from an IntegerField to another model:

```julia
query = M.New_join_position.objects
cjoin(query, "result" => "Result")
query.values("result__statusid__status", "description", "result")

df = query |> DataFrame

# Output:
# 3x3 DataFrame
#  Row | result__statusid__status  description  result 
#      | String?                   String?      Int32?
# -----+------------------------------------------------
#    1 | Finished                  teste 1           1
#    2 | Finished                  teste 2           2
#    3 | Finished                  teste 3           3
```

The `cjoin` creates a LEFT JOIN from `new_join_position.result` to `Result.resultId`, allowing you to traverse the relationship chain `result__statusid__status`.

### Join with Filter Conditions (LEFT JOIN)

Add conditions to the ON clause using fields from the joined model. When a row doesn't match the ON condition, the joined fields will be `missing`:

```julia
query = M.New_join_position.objects
cjoin(query, "result" => "Result", filters=["resultid" => 1])
query.values("result__statusid__status", "description", "result")

df = query |> DataFrame

# Output:
# 3x3 DataFrame
#  Row | result__statusid__status    description  result 
#      | Union{Missing, String}      String?      Int32?
# -----+--------------------------------------------------
#    1 | Finished                    teste 1           1
#    2 | missing                     teste 2           2
#    3 | missing                     teste 3           3
```

Notice that only the row whose joined `Result.resultid` is `1` has the status because the filter is applied in the ON clause, not WHERE. This returns all 3 rows, but only one row matches the join condition.

### Join with Filter Conditions (INNER JOIN)

Use `join_type="INNER"` to only return rows that match the join condition:

```julia
query = M.New_join_position.objects
cjoin(query, "result" => "Result", 
  filters=["resultid" => 1],
      join_type="INNER")
query.values("result__statusid__status", "description", "result")

df = query |> DataFrame

# Output:
# 1x3 DataFrame
#  Row | result__statusid__status  description  result 
#      | String?                   String?      Int32?
# -----+------------------------------------------------
#    1 | Finished                  teste 1           1
```

Only the row joined to `Result.resultid = 1` is returned because the INNER JOIN excludes non-matching rows.

### Join with Q/Qor Filters (AND/OR Logic)

Use `Q()` for AND logic and `Qor()` for OR logic in join conditions. Plain field names are automatically prefixed with the join path:

```julia
# Plain fields are auto-prefixed: "statusid__status" and nested fields work too
query = M.New_join_position.objects
cjoin(query, "result" => "Result", filters=[
  Q("statusid__status" => "Finished", Qor("positionorder" => 1, "positionorder" => 2))
])
query.values("result__statusid__status", "description")

df = query |> DataFrame
```

### Join with Driver Model (Q/Qor Example)

Here's a complete example joining Result to Driver with complex filter logic:

```julia
query = M.Result.objects

# Add custom join with recursive Q/Qor filters
# Plain field names ("nationality", "forename") are automatically prefixed
cjoin(query, "driverid" => "Driver", filters=[
  Q("nationality" => "Brazilian", Qor("forename" => "Ayrton", "forename" => "Nelson"))
])

# This also adds a regular filter to WHERE clause
query.filter("points" => 10)
query.values("driverid__surname", "points")

df = query |> DataFrame

# Generated SQL (simplified):
# SELECT ... FROM result AS Tb
#   LEFT JOIN driver AS Tb_1 ON Tb.driverid = Tb_1.driverid 
#                           AND (Tb_1.nationality = ? AND (Tb_1.forename = ? OR Tb_1.forename = ?))
# WHERE Tb.points = ?
```

Notice that the cjoin filter parameters (`"Brazilian", "Ayrton", "Nelson"`) appear in the ON clause, while the regular filter parameter (`10` for points) appears in the WHERE clause.

## Understanding cjoin Behavior

### Contract of `cjoin(filters=...)`

`cjoin` exists to modify the JOIN itself. Its `filters` are ON-clause predicates and should target fields on the joined model.

Use `cjoin(..., filters=...)` when you want SQL like:

```sql
LEFT JOIN driver ON result.driverid = driver.driverid AND driver.nationality = ?
```

Use `.filter(...)` when you want to filter the main query rows in `WHERE`:

```sql
WHERE result.points > ?
```

This distinction matters:

- `cjoin(filters=...)` is for joined-model predicates that belong in `ON`
- `.filter(...)` is for base-query predicates that belong in `WHERE`
- Passing base-table fields to `cjoin(filters=...)` is not a good API contract and should be treated as unsupported usage

### Dedicated `on()` API for Existing Join Paths

When the join path already exists through the model graph, you do not need to redefine it with `cjoin()` just to add ON-clause predicates. Use the chainable `query.on()` method instead:

```julia
query = M.Result.objects
query.on("driverid", "nationality" => "Brazilian", "code" => "SEN")
query.values("resultid", "driverid__surname", "points")

df = query |> DataFrame
```

This keeps all base `Result` rows in the query tree while only attaching `Driver` rows that satisfy the ON predicates.

You can also override the join type directly from `query.on()`:

```julia
query = M.Result.objects
query.on("driverid", "nationality" => "Brazilian", join_type="INNER")
query.values("resultid", "driverid__surname")
```

This changes the join keyword to `INNER JOIN` while keeping the predicate in the `ON` clause instead of moving it to `WHERE`.

### Reverse Join Example with `on()`

Reverse joins are the main use case for the dedicated API because they let you preserve base rows while limiting which related rows attach.

```julia
query = M.Result.objects
query.on("test_deletion", "name__@in" => ["reverse-join-a", "reverse-join-b"])
query.filter("resultid__@in" => [1, 2, 3])
query.values("resultid", "test_deletion__name")

df = query |> DataFrame
```

With the default `LEFT` semantics, all three `Result` rows remain, but only the matching reverse rows are attached. If you want only the matched base rows, switch to `join_type="INNER"` on the same `on()` call.

> [!TIP]
> **Chained Reverse Paths**: You can also use `on()` through chained reverse paths. For example, `query.on("test_deletion", "just_a_nested_roll_back__description" => "nested-value")` will correctly apply the `ON`-clause predicate deep within the reversed relationship traversal chain.

### Contract of `on()`

- `query.on("path", ...)` targets an existing join path, including reverse joins such as `"test_deletion"` and nested paths such as `"raceid__circuitid"`
- multiple predicates are combined with `AND` unless you use `Qor(...)`
- repeated `on()` calls for the same path merge additional predicates into the same `ON` clause
- `.filter(...)` keeps its existing `WHERE` semantics and is not silently rewritten into `ON`

### When cjoin is Applied

The `cjoin` configuration is only applied when you access fields through the join path:

```julia
# cjoin is NOT applied - no join path used in values()
query = M.New_join_position.objects
cjoin(query, "result" => "Result", filters=["resultid" => 1])
df = query |> DataFrame  # Returns all 3 rows with default columns

# cjoin IS applied - accessing result__* fields
query = M.New_join_position.objects
cjoin(query, "result" => "Result", filters=["resultid" => 1])
query.values("result__statusid__status", "description", "result")
df = query |> DataFrame  # Join is created with ON conditions
```

If you need to filter the base table at the same time, do it explicitly with `.filter(...)`:

```julia
query = M.New_join_position.objects
cjoin(query, "result" => "Result", filters=["resultid" => 1])
query.filter("description" => "teste 1")
query.values("result__statusid__status", "description", "result")
```

### Generated SQL

You can inspect the generated SQL using `show_query`:

```julia
query = M.New_join_position.objects
cjoin(query, "result" => "Result", filters=["resultid" => 1])
query.values("result__statusid__status", "description", "result")

@info query |> show_query

# Output:
# SELECT
#    "Tb_2"."status" as result__statusid__status,
#    "Tb"."description" as description,
#    "Tb"."result" as result
# FROM "new_join_position" as "Tb"
#  LEFT JOIN "result" AS "Tb_1" ON "Tb"."result" = "Tb_1"."resultid" 
#                                  AND "Tb_1"."resultid" = $1
#  LEFT JOIN "status" AS "Tb_2" ON "Tb_1"."statusid" = "Tb_2"."statusid"
```

## Use Cases

### 1. Legacy Databases Without Foreign Keys

When your database doesn't have proper foreign key constraints:

```julia
# Join on a code field instead of ID
query = M.Order.objects
cjoin(query, "product_code" => "Product")  # Joins on product_code = Product.code
query.values("product_code__name", "quantity")
```

### 2. Multi-Tenant Systems

Add tenant isolation at the join level:

```julia
query = M.Invoice.objects
cjoin(query, "customer_id" => "Customer", 
      filters=["tenant_id" => current_tenant_id])
query.values("customer_id__name", "amount")
```

### 3. Conditional Joins with Complex Logic

Join only when certain conditions are met using Q/Qor:

```julia
query = M.Result.objects
cjoin(query, "driverid" => "Driver",
      filters=[Q("nationality" => "British", Qor("code" => "HAM", "code" => "BUT"))],
      join_type="INNER")
query.values("driverid__forename", "driverid__surname", "points")
```

This creates: `ON ... AND (driver.nationality = ? AND (driver.code = ? OR driver.code = ?))`

### 4. Driver Filtering (Real-World Example)

Find results for drivers of a specific nationality with specific names:

```julia
query = M.Result.objects

# Add both a custom join condition and a regular filter
cjoin(query, "driverid" => "Driver", filters=[
  Q("nationality" => "Brazilian", Qor("forename" => "Ayrton", "forename" => "Nelson"))
])

query.filter("points__@gt" => 0)  # Regular WHERE clause filter
query.values("driverid__forename", "driverid__surname", "points")

df = query |> DataFrame

# Result: Only Brazilian drivers named Ayrton or Nelson with points > 0
```

## API Reference

```julia
cjoin(query, main_join; filters=[], field=nothing, join_type="LEFT")
```

### Arguments

| Argument | Type | Description |
|----------|------|-------------|
| `query` | `SQLObjectHandler` | The query object to add the join to |
| `main_join` | `Pair{String, String}` | Field name => Target model name (e.g., `"result" => "Result"`) |
| `filters` | `Vector` | Optional conditions for the ON clause. Supports `Pair`, `Q()`, `Qor()`, OP, or F expressions. Plain field names in filters are automatically prefixed with the join path. |
| `field` | `PormGField` | Optional custom field definition |
| `join_type` | `String` | Join type: `"LEFT"`, `"INNER"`, `"RIGHT"`, `"FULL"` (default: `"LEFT"`) |

### Filter Types in cjoin

- **Pair filters**: `"field" => value` - Plain field names are automatically prefixed (e.g., `"nationality"` → `"driverid__nationality"`)
- **Q filters**: `Q("field1" => val1, "field2" => val2)` - AND logic; plain field names are prefixed recursively
- **Qor filters**: `Qor("field1" => val1, "field2" => val2)` - OR logic; plain field names are prefixed recursively
- **OP filters**: Complex operator-based filters with the same prefixing behavior
- **F expressions**: Field-to-field comparisons (e.g., `F("field1") == F("field2")`)

## Important Notes

### Parameter Placement

When using `cjoin` with filters:
- **Join filter parameters** (from `filters=`) are placed in the **ON clause** of the JOIN and should reference joined-model fields
- **Regular filter parameters** (from `.filter()`) are placed in the **WHERE clause**

This is important for query efficiency and correctness:

```julia
query = M.Result.objects

# This parameter goes to WHERE clause
query.filter("points" => 10)

# These parameters go to ON clause (join condition)
cjoin(query, "driverid" => "Driver", filters=["nationality" => "Brazilian"])

# Result SQL:
# ... ON driver.driverid = result.driverid AND driver.nationality = ?
# WHERE result.points = ?
```

### Field Name Normalization

When you provide plain field names in `cjoin` filters, they are automatically prefixed with the join field to resolve them against the joined model:

```julia
# "nationality" is automatically prefixed to "driverid__nationality"
cjoin(query, "driverid" => "Driver", filters=["nationality" => "Brazilian"])

# This works with Q and Qor too:
cjoin(query, "driverid" => "Driver", filters=[
  Q("nationality" => "Brazilian", Qor("forename" => "Ayrton", "forename" => "Nelson"))
])

# All three fields (nationality, forename, forename) are auto-prefixed
```

If a field belongs to the base model instead, keep it in `.filter(...)` rather than `cjoin(...)`:

```julia
query = M.New_join_position.objects
cjoin(query, "result" => "Result", filters=["resultid" => 1])
query.filter("description" => "teste 1")
```

### ForeignKey Target Validation

When a join field already has a defined `ForeignKey` on the model, `cjoin()` validates that the target model matches:

```julia
# This works: Result.driverid FK points to Driver
query = M.Result.objects
cjoin(query, "driverid" => "Driver", filters=["nationality" => "Brazilian"])
query.values("driverid__surname")

# This raises an error: driverid points to Driver, not Constructor
query = M.Result.objects
cjoin(query, "driverid" => "Constructor", filters=["name" => "Ferrari"])  
# ArgumentError: Field 'driverid' is already a ForeignKey pointing to 'Driver', 
# but cjoin attempted to join with 'Constructor'...
```

**Why this validation exists:** If a ForeignKey target is mismatched, field prefixing would resolve against the wrong model, silently breaking your filters. By enforcing target model matching, `cjoin()` ensures ON-condition filters always apply to the correct joined model.

### Auto-Discovery Warning (No Explicit FK Link)

If the source field in `main_join` is **not** a ForeignKey field and you do not pass `field=...`, `cjoin()` auto-discovers the target model primary key and logs a **warning by default** to ensure you are joining intentionally.

Example:

```julia
# "result" is an IntegerField, not a ForeignKey
query = M.New_join_position.objects
cjoin(query, "result" => "Result")

# cjoin warns and auto-links:
# main.result -> Result.resultid   (or the model PK)
```

#### If your intended link is not the target model PK

Pass an explicit field mapping:

```julia
cjoin(query, "result" => "Result",
  field=Models.ForeignKey("Result", pk_field="your_target_field"))
```

This keeps behavior explicit and avoids accidental joins to the wrong target column.

#### If you intentionally want auto-discovery without the warning

You can suppress the warning using the `warn` parameter:

```julia
# Suppress the auto-discovery warning
cjoin(query, "result" => "Result", warn=false)
```

This is useful when you're confident about the join link and don't want the informational message in production logs.

### Other features are in development and will be documented soon.
