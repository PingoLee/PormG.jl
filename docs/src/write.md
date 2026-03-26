# Writing Data with PormG

This guide covers all data manipulation operations in PormG, including creating, updating, and deleting records. PormG provides both single-record and bulk operations for efficient data management.

---

## Creating Records

### Single Record Creation

Use the `.create()` method to insert individual records:

The `.create()` method returns a `Dict` containing the data of the newly created record, including the database-generated primary key.

```julia
# Load your models
include("db/models.jl")
import .models as M

# Create a new record
new_record = M.Just_a_test_deletion.objects.create("name" => "test", "test_result" => 1)
```

Upon success, `new_record` will contain:
```julia
Dict{Symbol, Any} with 4 entries:
  :test_result  => 1
  :id           => 172
  :name         => "test"
  :test_result2 => missing
```

PormG validates that all non-nullable fields are provided. If a required field is missing, it will raise an `ArgumentError`.

```julia
# This will fail because the 'driverref' field is required and not provided.
driver = M.Driver.objects.create(
    "forename" => "Lewis",
    "surname" => "Hamilton",
    "nationality" => "British",
    "dob" => Date(1985, 1, 7)
)
```

This will produce the following error:
```julia
ERROR: ArgumentError: Error in insert, the field driverref not allow null
```


### Creating with Relationships

To create a record with a `ForeignKey` relationship, you first need the ID of the related record. You can either create the related record first or use an existing one.

```julia
# Create related records
circuit = M.Circuit.objects.create(
    "name" => "Monaco",
    "country" => "Monaco",
    "circuitref" => "monaco",
    "location" => "Monaco",
    "lat" => 43.7347,
    "lng" => 7.4206,
    "alt" => 5,
    "url" => "https://example.com/circuits/monaco"
)

# Create a record with a foreign key reference and other fields
race = M.Race.objects.create(
    "year" => 2024,
    "round" => 8,
    "circuitid" => circuit[:circuitid],
    "name" => "Monaco Grand Prix",
    "date" => Date(2024, 5, 26),
    "time" => Time(13, 0, 0), # Optional: 13:00 UTC
    "url" => "https://example.com/races/monaco2024",
    "fp1_date" => Date(2024, 5, 24),
    "fp1_time" => Time(11, 30, 0),
    "fp2_date" => Date(2024, 5, 25),
    "fp2_time" => Time(11, 30, 0),
    "fp3_date" => Date(2024, 5, 26),
    "fp3_time" => Time(11, 30, 0),
    "quali_date" => Date(2024, 5, 25),
    "quali_time" => Time(15, 0, 0),
    "sprint_date" => Date(2024, 5, 26),
    "sprint_time" => Time(12, 0, 0)
)
```

Upon success, `race` will contain:
```julia
Dict{Symbol, Any} with 18 entries:
  :fp3_time    => 11:30:00
  :fp2_date    => Date("2024-05-25")
  :sprint_time => 12:00:00
  :time        => 13:00:00
  :year        => 2024
  :fp1_date    => Date("2024-05-24")
  :raceid      => 1146
  ⋮            => ⋮
```

### Creating Multiple Records Individually

```julia
# Create multiple records in a loop
test_data = [
    ("test10", 10),
    ("test11", 11),
    ("test12", 12)
]

for (name, test_result) in test_data
    M.Just_a_test_deletion.objects.create(
        "name" => name,
        "test_result" => test_result
    )
end
```

---

## Bulk Insert

### Basic insertion

Efficiently insert large datasets using `bulk_insert()`:

```julia
using CSV, DataFrames

# Prepare data
df = CSV.File("drivers.csv") |> DataFrame

# Bulk insert from DataFrame
query = M.Driver.objects
bulk_insert(query, df)
```

By default, `bulk_insert()` chunks data into batches of 1000 rows for efficient insertion. However, for larger datasets with many columns, you might need to adjust the batch size to avoid hitting LibPQ limits. Unfortunately, when an insertion exceeds these limits, LibPQ can raise an unknown error. If you encounter such an error, try reducing the `chunk_size`.

