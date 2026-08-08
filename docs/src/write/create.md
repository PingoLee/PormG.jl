# Creating Records

PormG provides methods for inserting data into your database, from single rows to complex related objects. All create operations are **async-aware** and will automatically participate in a transaction context if one is active.

!!! warning "Writes are disabled by default"
    Every write path — `create`, `update`, `delete`, the bulk helpers, the ManyToMany mutators —
    is gated on `change_data`, which defaults to **`false`**. Until you enable it, the first write
    raises `WritesDisabledError` before any SQL is generated. Enable it under the `config:` block
    of the **active environment** in `connection.yml`:

    ```yaml
    dev:
      adapter: postgresql
      # …
      config:
        change_data: true
    ```

    Two things bite here. A `change_data:` key placed anywhere else — at the top level, or outside
    the environment you actually loaded — is **silently ignored**, not an error. And a config
    created by `PormG.setup()` is already write-enabled, while one written by hand or registered
    through `register_connection` is not. See
    [Connection YML](../configuration/connection_yml.md).

## Single Record Creation

Use the `.create()` method to insert individual records. It returns a [`PormGRow`](../read/index.md) — the same row object `get()`, `first()`, and `list()` return — containing the newly created record, including any database-generated fields (like auto-increment primary keys). Because it's a `PormGRow`, you can read fields by dot-access or key, and mutate it and call `.save()` to persist further changes.

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

!!! note "SQLite does not use `RETURNING`"
    The SQL above is the PostgreSQL form. On SQLite, PormG deliberately issues a plain `INSERT`
    and then reads the row back with a follow-up `SELECT` on the **same** connection — SQLite's
    `last_insert_rowid()` is per-connection session state, so the read-back has to share the
    connection. `RETURNING` is avoided because it can hang inside `libsqlite3` for some table
    shapes (observed with an `AUTOINCREMENT` primary key that migrations left in a non-first
    column position). The returned `PormGRow` is identical either way; only the statement count
    differs.

### Return Value

The return value is a `PormGRow` carrying all fields of the inserted record. Read them by dot-access
(`row.name`) or by key (`row[:name]`), exactly like a row from `get()`/`first()`:

```julia
new_record.id            # 172        (auto-generated primary key)
new_record[:name]        # "test"
new_record.test_result   # 1
new_record[:test_result2] # missing   (null/unset fields show as missing)
```

Because it is a live row, you can also mutate it and persist the change:

```julia
new_record.test_result = 2
new_record.save()        # UPDATE ... WHERE id = 172
```

### Reading the primary key

Every row exposes `.pk` — the primary-key value, read from the model's declared pk column, whatever it is
named. It's the model-agnostic way to grab a just-created id:

```julia
new_record.pk            # 172 — the primary key, regardless of the column name
```

Compare that to reading the pk column by its declared name (`new_record[:id]` here; `[:driverid]`,
`[:circuitid]`, or `[:resultid]` for other models), which requires knowing each model's pk name. There is
also a function form, `pk(row)` (brought in by `using PormG`), and a non-throwing variant `pk(row, default)`:

```julia
pk(new_record)           # 172 — same value, function form
pk(new_record, nothing)  # 172, or `nothing` if the pk can't be read (never throws)
```

`.pk` and `pk(row)` throw if the model has no single-column primary key, or the row was fetched without its
pk column selected; `pk(row, default)` returns `default` in those cases instead. A composite (multi-column)
primary key has no scalar `.pk` — read the individual key columns.

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

PormG validates that all non-nullable fields are provided. If a required field is missing, it will raise an `InvalidValueError`.

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
ERROR: InvalidValueError: Error in insert, the field driverref not allow null
```

### Default Values

Fields with default values don't need to be specified:

```julia
# If 'created_at' has a default like CURRENT_TIMESTAMP, you can omit it
record = M.Status.objects.create("status" => "Finished")
# created_at will be set automatically to the current timestamp
```

A default is applied only to a field you **did not pass**. A key you pass is honored as written —
including `"field" => nothing`, which stores SQL `NULL` on a nullable field and raises
`InvalidValueError` on a `null=false` one. The bulk writers follow the identical rule, with
*"a field you did not pass"* reading as *"a column your `DataFrame` does not contain"* — see
[Defaults and Auto Values](bulk.md#Defaults-and-Auto-Values).

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

# The returned row includes the generated ID
generated_id = record[:driverid]
```

