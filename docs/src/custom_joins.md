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
- **ON clause conditions** - More efficient than WHERE clause filtering
- **Full Q/Qor/OP support** - Use the same filter syntax as .filter()
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

Add conditions to the ON clause. When a row doesn't match the condition, the joined fields will be `missing`:

```julia
query = M.New_join_position.objects
cjoin(query, "result" => "Result", filters=["description" => "teste 1"])
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

Notice that only "teste 1" has the status because the filter is applied in the ON clause, not WHERE. This returns all 3 rows but only "teste 1" matches the join condition.

### Join with Filter Conditions (INNER JOIN)

Use `join_type="INNER"` to only return rows that match the join condition:

```julia
query = M.New_join_position.objects
cjoin(query, "result" => "Result", 
      filters=["description" => "teste 1"],
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

Only "teste 1" is returned because the INNER JOIN excludes non-matching rows.

## Understanding cjoin Behavior

### When cjoin is Applied

The `cjoin` configuration is only applied when you access fields through the join path:

```julia
# cjoin is NOT applied - no join path used in values()
query = M.New_join_position.objects
cjoin(query, "result" => "Result", filters=["description" => "teste 1"])
df = query |> DataFrame  # Returns all 3 rows with default columns

# cjoin IS applied - accessing result__* fields
query = M.New_join_position.objects
cjoin(query, "result" => "Result", filters=["description" => "teste 1"])
query.values("result__statusid__status", "description", "result")
df = query |> DataFrame  # Join is created with ON conditions
```

### Generated SQL

You can inspect the generated SQL using `show_query`:

```julia
query = M.New_join_position.objects
cjoin(query, "result" => "Result", filters=["description" => "teste 1"])
query.values("result__statusid__status", "description", "result")

@info query |> show_query

# Output:
# SELECT
#    "Tb_2"."status" as result__statusid__status,
#    "Tb"."description" as description,
#    "Tb"."result" as result
# FROM "new_join_position" as "Tb"
#  LEFT JOIN "result" AS "Tb_1" ON "Tb"."result" = "Tb_1"."resultid" 
#                                  AND "Tb"."description" = $1
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

### 3. Conditional Joins

Join only when certain conditions are met:

```julia
query = M.Result.objects
cjoin(query, "driverid" => "Driver",
      filters=["nationality" => "British"],
      join_type="INNER")
query.values("driverid__forename", "points")
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
| `filters` | `Vector` | Optional conditions for the ON clause |
| `field` | `PormGField` | Optional custom field definition |
| `join_type` | `String` | Join type: `"LEFT"`, `"INNER"`, `"RIGHT"`, `"FULL"` (default: `"LEFT"`) |

### Other features are in development and will be documented soon.
