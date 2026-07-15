# API Reference

## Overview

PormG provides a Django-inspired ORM for Julia with an async-first architecture. This page serves as a comprehensive reference for all exported functions, types, and the query builder API. For topic-specific guides, see the [Reading](read/index.md) and [Writing](write/index.md) sections.

---

## Query Builder: Functor API

PormG uses a Django-style, object-oriented query builder. All database operations start from `Model.objects` and are chained using methods that either modify the query or execute it.

```julia
# The general pattern
results = M.Driver.objects
    .filter("nationality" => "Brazilian")
    .values("forename", "surname")
    .order_by("surname")
    .limit(10)
    .list()
```

### Chainable Methods

These methods modify the query builder and return the handler for further chaining:

| Method | Description | Example |
| :--- | :--- | :--- |
| `.filter(key => value, ...)` | Add WHERE conditions (AND). Multiple pairs are ANDed. | `.filter("nationality" => "British")` |
| `.values("field1", "field2", ...)` | Select specific columns. Use `"*"` for all main-table columns. | `.values("*", "driverid__surname")` |
| `.order_by("field", "-field")` | Sort results. Prefix with `-` for descending. | `.order_by("-points", "surname")` |
| `.limit(n)` | Limit the number of returned rows. | `.limit(10)` |
| `.offset(n)` | Skip the first `n` rows. | `.offset(20)` |
| `.db("key")` | Route the query to a different connection pool. | `.db("tenant_42")` |
| `.on("path", key => value)` | Add predicates to the ON clause of an existing join path. | `.on("driverid", "nationality" => "British")` |
| `.cjoin("field" => "Model", ...)` | Add a custom join at query time. | `.cjoin("driverid" => "Driver")` |

