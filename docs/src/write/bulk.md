## Bulk Operations

Bulk operations are designed for high-performance data manipulation of large datasets. PormG provides three dedicated tools:

- **`bulk_insert()`**: Standard SQL-based insertion with automatic chunking.
- **`bulk_copy()`**: PostgreSQL native `COPY` protocol for ultra-fast insertion.
- **`bulk_update()`**: Efficient multi-row updates from a DataFrame using a mapping key.

All three operations accept `show_query=:sql`, `show_query=:dict`, `show_query=:inspection`, `show_query=:params`, or `show_query=:none` to inspect the generated SQL without executing it. See [Query Inspection](../read/index.md#query-inspection) for a full description of each mode.

### The Mapping Adaptor Strategy ⭐

All bulk operations in PormG use a **Mapping Adaptor** approach. This means:
- **Default-Safe**: With `copy=true` (the default), PormG deep-copies the input `DataFrame` before applying defaults, timestamps, or other ORM-side normalization.
- **Flexible Mapping**: Use `columns = ["df_col" => "model_field"]` to map any DataFrame column to any table field.
- **Auto-Detection**: If you don't provide mappings, PormG automatically matches columns to fields by name (case-insensitive).
- **Centralized Validation**: Every row is automatically checked against the model's constraints (`max_length`, `nullability`, etc.) before reaching the database.
- **Relation Value Semantics**: Foreign-key columns accept scalar key values (including `0` if present in the target table). Use `nothing` or `missing` when you want SQL `NULL` on nullable relation columns.

If you are processing a very large frame and no longer need the original values, pass `copy=false` to let the bulk path mutate the caller's `DataFrame` in place and avoid the defensive deep copy.

---

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

**Generated SQL (PostgreSQL):**
```sql
INSERT INTO "driver" ("forename", "surname", "nationality", "driverref", "dob") 
VALUES 
  ($1, $2, $3, $4, $5), 
  ($6, $7, $8, $9, $10),
  -- ... (batched up to chunk_size rows)
```

### Auto-Generated Primary Keys

Do not prefill an auto-increment primary key with `max(id) + 1` before calling `bulk_insert()` or `bulk_copy()`.

- If the model uses `IDField()` or `AutoField()` and the DataFrame omits the primary key column, PormG leaves that field out of the SQL and lets the database allocate ids through its native sequence, identity, or autoincrement mechanism.
- If the DataFrame includes the primary key column but every value is blank (`missing`, `nothing`, or an empty string), PormG treats that column as omitted for bulk inserts and COPY as well.
- If you want to load explicit primary key values, provide a value for every row. Mixed blank and explicit values are rejected because the bulk path cannot safely express a row-by-row mix of generated and manual ids.

This keeps id allocation concurrency-safe and avoids the collision risks of a client-side `SELECT MAX(id)` allocator.

### Pre-allocating Primary Keys for Cross-Table FK Wiring

Sometimes you need the assigned primary key values **before** the insert—for example, when you are loading a parent table and a child table at the same time and need to populate a foreign key column.

Use `allocate_primary_keys()` for this:

```julia
drivers_df = CSV.File("f1/drivers.csv") |> DataFrame

# Reserve ids from the database sequence without inserting yet.
# After this call, drivers_df has an `id` column with integer values.
drivers_df = allocate_primary_keys(M.Driver.objects, drivers_df)

# Build the results table using the pre-allocated driver ids.
results_df = DataFrame(
    driverid  = repeat(drivers_df.id, inner=num_races),
    raceid    = ...,
    ...
)

# Insert both tables in a single transaction.
PormG.run_in_transaction("db_2") do
    bulk_insert(M.Driver.objects, drivers_df)
    bulk_insert(M.Result.objects, results_df)
end
```

**PostgreSQL**: ids are reserved by calling `nextval()` on the column's sequence. The allocation is atomic and concurrent-safe. Ids consumed by a call that is never followed by an insert (e.g. the transaction rolled back) leave gaps in the sequence; this is expected PostgreSQL behaviour and has no functional impact.

**SQLite**: Since SQLite has no standalone sequences and only generates IDs at the exact moment of insertion, PormG fully emulates PostgreSQL's behavior to provide a consistent API. IDs are derived from `max(MAX(pk), sqlite_sequence.seq) + 1 … + N`, and `allocate_primary_keys()` immediately forces an update to the table's `sqlite_sequence` counter to the end of that reserved range. 
Critically, PormG tracks this reserved high-water mark in memory within the `TransactionContext` during an open transaction. This guarantees that any subsequent `create()`, `bulk_insert()`, or `allocate_primary_keys()` calls for that table *within the same transaction* will safely skip over the IDs you just reserved. **You must** wrap the full pre-allocation and insertion workflow inside `PormG.run_in_transaction` when using SQLite to guarantee collision-safe reservations.

If the DataFrame already contains the primary key column with at least one non-blank value, `allocate_primary_keys()` returns it unchanged so it is safe to call unconditionally in a data-loading pipeline.

#### Notes and Limitations

- **Handler filters are ignored.** `allocate_primary_keys()` operates on the model that backs the handler. Any filters or annotations attached to `M.Model.objects.filter(...)` have no effect — pk allocation is always table-wide.
- **Column dtype narrows.** If you pass a DataFrame with a `Vector{Union{Missing, Int}}` pk column, the returned column is a plain `Vector{Int}`. Downstream code expecting the missing-able element type must be adjusted.
- **PostgreSQL schema scope.** The PG path looks up the sequence via `pg_get_serial_sequence('table', 'col')` without a schema prefix and therefore assumes the model's table lives in the default search path (typically `public`).
- **`clone` keyword.** `allocate_primary_keys(handler, df; clone=false)` skips the defensive copy and writes the new pk column straight into `df`. The default (`clone=true`) is the safe choice; flip it only when memory pressure justifies it.

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

**Generated SQL (PostgreSQL):**
```sql
COPY "driver" ("forename", "surname", "nationality", "driverref", "dob") FROM STDIN WITH (FORMAT CSV, HEADER FALSE)
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

**Generated SQL (PostgreSQL):**
```sql
COPY "driver" ("forename", "surname", "nationality") FROM STDIN WITH (FORMAT CSV, HEADER FALSE)
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
M.Circuit.objects.exists() && M.Circuit.objects.delete(allow_delete_all=true)
bulk_copy(M.Circuit.objects, circuits_df)

# Load drivers
drivers_df = CSV.File("f1/drivers.csv") |> DataFrame
for col in [:number]
    drivers_df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, drivers_df[!, col])