**Generated SQL (PostgreSQL):**
```sql
INSERT INTO "driver" ("forename", "surname", "nationality", "driverref", "dob") 
VALUES ($1, $2, $3, $4, $5) 
RETURNING *
-- Parameters: ["Max", "Verstappen", "Dutch", "max_verstappen", '1997-04-01']
```

## Update or Create

`update_or_create` is a Django-style row-level upsert: it inserts a row when the lookup doesn't exist yet, or updates it when it does — in a single atomic `INSERT ... ON CONFLICT ... DO UPDATE` statement (PostgreSQL and SQLite ≥ 3.24). It returns a `(row, created)` tuple, where `row` is a [`PormGRow`](../read/index.md) (dot-access + `.save()`, just like `get()`/`first()`) and `created` is `true` when a new row was inserted, `false` when an existing one was updated.

```julia
# Idempotently seed a status: insert it the first time, refresh its label on re-runs.
row, created = M.Status.objects.update_or_create(
    "statusid" => 3;                       # lookup — becomes the ON CONFLICT target
    defaults = ["status" => "Accident"],   # SET on a conflict, and merged into the INSERT
)

if created
    @info "inserted" row.status
else
    @info "updated existing" row.status
end

# The returned PormGRow can be edited and re-saved (further round-trip):
row.status = "Collision"
row.save()
```

**Generated SQL (PostgreSQL):**
```sql
INSERT INTO "status" ("statusid", "status")
VALUES ($1, $2)
ON CONFLICT ("statusid") DO UPDATE SET "status" = EXCLUDED."status"
RETURNING *, (xmax = 0) AS "__pormg_created"
-- Parameters: [3, "Accident"]
```

`(xmax = 0)` is how PostgreSQL reports whether the row was freshly inserted (`created = true`) or updated (`false`); PormG strips that sentinel column from the returned row.

**On SQLite** the statement is the same `INSERT ... ON CONFLICT ... DO UPDATE` **without** `RETURNING` (which PormG avoids on SQLite — see the note in the single-record section). `created` is derived from a pre-check + read-back run inside SQLite's serialized write transaction (`BEGIN IMMEDIATE` + the writer lock), so it is exact under the writer serialization that always guards writes.

### Rules and behavior

