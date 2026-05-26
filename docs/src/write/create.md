# Creating Records

PormG provides methods for inserting data into your database, from single rows to complex related objects. All create operations are **async-aware** and will automatically participate in a transaction context if one is active.

## Single Record Creation

Use the `.create()` method to insert individual records. It returns a `Dict` containing the newly created record, including any database-generated fields (like auto-increment primary keys).

```julia
# Load your models (preferred: hot-reload-friendly, self-registering)
PormG.@import_models "db/models.jl" models
import .models as M

# Create a new record
new_record = M.Just_a_test_deletion.objects.create("name" => "test", "test_result" => 1)
```

**Generated SQL (PostgreSQL):**
```sql
INSERT INTO "just_a_test_deletion" ("name", "test_result") 
VALUES ($1, $2) 
RETURNING *
-- Parameters: ["test", 1]
```

### Return Value

The return value is a `Dict{Symbol, Any}` with all fields of the inserted record:

```julia
Dict{Symbol, Any} with 4 entries:
  :id           => 172              # Auto-generated primary key
  :name         => "test"
  :test_result  => 1
  :test_result2 => missing          # Null/unset fields show as missing
```

You can access returned values immediately:

```julia
new_record = M.Driver.objects.create(
    "forename" => "Lewis",
    "surname" => "Hamilton",
    "nationality" => "British",
    "driverref" => "hamilton",
    "dob" => Date(1985, 1, 7)
)
```

**Generated SQL (PostgreSQL):**
```sql
INSERT INTO "driver" ("forename", "surname", "nationality", "driverref", "dob") 
VALUES ($1, $2, $3, $4, $5) 
RETURNING *
-- Parameters: ["Lewis", "Hamilton", "British", "hamilton", '1985-01-07']
```

```julia
# Access the auto-generated ID
driver_id = new_record[:driverid]

# Use it in subsequent operations
race_result = M.Result.objects.create(
    "driverid" => driver_id,
    "raceid" => 1,
    "constructorid" => 1,
    "positionorder" => 1
)
```

**Generated SQL (PostgreSQL):**
```sql
INSERT INTO "result" ("driverid", "raceid", "constructorid", "positionorder") 
VALUES ($1, $2, $3, $4) 
RETURNING *
-- Parameters: [driver_id, 1, 1, 1]
```

### Validation

PormG validates that all non-nullable fields are provided. If a required field is missing, it will raise an `ArgumentError`.

```julia
# This will fail because the 'driverref' field is required (NOT NULL)
driver = M.Driver.objects.create(
    "forename" => "Lewis",
    "surname" => "Hamilton",
    "nationality" => "British",
    "dob" => Date(1985, 1, 7)
    # Missing: driverref
)
```

**Error:**
```julia
ERROR: ArgumentError: Error in insert, the field driverref not allow null
```

### Default Values

Fields with default values don't need to be specified:

```julia
# If 'created_at' has a default like CURRENT_TIMESTAMP, you can omit it
record = M.Status.objects.create("status" => "Finished")
# created_at will be set automatically to the current timestamp
```

**Generated SQL (PostgreSQL):**
```sql
INSERT INTO "status" ("status") 
VALUES ($1) 
RETURNING *
-- Parameters: ["Finished"]
```

### Generated Fields

Primary key fields with `GENERATED ALWAYS AS IDENTITY` or auto-increment are created automatically:

```julia
# Don't provide an ID—the database generates it
record = M.Driver.objects.create(
    "forename" => "Max",
    "surname" => "Verstappen",
    "nationality" => "Dutch",
    "driverref" => "max_verstappen",
    "dob" => Date(1997, 4, 1)
)

# The returned dict includes the generated ID
generated_id = record[:driverid]
```

**Generated SQL (PostgreSQL):**
```sql
INSERT INTO "driver" ("forename", "surname", "nationality", "driverref", "dob") 
VALUES ($1, $2, $3, $4, $5) 
RETURNING *
-- Parameters: ["Max", "Verstappen", "Dutch", "max_verstappen", '1997-04-01']
```

## Creating with Relationships

To create a record with a `ForeignKey` relationship, you need the ID of the related record. You can either:
1. Create the related record first and use its returned ID
2. Use an existing ID from the database

### Example: Race with Circuit

```julia
# Step 1: Create the related record (Circuit)
circuit = M.Circuit.objects.create(
    "name" => "Monaco",
    "country" => "Monaco",
    "circuitref" => "monaco",
    "location" => "Monte Carlo",
    "lat" => 43.7347,
    "lng" => 7.4206,
    "alt" => 5,
    "url" => "https://en.wikipedia.org/wiki/Circuit_de_Monaco"
)
```

