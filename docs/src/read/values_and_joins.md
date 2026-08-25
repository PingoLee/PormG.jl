# Values and Joins

This page covers column selection, relation traversal with `__`, join types, reverse joins, wildcard selection, aliases, and common patterns.

---

## How Joins Work in PormG

PormG uses the double-underscore `__` notation (inspired by Django) to traverse relationships. When you reference a field like `driverid__surname`, PormG:

1. **Resolves** `driverid` as a ForeignKey relationship on the model.
2. **Creates** the appropriate SQL `JOIN` automatically.
3. **Selects** the `surname` column from the joined `Driver` table.

You never write raw `JOIN` statements — PormG builds them from your model definitions.

---

## Basic Field Selection

Select specific columns from the main table:

```julia
query = M.Result.objects
query.filter("statusid__status" => "Engine")
query.values("resultid", "statusid")
df = query |> DataFrame
```

This generates a simple `SELECT ... FROM ... WHERE` without any joins, since `resultid` and `statusid` are local columns on the `Result` table.

---

## Joined Field Selection

Select columns from related tables using `__`:

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

PormG generates:

```sql
SELECT 
    "Tb"."resultid" as "resultid",
    "Tb_1"."forename" as "driverid__forename",
    "Tb_2"."name" as "constructorid__name",
    "Tb_3"."status" as "statusid__status",
    "Tb"."grid" as "grid",
    "Tb"."laps" as "laps"
FROM "result" as "Tb"
    INNER JOIN "driver" AS "Tb_1" ON "Tb"."driverid" = "Tb_1"."driverid"
    INNER JOIN "constructor" AS "Tb_2" ON "Tb"."constructorid" = "Tb_2"."constructorid"
    INNER JOIN "status" AS "Tb_3" ON "Tb"."statusid" = "Tb_3"."statusid"
WHERE "Tb_3"."status" = $1
```

!!! note
    PormG uses table aliases (`Tb`, `Tb_1`, `Tb_2`, …) automatically. You never need to manage aliases yourself. Each joined table gets a sequential alias.

!!! warning "No lazy FK traversal — project related columns up front"
    PormG never lazily loads a related row. Accessing a `ForeignKey` or `OneToOneField`
    you did not project (`row.driverid`, or traversing further with
    `row.driverid.forename`) raises a `LazyTraversalError`. Project what you need up
    front with `values(...)`, then read it off the row by its key:

    ```julia
    # ✗ raises: driverid was not projected, and PormG won't lazily load it
    row = M.Result.objects.values("resultid", "points").first()
    driver_name = row.driverid.forename

    # ✓ project the related column, then read it
    row = M.Result.objects.values("resultid", "driverid__forename").first()
    driver_name = row[:driverid__forename]

    # ✓ or project the raw foreign-key value
    row = M.Result.objects.values("resultid", "driverid").first()
    driver_id = row[:driverid]
    ```

---

## Multi-Level Joins

Chain `__` segments to traverse multiple relationships:

```julia
query = M.Result.objects
query.filter("raceid__circuitid__country" => "Monaco")
query.values(
    "driverid__forename",
    "raceid__circuitid__name",
    "raceid__year"
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
query.values("constructorid", "name", "result__points")
query.filter("result__positionorder" => 1) # Filter for winning constructors
df = query |> DataFrame
```

### Naming Reverse Relations

By default, the name used to traverse backwards is the **lowercase name of the source model** (e.g., `result` for `Result`) — as long as that model declares exactly **one** relation to the target.

When a model declares **two or more** relations to the same target, one name cannot address them all, so PormG suffixes **every** member of that group with its own field name: `<model>_<field>`. No member keeps the bare model name, and PormG logs each derived name at `@info` when the models are registered.

```julia
# Incident points at Driver twice, so neither reverse accessor is the bare `incident`:
Incident = Models.Model("incident",
  id = Models.IDField(),
  causing_driver_id  = Models.ForeignKey(Driver, pk_field="id"),
  affected_driver_id = Models.ForeignKey(Driver, pk_field="id"),
)

query = M.Driver.objects
query.values("surname", "incident_causing_driver_id__lap")
```

The count spans relation kinds: a `ManyToManyField` to the same target counts toward the group too, which is why a model carrying both a self-`ForeignKey` and a self-`ManyToManyField` gets two distinct accessors instead of one collision.

Whenever you would rather read a name than derive it — and always when the group is larger than a pair — define a `related_name` on the field. An explicit name always wins:

```julia
# Model definition snippet
# "test_deletion" becomes the reverse traversal key from Result
test_result = Models.ForeignKey(Result, pk_field="resultid", related_name="test_deletion")
```

