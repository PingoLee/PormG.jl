---
name: pormg-usage
description: Use PormG.jl to define models, manage migrations, and write expressive database queries using the Django-inspired fluent API in Julia.
user-invocable: true
---

# PormG.jl — AI Usage Guide

## Purpose

Use this skill whenever you need to write, refactor, or debug code in a project that uses **PormG.jl** — a Django-inspired async-first ORM for Julia.

PormG exposes a fluent, expressive query API. Your default posture is:
- Write through `M.Model.objects` and chainable methods — never raw SQL.
- Use parameterized queries. Never interpolate user data into SQL strings.
- Prefer `DataFrame` output for analytics; prefer `list()` for programming logic.

---

## 1. Project Setup

```julia
using PormG

# First-time setup (interactive)
PormG.setup()   # configures db/connection.yml and optionally installs AI skills

# Load configuration (must happen BEFORE importing models)
PormG.Configuration.load("db")

# Import models with hot-reload support
PormG.@import_models "db/models.jl" models
import .models as M
```

---

## 2. Defining Models

Models live in a module (typically `db/models.jl`). Use `Models.Model(...)` and call `set_models` at the end.

```julia
module models
import PormG.Models

# Table name is the first positional argument (lowercase, snake_case)
Driver = Models.Model("drivers",
    driverid    = Models.IDField(),
    driverref   = Models.CharField(max_length=255),
    forename    = Models.CharField(max_length=50),
    surname     = Models.CharField(max_length=50),
    nationality = Models.CharField(max_length=50, null=true),
    dob         = Models.DateField(null=true),
    code        = Models.CharField(max_length=3, null=true),
    number      = Models.IntegerField(null=true),
    url         = Models.URLField(null=true),
)

Constructor = Models.Model("constructors",
    constructorid = Models.IDField(),
    name          = Models.CharField(max_length=255),
    nationality   = Models.CharField(max_length=50, null=true),
)

Race = Models.Model("races",
    raceid      = Models.IDField(),
    year        = Models.IntegerField(),
    name        = Models.CharField(max_length=255),
    date        = Models.DateField(),
    circuitid   = Models.ForeignKey("Circuit", on_delete="CASCADE"),
)

Result = Models.Model("results",
    resultid      = Models.IDField(),
    raceid        = Models.ForeignKey("Race", on_delete="CASCADE"),
    driverid      = Models.ForeignKey("Driver", on_delete="RESTRICT"),
    constructorid = Models.ForeignKey("Constructor", on_delete="RESTRICT"),
    positionorder = Models.IntegerField(),
    points        = Models.FloatField(null=true),
    laps          = Models.IntegerField(null=true),
    grid          = Models.IntegerField(null=true),
)

Models.set_models(@__MODULE__, @__DIR__)  # Always required at end
end
```

### Naming Conventions (Mandatory)
- **Models**: Capitalized, singular, snake_case for multi-word: `Driver`, `Race`, `Order_item`
- **Field names**: Lowercase, snake_case: `first_name`, `created_at`
- **Never use `__`** in field or table names — reserved for ORM join traversal
- Prefix reserved Julia keywords: `_id`, `_type`, `_end`

---

## 3. Field Types Reference

| Field | DB Type (PG/SQLite) | Key Parameters |
| :--- | :--- | :--- |
| `IDField()` | `BIGINT IDENTITY` / `INTEGER PK` | `generated_always` |
| `AutoField()` | `INTEGER SERIAL` / `INTEGER PK` | — |
| `CharField(max_length)` | `VARCHAR(n)` | `max_length`, `choices`, `default` |
| `TextField()` | `TEXT` | `null`, `blank` |
| `EmailField()` | `VARCHAR` | `max_length=254` |
| `URLField()` | `VARCHAR` | `max_length=200` |
| `SlugField()` | `VARCHAR` | `max_length=50`, defaults `db_index=true` |
| `UUIDField()` | `UUID` / `TEXT` | `auto_add=true` for auto-generation |
| `IntegerField()` | `INTEGER` | `default`, `null` |
| `BigIntegerField()` | `BIGINT` | — |
| `FloatField()` | `DOUBLE PRECISION` | rejects `Inf`, `NaN` |
| `DecimalField(...)` | `NUMERIC(p,s)` | `max_digits`, `decimal_places` |
| `BooleanField()` | `BOOLEAN` | `default` |
| `DateField()` | `DATE` | `auto_now_add`, `auto_now` |
| `DateTimeField()` | `TIMESTAMPTZ` | `auto_now_add`, `auto_now`, `type="TIMESTAMP"` |
| `TimeField()` | `TIME` | — |
| `DurationField()` | `INTERVAL` | — |
| `JSONField()` | `JSONB` / `TEXT` | accepts `Dict`, `Vector`, scalars |
| `ForeignKey(model)` | `BIGINT` + FK constraint | `on_delete`, `related_name` |
| `OneToOneField(model)` | `BIGINT` UNIQUE + FK | `on_delete` |
| `PasswordField()` | `VARCHAR(128)` | `auto_hash=true` — never stores plaintext |
| `ImageField()` | `VARCHAR` | stores file path |
| `BinaryField()` | `BYTEA` | — |

