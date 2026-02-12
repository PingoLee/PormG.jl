# Bulk Operations

Bulk operations are designed for high-performance data manipulation of large datasets. PormG provides three dedicated tools:

- **`bulk_insert()`**: Standard SQL-based insertion with automatic chunking (suitable for DataFrames with 1-10k rows)
- **`bulk_copy()`**: PostgreSQL native `COPY` protocol for ultra-fast insertion (suitable for 10k+ rows on PostgreSQL)
- **`bulk_update()`**: Efficient multi-row updates from a DataFrame

All bulk operations are **async-aware** and participate in transaction contexts automatically.

## Performance Comparison

| Operation | Dataset Size | Speed | Ideal For | Database |
| :--- | :--- | :--- | :--- | :--- |
| `create()` loop | < 100 rows | Slowest | Individual interactive inserts | All |
| `bulk_insert()` | 100 - 10k rows | Fast | CSV imports, batch operations | All |
| `bulk_copy()` ⭐ | 10k+ rows | Ultra-Fast | Initial data loads, migrations | PostgreSQL only |

⭐ `bulk_copy()` can be 10-100x faster than `bulk_insert()` for large datasets.

---

## Bulk Insert

Use `bulk_insert()` to insert a `DataFrame` into the database. By default, it chunks data into batches of 1000 rows.

```julia
using CSV, DataFrames

# Prepare data
df = CSV.File("drivers.csv") |> DataFrame

# Bulk insert from DataFrame
query = M.Driver.objects
bulk_insert(query, df)

# Adjust chunk size for tables with many columns
bulk_insert(query, df, chunk_size=500)
```

### Pre-processing and Error Handling

CSV data often contains strings like `\N` for null values. If these are passed to numeric columns, `bulk_insert` will throw an error. You must pre-process your `DataFrame` to use Julia's `missing`.

```julia
# Clean the DataFrame before insertion
cols_to_clean = [:position, :milliseconds, :rank]

for col in cols_to_clean
    df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
end

# Now the bulk insert will succeed
bulk_insert(query, df)
```

### Atomicity and Transactions

By default, `bulk_insert()` chunks data and processes each chunk in its own transaction. If any chunk fails, **only that chunk is rolled back**, not the entire operation.

To ensure all-or-nothing semantics (all rows inserted or none), wrap `bulk_insert()` in `run_in_transaction()`:

```julia
using PormG

# All inserts succeed together, or all fail together
PormG.run_in_transaction("db_2") do
    bulk_insert(M.Driver.objects, df)
end
```

### Error Handling Examples

```julia
# Detect duplicate key errors
try
    bulk_insert(M.Driver.objects, df)
catch e
    if contains(string(e), "duplicate key")
        @warn "Some rows have duplicate values" exception=e
    else
        rethrow(e)
    end
end

# Pre-validate data before insertion
using DataFrames

df_validated = df[
    (df.forename .!= "") .& 
    (!ismissing.(df.dob)),
    :
]
@info "Validated $(nrow(df_validated)) of $(nrow(df)) rows"
bulk_insert(M.Driver.objects, df_validated)
```

### Memory Efficiency

For very large CSV files, avoid loading the entire file into memory:

```julia
using CSV, DataFrames

# Process CSV in chunks
reader = CSV.Reader("massive_drivers.csv"; ntasks=4)
for chunk in Iterators.partition(reader, 5000)
    df_chunk = DataFrame(chunk)
    # Pre-process if needed
    bulk_insert(M.Driver.objects, df_chunk)
end
```

---

## Ultra-Fast Bulk Inserts (PostgreSQL COPY)

For truly massive datasets, PormG provides `bulk_copy()`, which uses PostgreSQL's native `COPY FROM STDIN` protocol. This is **10-100x faster** than standard SQL inserts.

### Why Use bulk_copy?

- **Raw Speed**: Bypasses the SQL statement parser.
- **Memory Efficient**: Streams data to the database.
- **Safe by Design**: Inherently immune to SQL injection.

### Basic Usage

```julia
# Fast bulk insert via COPY protocol
query = M.Driver.objects
bulk_copy(query, df)
```

### Advanced: Column Mapping

If your `DataFrame` column names differ from the database schema, use the `columns` parameter:

```julia
# Map DataFrame columns to model fields
bulk_copy(query, df_raw, columns = [
    "first_name" => "forename",
    "last_name" => "surname",
    "country" => "nationality"
])
```

### Sequence Management

After a `bulk_copy`, PormG automatically updates PostgreSQL `SERIAL`/`IDENTITY` sequences so that subsequent calls to `create()` do not result in primary key collisions.

