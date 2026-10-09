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
updated = query.update("nationality" => "Xylos")
# updated == 1
```

**Generated SQL (PostgreSQL):**
```sql
UPDATE "driver" AS "Tb" 
SET "nationality" = $2 
WHERE "Tb"."forename" = $1
-- Parameters: ["Lewis", "Xylos"]
```

`.update()` returns an `Integer` with the number of rows matched by the `WHERE` clause, following Django's update contract. This can be `0` when no rows match. A matched row is counted even if the assigned value is identical to the existing value.

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
- **Numeric Precision**: `DecimalField` values are checked for `max_digits`, `decimal_places`, and the `max_digits - decimal_places` digits allowed before the point (see [`DecimalField`](../fields.md#DecimalField(max_digits,-decimal_places))).
- **Nullability**: Attempts to set non-nullable fields to `nothing` or `missing` will throw an error.
- **Single Values**: A `Vector` or a tuple set on a text-like field (`CharField`, `TextField`, …) raises `InvalidValueError` naming the field, whatever its elements, on both backends. `JSONField` and `BinaryField` values are unaffected: each is serialized to one value first.
- **ForeignKey Scalars**: FK fields accept scalar primary-key values, including `0`; use `nothing` or `missing` only when you intend SQL `NULL` on a nullable relation field.

### Pagination Guard

!!! warning "`UPDATE` cannot carry `LIMIT`, `OFFSET` or `ORDER BY`"
    Standard SQL `UPDATE` does not support them. If any is set on the query handler when
    `.update()` is called, PormG raises `UnsafeMutationError` immediately — before any SQL is
    generated — so you get a clear error rather than a silent mutation of the wrong rows. There is
    no "update the first N rows" form; narrow the filter instead.

```julia
# These all raise UnsafeMutationError before any SQL is sent
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

### Projections Are Ignored

An `UPDATE` has no projection, so `.update()` ignores any `values()` set on the handler. The
statement binds only the `SET` values and the filter values, which means a handler you just read
from can be updated as is. A filter on a `values()` **alias** is the exception. On a read, that
filter resolves through the projection: an aggregate alias as a `HAVING` predicate, and any other
alias as the projected expression in `WHERE`. (An alias that reuses a field's name makes the read's
filter ambiguous, and it raises `AmbiguousFieldError`.) An `UPDATE` carries no projection, so PormG
would have to drop the filter or apply it to a different expression. It raises
`UnsafeMutationError` instead. Filter on the underlying field.

```julia
q = M.Result.objects.filter("raceid" => 1034)
q.values("driverid__surname", "double_points" => F("points") * 2)
rows = q.list()                    # the read uses the projection
q.update("positiontext" => "D")    # the projection is ignored; still scoped to raceid 1034

q.filter("double_points__@gt" => 20)
q.update("positiontext" => "D")    # ERROR: UnsafeMutationError — filter on "points__@gt" => 10 instead
```

### `change_data` Guard

If the connection is configured with `change_data: false`, any call to `.update()` raises a `WritesDisabledError` at the ORM layer before generating SQL. This applies to both normal execution and `show_query=:dict` dry-runs.

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
SET "points" = ("Tb"."points" + $3::bigint)
WHERE "Tb"."resultid" IN (SELECT DISTINCT "Tb"."resultid"
  FROM "result" as "Tb"
  INNER JOIN "driver" AS "Tb_1" ON "Tb"."driverid" = "Tb_1"."driverid"
  WHERE "Tb_1"."nationality" = $1 AND "Tb"."resultid" = $2)
  AND EXISTS (SELECT 1 FROM (SELECT 1) AS "__pormg_anchor"
  INNER JOIN "driver" AS "Tb_1" ON "Tb"."driverid" = "Tb_1"."driverid"
  WHERE "Tb_1"."nationality" = $4 AND "Tb"."resultid" = $5)
-- Parameters: ["British", 1, 10, "British", 1]
```

A filter that crosses a relation renders twice. The `IN (…)` selects rows through the primary key,
so the planner can use its index. The correlated `EXISTS` puts the same filters on the row being
updated, so they are re-checked if the row changes while the `UPDATE` waits on its lock — see
[Filters are a fence on PostgreSQL](delete.md#Filters-are-a-fence-on-PostgreSQL), which applies to
`update()` the same way. The joins are the ones a read of the filter renders (a nullable foreign key
stays a `LEFT JOIN`). A model without a primary key gets the `EXISTS` alone.

```julia
# Update with complex relationship traversal
query = M.Result.objects;
query.filter("raceid__circuitid__name__@icontains" => "Monaco", "resultid" => 7654);
query.update("points" => 11)
```

**Generated SQL (PostgreSQL):**
```sql
UPDATE "result" AS "Tb"
SET "points" = $3
WHERE "Tb"."resultid" IN (SELECT DISTINCT "Tb"."resultid"
  FROM "result" as "Tb"
  INNER JOIN "race" AS "Tb_1" ON "Tb"."raceid" = "Tb_1"."raceid"
  INNER JOIN "circuit" AS "Tb_2" ON "Tb_1"."circuitid" = "Tb_2"."circuitid"
  WHERE "Tb_2"."name" ILIKE $1 ESCAPE '\' AND "Tb"."resultid" = $2)
  AND EXISTS (SELECT 1 FROM (SELECT 1) AS "__pormg_anchor"
  INNER JOIN "race" AS "Tb_1" ON "Tb"."raceid" = "Tb_1"."raceid"
  INNER JOIN "circuit" AS "Tb_2" ON "Tb_1"."circuitid" = "Tb_2"."circuitid"
  WHERE "Tb_2"."name" ILIKE $4 ESCAPE '\' AND "Tb"."resultid" = $5)
-- Parameters: ["%Monaco%", 7654, 11, "%Monaco%", 7654]
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

### Setting a column from a `cjoin_on` copy

A [`cjoin_on`](../read/custom_joins.md) join can supply the new value too: pass `Joined(alias, column)`
as the value, directly or inside a SQL function. The join's `ON` clause becomes part of the
statement's `WHERE`, so a row is updated only when the join matches:

```julia
query = M.Result.objects
query.filter("raceid" => 18)
# Only results of British drivers match the join, so only those rows are updated.
query.cjoin_on("Driver", alias = "d", on = [
  Joined("d", "driverid") == F("driverid"),
  Joined("d", "nationality") => "British",
])
query.update("positiontext" => Joined("d", "code"))
```

```sql
UPDATE "result" AS "Tb"
SET "positiontext" = "d"."code"
FROM "driver" AS "d"
WHERE ("d"."driverid" = "Tb"."driverid") AND "d"."nationality" = $2 AND "Tb"."raceid" = $1
```

The statement joins in its `WHERE` clause, which only means what the `cjoin_on` says under two
conditions. PormG checks both, for **every** `cjoin_on` in the query, and raises `QueryBuildError`
when either fails:

- **The join is `INNER`** (the default), and so is every relation join in the statement. A `LEFT`,
  `RIGHT` or `FULL` join would act as an inner one and skip the rows it was declared to keep. A
  nullable foreign key is joined `LEFT`, so a path through one, named in the `ON` clause or anywhere
  else in the query, is refused too.
- **The join is to-one**: its `ON` clause pins the target's primary key or a unique column to one value
  per row (the rule is in [Custom Joins](../read/custom_joins.md), under *When PormG treats a
  `cjoin_on` join as to-many*).
  Otherwise the database would set each row from an arbitrary one of its matches.
