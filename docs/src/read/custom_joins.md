# Custom Join Documentation

## Overview

PormG provides a way to create custom join conditions using the chainable `.cjoin()` method on query handlers.

The `.cjoin()` method is the recommended approach as it's more flexible and allows you to specify join conditions when building queries, rather than at model definition time.

## `.cjoin()` Method 

The `.cjoin()` method allows you to add custom conditions to JOIN clauses at query time. This is particularly useful for:

1. **Legacy databases** where foreign key constraints don't exist
2. **Joining on non-ID fields** (e.g., joining on codes, names, or other unique identifiers)
3. **Adding extra conditions to the ON clause** beyond simple equality
4. **Complex multi-field joins** (e.g., multi-tenant systems where you need to match both tenant_id and another field)

## Key Features

- **Runtime flexibility** - Add join conditions when building queries
- **ON clause conditions** - Restrict the joined table during the JOIN itself
- **Full Q/Qor/operator suffix support** - Use the same filter syntax as .filter() for conditions that belong to the joined model
- **Automatic field prefixing** - Plain joined-model field names in join filters are automatically prefixed with the join path
- **F expressions** - Field-to-field comparisons in joins
- **Multi-tenant support** - Perfect for tenant isolation at join level
- **Nested joins** - Apply conditions to any level of join

## Installation

The `.cjoin()` method is built into the query builder handler, meaning no special function imports are required once you have loaded PormG:

```julia
using PormG, LibPQ   # load SQLite instead for a SQLite app
# Q, Qor, and F are automatically exported by PormG
```

## Basic Usage with `.cjoin()`

### Setup: Create Test Data

First, let's set up some test data. The `New_join_position` model has a `result` field (IntegerField) that we'll join to the `Result` model:

```julia
# Clear and populate test data
delete(M.New_join_position.objects, allow_delete_all = true)

M.New_join_position.objects.create("result" => 1, "description" => "teste 1")
M.New_join_position.objects.create("result" => 2, "description" => "teste 2")
M.New_join_position.objects.create("result" => 3, "description" => "teste 3")
```

### Simple Join

Create a custom join from an IntegerField to another model:

```julia
df = M.New_join_position.objects.
    cjoin("result" => "Result").
    values("result__statusid__status", "description", "result") |> DataFrame
```

# Output:
# 3x3 DataFrame
#  Row | result__statusid__status  description  result 
#      | String?                   String?      Int32?
# -----+------------------------------------------------
#    1 | Finished                  teste 1           1
#    2 | Finished                  teste 2           2
#    3 | Finished                  teste 3           3
```

The `.cjoin()` call creates a LEFT JOIN from `new_join_position.result` to `Result.resultid`, allowing you to traverse the relationship chain `result__statusid__status`.

### Join with Filter Conditions (LEFT JOIN)

Add conditions to the ON clause using fields from the joined model. When a row doesn't match the ON condition, the joined fields will be `missing`:

```julia
df = M.New_join_position.objects.
    cjoin("result" => "Result", filters=["resultid" => 1]).
    values("result__statusid__status", "description", "result") |> DataFrame
```

# Output:
# 3x3 DataFrame
#  Row | result__statusid__status    description  result 
#      | Union{Missing, String}      String?      Int32?
# -----+--------------------------------------------------
#    1 | Finished                    teste 1           1
#    2 | missing                     teste 2           2
#    3 | missing                     teste 3           3

Notice that only the row whose joined `Result.resultid` is `1` has the status because the filter is applied in the ON clause, not WHERE. This returns all 3 rows, but only one row matches the join condition.

### Join with Filter Conditions (INNER JOIN)

Use `join_type="INNER"` to only return rows that match the join condition:

```julia
df = M.New_join_position.objects.
    cjoin("result" => "Result", 
           filters=["resultid" => 1],
           join_type="INNER").
    values("result__statusid__status", "description", "result") |> DataFrame
