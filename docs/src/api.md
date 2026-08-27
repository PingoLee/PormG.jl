# API Reference

## Overview

PormG provides a Django-inspired ORM for Julia with an async-first architecture. This page serves as a comprehensive reference for all exported functions, types, and the query builder API. For topic-specific guides, see the [Reading](read/index.md) and [Writing](write/index.md) sections.

---

## Query Builder: Fluent API

PormG uses a Django-style, object-oriented query builder. All database operations start from `Model.objects` and are chained using methods that either modify the query or execute it.

```julia
# The general pattern (trailing-dot chain — a leading dot on the next line is a ParseError)
results = M.Driver.objects.
    filter("nationality" => "Brazilian").
    values("forename", "surname").
    order_by("surname").
    limit(10).
    list()
```

### Chainable Methods

These methods modify the query builder and return the handler for further chaining:

| Method | Description | Example |
| :--- | :--- | :--- |
| `.filter(key => value, ...)` | Add WHERE conditions (AND). Repeated calls **accumulate**, unlike `.values()`/`.order_by()` which replace. | `.filter("nationality" => "British")` |
| `.values("field1", "field2", ...)` | Select specific columns. Use `"*"` for all main-table columns. | `.values("*", "driverid__surname")` |
| `.order_by("field", "-field")` | Sort results. Prefix with `-` for descending. | `.order_by("-points", "surname")` |
| `.limit(n)` | Limit the number of returned rows. | `.limit(10)` |
| `.offset(n)` | Skip the first `n` rows. | `.offset(20)` |
| `.page(limit)` / `.page(limit, offset)` | Limit, or limit and offset in one call. The one-argument form leaves any `.offset()` already set untouched. | `.page(20, 40)` / `.page(20)` |
| `.distinct()` | Add `DISTINCT` to the SELECT. | `.distinct()` |
| `.db("key")` | Route the query to a different connection pool. | `.db("tenant_42")` |
| `.on("path", key => value)` | Add predicates to the ON clause of an existing join path. | `.on("driverid", "nationality" => "British")` |
| `.cjoin("field" => "Model", ...)` | Add a custom join at query time. | `.cjoin("driverid" => "Driver")` |
| `.cjoin_on("Model"; alias, on, join_type)` | Anchor-less join: `on` is the **entire** ON clause. | `.cjoin_on("Driver"; alias = "d", on = [...])` |
| `.with("name" => subquery; join_field, join_type)` | Define one CTE on the query; call again for a second. Its columns are then reached with [`CTE(name, path)`](@ref CTE). | `.with("fast" => sub)` |
| `.select_for_update(; nowait, skip_locked, no_key)` | `SELECT … FOR UPDATE` row lock (PostgreSQL; must run inside a transaction). | `.select_for_update(nowait = true)` |
| `.copy()` | Deep-copy the handler to branch a chain without disturbing the original. | `base.copy().filter("year" => 2020)` |

See also: [Custom Joins](read/custom_joins.md) for `.cjoin()` / `.cjoin_on()` / `.on()`, and
[Subqueries and CTEs](read/subqueries_and_ctes.md) for `.with()` and the [`CTE`](@ref) reference object.

!!! info "Important"
    Queries that use `.cjoin()` **must** call `.values(...)` explicitly before execution.
    A bare `SELECT *` across joined tables causes `DataFrames.jl` to crash with
    `ArgumentError: Duplicate variable names`. PormG throws a clear error if you forget.
    Use `.values("*", "joined_model__field")` to quickly select all main-table columns
    plus specific fields from the joined table.

### Terminal Methods

These methods finalize the query and execute it against the database:

| Method | Return Type | Description |
| :--- | :--- | :--- |
| `.list()` | `Vector{PormGRow}` | Returns model-aware rows with dot-access and relationship accessors. |
| `.list(:dict)` | `Vector{Dict{Symbol, Any}}` | Returns plain dictionaries for framework integrations that need real `Dict` values. |
| `.list(:json)` | `String` | Returns results as a JSON string. |
| `query \|> DataFrame` | `DataFrame` | Pipe to `DataFrame` for tabular output. |
| `.count()` | `Int` | Runs `SELECT COUNT(*)` and returns the count. |
| `.aggregate(alias => Agg(...), ...)` | `NamedTuple` | Whole-queryset aggregation (no `GROUP BY`); returns one named tuple of scalars. See [Aggregation](read/filters_and_aggregates.md). |
| `.exists()` | `Bool` | Returns `true` if at least one row matches. |
| `.first()` | `PormGRow` or `nothing` | Returns the first matching record or `nothing`. |
| `.last()` | `PormGRow` or `nothing` | Returns the last matching record; inverts `order_by`, or falls back to primary-key descending when unset. |
| `.earliest(fields...)` | `PormGRow` | Earliest row ordered by `fields` (ascending; `"-field"` flips); raises `DoesNotExist` when empty. |
| `.latest(fields...)` | `PormGRow` | Latest row ordered by `fields` (descending; `"-field"` flips); raises `DoesNotExist` when empty. |
| `.get(filters...)` | `PormGRow` | Returns exactly one row, or raises `DoesNotExist` / `MultipleObjectsReturned`. |
| `.create(key => value, ...)` | `PormGRow` | Inserts a single record and returns it as a row (dot-access + `.save()`). |
| `.update(key => value, ...)` | — | Updates all matching records. |
| `.get_or_create(lookup...; defaults)` | `(PormGRow, Bool)` | Fetch-or-insert, never updates a match; returns `(row, created)`. See [Get or Create](write/create.md#get-or-create). |
| `.update_or_create(lookup...; defaults)` | `(PormGRow, Bool)` | Row-level upsert: inserts on a fresh lookup or updates `defaults` on conflict; returns `(row, created)`. See [Update or Create](write/create.md#update-or-create). |
| `.delete()` | — | Deletes all matching records. |
| `.inspect()` | `Dict` | Full query metadata without executing — the `inspect_query` shape (see Query Inspection & Debugging below). |

### `PormGRow` Instance Methods

Rows returned by `.list()`, `.first()`, `.last()`, `.earliest()`, `.latest()`, `.get()`, `.create()`, `.get_or_create()`, and `.update_or_create()` expose model-aware property access and instance-level persistence:

| Method | Return Type | Description |
| :--- | :--- | :--- |
| `row.field` | value | Reads a selected field using normalized Julia-style field names. |
| `row[:field]` | value | Reads a selected field by `Symbol` or `String`. |
| `row.pk` | value | The row's primary-key value, via the model's declared pk column (any name, not just `id`). Throws if the model has no single-column pk. |
| `pk(row)` / `pk(row, default)` | value | Function form (exported by `using PormG`); the 2-arg variant returns `default` instead of throwing (best-effort). |
| `row.relationship` | `ManyToManyManager` | Accesses a many-to-many relationship manager when the model defines one. |
| `row.save()` | `PormGRow` | Persists fields assigned on the row and clears its dirty state. |
| `row.save(show_query=:sql)` | `Vector` | Returns planned `UPDATE` inspection payloads without executing or clearing dirty state. |
| `row.delete()` | `(Int, Dict)` | Deletes this row through the shared deletion collector (cascades like `query.delete()`); returns `(total, per-table counts)`. |

```julia
driver = M.Driver.objects.get("driverref" => "hamilton")
driver.nationality = "British"
driver.save()
```

`row.save()` requires a model with exactly one primary key. Primary-key assignments are rejected, and a row fetched without the primary key selected cannot be saved.

**Example:**

```julia
# Full query chain with DataFrame output (trailing-dot chain)
df = M.Result.objects.
    filter("driverid__nationality" => "Brazilian", "positionorder" => 1).
    values("driverid__forename", "driverid__surname", "raceid__year").
    order_by("-raceid__year") |> DataFrame

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

println(inspection[:sql_text])   # The generated SQL
println(inspection[:parameters]) # Bound parameters
println(inspection[:operation])  # Automatically detects :select
println(inspection[:dialect])    # :postgresql or :sqlite
```

!!! note
    `LIMIT` and `OFFSET` values are rendered as literal integers in the SQL string. They do **not** appear in `inspection[:parameter_buckets]` or `inspection[:parameters]`. This is by design.

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
| `Extract("field", "part")` | Extract date/time part | `Extract("dob", "year")` |
| `ToChar("field", fmt)` | Format to string | `ToChar("dob", "YYYY-MM")` |

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
- A `match_on` field's source column is its `columns=` mapping **when you declared one** — the mapping is authoritative even if a same-named DataFrame column also exists (that case warns) — otherwise a DataFrame column with the field's own name. A value PormG auto-populates for an out-of-scope field (`auto_now`, or a static `default` when `columns=` is omitted) is not a declared mapping: your same-named column outranks it, and with no column at all the call raises an `UnknownFieldError` rather than matching every row against one per-call constant.
- A match key is **matched, never written** — it stays out of the `SET` clause, so using an `auto_now` field as a key does not refresh that timestamp.
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

### `atomic`

Friendly, Django-flavored alias for `run_in_transaction`. A **nested** `atomic` on the same database
automatically becomes a `SAVEPOINT`, so a failing inner block rolls back only to its savepoint while the
outer transaction survives (works identically on PostgreSQL and SQLite):

```julia
atomic("db") do
    M.Result.objects.create("raceid" => 1, "driverid" => 1, "points" => 25)
    try
        atomic("db") do                 # nested → SAVEPOINT
            M.Result.objects.create("raceid" => 1, "driverid" => 1, "points" => 18)
            error("validation failed")  # rolls back to the savepoint only
        end
    catch
        # outer transaction still usable here
    end
end
```

Pass `durable = true` to require the block be the outermost transaction (raises if one is already active).

### `select_for_update`

Query-builder method that adds a `FOR UPDATE` clause to lock the selected rows until the surrounding
transaction commits — the guard for a safe read-modify-write. Keyword options `nowait`, `skip_locked`,
and `no_key` map to `FOR UPDATE NOWAIT` / `FOR UPDATE SKIP LOCKED` / `FOR NO KEY UPDATE` (`nowait` and
`skip_locked` are mutually exclusive). On PostgreSQL it must run inside a transaction; **on SQLite it is
a silent no-op** (no row-level locking). See [Row-Level Locking](write/transaction.md#Row-Level-Locking).

```julia
atomic("db") do
    row = M.Constructor_standings.objects.
        filter("constructorstandingsid" => 1).
        select_for_update().
        list() |> first
    M.Constructor_standings.objects.
        filter("constructorstandingsid" => row[:constructorstandingsid]).
        update("points" => row[:points] + 25)
end
```

---

## Async Execution

PormG is async-first *internally*: every terminal (`list()`, `count()`, `create()`, …) already
yields to the Julia scheduler while the database round-trip is in flight. There is no separate
async query API — wrap the ordinary call in a task:

```julia
t = Threads.@spawn M.Driver.objects.filter("nationality" => "Brazilian").list()
# ... other work overlaps the database round-trip ...
rows = fetch(t)   # Base.fetch on the Task — same rows as calling list() directly
```

### `fetch_async` / `await_result` (raw SQL)

The lower-level escape hatch accepts **raw SQL only** — not query-builder objects — and returns
a `FetchTask`:

```julia
settings = PormG.Configuration.get_settings("db")

task = fetch_async(settings, "SELECT count(*) FROM driver")
# ... do other work ...
result = await_result(task)   # returns rows and releases the pooled connection
```

Bind user values with a plain array — write the backend-native placeholder (`$1, $2` on
PostgreSQL, `?` on SQLite); PormG does no translation, and a NULL is `missing`:

```julia
# PostgreSQL
task = fetch_async(settings, "SELECT count(*) FROM driver WHERE nationality = \$1", ["Brazilian"])
n    = await_result(task)
# SQLite: the same call with "... = ?" and the same ["Brazilian"] array
```

!!! warning "An un-awaited `FetchTask` leaks its pool connection"
    `fetch_async` checks its connection out synchronously; only `await_result` returns it.
    Always await every task you start.

See the [Async & Concurrency guide](async.md) for fan-out patterns, `@async` vs
`Threads.@spawn`, connection-pool sizing, and why you must not fan out queries *inside* a
transaction.

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

SQLite: no-op — the block executes without locking. It warns once per lock key;
`on_missing_lock=:ignore` accepts that silently, `on_missing_lock=:error` raises
`BackendCapabilityError` rather than running unprotected.

See [Advisory Locks](advisory_lock.md) for the full reference.

---

## Abstract Types

PormG's type hierarchy provides the foundation for the query builder and model system:

| Type | Description |
| :--- | :--- |
| `PormGAbstractType` | Base abstract type for all PormG types. |
| `PormGSettings` | The connection-settings/config type (`Configuration.Settings` is a subtype). *Renamed from `SQLConn`.* |
| `PormGBackend` | Base for the database backend/dialect markers (subtypes: `PormGPostgres`, `PormGSQLite`), the dispatch key for SQL rendering and driver selection. |
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
| `SQLTypeCTE` | Supertype of [`CTE`](@ref)'s reference object — a CTE column handle. |
| `PormGModel` | Base for model types. |
| `PormGField` | Base for field type definitions. |
| `PormGError` | Root of the semantic error taxonomy (`<: Exception`). Every PormG misuse — querying, model definition, configuration, migrations, the pool — raises a subtype (see [Error taxonomy](#Error-taxonomy)); `catch PormGError` catches them all. |

---

## Exported Symbols

This is the curated public surface. `using PormG` brings **only** the names below into
scope — the SQL function constructors are *not* among them (see
[SQL function library](#sql-function-library-pormgfunctions)).

### Query Builder
`object`, `get`, `Q`, `Qor`, `F`, `Exists`, `OuterRef`, `Subquery`, `CTE`, `Interval`, `show_query`, `inspect_query`

### Rows & exceptions
`PormGRow`, `pk`, `DoesNotExist`, `MultipleObjectsReturned`

### Error taxonomy
Every PormG misuse raises a subtype of `PormGError` (`<: Exception`) so callers can `catch` a
**type** instead of matching on a message string. Catch `PormGError` for any PormG failure, or a
specific subtype for a specific reaction (#231, completed in #239):

`PormGError`, `FieldAccessError`, `UnknownFieldError`, `LazyTraversalError`, `FilterError`, `QueryBuildError`, `UnsafeMutationError`, `InvalidValueError`, `WritesDisabledError`, `UnsupportedConnectionError`, `BackendCapabilityError`, `ProtectedError`, `DefinitionError`, `FieldValidationError`, `ModelDefinitionError`, `ConfigurationError`, `InvalidConfigurationError`, `MigrationError`, `InvalidMigrationError`, `PoolError`, `DatabaseError`, `IntegrityError`, `OperationalError`, `StatementError`, `TransactionError`, `error_message`

!!! note "Database failures are wrapped too"
    The taxonomy has two halves. Most of it reports **misuse of PormG**, caught before anything is
    sent. [`DatabaseError`](#database-errors) reports what the **database itself** refused once a
    statement got there — a constraint violation, SQL the backend rejects, a connection dropped
    mid-query — so `catch PormGError` really does cover both, and an app never has to name
    `SQLite.SQLiteException` / `LibPQ.Errors.*` (which would mean depending on the driver package
    just to spell the type). The driver's own exception stays reachable on `.cause` (#268).

!!! warning "These are not `ArgumentError`s"
    The subtypes are deliberately **not** `<: ArgumentError`. A `catch ArgumentError` block around a
    PormG call will not match — catch `PormGError` (or a specific subtype) instead.

### Reading a caught error

Use `error_message(e)`, **not** `e.msg`. Most subtypes carry a `msg::String`, but the ones built
from structured fields — `DoesNotExist`, `MultipleObjectsReturned`, `PoolTimeoutError`,
`PoolConnectError`, the three `DatabaseError` subtypes (`IntegrityError`, `OperationalError`,
`StatementError`), and `DestructiveMigrationError` (which renders its `statements` too) — do not
render from `msg` alone, so reaching for that field breaks on exactly the errors you are least
likely to have tested against. See [Error Handling](errors.md) for the per-type field list.

```julia
try
    M.Result.objects.filter("driverid__surname" => "Senna").update("points" => 25)
catch e
    e isa PormGError || rethrow()
    @error "PormG rejected the write" msg=error_message(e) type=typeof(e)
end
```

`error_message` is defined through `showerror`, which every subtype implements, so it stays correct
for subtypes added later. It never returns *less* than `e.msg`: for most subtypes it is exactly that
field, and for the few with their own `showerror` it returns the richer rendering.

**Querying**

| Type | Raised when |
| :--- | :--- |
| `FieldAccessError` *(abstract)* | Umbrella for field/accessor lookup failures — `catch` it to get both cases below. |
| `UnknownFieldError` | A field, alias, column, or `__` lookup path does not exist on the model or projected row. |
| `LazyTraversalError` | An unprojected `ForeignKey` or `OneToOneField` was read off a fetched row — project it in `values(...)` first. |
| `FilterError` | Invalid filter argument/shape, or an operator misused on a JSON/subquery column. |
| `QueryBuildError` | Structural/API misuse while building a query (joins, CTEs, projection, ordering, window/bulk config). **The long-tail default** — it is the bucket for query-shape misuse that isn't one of the sharper categories, so `catch QueryBuildError` says little beyond "PormG rejected the query shape". Catch a sharper subtype when you need to branch on the cause. |
| `UnsafeMutationError` | An `update()`/`delete()` was requested without a filter (or another unsafe shape). |
| `ProtectedError` | A `delete()` was refused because rows reference the target through a `ForeignKey` with `on_delete = PROTECT`/`RESTRICT` — the data forbids it; delete or reassign the referencing rows first. |
| `BackendCapabilityError` | The active backend cannot do this: PG-only lookups on SQLite (JSONB, `iunaccent_*`), explicit window `frame=` on SQLite, `bulk_copy` on SQLite, `with_advisory_lock(...; on_missing_lock = :error)` on SQLite, or a too-old SQLite library. Change the query or the backend. |
| `InvalidValueError` | A **value** failed coercion/type validation on insert/update, an identifier failed the safety check, or an interval/duration could not be parsed. |
| `WritesDisabledError` | The connection is not permitted to insert/update/delete — `change_data: false` in `connection.yml`, which is why it lives under `ConfigurationError`. (Renamed from `PermissionError` in the pre-publish naming pass.) |
| `UnsupportedConnectionError` | A connection object that is neither PostgreSQL nor SQLite reached an execution path — an internal PormG dispatch bug; please report it. (Capability limits are `BackendCapabilityError`; an unbound model is `InvalidConfigurationError`.) |
| `DoesNotExist` / `MultipleObjectsReturned` | `get()` found zero / more than one row. |

**Defining models**

| Type | Raised when |
| :--- | :--- |
| `DefinitionError` *(abstract)* | Umbrella for definition-time failures — `catch` it to get both cases below. One `include("models.jl")` can raise either, so a handler naming only one silently misses the other. |
| `FieldValidationError` | A field constructor got an invalid argument — a kwarg of the wrong type, an out-of-range `max_length`, a `default` that violates the field's own contract, or a field type that cannot be a primary key. |
| `ModelDefinitionError` | A model/schema definition is invalid — more than one primary key, a duplicate `related_name`, an illegal field name, a `UniqueConstraint` or `Index` naming an unknown field, or an unresolvable `ForeignKey` target. |

`FieldValidationError` fires while *defining* a model; `InvalidValueError` fires while coercing a
*value* on the insert/update path. That is the distinction between the two.

**Configuration and migrations**

| Type | Raised when |
| :--- | :--- |
| `ConfigurationError` *(abstract)* | Umbrella for configuration failures — covers `InvalidConfigurationError`, `MissingConfigurationError`, **and** `WritesDisabledError` (listed in the Querying table above, where users meet it). |
| `InvalidConfigurationError` | Configuration is present but unusable — unsupported adapter, unknown connection key, malformed `extensions`, a model not bound to a connection (or bound to an entry whose pool was never built), a missing driver package, or an attempt to overwrite a static connection. |
| `MissingConfigurationError` | No configuration folder / `connection.yml`, or the selected environment has no matching block. **Not on the `using PormG` surface** — name it `PormG.Configuration.MissingConfigurationError`. |
| `MigrationError` *(abstract)* | Umbrella for migration-engine failures — `catch` it to get both cases below. |
| `InvalidMigrationError` | A duplicate index name in a plan, an invalid answer to an interactive `makemigrations` prompt, or an unimplemented `migrate_to(version)` path. |
| `DestructiveMigrationError` | A destructive plan was applied non-interactively without `destructive=true`; carries the refused `statements`. **Not on the `using PormG` surface** — name it `PormG.Migrations.DestructiveMigrationError`. |
| `PoolError` *(abstract)* | Umbrella for connection-pool failures — `catch` it to get both cases below. |
| `PoolTimeoutError` / `PoolConnectError` | The pool is saturated / a physical connection could not be opened. Both carry structured fields (`adapter`, `pool_size`, `attempts`, …) rather than a `msg` — read them with `error_message`. |

**Database errors**

Everything above reports *misuse of PormG*, raised before a statement leaves the process. These
report what the **database** refused once it got there. Each carries `adapter` (`"PostgreSQL"` /
`"SQLite"`) and `cause` — the driver's own exception, kept so SQLSTATE-level detail stays reachable
— instead of a `msg`, so read them with `error_message`.

| Type | Raised when |
| :--- | :--- |
| `DatabaseError` *(abstract)* | Umbrella for every failure raised by the database itself. `catch DatabaseError` covers all three below without naming a driver package. |
| `IntegrityError` | A constraint said no — `UNIQUE`, `FOREIGN KEY`, `NOT NULL`, `CHECK`, or an exclusion constraint. The one database failure applications routinely *handle* rather than propagate. |
| `OperationalError` | Transient, and retrying may succeed — the connection dropped mid-query, a deadlock, a serialization failure, or a lock that could not be acquired (including a `with_advisory_lock` timeout). |
| `StatementError` | The statement could not be executed — invalid SQL, unknown table/column, a rejected type, or insufficient privileges. Also the landing type for anything the backend could not classify, so the umbrella has no holes. |
| `TransactionError` | Not a database error: the *transaction API* was used in a way that cannot work — `atomic(durable=true)` nested inside an open transaction, or touching a model bound to one connection while a transaction is open on another. Nothing was sent. |

```julia
try
    M.Driver.objects.create("driverref" => "senna", "code" => "SEN")
catch e
    e isa IntegrityError   && return conflict(error_message(e))   # a constraint refused it
    e isa OperationalError && return retry_later()                # transient — try again
    rethrow()
end
```

!!! note "Classification is exact on PostgreSQL, message-based on SQLite"
    LibPQ parameterizes its exception type on the SQLSTATE, so on PostgreSQL the kind is read
    straight off the error code. `SQLite.SQLiteException` carries only a message, so on SQLite the
    kind comes from SQLite's own literal constraint strings (`"UNIQUE constraint failed"`, …) —
    stable, but not a code. Treat `IntegrityError` as reliable on both; `.cause` is there when you
    need more than PormG's three kinds.

Connect-time failure is **not** a `DatabaseError` — it never reached a statement, and arrives as
`PoolConnectError` under `PoolError`. A failed migration `ALTER TABLE` **is** one: `migrate()` lets
the `StatementError` through rather than re-wrapping it as `MigrationError`, which would bury the
constraint detail — so catch `DatabaseError` alongside `MigrationError` around `migrate()`.

The abstract umbrellas exist so the buckets have **no holes**: `catch ConfigurationError` also
catches a missing `connection.yml`, and `catch MigrationError` also catches a refused destructive
migration.

```julia
try
    M.Result.objects.update("points" => 25)   # no filter → refused, protects every row
catch e
    e isa PormG.UnsafeMutationError && @warn "add a filter before update()"
    e isa PormG.WritesDisabledError    && @warn "this connection is read-only"
    rethrow(e)
end
```

Reacting to a whole category — the umbrellas make one `catch` enough:

```julia
try
    PormG.Configuration.load("db_2")
    PormG.Migrations.migrate("db_2")
catch e
    e isa PormG.ConfigurationError && @error "check connection.yml" exception=e
    e isa PormG.MigrationError     && @error "migration refused"    exception=e
    rethrow(e)
end
```

### Bulk Operations
`bulk_insert`, `bulk_update`, `bulk_copy`, `allocate_primary_keys`, `resync_sequences`

### Async API
`fetch_async`, `await_result`, `FetchTask` — see [Async & Concurrency](async.md)

### Transactions
`run_in_transaction`, `atomic`, `with_savepoint`, `with_tx_context`, `in_transaction_context` —
plus `PormG.ConnectionPool.with_transaction` for hand-rolled lifecycles

### Locking
`with_advisory_lock`

### Connection pool
`pool_stats`, `PoolTimeoutError`, `PoolConnectError` — manual checkout via
`PormG.ConnectionPool.acquire_connection` / `release_connection` (pair them in a `finally`;
on SQLite a write needs `mode = :write`)

### Utilities & lifecycle
`upgrade_guide`, `register_ignore_tables!`, `@import_models`, `@models_module`, `@pormg_debug`

!!! note "`setup` and `install_ai_skills` are qualified-call-only"
    The one-off lifecycle helpers `PormG.setup()` (interactive project wizard) and
    `PormG.install_ai_skills()` are deliberately **not exported** — their generic names
    would otherwise land in every `using PormG` namespace. Call them qualified, exactly
    as shown throughout these docs.

!!! note "`fetch` extends `Base.fetch`"
    The low-level `fetch(settings, sql; params=[...])` escape hatch (values bound with
    backend-native placeholders — see [Async & Concurrency](async.md)) is a method of
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

`bulk_*`, `Q`, `Qor`, `F`, `Exists`, `OuterRef`, `Subquery`, `CTE`, `Interval` stay at the top level —
they are query primitives, not part of the function library.

The library in full — the same index `?PormG.Functions` prints in the REPL:

**Aggregate** — `Sum`, `Avg`, `Count`, `Max`, `Min` — see [Filters and Aggregates](read/filters_and_aggregates.md)

**Conditional** — `Case`, `When` — see [Functions and Dates](read/functions_and_dates.md)

**Window** — `WindowOver`, `WindowSpec`, `Rank`, `DenseRank`, `RowNumber`, `Lag`, `Lead`, `FirstValue`, `LastValue`, `NthValue` — see [Window Functions](read/window_functions.md)

**String** — `Concat`, `Lower`, `Upper`, `Length`, `Replace`, `Trim`, `LTrim`, `RTrim`

**Math** — `Abs`, `Round`, `Floor`, `Ceil`, `Sqrt`, `Exp`, `Ln`, `Power`, `Mod`

**Type / value** — `Cast`, `Extract`, `ToChar`, `Value`, `Coalesce`, `Greatest`, `Least`, `NullIf`

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

The following section contains auto-generated documentation from docstrings in the source code.

!!! note "What appears here"
    `Private = false` means this section lists only names each module marks as API — `export`ed, or
    declared `public` (Julia 1.11+). Internal helpers keep their docstrings in the source but stay
    off this page (#289). Note Documenter tests `Base.ispublic` against the module a docstring was
    *written in*, not `PormG`'s re-export list, so a user-facing name defined in a submodule needs a
    `public` declaration **there** — see the note above `public` in `src/QueryBuilder.jl`.

```@autodocs
Modules = [
    PormG,
    PormG.Kernel,
    PormG.Functions,
    PormG.QueryBuilder,
    PormG.Models,
    PormG.Migrations,
    PormG.Configuration,
    PormG.ConnectionPool,
    PormG.Utils,
]
Order = [:module, :constant, :type, :function, :macro]
Private = false
```
