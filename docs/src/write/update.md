# Updating Records

PormG allows you to update existing records efficiently using filters, relationship lookups, and database-level expressions.

## Instance Updates with `row.save()`

Use `row.save()` when you have already fetched exactly one model row and want to persist assignments made to that row.

```julia
driver = M.Driver.objects.get("driverref" => "hamilton")

driver.nationality = "British"
driver.save()
```

**Generated SQL (PostgreSQL):**
```sql
UPDATE "driver" 
SET "nationality" = $2 
WHERE "driverid" = $1
-- Parameters: [driver_id, "British"]
```

Only fields assigned on the row are included in the generated `UPDATE`. The primary key must be present on the row, and models with no primary key or multiple primary keys are rejected.

Inspection modes work the same way as other write methods, but they do not execute the update or clear the row's dirty state:

```julia
driver = M.Driver.objects.get("driverref" => "hamilton")
driver.forename = "Lewis"

sql = driver.save(show_query=:sql)
# row is still dirty; call driver.save() to execute
```

**Generated SQL (PostgreSQL):**
```sql
UPDATE "driver" 
SET "forename" = $2 
WHERE "driverid" = $1
-- Parameters: [driver_id, "Lewis"]
```

Rows can also save projected foreign-key fields selected through `values(...)`. In this example, the assignment targets the related `Driver` table, not the `Result` table:

```julia
result = M.Result.objects.
  filter("resultid" => 1).
  values("resultid", "driverid", "driverid__nationality").
  get()

result.driverid__nationality = "British"
result.save()
```

**Generated SQL (PostgreSQL):**
```sql
UPDATE "driver" 
SET "nationality" = $2 
WHERE "driverid" = $1
-- Parameters: [driver_id, "British"]
```

If you need to change both the foreign-key value and projected fields under that same foreign key, save those changes in two steps so PormG can route each update unambiguously.

## Single Record Updates

Update specific records by applying a filter to the model's objects and then calling `.update()`.

```julia
# Update a single record
query = M.Driver.objects;
query.filter("forename" => "Lewis");

# Verify current state
df = query |> DataFrame
# Row 1: nationality="British"

# Perform update
query.update("nationality" => "Xylos")
```

**Generated SQL (PostgreSQL):**
```sql
UPDATE "driver" AS "Tb" 
SET "nationality" = $2 
WHERE "Tb"."forename" = $1
-- Parameters: ["Lewis", "Xylos"]
```

```julia
# Verify the update
df = query |> DataFrame
# Row 1: nationality="Xylos"

# Restore state
query.update("nationality" => "British")
```

### Updating Multiple Fields

```julia
query = M.Race.objects;
query.filter("raceid" => 1);
query.update(
    "name" => "Australian Grand Prix",
    "date" => Date(2024, 3, 24),
    "round" => 1
)

# Use show_query=:sql to see the generated SQL
sql = query.update(
    "name" => "Australian Grand Prix",
    "date" => Date(2024, 3, 24),
    "round" => 1,
    show_query=:sql
)
```

Generated SQL:
```sql
UPDATE "race" AS "Tb"
SET "name" = $2, "date" = $3, "round" = $4
WHERE "Tb"."raceid" = $1
```

### Automatic Validation

All updates pass through a centralized validation engine that enforces:
- **Primary Key Protection**: You cannot update a Primary Key field.
- **Max Length**: Strings are checked against the model's `max_length`.
- **Numeric Precision**: `DecimalField` and `FloatField` are checked for `max_digits` and `decimal_places`.
- **Nullability**: Attempts to set non-nullable fields to `nothing` or `missing` will throw an error.
- **ForeignKey Scalars**: FK fields accept scalar primary-key values, including `0`; use `nothing` or `missing` only when you intend SQL `NULL` on a nullable relation field.

### Pagination Guard

Standard SQL `UPDATE` does not support `LIMIT`, `OFFSET`, or `ORDER BY`. If any of these are set on the query handler when `.update()` is called, PormG throws an `ArgumentError` immediately — before any SQL is generated — so the developer gets a clear error rather than silently mutating the wrong rows.

```julia
# These all raise ArgumentError before any SQL is sent
q = M.Driver.objects.filter("nationality" => "British")
q.limit(5).update("nationality" => "English")   # ERROR: UPDATE with LIMIT is not supported
q.offset(2).update("nationality" => "English")  # ERROR: UPDATE with OFFSET is not supported
q.order_by("driverid").update("nationality" => "English")  # ERROR: UPDATE with ORDER BY is not supported
```