**Common parameters (all fields):** `null=false`, `blank=false`, `unique=false`, `default=nothing`, `db_index=false`, `db_column=nothing`, `editable=true`

**`on_delete` options:** `"CASCADE"`, `"RESTRICT"`, `"PROTECT"`, `"SET_NULL"`, `"SET_DEFAULT"`, `"DO_NOTHING"`

---

## 4. Migrations

Always follow this ordered flow:

```julia
using PormG

# 1. First-time initialization (safe to run on existing DBs)
PormG.Migrations.init_migrations("db")

# 2. Check current state
PormG.Migrations.status("db")

# 3. Generate migration plan from current models
PormG.Migrations.makemigrations("db")

# 4. Dry-run: review SQL before executing (check for destructive ops)
PormG.Migrations.dry_run("db")

# 5. Apply migrations
PormG.Migrations.migrate("db")

# For destructive changes (column drops, renames), opt in explicitly:
PormG.Migrations.migrate("db", destructive=true)
```

> **Never** skip `dry_run()` before a destructive migration. If it reports DROP columns, require explicit approval.

---

## 5. Reading Data — Query Patterns

### Core pattern

```julia
query = M.Driver.objects

query.filter("nationality" => "Brazilian")
query.order_by("surname")
query.limit(10)

rows = query.list()         # Vector{Dict{Symbol, Any}}
df   = query |> DataFrame   # DataFrames.DataFrame
```

### Chainable methods

| Method | Description |
| :--- | :--- |
| `.filter(key => value, ...)` | Add WHERE conditions (AND). Multiple pairs are ANDed. |
| `.values("field", ...)` | Select specific columns. `"*"` = all main-table columns. |
| `.order_by("field", "-field")` | Sort. Prefix `-` for descending. |
| `.limit(n)` | Limit rows returned. |
| `.offset(n)` | Skip first `n` rows. |
| `.db("key")` | Route to a different connection pool. |
| `.on("path", key => value)` | Add ON-clause predicates to an existing join. |

### Terminal (execution) methods

| Method | Returns | Description |
| :--- | :--- | :--- |
| `.list()` | `Vector{Dict}` | All matching rows as dicts. |
| `.all()` | `Vector{Dict}` | Alias for `.list()`. |
| `query \|> DataFrame` | `DataFrame` | Tabular output. |
| `.first()` | `Dict` or `nothing` | First matching row. |
| `.count()` | `Int` | `SELECT COUNT(*)`. |
| `.exists()` | `Bool` | True if any rows match. |
| `.list_json()` | `String` | Results as JSON string. |

---

## 6. Joins and Lookups

### Relationship traversal
Use `__` to traverse ForeignKey relationships:

```julia
# Filter by joined field
M.Result.objects.filter("driverid__nationality" => "British")

# Deep traversal
M.Result.objects.filter("raceid__circuitid__country" => "Monaco")

# Select joined fields
M.Result.objects
    .values("driverid__forename", "driverid__surname", "raceid__year", "points")
    .order_by("-points")
```

### Filter operators
Append `__@operator` to any field path:

| Operator | SQL | Example |
| :--- | :--- | :--- |
| (none) | `=` | `"nationality" => "British"` |
| `__@gt` | `>` | `"points__@gt" => 10` |
| `__@gte` | `>=` | `"points__@gte" => 10` |
| `__@lt` | `<` | `"positionorder__@lt" => 3` |
| `__@lte` | `<=` | `"laps__@lte" => 50` |
| `__@ne` | `<>` | `"status__@ne" => "Retired"` |
| `__@in` | `IN (...)` | `"nationality__@in" => ["British", "French"]` |
| `__@nin` | `NOT IN` | `"nationality__@nin" => ["German"]` |
| `__@range` | `BETWEEN` | `"driverid__@range" => [1, 50]` |
| `__@isnull` | `IS NULL` | `"dob__@isnull" => true` |
| `__@contains` | `LIKE '%v%'` | `"name__@contains" => "Monaco"` |
| `__@icontains` | `ILIKE '%v%'` | `"name__@icontains" => "monaco"` |

### Date transforms
| Transform | Description |
| :--- | :--- |
| `__@year` | Extract year |
| `__@month` | Extract month |
| `__@day` | Extract day |
| `__@quarter` | Extract quarter (1–4) |
| `__@date` | Extract date part from datetime |

---

## 7. Complex Filters: Q Objects

Use `Q()` for AND logic and `Qor()` for OR logic when `.filter()` pairs are insufficient:

```julia
using PormG: Q, Qor

# OR: British OR Brazilian drivers
M.Driver.objects.filter(Qor("nationality" => "British", "nationality" => "Brazilian"))

# Combined AND + OR
M.Result.objects.filter(
    Q("points__@gt" => 10),
    Qor("driverid__nationality" => "British", "driverid__nationality" => "Brazilian")
)
```

---

## 8. F-Expressions