**Generated SQL for Step 1 (PostgreSQL):**
```sql
INSERT INTO "circuit" ("name", "country", "circuitref", "location", "lat", "lng", "alt", "url") 
VALUES ($1, $2, $3, $4, $5, $6, $7, $8) 
RETURNING *
-- Parameters: ["Monaco", "Monaco", "monaco", "Monte Carlo", 43.7347, 7.4206, 5, "https://..."]
```

```julia
# Step 2: Extract the auto-generated circuit ID
circuit_id = circuit[:circuitid]

# Step 3: Create the dependent record using the foreign key
race = M.Race.objects.create(
    "year" => 2024,
    "round" => 8,
    "circuitid" => circuit_id,  # Reference the related record
    "name" => "Monaco Grand Prix",
    "date" => Date(2024, 5, 26),
    "time" => Time(13, 0, 0),
    "url" => "https://www.formula1.com/races/2024-monaco-gp"
)
```

**Generated SQL for Step 3 (PostgreSQL):**
```sql
INSERT INTO "race" ("year", "round", "circuitid", "name", "date", "time", "url") 
VALUES ($1, $2, $3, $4, $5, $6, $7) 
RETURNING *
-- Parameters: [2024, 8, circuit_id, "Monaco Grand Prix", '2024-05-26', '13:00:00', "https://..."]
```

### Example: Result with Driver, Constructor, and Race

A more complex example showing multiple relationships:

```julia
# Assume we have IDs from existing or newly created records
driver_id = M.Driver.objects.filter("forename" => "Lewis").first().driverid
constructor_id = M.Constructor.objects.filter("name" => "Mercedes").first().constructorid
race_id = M.Race.objects.filter("year" => 2024, "round" => 1).first().raceid

# Create the result linking all three
result = M.Result.objects.create(
    "raceid" => race_id,
    "driverid" => driver_id,
    "constructorid" => constructor_id,
    "positionorder" => 1,
    "points" => 25.0,
    "grid" => 1,
    "laps" => 58
)

# The returned record includes all fields and IDs
@info "Result created" result_id=result[:resultid] points=result[:points]
```

**Generated SQL (PostgreSQL):**
```sql
INSERT INTO "result" ("raceid", "driverid", "constructorid", "positionorder", "points", "grid", "laps") 
VALUES ($1, $2, $3, $4, $5, $6, $7) 
RETURNING *
-- Parameters: [race_id, driver_id, constructor_id, 1, 25.0, 1, 58]
```

### Foreign Key Constraints

PormG enforces referential integrity. Attempting to create a record with a non-existent foreign key will raise an error:

```julia
# This will fail if circuit_id=9999 doesn't exist
try
    race = M.Race.objects.create(
        "year" => 2025,
        "round" => 1,
        "circuitid" => 9999,  # Does not exist!
        "name" => "Phantom Grand Prix",
        "date" => Date(2025, 3, 23)
    )
catch e
    @error "Foreign key constraint violation" exception=e
end
```

**Generated SQL (PostgreSQL):**
```sql
INSERT INTO "race" ("year", "round", "circuitid", "name", "date") 
VALUES ($1, $2, $3, $4, $5) 
RETURNING *
-- Parameters: [2025, 1, 9999, "Phantom Grand Prix", '2025-03-23']
```

## Creating Multiple Records Individually

While loop-based creation is possible, **for large datasets you should prefer [Bulk Operations](bulk.md)**. Single `create()` calls are appropriate for:
- User-submitted form data in web requests
- Real-time operations that need immediate feedback
- Small, on-demand data entry

For loading CSV files or batch imports, use `bulk_insert()` or `bulk_copy()`.

### Loop Example

```julia
# Good for small, interactive operations
test_data = [
    ("test10", 10),
    ("test11", 11),
    ("test12", 12)
]

created_ids = []
for (name, test_result) in test_data
    record = M.Just_a_test_deletion.objects.create(
        "name" => name,
        "test_result" => test_result
    )
    push!(created_ids, record[:id])
end

@info "Created $(length(created_ids)) records" ids=created_ids
```

**Generated SQL per iteration (PostgreSQL):**
```sql
INSERT INTO "just_a_test_deletion" ("name", "test_result") 
VALUES ($1, $2) 
RETURNING *
```

### Why Not Loop for Large Datasets?

```julia
# ❌ SLOW: 10,000 individual inserts = 10,000 database round-trips
for i in 1:10000
    M.Driver.objects.create("forename" => "Driver $i", ...)
end

# ✅ FAST: One bulk operation = 1-10 database round-trips
df = DataFrame(forename = ["Driver $i" for i in 1:10000], ...)
bulk_insert(M.Driver.objects, df)
```

See [Bulk Operations](bulk.md) for performance comparisons and when to use each method.