```julia
# Bulk insert 10,000 drivers
bulk_copy(M.Driver.objects, df_large)

# The ID sequence is automatically synchronized
# Create a new driver—the ID is guaranteed to not collide
new_driver = M.Driver.objects.create(
    "forename" => "Oscar",
    "surname" => "Piastri",
    "nationality" => "Australian",
    "driverref" => "piastri",
    "dob" => Date(2001, 1, 25)
)
# new_driver[:driverid] will be the next available ID after the bulk copy
```

### Real-World Example: Loading F1 Season Data

```julia
using CSV, DataFrames
import PormG.models as M

# Load initial reference data
circuits_df = CSV.File("f1/circuits.csv") |> DataFrame
M.Circuit.objects |> do_exists && delete(M.Circuit.objects, allow_delete_all=true)
bulk_copy(M.Circuit.objects, circuits_df)

# Load drivers
drivers_df = CSV.File("f1/drivers.csv") |> DataFrame
for col in [:number]
    drivers_df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, drivers_df[!, col])
end
M.Driver.objects |> do_exists && delete(M.Driver.objects, allow_delete_all=true)
bulk_copy(M.Driver.objects, drivers_df)

# Load races with pre-processing
races_df = CSV.File("f1/races.csv") |> DataFrame
rename!(races_df, lowercase.(names(races_df)))
for col in [:fp1_date, :fp1_time, :fp2_date, :fp2_time, :fp3_date, :fp3_time, :quali_date, :quali_time, :sprint_date, :sprint_time]
    races_df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, races_df[!, col])
end
M.Race.objects |> do_exists && delete(M.Race.objects, allow_delete_all=true)
bulk_copy(M.Race.objects, races_df)

# Load results (the largest table)
results_df = CSV.File("f1/results.csv") |> DataFrame
rename!(results_df, lowercase.(names(results_df)))
for col in [:position, :time, :milliseconds, :fastestlap, :rank, :fastestlaptime, :fastestlapspeed, :number]
    results_df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, results_df[!, col])
end
M.Result.objects |> do_exists && delete(M.Result.objects, allow_delete_all=true)
bulk_copy(M.Result.objects, results_df, chunk_size=10000)

# Verify all data loaded
@info "Data loaded" \
    circuits=M.Circuit.objects |> do_count \
    drivers=M.Driver.objects |> do_count \
    races=M.Race.objects |> do_count \
    results=M.Result.objects |> do_count
```

---

## Bulk Update

`bulk_update()` allows you to update multiple records from a `DataFrame`. It typically uses a temporary table or a `values` join to update the database in a single transaction.

### Basic Usage

```julia
# Get existing data
query = M.Result.objects
df = query |> DataFrame

# Modify data in the DataFrame
for row in eachrow(df)
    row.points = row.points + 1
end

# Bulk update specifying which columns to update and which to use as filters (keys)
bulk_update(query, df, columns=["points"], filters=["resultid"])
```

### Use Cases

Bulk updates are ideal for:
- **Award/penalty application**: Adjust points across multiple race results
- **Batch corrections**: Fix systematic data issues (e.g., unit conversions)
- **Bulk status changes**: Update fields across many related records
- **Data migrations**: Transform existing data in place

### Example: Adjust Points After Manual Review

```julia
query = M.Result.objects
df = query.filter("raceid__year" => 2024) |> DataFrame

# Apply manual adjustments
for row in eachrow(df)
    # Award bonus points for fastest lap
    if row.fastestlapspeed > 350.0
        row.points = row.points + 1
    end
    
    # Penalize for incidents
    if row.statusid == 137  # Collision
        row.points = max(0, row.points - 2)
    end
end

# Bulk update all adjustments in one transaction
PormG.run_in_transaction("db_2") do
    bulk_update(query, df, columns=["points"], filters=["resultid"])
end
```

### Custom Filters

You can pass static filters alongside the DataFrame mapping:

```julia
bulk_update(
    query, df, 
    columns=["milliseconds"], 
    filters=["resultid", "statusid" => 1],  # Only update where statusid == 1
)
```

### Limitations & Workarounds

- **No Related Joins**: `bulk_update` filters currently do not support double-underscore lookups (e.g., `statusid__status`).
  - **Workaround**: Filter the data in Julia before passing to `bulk_update`:
  
```julia
query = M.Result.objects
df = query.filter("statusid__status" => "Finished") |> DataFrame

# Modify data
for row in eachrow(df)
    row.points = row.points + 1
end

# Bulk update (filter already applied via DataFrame)
bulk_update(query, df, columns=["points"], filters=["resultid"])
```

### Performance Characteristics

- **Atomicity**: All rows updated together or none.
- **Speed**: Much faster than individual `update()` calls (100-1000x for large datasets).
- **Memory**: Entire DataFrame must fit in memory; use chunking for very large datasets:

```julia
# Process in chunks for huge datasets
for chunk_df in Iterators.partition(eachrow(df), 10000)
    chunk = DataFrame(chunk_df)
    # Modify chunk
    bulk_update(query, chunk, columns=["points"], filters=["resultid"])
end
```