```julia
query = M.Driver.objects
bulk_insert(query, df, chunk_size=500)
```

### Bulk Insert with error handling

When performing bulk inserts, especially from sources like CSV files, you might encounter data that doesn't align with your database schema. A common issue is trying to insert a string value (like `\N`, often used to represent `NULL` in CSVs) into a numeric column. This mismatch will cause `bulk_insert()` to raise an error and halt the operation.

#### Example: A Failing Insert

Imagine you're loading data from a `results.csv` file.

```julia
# Load data from a CSV file
df = CSV.File("results.csv") |> DataFrame

# Attempt a bulk insert
query = M.Result.objects
bulk_insert(query, df)
```

If the `milliseconds` column in your CSV contains `\N` for some rows, while the corresponding database column is numeric, you'll get an error:

```julia
julia> bulk_insert(query, df)
ERROR: ArgumentError: Error in bulk_insert, the field milliseconds in row 6 has a value that can't be formatted: \N
```

#### The Solution: Pre-process Your Data

To fix this, you need to "clean" the data in your DataFrame before passing it to `bulk_insert()`. The goal is to convert problematic strings like `\N` into Julia's `missing` value. PormG will then correctly interpret `missing` as a `NULL` value for the database.

Here’s how you can clean the DataFrame. This code iterates through potentially problematic columns and replaces any `\N` strings with `missing`.

```julia
# Define the list of columns that need cleaning
cols_to_clean = [
    :position, :time, :milliseconds, :fastestlap, :rank, 
    :fastestlaptime, :fastestlapspeed, :number
]

# In each specified column, replace "\N" with `missing`
for col in cols_to_clean
    df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
end

# Now, the bulk insert will succeed
bulk_insert(query, df)

# You can verify the result
query.count()
26759
```

By pre-processing the data, you ensure it's compatible with your database schema, leading to a smooth and successful bulk insert.

---

## Ultra-Fast Bulk Inserts with PostgreSQL COPY

### bulk_copy: PostgreSQL Native High-Performance Insertion

For truly massive datasets, PormG provides `bulk_copy()`, which uses PostgreSQL's native `COPY FROM STDIN` protocol—the fastest way to bulk insert data into PostgreSQL.

The `COPY` protocol bypasses the standard SQL statement parser for each row, achieving **10-100x faster insertion** than `bulk_insert()` on large datasets.

#### Why Use bulk_copy?

- **Raw Speed**: Uses PostgreSQL's optimized binary protocol, not SQL statements
- **Memory Efficient**: Streams data without loading everything into memory simultaneously
- **Safe by Design**: Data is completely isolated from SQL parsing (immune to SQL injection)
- **Ideal for**: Large initial data loads, data migrations, ETL pipelines

#### Basic Usage

```julia
using DataFrames
import PormG.models as M

# Prepare your data (as a DataFrame)
df = DataFrame(
    forename = ["Lewis", "Max", "Lando"],
    surname = ["Hamilton", "Verstappen", "Norris"],
    nationality = ["British", "Dutch", "British"]
)

# Fast bulk insert via COPY protocol
query = M.Driver.objects
bulk_copy(query, df)

# Verify
query.count()
3
```

#### Advanced: Column Mapping

If your DataFrame column names differ from the database schema, use the `columns` parameter:

```julia
# DataFrame with different column names
df_raw = DataFrame(
    first_name = ["Lewis", "Max"],
    last_name = ["Hamilton", "Verstappen"],
    country = ["British", "Dutch"]
)

# Map DataFrame columns to model fields
bulk_copy(query, df_raw, columns = [
    "first_name" => "forename",
    "last_name" => "surname",
    "country" => "nationality"
])
```

#### Chunking Large Datasets

For very large datasets, `bulk_copy()` automatically chunks data to ensure stable insertion:

```julia
# Insert 1 million rows in chunks of 10,000
df_huge = CSV.File("massive_drivers.csv") |> DataFrame

bulk_copy(query, df_huge, chunk_size = 10_000)
```

#### Automatic Sequence Management