```

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
df = M.New_join_position.objects.
    cjoin("result" => "Result", filters=[
        Q("statusid__status" => "Finished", Qor("positionorder" => 1, "positionorder" => 2))
    ]).
    values("result__statusid__status", "description") |> DataFrame
```

### Join with Driver Model (Q/Qor Example)

Here's a complete example joining Result to Driver with complex filter logic:

```julia
# Add custom join with recursive Q/Qor filters + WHERE clause filter
# Plain field names ("nationality", "forename") are automatically prefixed
df = M.Result.objects.
    cjoin("driverid" => "Driver", filters=[
        Q("nationality" => "Brazilian", Qor("forename" => "Ayrton", "forename" => "Nelson"))
    ]).
    filter("points" => 10).
    values("driverid__surname", "points") |> DataFrame
```

# Generated SQL (simplified):
# SELECT ... FROM result AS Tb
#   LEFT JOIN driver AS Tb_1 ON Tb.driverid = Tb_1.driverid 
#                           AND (Tb_1.nationality = ? AND (Tb_1.forename = ? OR Tb_1.forename = ?))
# WHERE Tb.points = ?
```

Notice that the cjoin filter parameters (`"Brazilian", "Ayrton", "Nelson"`) appear in the ON clause, while the regular filter parameter (`10` for points) appears in the WHERE clause.

## Understanding `.cjoin()` Behavior

### Contract of `.cjoin(filters=...)`

`.cjoin()` exists to modify the JOIN itself. Its `filters` are ON-clause predicates and should target fields on the joined model.

Use `.cjoin(..., filters=...)` when you want SQL like:

```sql
LEFT JOIN driver ON result.driverid = driver.driverid AND driver.nationality = ?
```

Use `.filter(...)` when you want to filter the main query rows in `WHERE`:

```sql
WHERE result.points > ?
```

This distinction matters:

- `.cjoin(filters=...)` is for joined-model predicates that belong in `ON`
- `.filter(...)` is for base-query predicates that belong in `WHERE`
- Passing base-table fields to `.cjoin(filters=...)` is not a good API contract and should be treated as unsupported usage

### Dedicated `on()` API for Existing Join Paths

When the join path already exists through the model graph, you do not need to redefine it with `.cjoin()` just to add ON-clause predicates. Use the chainable `query.on()` method instead:

```julia
df = M.Result.objects.
    on("driverid", "nationality" => "Brazilian", "code" => "SEN").
    values("resultid", "driverid__surname", "points") |> DataFrame
```

This keeps all base `Result` rows in the query tree while only attaching `Driver` rows that satisfy the ON predicates.

You can also override the join type directly from `query.on()`:

```julia
query = M.Result.objects.
    on("driverid", "nationality" => "Brazilian", join_type="INNER").
    values("resultid", "driverid__surname")
```

This changes the join keyword to `INNER JOIN` while keeping the predicate in the `ON` clause instead of moving it to `WHERE`.

### Reverse Join Example with `on()`

Reverse joins are the main use case for the dedicated API because they let you preserve base rows while limiting which related rows attach.

```julia
df = M.Result.objects.
    on("test_deletion", "name__@in" => ["reverse-join-a", "reverse-join-b"]).
    filter("resultid__@in" => [1, 2, 3]).
    values("resultid", "test_deletion__name") |> DataFrame
```

With the default `LEFT` semantics, all three `Result` rows remain, but only the matching reverse rows are attached. If you want only the matched base rows, switch to `join_type="INNER"` on the same `on()` call.

!!! tip
    **Chained Reverse Paths**: You can also use `on()` through chained reverse paths. For example, `query.on("test_deletion", "just_a_nested_roll_back__description" => "nested-value")` will correctly apply the `ON`-clause predicate deep within the reversed relationship traversal chain.

### Contract of `on()`

- `query.on("path", ...)` targets an existing join path, including reverse joins such as `"test_deletion"` and nested paths such as `"raceid__circuitid"`
- multiple predicates are combined with `AND` unless you use `Qor(...)`
- repeated `on()` calls for the same path merge additional predicates into the same `ON` clause
- `.filter(...)` keeps its existing `WHERE` semantics and is not silently rewritten into `ON`

### When `.cjoin()` is Applied

The `.cjoin()` configuration is only applied when you access fields through the join path:

```julia
# cjoin is NOT applied - no join path used in values()
df = M.New_join_position.objects.
    cjoin("result" => "Result", filters=["resultid" => 1]) |> DataFrame  # Returns all 3 rows with default columns