- **Lookup → conflict target.** The lookup pair(s) identify the row and become the `ON CONFLICT (...)` columns. A composite key is fully supported — pass several lookup pairs: `update_or_create("year" => 2024, "round" => 8; defaults = [...])`. The target must be backed by a real UNIQUE/PRIMARY KEY constraint in the database (PormG does not require it to be declared on the model — the database is the source of truth; a missing constraint surfaces as the backend's own error).
- **`defaults` is required** and is the DO UPDATE `SET`. Fields in `defaults` are also merged into the INSERT. `update_or_create` always updates on conflict; when you want to *keep* an existing row untouched, use [`get_or_create`](#get-or-create) instead.
- **Lookup and `defaults` must not overlap** — each field is either a match key or an updated value, never both.
- **`auto_now` fields refresh on the update arm.** Any field with `auto_now = true` is appended to the SET so a conflict updates its timestamp (matching `.save()`/`.update()`); `auto_now_add` fields are create-only and are not refreshed.
- **Field names are logical.** `db_column` mappings are resolved to the physical column names in the rendered SQL.

## Get or Create

`get_or_create` is the no-update sibling of `update_or_create`: it returns an existing row when the lookup matches, or inserts a new one when it doesn't — and **never modifies a matching row**. It returns the same `(row, created)` tuple, where `row` is a [`PormGRow`](../read/index.md) and `created` is `true` only when a new row was inserted.

```julia
# First call for this status → inserted.
row, created = M.Status.objects.get_or_create(
    "statusid" => 200; defaults = ["status" => "Provisional Classification"])
# created == true, row.status == "Provisional Classification"

# Second call with the same lookup → the existing row is returned unchanged.
# The new defaults are IGNORED (get_or_create never updates on a hit).
row, created = M.Status.objects.get_or_create(
    "statusid" => 200; defaults = ["status" => "Something Else"])
# created == false, row.status == "Provisional Classification"  (still the original)
```

### `get_or_create` vs `update_or_create`

| | On a match | `defaults` |
|---|---|---|
| `get_or_create` | returns it **unchanged** | optional — create-only extras used only when inserting |
| `update_or_create` | **updates** it with `defaults` | required — becomes the `SET` |

### Rules and behavior

- **Lookup → conflict target.** As with `update_or_create`, the lookup pair(s) identify the row and, on the create path, become the `ON CONFLICT (...)` columns. The lookup **must be backed by a real UNIQUE/PRIMARY KEY constraint** so a concurrent insert of the same key is a safe no-op rather than a duplicate-key error. A non-unique lookup raises an actionable error pointing you at `filter(...).first()` + `create(...)`.
- **`defaults` is optional** — a bare `get_or_create("statusid" => 200)` is a valid pure get-or-create. `defaults` supplies extra columns applied **only** when a row is inserted.
- **Non-lookup `NOT NULL` columns are needed only on insert.** `get_or_create` runs the `SELECT` first; on a match it returns immediately, so a matching row is returned even if you didn't supply every required column. On a miss the insert must satisfy every `NOT NULL` column (via the lookup, `defaults`, or a model default), exactly like `create`.
- **Race-safe.** The create path runs `INSERT ... ON CONFLICT (lookup) DO NOTHING`, so if a competing writer inserts the same key first, PormG re-reads the winner and returns `created = false` — no duplicate-key crash.

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

On PostgreSQL, creating a record whose foreign key points at a row that does not exist raises
[`IntegrityError`](../errors.md) — the database refused the statement:

```julia
# This will fail if circuitid=9999 doesn't exist
try
    race = M.Race.objects.create(
        "year" => 2025,
        "round" => 1,
        "circuitid" => 9999,  # Does not exist!
        "name" => "Phantom Grand Prix",
        "date" => Date(2025, 3, 23)
    )
catch e
    e isa IntegrityError || rethrow()
    @error "Foreign key constraint violation" msg=error_message(e) adapter=e.adapter
end
```

`IntegrityError` covers every constraint the database enforces — `FOREIGN KEY`, `UNIQUE`,
`NOT NULL`, `CHECK`. It is a `DatabaseError`, so it means the statement *reached* the database and
was rejected there; a value PormG rejects before sending raises `InvalidValueError` instead (see
the null-field example above).

!!! note "Foreign keys are enforced on both backends"
    The insert above raises `IntegrityError` on SQLite as well as PostgreSQL: PormG issues
    `PRAGMA foreign_keys = ON` on every SQLite connection (#276). SQLite itself defaults the pragma
    to **off**, which used to mean a dangling reference stored silently there while failing in
    production PostgreSQL — a bug shape that passed its own test suite.

    Enforcement is **not retroactive**: rows already dangling in an existing database stay as they
    are, and only new statements are checked.

    **Inside a transaction the check happens at `COMMIT`, not at the statement**, on both backends
    (PostgreSQL foreign keys are `DEFERRABLE INITIALLY DEFERRED`; SQLite matches with
    `PRAGMA defer_foreign_keys`). So a block that writes children before their parents commits
    normally — the inconsistency only has to be gone by the end. The example above is autocommit, so
    it raises immediately.

    For the rarer case where a violation must actually persist — a repair, or a load too large for
    one transaction — [`without_foreign_keys`](@ref) suspends enforcement for a block on a single
    pinned connection and verifies the result with `PRAGMA foreign_key_check` before committing.

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