After bulk insertion, PormG automatically updates PostgreSQL `SERIAL`/`IDENTITY` sequences to prevent ID collisions on subsequent `create()` calls:

```julia
# Bulk insert 100 drivers
bulk_copy(query, df)

# Create a new driver—the ID sequence is already synchronized
new_driver = query.create("forename" => "Oscar", "surname" => "Piastri", "nationality" => "Australian")

# new_driver will have a unique ID (not colliding with bulk-inserted rows)
```

#### Example: Loading F1 Data at Scale

```julia
# Load drivers from CSV
drivers_csv = CSV.File("f1/drivers.csv") |> DataFrame
M.Driver.objects.exists() || bulk_copy(M.Driver.objects, drivers_csv)

# Load constructors
constructors_csv = CSV.File("f1/constructors.csv") |> DataFrame
bulk_copy(M.Constructor.objects, constructors_csv)

# Load races
races_csv = CSV.File("f1/races.csv") |> DataFrame
bulk_copy(M.Race.objects, races_csv)

# Load results (with relationships intact)
results_csv = CSV.File("f1/results.csv") |> DataFrame
bulk_copy(M.Result.objects, results_csv)

# Verify all loaded
M.Driver.objects.count()          # 800+
M.Constructor.objects.count()     # 200+
M.Race.objects.count()            # 1100+
M.Result.objects.count()          # 25000+
```

#### Safety: SQL Injection Protection

`bulk_copy()` is inherently immune to SQL injection because:

1. **Data is never parsed as SQL** — `COPY FROM STDIN` treats all input as pure data
2. **CSV escaping is automatic** — Quotes, commas, newlines are handled safely by Julia's `CSV.jl`
3. **No string interpolation** — Table and column names are sanitized via `quote_identifier`

You can safely insert rows containing SQL metacharacters:

```julia
# These strings are stored as-is, not executed
df_safe = DataFrame(
    name = [
        "'; DROP TABLE drivers; --",
        "\" OR \"1\"=\"1",
        "UNION SELECT * FROM races"
    ],
    code = ["INJECT1", "INJECT2", "INJECT3"]
)

bulk_copy(M.Just_a_test_deletion.objects, df_safe)

# All rows are safely retrieved without any SQL being executed
M.Just_a_test_deletion.objects.count()
3
```



### Single Record Updates

Update specific records using filters:

```julia
# Update a single record
query = M.Driver.objects;
query.filter("forename" => "Lewis");
query.count()
1
df = query |> DataFrame
1×9 DataFrame
 Row │ number  surname   driverid  driverref  nationality  dob         code     url                                forename 
     │ Int32?  String?   Int64?    String?    String?      Date?       String?  String?                            String?  
─────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
   1 │     44  Hamilton         1  hamilton   British      1985-01-07  HAM      http://en.wikipedia.org/wiki/Lew…  Lewis

query.update("nationality" => "Xylos")

# Verify the update
df = query |> DataFrame
1×9 DataFrame
 Row │ number  surname   driverid  driverref  nationality  dob         code     url                                forename 
     │ Int32?  String?   Int64?    String?    String?      Date?       String?  String?                            String?  
─────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
   1 │     44  Hamilton         1  hamilton   Xylos       1985-01-07  HAM      http://en.wikipedia.org/wiki/Lew…  Lewis

query.update("nationality" => "British")

# Update multiple fields
query = M.Race.objects;
query.filter("raceid" => 1);
query.update(
    "name" => "Australian Grand Prix",
    "date" => Date(2024, 3, 24),
    "round" => 1
)

# If you want to see the query (without executing it)
sql = query.update(
    "name" => "Australian Grand Prix",
    "date" => Date(2024, 3, 24),
    "round" => 1,
    show_query=:sql
)
```

The return value of the `update()` when show_query is `:sql` is:
```julia
"UPDATE \"race\" AS \"Tb\" SET \"name\" = $2, \"date\" = $3, \"round\" = $4 WHERE \"Tb\".\"raceid\" = $1"
```

### Updates with Relationships