Because `limit()`, `offset()`, and `order_by()` mutate the handler in place (last-call model), create a fresh handler for the update if you also need pagination elsewhere:

```julia
# Read the first 5 British drivers
read_q = M.Driver.objects.filter("nationality" => "British")
read_q.limit(5)
top5 = read_q.list()

# Update ALL British drivers on a separate handler
update_q = M.Driver.objects.filter("nationality" => "British")
update_q.update("nationality" => "English")
```

### `change_data` Guard

If the connection is configured with `change_data: false`, any call to `.update()` raises an `ArgumentError` at the ORM layer before generating SQL. This applies to both normal execution and `show_query=:dict` dry-runs.

```julia
# connection.yml: change_data: false
query = M.Driver.objects.filter("driverid" => 1)
query.update("forename" => "Blocked")
# ERROR: Not allowed to update ...
```

See [Connection YML](../configuration/connection_yml.md) for the `change_data` configuration option.

---

## Updates with Relationships

PormG supports updating records based on filter criteria spanning related tables.

```julia
# Update records matching a joined condition
query = M.Result.objects;
query.filter("driverid__nationality" => "British", "resultid" => 1);
query.update("points" => F("points") + 10)
```

**Generated SQL (PostgreSQL):**
```sql
UPDATE "result" AS "Tb" 
SET "points" = "Tb"."points" + 10 
FROM "driver" AS "Tb_1" 
WHERE "Tb"."driverid" = "Tb_1"."driverid" 
  AND "Tb_1"."nationality" = $1 
  AND "Tb"."resultid" = $2
-- Parameters: ["British", 1]
```

```julia
# Update with complex relationship traversal
query = M.Result.objects;
query.filter("raceid__circuitid__name__@icontains" => "Monaco", "resultid" => 7654);
query.update("points" => 11)
```

**Generated SQL (PostgreSQL):**
```sql
UPDATE "result" AS "Tb" 
SET "points" = 11 
FROM "race" AS "Tb_1", "circuit" AS "Tb_2" 
WHERE "Tb"."raceid" = "Tb_1"."raceid" 
  AND "Tb_1"."circuitid" = "Tb_2"."circuitid" 
  AND "Tb_2"."name" ILIKE $1 
  AND "Tb"."resultid" = $2
-- Parameters: ["Monaco", 7654]
```

---

## F Expressions

`F` expressions allow database-level operations without loading data into Julia, similar to Django's F objects. This is highly efficient for increments, decrements, and copying values between columns.

### Basic F Expression Usage

```julia
# Increment a counter field directly in the database
query = M.Driver.objects;
query.filter("driverid" => 1);
query.update("number" => F("number") + 1)
```

**Generated SQL (PostgreSQL):**
```sql
UPDATE "driver" AS "Tb" 
SET "number" = "Tb"."number" + 1 
WHERE "Tb"."driverid" = $1
-- Parameters: [1]
```

```julia
# Set one field equal to another
query.update("number" => F("driverid"))
```

**Generated SQL (PostgreSQL):**
```sql
UPDATE "driver" AS "Tb" 
SET "number" = "Tb"."driverid" 
WHERE "Tb"."driverid" = $1
-- Parameters: [1]
```

### Supported Mathematical Operations

All basic mathematical operations are supported within the database context using `F`.

```julia
query = M.Just_a_test_deletion.objects;

# Addition
query.update("test_result2" => F("test_result") + 1)

# Multiplication  
query.update("test_result2" => F("test_result2") * 2)

# Division
query.update("test_result2" => F("test_result2") / 2)

# Combining multiple F expressions
query.update("test_result2" => F("test_result") + F("test_result"))

# Subtraction
query.update("test_result2" => F("test_result2") - 1)
```

### F Expressions with Relationships

You can reference fields from related models within an `F` expression. PormG will automatically handle the necessary `JOIN` or `FROM` clause logic.

```julia
query = M.Result.objects;
query.filter("resultid" => 3);

# Update using a value from the joined Driver model
query.update("grid" => F("driverid__number"))

# Deep relationship traversal
query.update("positiontext" => F("raceid__circuitid__country"))
```

**Generated SQL Example:**
```sql
UPDATE "result" AS "Tb"
SET "positiontext" = "Tb_2"."country"
FROM "race" AS "Tb_1", "circuit" AS "Tb_2"
WHERE "Tb"."raceid" = "Tb_1"."raceid" 
  AND "Tb_1"."circuitid" = "Tb_2"."circuitid" 
  AND "Tb"."resultid" = $1
```