# cjoin IS applied - accessing result__* fields
df = M.New_join_position.objects.
    cjoin("result" => "Result", filters=["resultid" => 1]).
    values("result__statusid__status", "description", "result") |> DataFrame  # Join is created with ON conditions
```

If you need to filter the base table at the same time, do it explicitly with `.filter(...)`:

```julia
query = M.New_join_position.objects.
    cjoin("result" => "Result", filters=["resultid" => 1]).
    filter("description" => "teste 1").
    values("result__statusid__status", "description", "result")
```

### Generated SQL

You can inspect the generated SQL using `show_query`:

```julia
query = M.New_join_position.objects.
    cjoin("result" => "Result", filters=["resultid" => 1]).
    values("result__statusid__status", "description", "result")

@info query |> show_query

# Output:
# SELECT
#    "Tb_2"."status" as result__statusid__status,
#    "Tb"."description" as description,
#    "Tb"."result" as result
# FROM "new_join_position" as "Tb"
#  LEFT JOIN "result" AS "Tb_1" ON "Tb"."result" = "Tb_1"."resultid" 
#                                  AND "Tb_1"."resultid" = \$1
#  LEFT JOIN "status" AS "Tb_2" ON "Tb_1"."statusid" = "Tb_2"."statusid"
```

## Full-Control ON Clauses with `.cjoin_on()` (#45)

`.cjoin()` and `.on()` always emit a base equi-anchor (`main.field = target.pk`) and AND-append
filters that must target the **single joined model**. When you need the *entire* ON clause to be
your own — an arbitrary boolean (top-level `OR`), field-to-field comparisons across **both** sides
(a self-join), or SQL functions in the ON — use **`.cjoin_on()`**.

```julia
query.cjoin_on("Model"; alias="b2", on=[ ... ], join_type="INNER")
```

- **`"Model"`** — the model to join (may be the query's **own** model, for a self-join).
- **`alias`** — the SQL alias for the joined copy. Reference its columns as `F("alias.column")`.
- **`on`** — the expressions that form the **entire** ON clause. No equi-anchor is added.
- **`join_type`** — defaults to `"INNER"`.

### Reference convention

Inside `on`, the two sides of the join are named by how you write `F(...)`:

| You write | Resolves to |
|-----------|-------------|
| `F("col")` (bare) | the **base/main** table (the query's own alias) |
| `F("b2.col")` | the **joined copy** declared by this `cjoin_on` (its `alias`) |

This is unambiguous even in a self-join, where both sides share every column name.

### Self-join example

Find, for each lap, other laps in the same race — or the same driver+lap — or the same calendar
year of the timestamp:

```julia
query = M.Lap.objects
query.cjoin_on("Lap"; alias="b2", join_type="INNER", on=[
  Qor(
    F("b2.raceid") == F("raceid"),
    Q(F("b2.driverid") == F("driverid"), F("b2.lap") == F("lap")),
    F("b2.dt__@year") == F("dt__@year"),          # year() on both sides — dialect-aware
  ),
])
query.values("id")
```

**Generated SQL (SQLite** — PostgreSQL renders `$n` placeholders and `EXTRACT(YEAR FROM …)`**):**

```sql
SELECT "Tb"."id" as "id"
FROM "laps" as "Tb"
 INNER JOIN "laps" AS "b2" ON (
       ("b2"."raceid" = "Tb"."raceid")
    OR (("b2"."driverid" = "Tb"."driverid") AND ("b2"."lap" = "Tb"."lap"))
    OR (CAST(strftime('%Y', "b2"."dt") AS INTEGER) = CAST(strftime('%Y', "Tb"."dt") AS INTEGER))
 )
