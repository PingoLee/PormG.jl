## Bulk Operations

Bulk operations are designed for high-performance data manipulation of large datasets. PormG provides three dedicated tools:

- **`bulk_insert()`**: Standard SQL-based insertion with automatic chunking.
- **`bulk_copy()`**: PostgreSQL native `COPY` protocol for ultra-fast insertion.
- **`bulk_update()`**: Efficient multi-row updates from a DataFrame using `match_on=` keys.

All three operations accept `show_query=:sql`, `show_query=:dict`, `show_query=:inspection`, `show_query=:params`, or `show_query=:none` to inspect the generated SQL without executing it. See [Query Inspection](../read/index.md#Query-Inspection) for a full description of each mode.

### The Mapping Adaptor Strategy ⭐

All bulk operations in PormG use a **Mapping Adaptor** approach. This means:
- **Never Mutates, Never Copies**: The pipeline works on a zero-copy wrapper of the input `DataFrame` (shared column vectors). Injected defaults and timestamps are added to that internal frame only — see [Defaults and Auto Values](#Defaults-and-Auto-Values) — so your `DataFrame` is untouched, unconditionally, and no data is duplicated. There is no `copy=` knob because there is nothing to protect against.
- **Flexible Mapping**: Use `columns = ["df_col" => "model_field"]` to map any DataFrame column to any table field.
- **No conflicting target mappings**: A model field may not be mapped from two different `DataFrame` source columns. `columns = ["c1" => "laps", "c2" => "laps"]` raises a `QueryBuildError` instead of silently letting the later entry win — which column survived used to depend on list position. An unambiguous repeat of the *same* source (`["c1" => "laps", "c1" => "laps"]`, or a bare `"laps"` alongside `"laps" => "laps"`) is still accepted, and a bare `"laps"` the frame has no column for claims no source at all, so it may still be paired with an explicit `"c2" => "laps"` mapping.
- **Auto-Detection**: If you don't provide mappings, PormG automatically matches columns to fields by **exact, case-sensitive** name. A column differing only in case from a model field (e.g. `RaceId` vs `raceid`) raises an error instead of being silently folded — normalize first with `rename!(df, lowercase.(names(df)))` or map it explicitly.
- **Centralized Validation**: Every row is automatically checked against the model's constraints (`max_length`, `nullability`, etc.) before reaching the database.
- **Relation Value Semantics**: Foreign-key columns accept scalar key values (including `0` if present in the target table). Use `nothing` or `missing` when you want SQL `NULL` on nullable relation columns.

### Defaults and Auto Values

**For a field the write touches, PormG supplies a value only when your `DataFrame` has no column for it. A column that *is* present is your data, and PormG never rewrites its cells.**

That is one rule covering every fill kind — a static `default`, `auto_now`, `auto_now_add`, and a UUID `auto_add` — across `bulk_insert()`, `bulk_copy()` and `bulk_update()` alike, whether or not the field is nullable.

So a blank cell (`missing` or `nothing`) in a column you supplied means **`NULL`**, exactly as an explicit `"field" => nothing` does in [`create()`](create.md#Default-Values). On a `null=false` field that blank raises `InvalidValueError` — *"null values are not allowed"* — which is PormG's own validation reporting the field by name, not a database constraint error, and it is the same error `create()` raises for the same input. Nothing is persisted: the write is wrapped in a transaction, so a row that fails validation part-way through rolls back the chunks already sent.

To have PormG supply the value, **leave the column out of the `DataFrame`**:

```julia
# Stint = Models.Model("stint",
#     driver    = Models.CharField(),
#     laps      = Models.IntegerField(default = 0, null = true),
#     pit_stops = Models.IntegerField(default = 0))

df = DataFrames.DataFrame(driver = ["Senna", "Prost"], laps = [missing, 71])

bulk_insert(M.Stint.objects, df)
# laps      → NULL, 71   (your column, your cells — the blank is honored)
# pit_stops → 0, 0       (absent from the frame — PormG fills the default)

bulk_insert(M.Stint.objects, DataFrames.select(df, DataFrames.Not(:laps)))
# laps      → 0, 0       (now absent too, so the default applies)
```

Qualifications:

- **A field you leave out of `columns=` is out of scope, not "your data".** If your frame carries a column for it, those cells are not written — you said not to write that field. On `bulk_insert()`/`bulk_copy()` PormG still supplies the field's default or timestamp, which is what lets a partial `columns=` insert satisfy the model's `null=false` columns.
- `bulk_update(..., columns = [...])` does **not** synthesize a static `default` for an absent column — that would overwrite live rows merely because your frame lacks the column. `auto_now`/`auto_now_add` still inject, so timestamps stay current.
- **`match_on` key columns are not null-checked.** They identify rows rather than being written, so a blank cell in one does not raise — it simply matches nothing, since `column = NULL` is never true. Before this rule changed, such a blank was quietly back-filled with the field's `default` and matched the default-valued row instead. (`filters=` fields are exempt from the check too, but they carry constants rather than `DataFrame` columns, so no cell can be blank there.)
- An auto-increment primary key column whose values are **all** blank counts as absent, so the database allocates the ids. A `UUIDField(auto_add = true)` primary key follows the same rule too — see [Auto-Generated Primary Keys](#Auto-Generated-Primary-Keys) for both.

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
# The CSV ships camelCase headers (driverid, driverref, ...); bulk matching is
# case-sensitive, so normalize them to the model's lowercase field names first.
rename!(df, lowercase.(names(df)))

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

### Conflict Handling (ON CONFLICT)

By default a duplicate key aborts the batch. When overlap is *expected* — idempotent re-seeding, or concurrent loaders filling one shared dimension table — attach an `ON CONFLICT` clause with `on_conflict=` instead of catching the error. PostgreSQL and SQLite (≥ 3.24) share the syntax, so the same call works on both backends.

```julia
# The status dimension is re-seeded on every deploy; some rows already exist.
statuses_df = DataFrame(
    statusid = [1, 3, 4, 130],
    status   = ["Finished", "Accident", "Collision", "Withdrew"],
)

# Skip any row whose insert violates a unique constraint
bulk_insert(M.Status.objects, statuses_df, on_conflict = :nothing)

# Skip only when a specific target conflicts
bulk_insert(M.Status.objects, statuses_df,
    on_conflict = (action = :nothing, target = ["statusid"]))

# Upsert: keep the existing row, refresh its label
bulk_insert(M.Status.objects, statuses_df,
    on_conflict = (action = :update, target = ["statusid"], set = ["status"]))
```

**Generated SQL (PostgreSQL):**
```sql
INSERT INTO "status" ("statusid", "status")
VALUES ($1, $2), ($3, $4), ($5, $6), ($7, $8)
ON CONFLICT ("statusid") DO UPDATE SET "status" = EXCLUDED."status"
```

**Accepted forms:**

- `nothing` (default) — no clause; a duplicate key raises, exactly as before.
- `:nothing` — `ON CONFLICT DO NOTHING`, untargeted: *any* unique violation skips the row.
- `(action = :nothing, target = ["field"])` — skip only when the named columns conflict.
- `(action = :update, target = ["field"], set = ["field", ...])` — upsert: on a `target` conflict, overwrite each `set` column with the value the batch tried to insert (`EXCLUDED.column` in SQL). Both `target` and `set` are required for `:update`.

**Rules and behavior:**

- `target` and `set` take **logical model field names**; PormG resolves `db_column` mappings and renders the quoted physical column names.
- `set` columns must participate in the INSERT (be present in the DataFrame / `columns=` selection). `EXCLUDED.col` for a non-inserted column would silently write the column *default* instead of a caller value, so PormG rejects it up front.
- `target` columns must exist on the model, but are **not** required to be declared `unique`/`primary_key` there — the database is the source of truth (partial indexes, constraints created outside PormG). A target with no matching constraint surfaces as the backend's own error (PostgreSQL: *"there is no unique or exclusion constraint matching the ON CONFLICT specification"*).
- **Dedupe the DataFrame on `target` first** when using `:update`. A batch that conflicts with *itself* diverges across engines: PostgreSQL raises *"cannot affect row a second time"*, while SQLite applies rows serially (last one wins). `unique(df, [:statusid])` before the call keeps behavior identical on both.
- With `on_conflict` set, the duplicate-key → sequence-resync retry is **skipped**: a conflict is expected, not a symptom of a stale sequence. A duplicate-key error that still surfaces (a *different* constraint than your target) propagates immediately. The normal post-insert sequence synchronization for explicit primary keys still runs.
- Under `DO NOTHING` with server-generated primary keys, PostgreSQL still consumes sequence values for skipped rows — the standard harmless gaps.
- `bulk_copy()` cannot express `ON CONFLICT` (the COPY protocol has no such clause); use `bulk_insert(...; on_conflict=...)` when duplicates are possible.

### Auto-Generated Primary Keys

Do not prefill an auto-increment primary key with `max(id) + 1` before calling `bulk_insert()` or `bulk_copy()`.

- If the model uses `IDField()` or `AutoField()` and the DataFrame omits the primary key column, PormG leaves that field out of the SQL and lets the database allocate ids through its native sequence, identity, or autoincrement mechanism.
- If the DataFrame includes the primary key column but every value is blank (`missing`, `nothing`, or an empty string), PormG treats that column as omitted for bulk inserts and COPY as well.
- If you want to load explicit primary key values, provide a value for every row. Mixed blank and explicit values are rejected because the bulk path cannot safely express a row-by-row mix of generated and manual ids.

This keeps id allocation concurrency-safe and avoids the collision risks of a client-side `SELECT MAX(id)` allocator.

A `UUIDField(primary_key = true, auto_add = true)` column follows the same absent/all-blank/mixed rules ([#334](https://github.com/PingoLee/PormG.jl/issues/334)): omit the column, or carry it with every cell blank, and PormG mints a fresh, **distinct** `uuid4()` per row; mix blank and explicit cells and it raises, same as an auto-increment pk. `allocate_primary_keys()` (below) does **not** support pre-reserving UUID pks, though — there is nothing to reserve from a database sequence. Generate the values locally instead, before the bulk call, if you need them ahead of the insert:

```julia
df[!, :token] = [UUIDs.uuid4() for _ in 1:DataFrames.nrow(df)]
```

### Pre-allocating Primary Keys for Cross-Table FK Wiring

Sometimes you need the assigned primary key values **before** the insert—for example, when you are loading a parent table and a child table at the same time and need to populate a foreign key column.

Use `allocate_primary_keys()` for this:

```julia
drivers_df = CSV.File("f1/drivers.csv") |> DataFrame
rename!(drivers_df, lowercase.(names(drivers_df)))   # camelCase headers → lowercase fields

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
Critically, PormG tracks this reserved high-water mark in memory within the `TransactionContext` during an open transaction. This guarantees that any subsequent `create()`, `bulk_insert()`, or `allocate_primary_keys()` calls for that table *within the same transaction* will safely skip over the IDs you just reserved. `allocate_primary_keys()` is **self-protecting**: when it is not already running inside a transaction it auto-opens one (`BEGIN IMMEDIATE` plus the in-process write lock), so a bare call is collision-safe even under concurrent writers. Wrapping the full pre-allocation **and** insertion workflow inside `PormG.run_in_transaction` is still recommended — that way a rolled-back insert also releases the IDs you reserved, whereas a standalone allocation whose later insert never lands leaves a harmless gap, exactly like PostgreSQL.

If the DataFrame already contains the primary key column with at least one non-blank value, `allocate_primary_keys()` returns it unchanged so it is safe to call unconditionally in a data-loading pipeline.

#### Notes and Limitations

- **Handler filters are ignored.** `allocate_primary_keys()` operates on the model that backs the handler. Any filters or annotations attached to `M.Model.objects.filter(...)` have no effect — pk allocation is always table-wide.
- **Column dtype narrows.** If you pass a DataFrame with a `Vector{Union{Missing, Int}}` pk column, the returned column is a plain `Vector{Int}`. Downstream code expecting the missing-able element type must be adjusted.
- **PostgreSQL schema scope.** The PG path looks up the sequence via `pg_get_serial_sequence('table', 'col')` without a schema prefix and therefore assumes the model's table lives in the default search path (typically `public`).
- **`clone` keyword.** With the default `clone=true`, the returned `DataFrame` is a genuine copy with independent column vectors — the new pk column exists only on the returned frame, the caller's `DataFrame` is untouched, and later element writes on either frame never affect the other. (Unlike the bulk operations' internal zero-copy working frames, this frame is *returned* to you, so it must not alias your data.) `allocate_primary_keys(handler, df; clone=false)` instead writes the new pk column straight into `df`, for when you deliberately want the caller's frame updated in place.

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
using PormG, LibPQ   # "db_2" is a PostgreSQL connection

# All inserts succeed together, or all fail together
PormG.run_in_transaction("db_2") do
    bulk_insert(M.Driver.objects, df)
end
```

### Error Handling Examples

```julia
# Detect duplicate key errors
# (if duplicates are EXPECTED, prefer on_conflict = :nothing — see Conflict Handling above)
try
    bulk_insert(M.Driver.objects, df)
catch e
    e isa IntegrityError || rethrow()
    @warn "Some rows violate a constraint" msg=error_message(e) adapter=e.adapter
end
```

`IntegrityError` is what the database itself refused — `UNIQUE`, `FOREIGN KEY`, `NOT NULL`,
`CHECK`. Match on the **type**, never on the message: the wording differs between PostgreSQL and
SQLite and is not part of any contract. See [Error Handling](../errors.md) for the full set.

```julia
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

!!! note
    The COPY protocol cannot express `ON CONFLICT` — a single duplicate row makes the whole COPY fail. When duplicates are possible, use `bulk_insert(...; on_conflict = ...)` instead (see [Conflict Handling](#conflict-handling-on-conflict)).

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

Row-level writers (`create`, `update_or_create`, `get_or_create`) do not resync automatically — see
[`resync_sequences`](../schema_conventions.md#Explicit-repair:-resync_sequences) for repairing a
sequence after one of those, or after any load that happened outside PormG entirely.

### Real-World Example: Loading F1 Season Data

```julia
using CSV, DataFrames
import .models as M

# Load initial reference data
# The Ergast CSVs ship camelCase headers (circuitid, driverref, ...); bulk matching is
# case-sensitive, so normalize headers to the model's lowercase fields before loading.
circuits_df = CSV.File("f1/circuits.csv") |> DataFrame
rename!(circuits_df, lowercase.(names(circuits_df)))
M.Circuit.objects.exists() && M.Circuit.objects.delete(allow_delete_all=true)
bulk_copy(M.Circuit.objects, circuits_df)

# Load drivers
drivers_df = CSV.File("f1/drivers.csv") |> DataFrame
rename!(drivers_df, lowercase.(names(drivers_df)))
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
bulk_copy(M.Result.objects, results_df)

# Verify all data loaded
@info "Data loaded" \
    circuits=M.Circuit.objects.count() \
    drivers=M.Driver.objects.count() \
    races=M.Race.objects.count() \
    results=M.Result.objects.count()
```

---

## Bulk Update

`bulk_update()` updates multiple rows from a `DataFrame`. It separates three concerns:

- **`columns=`** — the **participating fields and their mappings**. This is the **single place** a DataFrame column is mapped to a model field (`"df_col" => "model_field"`, or a bare string when the names match). Fields selected by `match_on=` are used for matching only — they are **not** SET.
- **`match_on=`** — the **per-row match keys** that identify which row each DataFrame row updates (the merge condition `Tb.field = source.field`). Bare **model field names** only; the source column is the `columns=` mapping for that field when declared, otherwise a DataFrame column with the field's own name. If omitted, the model primary key(s) are used.
- **`filters=`** — **constant** predicates AND'd onto every row's `WHERE` (`"model_field" => value`), e.g. `"category_id" => 172100` or `"points__@in" => [18, 25]`.

**One border crossing.** `columns=` is the only argument where DataFrame names appear; `match_on=` and `filters=` always speak the model's field language. That keeps every `=>` in the bulk API meaning the same thing — "df column *to* model field" — and it appears exactly once.

PormG validates every row up front, then emits a multi-row `UPDATE` using a `VALUES` source (PostgreSQL) or `WITH source(...) AS (VALUES ...)` form (SQLite).

!!! note "Migrated from a single `filters=` argument"
    Earlier versions packed both row-matching keys and constant predicates into `filters=`. Row matching now lives in `match_on=`. Passing a per-row match key in `filters=` (a bare string, or a `"df_col" => "model_field"` pair) raises an error telling you to move it to `match_on=` — there is no silent fallback.

    This migration error is a **temporary deprecation aid** and will be removed in a future release; once your call sites use `match_on=`, you will not see it again.

!!! note "Migrated from the `match_on=` pair grammar (#107)"
    Earlier versions also accepted `"df_col" => "model_field"` pairs in `match_on=`, so the same mapping could be declared in two places. Pairs in `match_on=` now raise a migration error showing the rewrite: move the pair into `columns=` and keep the bare field name in `match_on=` — e.g. `match_on=["record_id" => "id"]` becomes `columns=[..., "record_id" => "id"], match_on=["id"]`. Like the `filters=` shim above, this error is temporary.

### Basic Usage

```julia
# Get existing data
query = M.Result.objects
df = query |> DataFrame

# Modify data in the DataFrame
for row in eachrow(df)
    row.points = row.points + 1
end

# Bulk update specifying the columns to SET and the keys that identify each row
bulk_update(query, df,
    columns=["points"],       # SET: auto-matches 'points' in the DataFrame
    match_on=["resultid"]     # match key: auto-matches 'resultid' in the DataFrame
)
```

**Generated SQL (PostgreSQL):**
```sql
UPDATE "result" AS "Tb" 
SET "points" = source."points"::double precision 
FROM (VALUES 
  (26.0::double precision, 1::bigint), 
  (19.0::double precision, 2::bigint),
  -- ... (chunked multi-row values)
) AS source ("points", "resultid") 
WHERE "Tb"."resultid" = source."resultid"::bigint
```

The `VALUES` source columns are always the **model field names** (`points`, `resultid`), in SET-fields-then-match-keys order — never the DataFrame column names. The DataFrame mapping is applied when reading the values into the parameters, so the SQL you inspect is always expressed in model terms.

```julia
# Using explicit mapping (Adaptor style)
# This allows using a DataFrame with totally different column names
custom_df = DataFrame(
    "new_score" => [25, 18, 15],
    "record_id" => [1, 2, 3]
)

bulk_update(query, custom_df,
    columns=["new_score" => "points",       # SET: map 'new_score' to field 'points'
             "record_id" => "id"],          # mapping for the match key (not SET)
    match_on=["id"]                         # merge key, by model field name
)
```

**Generated SQL (PostgreSQL):** the mapped DataFrame names (`new_score`, `record_id`) do **not** appear — the source is named with the model fields they map to (`points`, `id`):
```sql
UPDATE "result" AS "Tb" 
SET "points" = source."points"::integer 
FROM (VALUES 
  (25::integer, 1::bigint), 
  (18::integer, 2::bigint), 
  (15::integer, 3::bigint)
) AS source ("points", "id") 
WHERE "Tb"."id" = source."id"::bigint
```

### Matching and Execution Rules

- **Case-sensitive DataFrame matching**: PormG resolves `columns` and `match_on` against `DataFrame` column names **exactly**. A name that differs only in case from the model field (e.g. `ID` vs `id`) is rejected with an error that names the candidate column and suggests the fix — either `rename!(df, lowercase.(names(df)))` or an explicit `"DF_COL" => "field"` mapping in `columns=`. (An explicit `columns=` mapping is always honored, even when its source column differs in case from the field name.)
- **Mapping-first match keys**: A `match_on` field with a `columns=` mapping always uses that mapping as its source. If the `DataFrame` *also* carries a column with the field's own name, the mapping still wins and the same-named column is ignored — with a warning, so the ambiguity is visible.
- **Primary key fallback**: If you omit `match_on=`, `bulk_update()` infers the model primary key column(s) and expects those columns to be present in the `DataFrame` (or mapped in `columns=`).
- **Missing column errors**: A `match_on` field with no source — no `columns=` mapping and no same-named `DataFrame` column — raises an `UnknownFieldError` rather than silently degrading to a constant filter. An explicit `columns=` mapping (`"df_col" => "field"`) whose source column is absent likewise raises — it is never silently bound to a non-existent column.
- **Handler filters are rebuilt**: `bulk_update()` clears any filters already attached to the query handler and rebuilds the `WHERE` clause from `match_on=` and `filters=`. Pass every predicate you need through those arguments rather than relying on prior `query.filter(...)` state.
- **Dry-run support**: `show_query=:dict` and `show_query=:inspection` return metadata, `:sql` returns SQL text, `:params` returns the bound parameter list, and `:none` builds the statement and returns `nothing` without executing.
- **Empty input is a no-op**: An empty `DataFrame` returns `nothing` after logging a warning.
- **Nullable columns accept all-`missing` batches**: If a nullable update column is `missing` for every targeted row, PormG writes SQL `NULL` for every row in that column — **including a column that carries a static `default`**, which is not written back over your blanks (see [Defaults and Auto Values](#Defaults-and-Auto-Values)).

### Migrating existing `bulk_update()` calls

If you have application code written against the older single-`filters=` API, update
each call by splitting `filters=` into **`match_on=`** (row-matching keys) and
**`filters=`** (constant predicates). The transformation is mechanical:

| Old call | New call |
|----------|----------|
| `filters=["id"]` | `match_on=["id"]` |
| `filters=["record_id" => "id"]` | `columns=[..., "record_id" => "id"], match_on=["id"]` |
| `match_on=["record_id" => "id"]` *(pre-#107 pair)* | `columns=[..., "record_id" => "id"], match_on=["id"]` |
| `filters=["id", "category_id" => 172100]` | `match_on=["id"], filters=["category_id" => 172100]` |
| `filters=["category_id" => 172100]` *(constant only)* | unchanged — stays in `filters=` |
| `filters=[]` or `filters` omitted | unchanged — the primary key is inferred |

**Rule of thumb:**

- If an entry references a **DataFrame column** it is a per-row key: the bare field name
  goes to `match_on=`, and any `"df_col" => "field"` mapping goes to `columns=` (a field
  listed in both is used for matching only — it is never SET).
- If an entry is `"field" => value` with a **literal value** (number, string, bool,
  array, `__@` lookup) → it is a constant predicate → leave it in `filters=`.

**How to update your apps:** search each project for `bulk_update(` and inspect its
`filters=`. The fastest path is to **run the app or its tests** — every old per-row
key still passed in `filters=` now raises a `QueryBuildError` that names the offending
key and tells you to move it to `match_on=`. Fix them one at a time until the errors
stop. Calls that only ever passed constant `field => value` predicates (or no
`filters=` at all) need no change.

!!! warning "The migration error is temporary"
    The `QueryBuildError` that detects the old per-row-key-in-`filters=` usage is a
    transitional aid for updating existing call sites. Once your applications are
    migrated it can be removed from PormG (see the `DEPRECATION SHIM` block in
    `src/querybuilder/execution_bulk.jl`); after removal, the same mistake surfaces
    as a generic "filters entry is not a constant predicate" error instead.

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
    bulk_update(query, df, columns=["points"], match_on=["resultid"])
end
```

### Match Keys and Constant Filters

`bulk_update()` combines **per-row match keys** (`match_on=`, driven by DataFrame values) with **constant filters** (`filters=`, the same value for every row).

- **`match_on=`**: bare model field names, e.g. `["id"]`. Each key's per-row values come from the DataFrame — through the `columns=` mapping when one is declared, otherwise from the same-named DataFrame column; the keys identify which row each DataFrame row updates.
- **`filters=`**: `["status" => "active"]`. Always a constant predicate AND'd onto the `WHERE` clause for every row.

```julia
# Per-row match key + constant scope guard
bulk_update(query, df,
    columns=["new_points" => "points",
             "record_id" => "id"],    # mapping for the match key (not SET)
    match_on=["id"],                  # match DB 'id' against DF 'record_id'
    filters=["category_id" => 172100] # constant: only rows where category_id is 172100
)
```

**Generated SQL (PostgreSQL):** again the source columns are the model fields (`points`, `id`), not the DataFrame names (`new_points`, `record_id`):
```sql
UPDATE "result" AS "Tb" 
SET "points" = source."points"::integer 
FROM (VALUES 
  (25::integer, 1::bigint), 
  (18::integer, 2::bigint)
) AS source ("points", "id") 
WHERE "Tb"."id" = source."id"::bigint 
  AND "Tb"."category_id" = 172100
```

Together, `match_on=` and `filters=` are the whole contract for the bulk-update `WHERE` clause. If you already used `query.filter(...)` to prepare the `DataFrame`, switch back to a fresh handler for the write or repeat the predicate in `filters=`.

### Join Limits

- **Base-table lookup operators are supported**: Static filters such as `"points__@in" => [18, 25]` or `"statusid__@isnull" => true` are valid as long as they only reference columns on the model being updated.
- **Relation traversals that require JOINs are rejected**: Constant filters such as `"statusid__status" => "Finished"` or `"raceid__circuitid__country" => "Italy"` are not allowed on `bulk_update()` because the `VALUES`-driven mutation path cannot safely merge in joined query state.
- **Workaround**: Read the target rows through a normal joined query, mutate the resulting `DataFrame`, then write back through a fresh handler matching on the primary key only.
  
```julia
df = M.Result.objects.filter("statusid__status" => "Finished") |> DataFrame

# Modify data
for row in eachrow(df)
    row.points = row.points + 1
end

# Bulk update by primary key on a fresh handler.
# Do not rely on the earlier .filter(...) state surviving into bulk_update.
bulk_update(M.Result.objects, df, columns=["points"], match_on=["resultid"])
```

### Performance Characteristics

- **Atomicity**: All rows updated together or none.
- **Speed**: Much faster than individual `update()` calls (100-1000x for large datasets).
- **Memory**: PormG never copies the input frame — the pipeline works on a zero-copy wrapper (shared column vectors), and caller-owned data is unconditionally unchanged. Peak memory is bounded by the ORM-side columns it adds internally (e.g. `updated_at`), not by your data.
- **Chunking**: For very large datasets, process the `DataFrame` in chunks:

```julia
# Process in chunks for huge datasets
for chunk_df in Iterators.partition(eachrow(df), 10000)
    chunk = DataFrame(chunk_df)
    # Modify chunk
    bulk_update(query, chunk, columns=["points"], match_on=["resultid"])
end
```