```julia
# Querying using the related_name
query = M.Result.objects
query.values("resultid", "test_deletion__name")
```

### Chained Multi-Hop Reverse Joins

PormG supports traversing multiple relationships in reverse, seamlessly chaining backward hops. Continuing from the previous example, if a `Just_a_nested_roll_back` model has a FK to `Just_a_test_deletion`:

```julia
# Result ← test_deletion (related_name) ← just_a_nested_roll_back (lowercase model name)
query = M.Result.objects
query.filter("test_deletion__just_a_nested_roll_back__description" => "nested-value")
query.values("resultid", "test_deletion__just_a_nested_roll_back__id")
```

---

## Wildcard Selection with `*`

Use `"*"` to select all columns from the main table, then add specific joined fields:

```julia
query = M.Result.objects
query.filter("driverid__nationality" => "Brazilian")
query.values("*", "driverid__surname", "driverid__forename")
df = query |> DataFrame
```

This selects every column from `Result` plus `surname` and `forename` from the joined `Driver` table.

!!! info "Important"
    Queries that use `.cjoin()` **must** call `.values(...)` explicitly before execution. A bare `SELECT *` across joined tables causes `DataFrames.jl` to crash with `ArgumentError: Duplicate variable names`. Use `.values("*", "joined__field")` to safely include joined columns.

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
query.filter("statusid__status" => "Finished", "resultid" => 26745)
query.values(
    "resultid",
    "circuit" => "raceid__circuitid__name"
)
df = query |> DataFrame
# DataFrame columns: :resultid, :circuit
```

### Alias with Date Transforms

```julia
query = M.Result.objects
query.filter("statusid__status" => "Finished", "resultid" => 26745)
query.values(
    "resultid",
    "circuit" => "raceid__circuitid__name",
    "quarter" => "raceid__date__@quarter"
)
df = query |> DataFrame
# DataFrame columns: :resultid, :circuit, :quarter
```

### Alias with Aggregates and F-Expressions

```julia
query = M.Result.objects
query.values(
    "driver" => "driverid__surname",
    "total_pts" => Sum("points"),
    "bonus" => F("points") * 0.1
)
```

### Mixed-Case and Unicode Aliases

All aliases are quoted in the generated SQL (`AS "alias"`), so the exact name you provide is preserved — including uppercase letters and Unicode characters:

```julia
df = M.Driver.objects.filter("driverref" => "hamilton").
    values("Surname" => "surname", "localização" => "nationality") |> DataFrame
# DataFrame columns: :Surname, Symbol("localização")
# PostgreSQL would fold these to lowercase without quoting
```

!!! note
    Alias identifiers must start with a Unicode letter or underscore, followed by letters, combining marks, digits, or underscores. Aliases containing spaces, punctuation, or other special characters throw an `InvalidValueError` at query-build time.

!!! tip
    Aliasing happens at the SQL level (`SELECT "field" AS "alias"`). This is more efficient than renaming columns in a Julia DataFrame after the query.

---

## Common Patterns

### Filter by Related Fields

```julia
# All results for British drivers
query = M.Result.objects
query.filter("driverid__nationality" => "British")
```

### Select Across Multiple Relations

```julia
# Full race result detail
query = M.Result.objects
query.values(
    "positionorder",
    "driverid__forename",
    "driverid__surname",
    "constructorid__name",
    "raceid__name",
    "raceid__circuitid__country"
)
```

### Combine Multiple Joins in One Filter

Multiple filter pairs involving different joins are ANDed together:

```julia
# British drivers at Monaco
query = M.Result.objects
query.filter(
    "driverid__nationality" => "British",
    "raceid__circuitid__name__@icontains" => "monaco"
)
```

### Aggregate Across Joins

```julia
# Wins per constructor
query = M.Result.objects
query.filter("positionorder" => 1)
query.values("constructorid__name", "wins" => Count("resultid"))
query.order_by("-wins")
df = query |> DataFrame
```

### Join Path in Filters Only (No Explicit `values()`)

When you filter on a joined field but don't call `values()`, PormG still creates the join for the `WHERE` clause but selects `*` from the main table:

```julia
# Returns all Result columns, filtered by driver nationality
df = M.Result.objects.filter("driverid__nationality" => "British") |> DataFrame
```

---

## Next Steps

- **[Filters and Aggregates](filters_and_aggregates.md)** — Learn about lookup operators (`@gt`, `@in`, `@contains`, …) and grouping.
- **[Custom Joins](custom_joins.md)** — Use `.cjoin()` for non-FK joins and `.on()` for ON-clause predicates.