# Writing Data with PormG

This guide covers all data manipulation operations in PormG, including creating, updating, and deleting records. PormG provides both single-record and bulk operations for efficient data management.

## Table of Contents

- [Creating Records](#creating-records)
- [Updating Records](#updating-records)
- [Deleting Records](#deleting-records)
- [Bulk Operations](#bulk-operations)
- [F Expressions](#f-expressions)


---

## Creating Records

### Single Record Creation

Use the `.create()` method to insert individual records:

```julia
# Load your models
include("db/models.jl")
import .models as M

# Create a single record
query = M.Driver |> object
driver = query.create(
    "forename" => "Lewis",
    "surname" => "Hamilton",
    "nationality" => "British",
    "dob" => Date(1985, 1, 7)
)
```

### Creating with Relationships

```julia
# Create related records
circuit_query = M.Circuit |> object
circuit = circuit_query.create("name" => "Monaco", "country" => "Monaco")

# Create record with foreign key reference
race_query = M.Race |> object
race = race_query.create(
    "name" => "Monaco Grand Prix",
    "circuitid" => circuit.circuitid,
    "date" => Date(2024, 5, 26),
    "year" => 2024
)
```

### Creating Multiple Records Individually

```julia
# Create multiple records in a loop
drivers_data = [
    ("Max", "Verstappen", "Dutch"),
    ("Charles", "Leclerc", "Monégasque"),
    ("Carlos", "Sainz Jr.", "Spanish")
]

query = M.Driver |> object
for (forename, surname, nationality) in drivers_data
    query.create(
        "forename" => forename,
        "surname" => surname,
        "nationality" => nationality,
        "dob" => Date(1995, 1, 1)  # Sample date
    )
end
```

---

## Updating Records

### Single Record Updates

Update specific records using filters:

```julia
# Update a single record
query = M.Driver |> object
query.filter("forename" => "Lewis")
query.update("nationality" => "British")

# Update multiple fields
query = M.Race |> object
query.filter("raceid" => 1)
query.update(
    "name" => "Australian Grand Prix",
    "date" => Date(2024, 3, 24),
    "round" => 1
)
```

### Conditional Updates

```julia
# Update records matching criteria
query = M.Result |> object
query.filter("statusid__status" => "Retired")
query.update("points" => 0)

# Update with complex filters
query = M.Race |> object
query.filter("year" => 2023, "date__@lt" => Date(2023, 6, 1))
query.update("season" => "first_half")
```

### Updates with Relationships

```julia
# Update using related field filters
query = M.Result |> object
query.filter("raceid__circuitid__country" => "Monaco")
query.update("bonus_points" => 2)

# Update foreign key relationships
query = M.Result |> object
query.filter("driverid__nationality" => "German")
query.update("statusid" => 1)  # Finished status
```

---

## Deleting Records

### Single Record Deletion

```julia
# Delete specific records
query = M.Driver |> object
query.filter("nationality" => "Retired")
delete(query)

# Delete with multiple conditions
query = M.Result |> object
query.filter("points" => 0, "statusid__status" => "Disqualified")
delete(query)
```

### Bulk Deletion

```julia
# Delete all records (requires explicit permission)
query = M.Just_a_test_deletion |> object
delete(query, allow_delete_all=true)

# Delete with conditions
query = M.Result |> object
query.filter("raceid__year__@lt" => 1960)
delete(query)
```

### Cascade Deletion

Foreign key relationships with `on_delete="CASCADE"` will automatically delete related records:

```julia
# This will also delete related Result records if configured with CASCADE
query = M.Race |> object
query.filter("name" => "Cancelled Grand Prix")
delete(query)
```

---

## Bulk Operations

### Bulk Insert

Efficiently insert large datasets using `bulk_insert()`:

```julia
using CSV, DataFrames

# Prepare data
df = CSV.File("drivers.csv") |> DataFrame

# Bulk insert from DataFrame
query = M.Driver |> object
bulk_insert(query, df)
```

### Bulk Insert with Data Processing

```julia
# Load and preprocess CSV data
df = CSV.File("results.csv") |> DataFrame

# Handle missing values
for col in [:position, :time, :milliseconds, :fastestlap]
    df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
end

# Bulk insert with copy optimization
query = M.Result |> object
bulk_insert(query, df, copy=true)
```

### Bulk Update

Update multiple records from a DataFrame:

```julia
# Get existing data
query = M.Result |> object
df = query |> DataFrame

# Modify data
for (index, row) in enumerate(eachrow(df))
    row.points = row.points + 1  # Bonus point adjustment
    row.milliseconds = row.milliseconds * 1000  # Convert to microseconds
end

# Bulk update using ID as filter
bulk_update(query, df, columns=["points", "milliseconds"], filters=["resultid"])
```

### Bulk Update with Custom Filters

```julia
# Update with additional static filters
query = M.Result |> object
df = query |> DataFrame

# Modify lap times
for row in eachrow(df)
    if !ismissing(row.milliseconds)
        row.milliseconds = row.milliseconds - 1000  # Improve lap time by 1 second
    end
end

# Bulk update with custom filters
bulk_update(
    query, df, 
    columns=["milliseconds"], 
    filters=["resultid", "statusid__status" => "Finished"],
    show_query=false
)
```

---

## F Expressions

F expressions allow database-level operations without loading data into Julia, similar to Django's F objects.

### Basic F Expression Usage

```julia
# Increment a counter field
query = M.Driver |> object
query.filter("driverid" => 1)
query.update("wins" => F("wins") + 1)

# Set one field equal to another
query = M.Result |> object
query.filter("fastestlaptime" => missing)
query.update("fastestlaptime" => F("time"))
```

### Arithmetic Operations

```julia
# Mathematical operations
query = M.Result |> object
query.filter("resultid" => 1)

# Addition
query.update("total_time" => F("time") + F("milliseconds"))

# Multiplication  
query.update("penalty_time" => F("milliseconds") * 1.1)

# Division
query.update("average_speed" => F("distance") / F("time"))

# Subtraction
query.update("time_difference" => F("time") - F("fastestlaptime"))
```

### F Expressions with Relationships

```julia
# Use values from related models
query = M.Result |> object
query.filter("resultid" => 1)

# Update using related field values
query.update("driver_number" => F("driverid__number"))

# Complex relationship traversal
query.update("circuit_country" => F("raceid__circuitid__country"))
```

### F Expressions in Filters

```julia
# Compare fields within the same record
query = M.Race |> object
query.filter(F("fp1_date") <= F("date"))

# Use F expressions with other operators
query = M.Result |> object
query.filter(F("milliseconds") < F("fastestlaptime"))
```

### F Expressions in Annotations

```julia
# Calculate values in SELECT
query = M.Result |> object
query.values(
    "driverid__forename",
    "points",
    "bonus_points" => F("points") * 0.1,
    "total_points" => F("points") + (F("points") * 0.1)
)
df = query |> list |> DataFrame
```



---

This comprehensive guide covers all data writing operations in PormG. For more details on querying data, see the [read.md](read.md) documentation. For field definitions and validation, refer to [fields.md](fields.md).
