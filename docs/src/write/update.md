# Updating Records

PormG allows you to update existing records efficiently using filters, relationship lookups, and database-level expressions.

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

# Use show_query=true to see the generated SQL
query.update(
    "name" => "Australian Grand Prix",
    "date" => Date(2024, 3, 24),
    "round" => 1,
    show_query=true
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

---

## Updates with Relationships

PormG supports updating records based on filter criteria spanning related tables.

```julia
# Update records matching a joined condition
query = M.Result.objects;
query.filter("driverid__nationality" => "British", "resultid" => 1);
query.update("points" => F("points") + 10)

# Update with complex relationship traversal
query = M.Result.objects;
query.filter("raceid__circuitid__name__@icontains" => "Monaco", "resultid" => 7654);
query.update("points" => 11)
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

# Set one field equal to another
query.update("number" => F("driverid"))
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