```

No `main.field = target.pk` anchor is emitted — the `on` expression **is** the ON clause. Bound
parameters from `on` route to the JOIN clause (ahead of any WHERE parameters).

!!! note "Cross-side references use `F()`"
    Reference the joined copy with `F("alias.col")`. Alias-qualified **operator pairs**
    (`"b2.col__@gte" => 3`) are not supported yet — express a joined-side comparison-to-literal by
    restructuring, or filter the base side with a bare pair (`"col__@gte" => 3`). Referencing a
    *third* table (another join's alias) inside one `cjoin_on` is also out of scope for now, and a
    predicate that all relocates onto a later join leaves this one with no `ON` clause of its own,
    which raises `QueryBuildError` (#435).

    **A CTE cannot be referenced from an `ON` clause at all.** A `CTE(name, path)` inside `on`
    raises `FilterError`: an `ON` clause targets the joined *model*, and a CTE is joined by its own
    `.with(...)` declaration. Put the predicate in `.filter(...)` instead (#444).

    One CTE-related collision still reaches the `ON` machinery: a `cjoin_on` **alias** spelled the
    same as an unkeyed (CROSS-joined) CTE's name. That collision hands the CTE this join's
    predicates, and a `CROSS JOIN` has no `ON` clause to carry them — so PormG raises
    `QueryBuildError` rather than dropping them and matching every row (#424). Rename the alias,
    give the CTE a `join_field`, or move the predicate to `.filter(...)` (#44).

    `cjoin_on` works in reads and in the common `update()`/`delete()` (which scope rows via a
    subquery); only a **correlated** UPDATE-FROM/DELETE-USING (setting a column *from* a joined
    table) is unsupported and raises. Finally, a `cjoin_on` join is not tracked by the #74
    aggregate fan-out guard — if the join is to-many, aggregate the base table with `distinct=true`
    (or over the joined table's own column) to avoid silent row multiplication.

!!! warning "Give the join a predicate that names its own alias"
    Every predicate in `on` that references a join emitted *after* this one is moved onto that
    join — it has to be, because a join cannot reference an alias that has not appeared yet. If
    **all** of them move, your join is left with no `ON` clause and PormG raises, naming the alias
    they went to (#435):

    ```julia
    query = M.Result.objects
    query.values("points")
    query.cjoin_on("Driver", alias = "d", on = ["raceid__circuitid__country" => "Italy"])
    # ERROR: Every ON predicate given for d resolved onto Tb_2 instead, …
    ```

    **The fix depends on whether your predicates name the alias at all**, and the two cases pull
    in opposite directions. The error message tells you which one you are in.

    *Nothing names it* — as above. The join has nothing correlating it. Add a predicate that does
    (`F("d.driverid") == F("driverid")`), or move the conditions to `.filter(...)` and drop the
    `cjoin_on` entirely — it needs at least one `on` predicate, so moving them all out without
    removing the call raises too.

    Here, **do not** "fix" it by projecting the path in `values(...)` first. That builds those
    joins ahead of the `cjoin_on`, so nothing needs to move and the query renders — as
    `INNER JOIN "driver" AS "d" ON "Tb_2"."country" = ?`, an `ON` clause that never mentions `d`.
    That is an unconstrained join: every `driver` row against every qualifying base row, silently.
    The error is the better outcome.

    *It names the alias and a deeper path* — `on = [F("d.nationality") == F("raceid__circuitid__country")]`,
    drivers racing in their home country — is a real correlation that moved only because the join
    on its other side is built later. Projecting **is** the fix here: add
    `raceid__circuitid__country` to `values(...)` and the clause renders exactly as written.

    *It names the alias and another `cjoin_on` alias* — there is no path to project, so declare
    the predicate on whichever of the two PormG emits **later**; the reference then points
    backwards and nothing moves. The error message names that join for you. Give the first join an
    `ON` predicate of its own as well — it is still joined, and `cjoin_on` requires at least one:

    ```julia
    # ✗ before — d1's only predicate names d2, which is emitted after it
    query.cjoin_on("Driver", alias = "d1", on = [F("d1.surname") == F("d2.surname")])
    query.cjoin_on("Driver", alias = "d2", on = [F("d2.driverid") == F("driverid")])

    # ✓ after — the shared predicate moves to d2, and d1 gets one of its own
    query.cjoin_on("Driver", alias = "d1", on = [F("d1.driverid") == F("driverid")])
    query.cjoin_on("Driver", alias = "d2", on = [F("d2.surname") == F("d1.surname")])
    ```

    (Which of two `cjoin_on` aliases is emitted first is currently decided by alias hashing rather
    than declaration order — [#449](https://github.com/PingoLee/PormG.jl/issues/449).)

    More generally, PormG checks that the join *has* an `ON` clause, not that the clause
    constrains it — `on = ["points__@gt" => 10]` renders and multiplies rows just the same
    ([#448](https://github.com/PingoLee/PormG.jl/issues/448)). Make sure at least one predicate
    names the alias you gave.

## Use Cases

### 1. Legacy Databases Without Foreign Keys

When your database doesn't have proper foreign key constraints:

```julia
# Join on a code field instead of ID
query = M.Order.objects.
    cjoin("product_code" => "Product").  # Joins on product_code = Product.code
    values("product_code__name", "quantity")