end
M.Driver.objects.exists() && M.Driver.objects.delete(allow_delete_all=true)
bulk_copy(M.Driver.objects, drivers_df)

# Load races with pre-processing
races_df = CSV.File("f1/races.csv") |> DataFrame
rename!(races_df, lowercase.(names(races_df)))
for col in [:fp1_date, :fp1_time, :fp2_date, :fp2_time, :fp3_date, :fp3_time, :quali_date, :quali_time, :sprint_date, :sprint_time]
    races_df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, races_df[!, col])
end
M.Race.objects.exists() && M.Race.objects.delete(allow_delete_all=true)
bulk_copy(M.Race.objects, races_df)

# Load results (the largest table)
results_df = CSV.File("f1/results.csv") |> DataFrame
rename!(results_df, lowercase.(names(results_df)))
for col in [:position, :time, :milliseconds, :fastestlap, :rank, :fastestlaptime, :fastestlapspeed, :number]
    results_df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, results_df[!, col])
end
M.Result.objects.exists() && M.Result.objects.delete(allow_delete_all=true)
bulk_copy(M.Result.objects, results_df, chunk_size=10000)

# Verify all data loaded
@info "Data loaded" \
    circuits=M.Circuit.objects.count() \
    drivers=M.Driver.objects.count() \
    races=M.Race.objects.count() \
    results=M.Result.objects.count()
```

---

## Bulk Update

`bulk_update()` updates multiple rows from a `DataFrame`. PormG matches update columns and row-identifying filters against model fields, validates every row up front, and then emits a multi-row `UPDATE` using a `VALUES` source (PostgreSQL) or `WITH source(...) AS (VALUES ...)` form (SQLite).

### Basic Usage

```julia
# Get existing data
query = M.Result.objects
df = query |> DataFrame

# Modify data in the DataFrame
for row in eachrow(df)
    row.points = row.points + 1
end

# Bulk update specifying columns to update and keys to use as identifiers
# You can map DataFrame columns to model fields for both SET values and FILTERS
bulk_update(query, df, 
    columns=["points"],                      # Auto-matches 'points' in DF
    filters=["resultid"]                    # Auto-matches 'resultid' in DF
)
```

**Generated SQL (PostgreSQL):**
```sql
UPDATE "result" AS "Tb" 
SET "points" = "source"."points" 
FROM (VALUES 
  (1::bigint, 26.0::double precision), 
  (2::bigint, 19.0::double precision),
  -- ... (chunked multi-row values)
) AS "source"("resultid", "points") 
WHERE "Tb"."resultid" = "source"."resultid"
```

```julia
# Using explicit mapping (Adaptor style)
# This allows using a DataFrame with totally different column names
custom_df = DataFrame(
    "new_score" => [25, 18, 15],
    "record_id" => [1, 2, 3]
)