See also: [`.cjoin()`](#cjoin) for custom join definitions and [`.with()`](#with-common-table-expressions) for CTEs.

> [!IMPORTANT]
> Queries that use `.cjoin()` **must** call `.values(...)` explicitly before execution.
> A bare `SELECT *` across joined tables causes `DataFrames.jl` to crash with
> `ArgumentError: Duplicate variable names`. PormG throws a clear error if you forget.
> Use `.values("*", "joined_model__field")` to quickly select all main-table columns
> plus specific fields from the joined table.

### Terminal Methods

These methods finalize the query and execute it against the database:

| Method | Return Type | Description |
| :--- | :--- | :--- |
| `.list()` | `Vector{PormGRow}` | Returns model-aware rows with dot-access and relationship accessors. |
| `.list(:dict)` | `Vector{Dict{Symbol, Any}}` | Returns plain dictionaries for framework integrations that need real `Dict` values. |
| `.list(:json)` | `String` | Returns results as a JSON string. |
| `query \|> DataFrame` | `DataFrame` | Pipe to `DataFrame` for tabular output. |
| `.count()` | `Int` | Runs `SELECT COUNT(*)` and returns the count. |
| `.exists()` | `Bool` | Returns `true` if at least one row matches. |
| `.first()` | `PormGRow` or `nothing` | Returns the first matching record or `nothing`. |
| `.get(filters...)` | `PormGRow` | Returns exactly one row, or raises `DoesNotExist` / `MultipleObjectsReturned`. |
| `.create(key => value, ...)` | `Dict` | Inserts a single record and returns it. |
| `.update(key => value, ...)` | — | Updates all matching records. |
| `.delete()` | — | Deletes all matching records. |

### `PormGRow` Instance Methods

Rows returned by `.list()`, `.first()`, and `.get()` expose model-aware property access and instance-level persistence:

| Method | Return Type | Description |
| :--- | :--- | :--- |
| `row.field` | value | Reads a selected field using normalized Julia-style field names. |
| `row[:field]` | value | Reads a selected field by `Symbol` or `String`. |
| `row.relationship` | `ManyToManyManager` | Accesses a many-to-many relationship manager when the model defines one. |
| `row.save()` | `PormGRow` | Persists fields assigned on the row and clears its dirty state. |
| `row.save(show_query=:sql)` | `Vector` | Returns planned `UPDATE` inspection payloads without executing or clearing dirty state. |

```julia
driver = M.Driver.objects.get("driverref" => "hamilton")
driver.nationality = "British"
driver.save()
```

`row.save()` requires a model with exactly one primary key. Primary-key assignments are rejected, and a row fetched without the primary key selected cannot be saved.

**Example:**

```julia
# Full query chain with DataFrame output
df = M.Result.objects
    .filter("driverid__nationality" => "Brazilian", "positionorder" => 1)
    .values("driverid__forename", "driverid__surname", "raceid__year")
    .order_by("-raceid__year") |> DataFrame

# Count and existence checks
n = M.Driver.objects.filter("nationality" => "British").count()
has_british = M.Driver.objects.filter("nationality" => "British").exists()
```

---

## Query Inspection & Debugging

### `show_query`

An integrated switch available on all terminal methods to toggle between execution and inspection.

| Mode | Description |
| :--- | :--- |
| `:execute` | Default. Executes the query and returns results. |
| `:sql` | Returns the SQL string only. Minimal overhead for benchmarking. |
| `:dict` | Returns full metadata dictionary (sql, parameters, dialect, model, operation, etc.). |
| `:inspection` | Alias of `:dict`. Useful when you want the same rich metadata shape used by `inspect_query()`. |
| `:params` | Returns the parameters array only. |
| `:none` | Returns `nothing`. Zero-overhead mode for benchmarking the builder itself. |

```julia
query = M.Driver.objects.filter("nationality" => "British")

# Get just the SQL string
sql = query.list(show_query=:sql)

# Benchmark the builder without execution overhead
@time query.list(show_query=:none)

# Get full metadata
meta = query.list(show_query=:dict)
```

### `inspect_query`

Dedicated API for comprehensive query inspection without executing. Features a **heuristic intent detector** that guesses the operation type (select, insert, update) based on the object state.

```julia
query = M.Driver.objects.filter("nationality" => "Brazilian").order_by("surname")
inspection = query |> inspect_query()

println(inspection[:sql])        # The generated SQL
println(inspection[:parameters]) # Bound parameters
println(inspection[:operation])  # Automatically detects :select
println(inspection[:dialect])    # :postgresql or :sqlite
```

> [!NOTE]
> `LIMIT` and `OFFSET` values are rendered as literal integers in the SQL string. They do **not** appear in `inspection[:parameter_buckets]` or `inspection[:parameters]`. This is by design.

---

## Filter Operators

PormG uses `__@` suffixes for lookup operators and field transforms:

### Comparison Operators

| Operator | SQL Equivalent | Example |
| :--- | :--- | :--- |
| `field` | `= value` | `"nationality" => "British"` |
| `field__@gt` | `> value` | `"points__@gt" => 10` |
| `field__@gte` | `>= value` | `"points__@gte" => 10` |
| `field__@lt` | `< value` | `"positionorder__@lt" => 3` |
| `field__@lte` | `<= value` | `"positionorder__@lte" => 10` |
| `field__@ne` | `<> value` | `"status__@ne" => "Retired"` |
| `field__@in` | `IN (...)` | `"nationality__@in" => ["British", "French"]` |
| `field__@nin` | `NOT IN (...)` | `"nationality__@nin" => ["British", "German"]` |
| `field__@range` | `BETWEEN a AND b` | `"driverid__@range" => [1, 50]` |
| `field__@isnull` | `IS NULL / IS NOT NULL` | `"dob__@isnull" => true` |
| `field__@contains` | `LIKE '%val%'` | `"name__@contains" => "Monaco"` |
| `field__@icontains` | `ILIKE '%val%'` | `"name__@icontains" => "monaco"` |

### Transform Functions

| Transform | Description | Example |
| :--- | :--- | :--- |
| `field__@year` | Extract year from date | `"dob__@year" => 1960` |
| `field__@month` | Extract month from date | `"dob__@month" => 3` |
| `field__@day` | Extract day from date | `"dob__@day" => 21` |
| `field__@quarter` | Extract quarter (1-4) | `"date__@quarter" => 1` |
| `field__@date` | Extract date from datetime | `"created_at__@date" => Date(2025, 1, 1)` |
| `field__@round` | Round numeric value | `"points__@round" => 0` |
| `field__@floor` | Floor numeric value | `"points__@floor" => 0` |
| `field__@ceil` | Ceiling numeric value | `"points__@ceil" => 0` |

For the full list of operators and transforms, see [Filters and Aggregates](read/filters_and_aggregates.md).

---

## F-Expressions

`F()` enables database-side field references and arithmetic. Use it for field-to-field comparisons and computed expressions.

```julia
using PormG: F
using PormG.Functions: Sum, Count

# Field-to-field comparison
M.Result.objects.filter(F("grid") == F("positionorder"))

# Arithmetic in projections
M.Result.objects.values(
    "driverid__surname",
    "bonus" => F("points") * 0.1
)

# Aggregate ratios
M.Result.objects.values(
    "driverid__surname",
    "avg_pts" => Sum("points") / Count("resultid")
)

# Atomic update (no read-modify-write race)
M.Result.objects.filter("resultid" => 1).update("points" => F("points") + 10)

# Date arithmetic with explicit Julia durations (or the Interval helper)
using Dates
M.Race.objects.filter("raceid" => 1).update("date" => F("date") + (Month(1) + Day(15)))
```

`+`/`-` accept `Dates` durations (`Day`, `Month`, `Year`, …) and `Interval(...)` for cross-database date math. See [Field Expressions](read/field_expressions.md) for the full reference.

---

## Q Objects: Complex Boolean Logic

`Q()` and `Qor()` enable complex boolean predicates with AND/OR logic:

```julia
using PormG: Q, Qor

# AND logic (Q contains AND by default)
M.Driver.objects.filter(Q("nationality" => "Brazilian", "code" => "SEN"))

# OR logic
M.Driver.objects.filter(Qor("nationality" => "Brazilian", "nationality" => "French"))

# Nested AND/OR
M.Driver.objects.filter(
    Q("nationality" => "Brazilian", Qor("forename" => "Ayrton", "forename" => "Nelson"))
)
```

See [Q Objects](read/q_objects.md) for the full reference.

---

## Aggregate Functions

All aggregate functions can be used in `.values()` for grouping or combined with F-expressions:

| Function | SQL | Example |
| :--- | :--- | :--- |
| `Count("field")` | `COUNT(field)` | `"total" => Count("resultid")` |
| `Sum("field")` | `SUM(field)` | `"total_pts" => Sum("points")` |
| `Avg("field")` | `AVG(field)` | `"avg_pts" => Avg("points")` |
| `Max("field")` | `MAX(field)` | `"best" => Max("points")` |
| `Min("field")` | `MIN(field)` | `"worst" => Min("points")` |

When aggregate values appear in `values()`, PormG automatically groups by the non-aggregated columns. Aggregate-based filters are promoted to `HAVING`.

```julia
# Wins per constructor with HAVING filter
df = M.Result.objects.values(
    "constructorid__name",
    "wins" => Count("resultid")
).filter(
    "positionorder" => 1,
    "wins__@gt" => 50
).order_by("-wins") |> DataFrame
```

---

## SQL Functions

`PormG.Functions` provides a comprehensive set of SQL functions:

### String Functions

| Function | Description | Example |
| :--- | :--- | :--- |
| `Lower("field")` | Convert to lowercase | `"name_lower" => Lower("surname")` |
| `Upper("field")` | Convert to uppercase | `"name_upper" => Upper("surname")` |
| `Length("field")` | String length | `"name_len" => Length("surname")` |
| `Concat(args...)` | Concatenate values | `"full" => Concat("forename", Value(" "), "surname")` |
| `Trim("field")` | Trim whitespace | `"clean" => Trim("name")` |
| `LTrim("field")` | Left trim | `"clean" => LTrim("name")` |
| `RTrim("field")` | Right trim | `"clean" => RTrim("name")` |
| `Replace("field", old, new)` | Replace substring | `"fixed" => Replace("name", "-", " ")` |

### Numeric Functions

| Function | Description |
| :--- | :--- |
| `Abs("field")` | Absolute value |
| `Round("field", precision)` | Round to precision |
| `Floor("field")` | Floor |
| `Ceil("field")` | Ceiling |
| `Sqrt("field")` | Square root |
| `Exp("field")` | Exponential |
| `Ln("field")` | Natural logarithm |
| `Power("field", n)` | Raise to power |
| `Mod("field", n)` | Modulo |

### Conditional & Utility Functions

| Function | Description | Example |
| :--- | :--- | :--- |
| `Value(x)` | Literal value in SQL | `Value("hello")` |
| `Coalesce(args...)` | First non-null value | `Coalesce("nickname", "forename")` |
| `NullIf("field", value)` | Returns NULL if equal | `NullIf("code", "")` |
| `Greatest(args...)` | Maximum of values | `Greatest("points", Value(0))` |
| `Least(args...)` | Minimum of values | `Least("points", Value(100))` |
| `Cast("field", type)` | Type casting | `Cast("points", "INTEGER")` |
| `Extract("part", "field")` | Extract date/time part | `Extract("year", "dob")` |
| `To_char("field", fmt)` | Format to string | `To_char("dob", "YYYY-MM")` |

### Case Expressions

**Binary (single condition):** pass `otherwise` directly to `When` — no `Case` wrapper needed:

```julia
# CASE WHEN idade >= 60 THEN 'Sim' ELSE 'Não' END
"mais_60" => When("idade__@gte" => 60, then = "Sim", otherwise = "Não")
```

**Multi-branch:** wrap a vector of `When` fragments in `Case`:

```julia
"category" => Case([
    When("positionorder" => 1,            then = "Winner"),
    When("positionorder__@lte" => 3,      then = "Podium"),
], default = "Other")
```

Plain strings and numbers work as `then`, `otherwise`, and `default` values without `Value()`.

See [Functions and Dates](read/functions_and_dates.md) for more details.

---

## Custom Joins

### `.cjoin()`

Defines custom join conditions at query time as a chainable method on the query handler. Useful for legacy databases, non-FK joins, and multi-tenant systems.

```julia
using PormG: Q, Qor

df = M.Result.objects.cjoin(
    "driverid" => "Driver",
    filters=[Q("nationality" => "Brazilian", Qor("forename" => "Ayrton", "forename" => "Nelson"))],
    join_type="INNER"
).values("driverid__forename", "driverid__surname", "points") |> DataFrame
```

**Parameters:**

| Argument | Type | Description |
| :--- | :--- | :--- |
| `main_join` | `Pair{String,String}` | `"field" => "TargetModel"` — the join path. |
| `filters` | `Vector` | ON-clause predicates. Supports `Pair`, `Q()`, `Qor()`, F expressions. |
| `join_type` | `String` | `"LEFT"` (default), `"INNER"`, `"RIGHT"`, or `"FULL"`. |
| `field` | `PormGField` | Optional custom field definition for non-FK joins. |
| `warn` | `Bool` | Suppress auto-discovery warnings (default: `true`). |

See [Custom Joins](read/custom_joins.md) for the full documentation.

### `on()`

Adds ON-clause predicates to existing join paths (including reverse joins) without redefining them:

```julia
query = M.Result.objects
query.on("driverid", "nationality" => "Brazilian", "code" => "SEN")
query.values("resultid", "driverid__surname", "points")
```

---

## Bulk Operations

### `bulk_insert`

Inserts multiple records in a single operation. Returns the inserted rows.

```julia
df = DataFrame([
    Dict("forename" => "Ayrton", "surname" => "Senna", "nationality" => "Brazilian"),
    Dict("forename" => "Alain",  "surname" => "Prost", "nationality" => "French"),
])
result = bulk_insert(M.Driver, df)
```

Duplicates can be skipped or merged instead of erroring with the `on_conflict=` keyword (PostgreSQL and SQLite ≥ 3.24; see [Conflict Handling](write/bulk.md#conflict-handling-on-conflict)):

```julia
bulk_insert(M.Status, df, on_conflict = :nothing)                                  # ON CONFLICT DO NOTHING
bulk_insert(M.Status, df, on_conflict = (action = :nothing, target = ["statusid"]))  # targeted skip
bulk_insert(M.Status, df,                                                          # upsert
    on_conflict = (action = :update, target = ["statusid"], set = ["status"]))
```

### `bulk_update`

Updates multiple records in a single operation.

```julia
bulk_update(M.Result.objects, df_with_changes, columns=["points"], match_on=["resultid"])
```

Key contracts:

- `columns=` names the participating fields and is the **single place** a DataFrame column is mapped to a model field (`"df_col" => "field"`); `match_on=` selects the per-row merge keys by **bare model field name** (a field in both is matched, never SET); `filters=` are constant predicates applied to every row.
- A `match_on` field's source column is its `columns=` mapping when declared — the mapping is authoritative even if a same-named DataFrame column also exists (that case warns) — otherwise a DataFrame column with the field's own name.
- DataFrame columns are matched **case-sensitively** for both `columns` and `match_on`. A column that differs only in case from the model field (e.g. `RaceId` vs `raceid`) raises an error naming the candidate; normalize headers with `rename!(df, lowercase.(names(df)))` or map explicitly with `"DF_COL" => "field"` in `columns=`.
- If `match_on` is omitted, PormG infers the model primary key columns and uses those to identify rows.
- A per-row match key passed in `filters=` (a bare string or `"df_col" => "field"` pair) raises a migration error directing you to `match_on=`; there is no silent fallback. Likewise, the pre-#107 pair grammar in `match_on=` (`["record_id" => "id"]`) raises a migration error showing the rewrite (`columns=[..., "record_id" => "id"], match_on=["id"]`). Both migration errors are temporary deprecation aids and will be removed in a future release.
- `bulk_update()` rebuilds the `WHERE` clause from `match_on=` and `filters=` and does not preserve filters that were already attached to the handler.
- Constant lookup filters on base-table columns are supported, but relation traversals that would require JOINs are rejected.
- Foreign-key columns accept scalar primary-key values, including `0` when that referenced row exists; use `nothing` or `missing` to write SQL `NULL` on nullable FK columns.
- The same dry-run modes available elsewhere apply here: `:sql`, `:dict`, `:inspection`, `:params`, and `:none`.

### `bulk_copy`

⭐ **PostgreSQL Only.** Uses PostgreSQL's native `COPY FROM STDIN` protocol for ultra-fast bulk loading.

```julia
bulk_copy(M.Driver.objects, df)
```

| Function | Best For | Speed | Protocol |
| :--- | :--- | :--- | :--- |
| `create()` | Single rows | Standard | SQL INSERT |
| `bulk_insert()` | Medium datasets (< 10k rows) | Fast | Multi-row INSERT |
| `bulk_copy()` ⭐ | Massive datasets | Ultra-Fast | Postgres COPY |
| `bulk_update()` | Modifying many rows | Fast | Multi-row UPDATE |

---

## Transactions

### `run_in_transaction`

Executes a block inside a database transaction with automatic commit/rollback:

```julia
PormG.run_in_transaction("db") do
    M.Result.objects.create("raceid" => 1, "driverid" => 1, "points" => 25)
    M.Driver.objects.filter("driverid" => 1).update("code" => "WIN")
    # If any exception is raised, both operations are rolled back
end
```

**Key features:**
- Async context propagation — spawned `@async` tasks inherit the transaction
- Connection sharing — all queries in the block use the same connection
- Automatic rollback on error

See [Transactions](write/transaction.md) for the full reference including savepoints and multithreaded patterns.

---

## Async Execution

### `fetch_async`

Execute a query asynchronously, returning a `FetchTask`:

```julia
task = fetch_async(M.Driver.objects.filter("nationality" => "Brazilian"))
# ... do other work ...
result = await_result(task)
```

---

## Configuration API

### `Configuration.load(path; env=nothing)`

Loads a database configuration folder. Use `env` to explicitly set the environment instead of relying on `ENV["PORMG_ENV"]`.

```julia
PormG.Configuration.load("db"; env="prod")
```

### `Configuration.load_many(paths; env=nothing)`

Bootstraps multiple database folders in one call:

```julia
PormG.Configuration.load_many(["db", "db_analytics"]; env="prod")
```

### `Configuration.is_loaded(path_or_key)`

Returns `true` if PormG has registered settings for the given folder/key. Does not open connections.

### `Configuration.ping(path_or_key)`

Tests actual database reachability. Returns `Bool`.

### `Configuration.status(path_or_key)`

Returns a rich status payload:

```julia
s = PormG.Configuration.status("db")
# (key="db", loaded=true, reachable=true, adapter="PostgreSQL", app_env="prod")
```

For the full configuration guide, see [Configuration](configuration/index.md).

---

## Advisory Locks

### `with_advisory_lock`

Acquires a PostgreSQL advisory lock for distributed coordination:

```julia
PormG.with_advisory_lock("db", "migration_lock"; wait=true, timeout_ms=10000) do
    # Critical section — only one process at a time
    PormG.Migrations.migrate("db")
end
```

**Strategies:**
- `:poll` (default) — Client-side polling with interval
- `:block` — Server-side blocking via `pg_advisory_lock`

SQLite: No-op (executes the block without locking).

See [Advisory Locks](advisory_lock.md) for the full reference.

---

---

## Terminal Dashboard

### `tui(db_path; models_module=nothing, fps=30)`

Launches an interactive terminal dashboard for migration review and query inspection. Requires `Tachikoma.jl`.

```julia
using Tachikoma
PormG.tui("db"; models_module=M)
```

See [Migrations: Terminal Dashboard](migrations/tachikoma.md) for details.

---

## Abstract Types

PormG's type hierarchy provides the foundation for the query builder and model system:

| Type | Description |
| :--- | :--- |
| `PormGAbstractType` | Base abstract type for all PormG types. |
| `SQLConn` | Represents a database connection (subtypes: `PormGPostgres`, `PormGSQLite`). |
| `SQLObject` | Base for objects that can be stored in the database. |
| `SQLObjectHandler` | Handles operations on SQL objects (the query builder). |
| `SQLTableAlias` | Manages table aliases in SQL queries. |
| `SQLInstruction` | Represents an instruction to build a SQL query. |
| `SQLType` | Base for SQL-related expression types. |
| `SQLTypeField` | Represents a field expression in queries. |
| `SQLTypeQ` | Q-expression type (AND logic). |
| `SQLTypeQor` | Qor-expression type (OR logic). |
| `SQLTypeF` | F-expression type (field references). |
| `SQLTypeFunction` | SQL function type. |
| `SQLTypeCTE` | Common Table Expression type. |
| `PormGModel` | Base for model types. |
| `PormGField` | Base for field type definitions. |

---

## Exported Symbols

This is the curated public surface. `using PormG` brings **only** the names below into
scope — the SQL function constructors are *not* among them (see
[SQL function library](#sql-function-library-pormgfunctions)).

### Query Builder
`object`, `get`, `Q`, `Qor`, `F`, `Exists`, `OuterRef`, `Interval`, `show_query`, `inspect_query`

### Rows & exceptions
`PormGRow`, `DoesNotExist`, `MultipleObjectsReturned`

### Bulk Operations
`bulk_insert`, `bulk_update`, `bulk_copy`, `allocate_primary_keys`

### Async API
`fetch_async`, `await_result`, `FetchTask`

### Transactions
`run_in_transaction`, `with_savepoint`, `with_tx_context`, `in_transaction_context`

### Locking
`with_advisory_lock`

### Utilities & lifecycle
`setup`, `install_ai_skills`, `tui`, `register_ignore_tables!`, `@import_models`, `@models_module`, `@pormg_debug`

!!! note "`fetch` extends `Base.fetch`"
    The low-level `fetch(settings, sql; params=…)` escape hatch is a method of
    `Base.fetch`, so it is always in scope (no import, no qualification) and does not
    shadow Base. Prefer the fluent terminals (`list()`, `DataFrame`, `count()`) for
    application code.

### SQL function library: `PormG.Functions`

The aggregate, conditional, window, string and math constructors live **only** in the
`PormG.Functions` submodule — they are not exported into `Main`, and there is no
`PormG.Sum` alias either. Their names (`Sum`, `Count`, `Max`, `Round`, `Replace`,
`Length`, …) are generic enough to collide with `Base` and user code, so the library has
exactly one home. Reach it either way:

```julia
using PormG, PormG.Functions          # bring the whole library into scope
using PormG.Functions: Sum, Count     # …or just the ones you use
M.Result.objects.values(              # …or qualify without importing
    "n" => PormG.Functions.Count("resultid"))
```

`bulk_*`, `Q`, `Qor`, `F`, `Exists`, `OuterRef`, `Interval` stay at the top level — they are
query primitives, not part of the function library.

**Aggregate** — `Sum`, `Avg`, `Count`, `Max`, `Min`
**Conditional** — `Case`, `When`
**Window** — `WindowOver`, `WindowSpec`, `Rank`, `DenseRank`, `RowNumber`, `Lag`, `Lead`, `FirstValue`, `LastValue`, `NthValue`
**String** — `Concat`, `Lower`, `Upper`, `Length`, `Replace`, `Trim`, `LTrim`, `RTrim`
**Math** — `Abs`, `Round`, `Floor`, `Ceil`, `Sqrt`, `Exp`, `Ln`, `Power`, `Mod`
**Type / value** — `Cast`, `Extract`, `To_char`, `Value`, `Coalesce`, `Greatest`, `Least`, `NullIf`

### Result-shape contract for `list()`

The terminal `list()` methods return a documented, stable shape:

| Call | Returns |
|------|---------|
| `query.list()` | `Vector{PormGRow}` |
| `query.list(:dict)` | `Vector{Dict{Symbol, Any}}` |
| `query.list(:json)` | JSON string |
| `query |> DataFrame` | `DataFrame` (preferred for analytical queries) |

---

## Auto-Generated API Docs

The following section contains auto-generated documentation from docstrings in the source code:

```@autodocs
Modules = [PormG, PormG.Functions, PormG.QueryBuilder, PormG.Models]
Order   = [:function, :type]
```