`F("fieldname")` creates a database-side field reference. Use for atomic updates and computed columns.

```julia
using PormG: F

# Atomic increment (no read-modify-write race)
M.Result.objects.filter("resultid" => 1).update("points" => F("points") + 1)

# Field-to-field copy
M.Result.objects.filter("resultid" => 5).update("grid" => F("positionorder"))

# Computed column in SELECT
M.Result.objects.values(
    "driverid__surname",
    "bonus" => F("points") * 0.1
)

# Field-to-field comparison in filter
M.Result.objects.filter(F("grid") == F("positionorder"))

# Cross-join arithmetic
M.Result.objects.filter(
    F("driverid__dob__@month") == F("raceid__date__@month")
)
```

---

## 9. Writing Data

### Create a single record
```julia
driver = M.Driver.objects.create(
    "forename"    => "Ayrton",
    "surname"     => "Senna",
    "nationality" => "Brazilian",
    "driverref"   => "senna"
)
# Returns Dict with all fields including the new PK
```

### Update matching records
```julia
M.Driver.objects
    .filter("driverid" => 1)
    .update("nationality" => "Brazil")

# With F-expression (atomic)
M.Result.objects
    .filter("resultid__@in" => [1, 2, 3])
    .update("points" => F("points") * 1.1)
```

### Delete records
```julia
# Delete with filter
M.Result.objects.filter("raceid__year__@lt" => 1960).delete()

# Inspect before deleting (never executes)
sql = M.Result.objects.filter("raceid" => 999).delete(show_query=:sql)

# Delete all (requires explicit opt-in to prevent accidents)
M.Just_a_test_deletion.objects.delete(allow_delete_all=true)
```

---

## 10. Bulk Operations

For large datasets, always use bulk operations instead of loops:

```julia
using CSV, DataFrames

# Standard batch insert (all dialects)
df = CSV.File("drivers.csv") |> DataFrame
bulk_insert(M.Driver.objects, df)
bulk_insert(M.Driver.objects, df, chunk_size=500)  # custom chunk size

# Ultra-fast COPY (PostgreSQL only — 10-100x faster than bulk_insert)
bulk_copy(M.Driver.objects, df)
bulk_copy(M.Driver.objects, df, chunk_size=10_000)

# Map DataFrame columns to model fields
bulk_copy(M.Driver.objects, df, columns=[
    "first_name" => "forename",
    "last_name"  => "surname"
])

# Batch update from DataFrame
bulk_update(M.Result.objects, df,
    columns = ["points"],     # fields to SET
    filters = ["resultid"]    # fields to match on (WHERE)
)
```

**Pre-process CSV nulls before bulk operations:**
```julia
for col in [:position, :milliseconds, :rank]
    df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
end
```

---

## 11. Transactions

```julia
using PormG

# Wrap multiple operations in a single atomic transaction
PormG.run_in_transaction("db") do
    M.Race.objects.create("year" => 2025, "name" => "New Race", "date" => today())
    bulk_insert(M.Result.objects, results_df)
end
# All operations commit together, or all roll back on error
```

---

## 12. Query Inspection & Debugging

Every terminal method accepts `show_query`:

| Mode | Returns | Use |
| :--- | :--- | :--- |
| `:execute` | query result | Default — runs the query |
| `:sql` | `String` | Print the SQL without executing |
| `:dict` | `Dict` | Full metadata: sql, params, dialect, operation |
| `:params` | `Array` | Parameters only |
| `:none` | `nothing` | Benchmark the builder with zero overhead |

```julia
query = M.Driver.objects.filter("nationality" => "British")

# Inspect SQL
sql = query.list(show_query=:sql)

# Full metadata (useful for mutations — update, delete, bulk ops)
meta = query.update("nationality" => "GB", show_query=:dict)
println(meta[:sql])
println(meta[:parameters])

# Inspect SELECT queries without executing
using PormG: inspect_query
inspection = query |> inspect_query()
println(inspection[:sql])
println(inspection[:dialect])
```

---

## 13. Multi-Database & Multi-Tenancy

```julia
# Route a single query to a different connection pool
M.Driver.objects.filter("nationality" => "British").db("reporting").list()

# Load multiple connections
PormG.Configuration.load_many(["db/conn_primary.yml", "db/conn_replica.yml"])
```

---

## 14. Anti-Patterns

| Anti-Pattern | Preferred Alternative |
| :--- | :--- |
| Raw SQL strings | Fluent `filter()`, `values()`, `update()` |
| `query \|> list` (free function) | `query.list()` |
| `delete(query)` (free function) | `query.delete()` |
| `SELECT *` across joins | `.values("*", "joined__field")` explicitly |
| Loops for batch inserts | `bulk_insert()` or `bulk_copy()` |
| Python-style `annotate()` | `values("alias" => F("field") * 1.5)` |
| `F("points") > 20` in filter | `"points__@gt" => 20` (suffix syntax) |
| Modifying fixture data to fit model | Normalize at import time |
| Skipping `dry_run()` before migrate | Always run `dry_run()` first |