bulk_update(query, custom_df,
    columns=["new_score" => "points"],      # Map 'new_score' to table field 'points'
    filters=["record_id" => "id"]           # Map 'record_id' to table field 'id'
)
```

**Generated SQL (PostgreSQL):**
```sql
UPDATE "result" AS "Tb" 
SET "points" = "source"."new_score" 
FROM (VALUES 
  (1::bigint, 25::integer), 
  (2::bigint, 18::integer), 
  (3::bigint, 15::integer)
) AS "source"("record_id", "new_score") 
WHERE "Tb"."id" = "source"."record_id"
```

### Matching and Execution Rules

- **Case-insensitive DataFrame matching**: PormG resolves `columns` and dynamic `filters` against `DataFrame` column names case-insensitively, so `ID` and `POINTS` work for model fields `id` and `points`.
- **Primary key fallback**: If you omit `filters=`, `bulk_update()` infers the model primary key column(s) and expects those columns to be present in the `DataFrame`.
- **Handler filters are rebuilt**: `bulk_update()` clears any filters already attached to the query handler and rebuilds the `WHERE` clause from `filters=`. Pass every predicate you need through `filters=` rather than relying on prior `query.filter(...)` state.
- **Dry-run support**: `show_query=:dict` and `show_query=:inspection` return metadata, `:sql` returns SQL text, `:params` returns the bound parameter list, and `:none` builds the statement and returns `nothing` without executing.
- **Empty input is a no-op**: An empty `DataFrame` returns `nothing` after logging a warning.
- **Nullable columns accept all-`missing` batches**: If a nullable update column is `missing` for every targeted row, PormG writes SQL `NULL` for every row in that column.

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

### Mixed Filters (Static and Dynamic)

`bulk_update()` supports a powerful mix of **dynamic filters** (based on DataFrame values) and **static filters** (applying the same value to all rows).

- **Dynamic**: `filters=["id"]` or `filters=["record_id" => "id"]`. PormG looks for the key in the DataFrame.
- **Static**: `filters=["status" => "active"]`. If the key is **not** in the DataFrame but exists in the model, PormG treats it as a static filter for the query.

```julia
# Mixed filters example
bulk_update(query, df,
    columns=["new_points" => "points"],
    filters=[
        "record_id" => "id",      # Dynamic: Match DB 'id' with DF 'record_id'
        "category_id" => 172100   # Static: Only update records where DB 'category_id' is 172100
    ]
)
```

**Generated SQL (PostgreSQL):**
```sql
UPDATE "result" AS "Tb" 
SET "points" = "source"."new_points" 
FROM (VALUES 
  (1::bigint, 25::integer), 
  (2::bigint, 18::integer)
) AS "source"("record_id", "new_points") 
WHERE "Tb"."id" = "source"."record_id" 
  AND "Tb"."category_id" = 172100
```

The `filters=` argument is the whole contract for the bulk-update `WHERE` clause. If you already used `query.filter(...)` to prepare the `DataFrame`, switch back to a fresh handler for the write or repeat the predicate in `filters=`.

### Join Limits

- **Base-table lookup operators are supported**: Static filters such as `"points__@in" => [18, 25]` or `"statusid__@isnull" => true` are valid as long as they only reference columns on the model being updated.
- **Relation traversals that require JOINs are rejected**: Filters such as `"statusid__status" => "Finished"` or `"raceid__circuitid__country" => "Italy"` are not allowed on `bulk_update()` because the `VALUES`-driven mutation path cannot safely merge in joined query state.
- **Workaround**: Read the target rows through a normal joined query, mutate the resulting `DataFrame`, then write back through a fresh handler using primary-key filters only.
  
```julia
df = M.Result.objects.filter("statusid__status" => "Finished") |> DataFrame

# Modify data
for row in eachrow(df)
    row.points = row.points + 1
end

# Bulk update by primary key on a fresh handler.
# Do not rely on the earlier .filter(...) state surviving into bulk_update.
bulk_update(M.Result.objects, df, columns=["points"], filters=["resultid"])
```

### Performance Characteristics

- **Atomicity**: All rows updated together or none.
- **Speed**: Much faster than individual `update()` calls (100-1000x for large datasets).
- **Memory**: By default PormG deep-copies the input frame to keep caller-owned data unchanged. Pass `copy=false` to reduce peak memory when you explicitly want in-place mutation.
- **Chunking**: For very large datasets, process the `DataFrame` in chunks:

```julia
# Process in chunks for huge datasets
for chunk_df in Iterators.partition(eachrow(df), 10000)
    chunk = DataFrame(chunk_df)
    # Modify chunk
    bulk_update(query, chunk, columns=["points"], filters=["resultid"])
end
```