```

### 2. Multi-Tenant Systems

Add tenant isolation at the join level:

```julia
query = M.Invoice.objects.
    cjoin("customer_id" => "Customer", 
            filters=["tenant_id" => current_tenant_id]).
    values("customer_id__name", "amount")
```

### 3. Conditional Joins with Complex Logic

Join only when certain conditions are met using Q/Qor:

```julia
query = M.Result.objects.
    cjoin("driverid" => "Driver",
            filters=[Q("nationality" => "British", Qor("code" => "HAM", "code" => "BUT"))],
            join_type="INNER").
    values("driverid__forename", "driverid__surname", "points")
```

This creates: `ON ... AND (driver.nationality = ? AND (driver.code = ? OR driver.code = ?))`

### 4. Driver Filtering (Real-World Example)

Find results for drivers of a specific nationality with specific names:

```julia
# Add both a custom join condition and a regular filter
query = M.Result.objects.
    cjoin("driverid" => "Driver", filters=[
        Q("nationality" => "Brazilian", Qor("forename" => "Ayrton", "forename" => "Nelson"))
    ]).
    filter("points__@gt" => 0).  # Regular WHERE clause filter
    values("driverid__forename", "driverid__surname", "points")

df = query |> DataFrame

# Result: Only Brazilian drivers named Ayrton or Nelson with points > 0
```

## API Reference

```julia
query.cjoin(main_join; filters=[], field=nothing, join_type="LEFT")
```

### Arguments

| Argument | Type | Description |
|----------|------|-------------|
| `main_join` | `Pair{String, String}` | Field name => Target model name (e.g., `"result" => "Result"`) |
| `filters` | `Vector` | Optional conditions for the ON clause. Supports `Pair`, `Q()`, `Qor()`, operator suffixes, or F expressions. Plain field names in filters are automatically prefixed with the join path. |
| `field` | `PormGField` | Optional custom field definition |
| `join_type` | `String` | Join type: `"LEFT"`, `"INNER"`, `"RIGHT"`, `"FULL"` (default: `"LEFT"`) |

### Filter Types in `.cjoin()`

- **Pair filters**: `"field" => value` - Plain field names are automatically prefixed (e.g., `"nationality"` → `"driverid__nationality"`)
- **Q filters**: `Q("field1" => val1, "field2" => val2)` - AND logic; plain field names are prefixed recursively
- **Qor filters**: `Qor("field1" => val1, "field2" => val2)` - OR logic; plain field names are prefixed recursively
- **Operator suffix filters**: Complex operator-based filters using the suffix operator system (e.g., `"nationality__@ne" => "British"`)
- **F expressions**: Field-to-field comparisons (e.g., `F("field1") == F("field2")`)

## Important Notes

### Parameter Placement

When using `.cjoin()` with filters:
- **Join filter parameters** (from `filters=`) are placed in the **ON clause** of the JOIN and should reference joined-model fields
- **Regular filter parameters** (from `.filter()`) are placed in the **WHERE clause**

This is important for query efficiency and correctness:

```julia
# This parameter goes to WHERE clause, cjoin filters go to ON clause
query = M.Result.objects.
    filter("points" => 10).
    cjoin("driverid" => "Driver", filters=["nationality" => "Brazilian"])