```julia
# Update with relationships
query = M.Result.objects;
query.filter("driverid__nationality" => "British", "resultid" => 1);
query.update("points" => F("points") + 10)

# if you want to see the query (without executing it)
sql = query.update("points" => F("points") + 10, show_query=:sql)

# Update with complex JOINs
query = M.Result.objects;
query.filter("raceid__circuitid__name__@icontains" => "Monaco", "resultid" => 7654);
query.update("points" => 11, show_query=:sql)
```

---

## Deleting Records

### Single Record Deletion

If you want to use this example, first create a few records in the `Just_a_test_deletion` table as show in the [Creating Multiple Records Individually](#creating-multiple-records-individually) section for details.

```julia
# Delete specific records
query = M.Just_a_test_deletion.objects;
query.filter("test_result" => 10)
delete(query)
```
If you had created records with test_result values of 10, 11, and 12, the above code would delete the record with test_result equal to 10, and the return value would be:
```julia
(1, Dict{String, Integer}("just_a_test_deletion" => 1))
```

```julia
# Delete with multiple conditions (AND want just see the query without executing it)
# Note: delete() returns a Vector{String} when there are multiple cascading queries
query = M.Just_a_test_deletion.objects;
query.filter("test_result__@in" => [11, 12], "test_result2__@isnull" => true)
delete_queries = delete(query, show_query=:sql)
```

The return value of the above code when using `show_query=:sql` is a String (or Vector of Strings if cascading):
```julia
"DELETE FROM just_a_test_deletion WHERE \"id\" IN (SELECT \"Tb\".\"id\" as id FROM \"just_a_test_deletion\" as \"Tb\" ...)"
```

However, if you execute the above code without the `show_query` parameter, it will delete the records and return the counts:
```julia
(2, Dict{String, Integer}("just_a_test_deletion" => 2))
```

### Bulk Deletion

```julia
# Delete all records (requires explicit permission)
query = M.Just_a_test_deletion.objects
delete(query, allow_delete_all=true)

# Delete with conditions
query = M.Result.objects
query.filter("raceid__year__@lt" => 1960)
delete(query)
```

### Cascade Deletion

Foreign key relationships with `on_delete="CASCADE"` will automatically delete related records:

```julia
# This will also delete related Result records if configured with CASCADE
query = M.Race.objects
query.filter("name" => "Cancelled Grand Prix")
delete(query)
```

---



### Bulk Update

Update multiple records from a DataFrame:

```julia
# Get existing data
query = M.Result.objects
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
query = M.Result.objects
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
    filters=["resultid", "statusid" => 1],
)
```

### Bulk Update with unsupported join in bulk_update

```julia
# Unsupported join in bulk_update, you will get a error
bulk_update(
    query, df, 
    columns=["milliseconds"], 
    filters=["resultid", "statusid__status" => "Finished"],
)
ERROR: "Error in bulk_update, the join is not allowed in bulk_update"
```

---

## F Expressions

F expressions allow database-level operations without loading data into Julia, similar to Django's F objects.

### Basic F Expression Usage

```julia
# Increment a counter field
query = M.Driver.objects;
query.filter("driverid" => 1);
df = query |> DataFrame

1×9 DataFrame
 Row │ number  surname   driverid  driverref  nationality  dob         code     url                                forename 
     │ Int32?  String?   Int64?    String?    String?      Date?       String?  String?                            String?  
─────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
   1 │     44  Hamilton         1  hamilton   British      1985-01-07  HAM      http://en.wikipedia.org/wiki/Lew…  Lewis

query.update("number" => F("number") + 1)

df = query |> DataFrame

1×9 DataFrame
 Row │ number  surname   driverid  driverref  nationality  dob         code     url                                forename 
     │ Int32?  String?   Int64?    String?    String?      Date?       String?  String?                            String?  
─────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
   1 │     45  Hamilton         1  hamilton   British      1985-01-07  HAM      http://en.wikipedia.org/wiki/Lew…  Lewis

query.update("number" => F("number") - 1)

# Set one field equal to another
query = M.Driver.objects;
query.filter("driverid" => 1);
query.update("number" => F("driverid"))

df = query |> DataFrame

1×9 DataFrame
 Row │ number  surname   driverid  driverref  nationality  dob         code     url                                forename 
     │ Int32?  String?   Int64?    String?    String?      Date?       String?  String?                            String?  
─────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
   1 │      1  Hamilton         1  hamilton   British      1985-01-07  HAM      http://en.wikipedia.org/wiki/Lew…  Lewis

query.update("number" => 44)
```

With F, you can do all basic mathematical operations directly in the database.

```julia
query = M.Just_a_test_deletion.objects;
query.exists() && query.delete(allow_delete_all = true)
query.create("name" => "fexpr", "test_result" => 1)
query.create("name" => "fexpr", "test_result" => 2)
query.create("name" => "fexpr", "test_result" => 3)

query = M.Just_a_test_deletion.objects;
query.filter("test_result" => 1)

# Addition
query.update("test_result2" => F("test_result") + 1)

# Multiplication  
query.update("test_result2" => F("test_result2") * 2)

# Division
query.update("test_result2" => F("test_result2") / 2)

# Opereations with only F expressions
query.update("test_result2" => F("test_result") + F("test_result"))

# Subtraction
query.update("test_result2" => F("test_result2") - 1)

```

### F Expressions with Relationships

```julia
# Use values from related models
query = M.Result.objects;
query.filter("resultid" => 3);
df = query |> DataFrame
1×18 DataFrame
 Row │ fastestlapspeed  points    raceid  number  time     fastestlaptime  driverid  position  laps    rank    statusid  resultid  fastestlap  grid    milliseconds  positionorder  positiontext  constructorid 
     │ Float64?         Float64?  Int64?  Int32?  String?  Time?           Int64?    Int32?    Int32?  Int32?  Int64?    Int64?    Int32?      Int32?  Int32?        Int32?         String?       Int64?        
─────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
   1 │         216.719       6.0      18       7  +8.163   00:01:28.09            3         3      58       5         1         3          41       7       5697779              3  3                         3


# Update using related field values 
query.update("grid" => F("driverid__number"))

df = query |> DataFrame
1×18 DataFrame
 Row │ fastestlapspeed  points    raceid  number  time     fastestlaptime  driverid  position  laps    rank    statusid  resultid  fastestlap  grid    milliseconds  positionorder  positiontext  constructorid 
     │ Float64?         Float64?  Int64?  Int32?  String?  Time?           Int64?    Int32?    Int32?  Int32?  Int64?    Int64?    Int32?      Int32?  Int32?        Int32?         String?       Int64?        
─────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
   1 │         216.719       6.0      18       7  +8.163   00:01:28.09            3         3      58       5         1         3          41       6       5697779              3  3                         3

# Complex relationship traversal
query.update("positiontext" => F("raceid__circuitid__country"))

# Yeah, I know, nothing this make any sense, but it's just an example
sql = query.update("grid" => F("driverid__number"), show_query=:sql)
# Returns: "UPDATE \"result\" AS \"Tb\" SET \"grid\" = \"Tb_1\".\"number\" FROM \"driver\" AS \"Tb_1\" WHERE \"Tb\".\"driverid\" = \"Tb_1\".\"driverid\" AND \"Tb\".\"resultid\" = $1"

sql = query.update("positiontext" => F("raceid__circuitid__country"), show_query=:sql)
# Returns: "UPDATE \"result\" AS \"Tb\" SET \"positiontext\" = \"Tb_2\".\"country\" FROM \"race\" AS \"Tb_1\", \"circuit\" AS \"Tb_2\" WHERE \"Tb\".\"raceid\" = \"Tb_1\".\"raceid\" AND \"Tb_1\".\"circuitid\" = \"Tb_2\".\"circuitid\" AND \"Tb\".\"resultid\" = $1"
```

---

This comprehensive guide covers all data writing operations in PormG. For more details on querying data, see the [Reading overview](read/index.md). For field definitions and validation, refer to [fields.md](fields.md).