# Result SQL:
# ... ON driver.driverid = result.driverid AND driver.nationality = ?
# WHERE result.points = ?
```

### Field Name Normalization

When you provide plain field names in `.cjoin()` filters, they are automatically prefixed with the join field to resolve them against the joined model:

```julia
# "nationality" is automatically prefixed to "driverid__nationality"
query = M.Result.objects.cjoin("driverid" => "Driver", filters=["nationality" => "Brazilian"])

# This works with Q and Qor too:
query = M.Result.objects.cjoin("driverid" => "Driver", filters=[
  Q("nationality" => "Brazilian", Qor("forename" => "Ayrton", "forename" => "Nelson"))
])

# All three fields (nationality, forename, forename) are auto-prefixed
```

If a field belongs to the base model instead, keep it in `.filter(...)` rather than `.cjoin(...)`:

```julia
query = M.New_join_position.objects.
    cjoin("result" => "Result", filters=["resultid" => 1]).
    filter("description" => "teste 1")
```

### ForeignKey Target Validation

When a join field already has a defined `ForeignKey` on the model, `.cjoin()` validates that the target model matches:

```julia
# This works: Result.driverid FK points to Driver
query = M.Result.objects.
    cjoin("driverid" => "Driver", filters=["nationality" => "Brazilian"]).
    values("driverid__surname")

# This raises an error: driverid points to Driver, not Constructor
query = M.Result.objects.
    cjoin("driverid" => "Constructor", filters=["name" => "Ferrari"])  
# QueryBuildError: Field 'driverid' is already a ForeignKey pointing to 'Driver', 
# but `.cjoin()` attempted to join with 'Constructor'...
# Use query.cjoin("driverid" => "Driver", filters=[...]) instead.
```

**Why this validation exists:** If a ForeignKey target is mismatched, field prefixing would resolve against the wrong model, silently breaking your filters. By enforcing target model matching, `.cjoin()` ensures ON-condition filters always apply to the correct joined model.

### Auto-Discovery Warning (No Explicit FK Link)

If the source field in `main_join` is **not** a ForeignKey field and you do not pass `field=...`, `.cjoin()` auto-discovers the target model primary key and logs a **warning by default** to ensure you are joining intentionally.

Example:

```julia
# "result" is an IntegerField, not a ForeignKey
query = M.New_join_position.objects.cjoin("result" => "Result")

# cjoin warns and auto-links:
# main.result -> Result.resultid   (or the model PK)
```

#### If your intended link is not the target model PK

Pass an explicit field mapping:

```julia
query = M.New_join_position.objects.cjoin("result" => "Result",
      field=Models.ForeignKey("Result", pk_field="your_target_field"))
```

This keeps behavior explicit and avoids accidental joins to the wrong target column.

#### If you intentionally want auto-discovery without the warning

You can suppress the warning using the `warn` parameter:

```julia
# Suppress the auto-discovery warning
query = M.New_join_position.objects.cjoin("result" => "Result", warn=false)
```

This is useful when you're confident about the join link and don't want the informational message in production logs.

### Other features are in development and will be documented soon.
