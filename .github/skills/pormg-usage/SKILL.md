---
name: pormg-usage
description: Answer PormG usage questions and write consumer-style examples for model definitions, @import_models, migration flow, fluent queries, joins, F/Q/Qor expressions, aggregations, and bulk operations.
---

# PormG.jl — AI Usage Guide

## Purpose

Use this skill whenever you need to write, refactor, or debug code in a project that uses **PormG.jl** — a Django-inspired async-first ORM for Julia.

**Audience: you are a PormG consumer** — writing application code in a project that *depends on* PormG, not editing the package itself. Changing PormG's own `src/`, in-repo `docs/`, or integration tests? Use `pormg-public-api-development` instead.

PormG exposes a fluent, expressive query API. Your default posture is:
- Write through `M.Model.objects` and chainable methods — never raw SQL.
- Use parameterized queries. Never interpolate user data into SQL strings.
- Prefer `DataFrame` output for analytics; prefer `list()` for programming logic.

## Supporting files (load on demand)

This skill is split so the common read/query path stays lean. Read these sibling files **only when the task needs them**:

- **[`reference.md`](reference.md)** — full field-type table, field parameters, and `on_delete` options. Load when *defining models* or choosing a field type.
- **[`writing.md`](writing.md)** — migrations flow, create/update/delete, the `row.save()` lifecycle, many-to-many managers, bulk insert/copy/update, and transactions (`atomic`/savepoints/`select_for_update`). Load when *changing data or schema*.

> Building a **package on top of** PormG (extension hooks like `register_ignore_tables!`, `set_before_connect_hook`, the package-extension pattern)? That's a framework-author topic — see the *Extending PormG* page in the PormG documentation (<https://pingolee.github.io/PormG.jl>), not this skill.

Everything below covers setup, the read/query surface, and a summary of the write path (full detail in `writing.md`).

---

## 1. Project Setup

```julia
using PormG, LibPQ   # Add the driver to your project (`Pkg.add("LibPQ")`, or `"SQLite"`) and load
                     # it alongside PormG. Both are weak dependencies of PormG, so a bare
                     # `using PormG` gives you the ORM but no backend, and the first query raises
                     # "the PostgreSQL backend requires LibPQ".

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

> Full field-type table, parameters, and `on_delete` options: see [`reference.md`](reference.md).

### Naming Conventions (Mandatory)
- **Models**: Capitalized, singular, snake_case for multi-word: `Driver`, `Race`, `Order_item`
- **Field names**: Lowercase, snake_case: `first_name`, `created_at`
- **Never use `__`** in field or table names — reserved for ORM join traversal
- **A field name may not start with `_`** (#317). For a column that is a Julia keyword — or that
  genuinely begins with an underscore — declare a legal identifier and name the column with
  `db_column`: `end_ = Models.CharField(db_column = "end")`. `id` needs nothing special.
- **Query fields in the case they were declared** — lookups are case-sensitive (#57). The F1 models declare **lowercase** fields, so their paths are lowercase (`constructorid__name`); a camelCase path throws because the field doesn't exist under that case. (House style is lowercase snake_case; mixed-case columns are supported when you declare them that way.)

> Migrations, create/update/delete, bulk operations, and transactions live in [`writing.md`](writing.md).

---

## 3. Reading Data — Query Patterns

### Core pattern

```julia
query = M.Driver.objects

query.filter("nationality" => "Brazilian")
query.order_by("surname")
query.limit(10)

rows = query.list()         # Vector{PormGRow}
dicts = query.list(:dict)   # Vector{Dict{Symbol, Any}}
df   = query |> DataFrame   # DataFrames.DataFrame
```

### Chainable methods

| Method | Description |
| :--- | :--- |
| `.filter(key => value, ...)` | Add WHERE conditions (AND). Multiple pairs are ANDed. |
| `.values("field", ...)` | Select specific columns. `"*"` = all main-table columns. `"alias" => "field"` renames the output column. |
| `.order_by("field", "-field")` | Sort. Prefix `-` for descending. |
| `.limit(n)` | Limit rows returned. |
| `.offset(n)` | Skip first `n` rows. |
| `.page(limit)` / `.page(limit, offset)` | Limit, or limit and offset, in one call. `.page(n)` leaves any offset already set. Positional `Integer`s only — no keywords. |
| `.db("key")` | Route to a different connection pool. |
| `.on("path", key => value)` | Add ON-clause predicates to an existing join. |

### Terminal (execution) methods

| Method | Returns | Description |
| :--- | :--- | :--- |
| `.list()` | `Vector{PormGRow}` | All matching rows as model-aware rows. |
| `.list(:dict)` | `Vector{Dict}` | Plain dictionaries. |
| `.list(:json)` | `String` | Results as JSON string. |
| `query \|> DataFrame` | `DataFrame` | Tabular output. |
| `.first()` | `PormGRow` or `nothing` | First matching row. |
| `.get(filters...)` | `PormGRow` | Exactly one matching row, or raises `DoesNotExist` / `MultipleObjectsReturned`. |
| `.count()` | `Int` | `SELECT COUNT(*)`. |
| `.exists()` | `Bool` | True if any rows match. |

---

## Writing & Mutating Data

Full detail (create/update/delete, bulk ops, transactions) is in [`writing.md`](writing.md); this
is the at-a-glance surface so you don't reach for a stale pattern.

**Row lifecycle.** `create()`, `get()`, `first()`, and `list()` return `PormGRow` values (not `Dict`
— changed in #166); `update_or_create()` returns `(row::PormGRow, created::Bool)`. A `PormGRow` is
dirty-tracked: assign fields, then `save()` writes only the changed columns.
```julia
driver = M.Driver.objects.create("forename" => "Ayrton", "surname" => "Senna")  # PormGRow
driver.nationality = "Brazilian"    # dirty-tracked on assignment
driver.save()                       # UPDATE ... WHERE <pk>; returns the row (no-op if clean)

# Queryset .update() returns the matched-row count (Int), not a row:
n = M.Result.objects.filter("raceid" => 1).update("points" => F("points") + 1)
```

**Many-to-many managers** (bang-free since 0.3.0) — access a `ManyToMany` field declared on the
model (here `Driver` declares `sponsors`) to get a manager: `driver.sponsors.add(1, 2)`,
`.remove(2)`, `.set(1, 4, 5)`, `.clear()`, `.all()`.

**Transactions** — `atomic("db") do … end` (friendly alias of `run_in_transaction`); a nested
`atomic` on the same db is a SAVEPOINT; `atomic("db"; durable=true)` forces a top-level transaction.
Row locking: `query.select_for_update().list()` (PostgreSQL only; must run inside a transaction;
silent no-op on SQLite).

**`get()` exceptions** — `get()` raises `PormG.DoesNotExist` when nothing matches and
`PormG.MultipleObjectsReturned` when more than one row matches. Catch them to handle lookups.

---

## 4. Joins and Lookups

### Relationship traversal
Use `__` to traverse ForeignKey relationships (query each segment in the case it was declared; the F1 models use lowercase):

```julia
# Filter by joined field
M.Result.objects.filter("driverid__nationality" => "British")

# Deep traversal
M.Result.objects.filter("raceid__circuitid__country" => "Monaco")

# Select joined fields
M.Result.objects.
    values("driverid__forename", "driverid__surname", "raceid__year", "points").
    order_by("-points")
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

## 5. Complex Filters: Q Objects

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

## 6. F-Expressions

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

## 7. Aggregations

Aggregate constructors: `Count`, `Sum`, `Avg`, `Max`, `Min`. Use them inside `values()` with an alias. PormG auto-generates `GROUP BY` from the **non-aggregate** columns — never write `GROUP BY` yourself.

```julia
using PormG.Functions: Count, Sum, Max, Min

# Wins per constructor — grouped by the plain column, COUNT aggregated
M.Result.objects.
    filter("positionorder" => 1).
    values("constructorid__name", "wins" => Count("resultid")).
    order_by("-wins")
```

### No grouping → single row (Django `.aggregate()` equivalent)

When **every** `values()` column is an aggregate, there are no non-aggregate columns to group by, so PormG emits **no `GROUP BY`** and returns one summary row over the whole (optionally filtered) table:

```julia
M.Result.objects.
    filter("constructorid" => 131).
    values(
        "max_points"    => Max("points"),
        "min_points"    => Min("points"),
        "total_results" => Count("resultid"),
    )   # → one-row result; WHERE still filters rows before aggregation
```

### Aggregate arithmetic — and when NOT to use `F`

Aggregates take part in arithmetic; the result stays database-side and constants are parameterized (`$1` / `?`), not interpolated:

```julia
"net_points" => Sum("points") - 10      # SUM(points) - 10
"id_span"    => Max("id") - Min("id")   # MAX(id) - MIN(id)
```

Pass the column to the aggregate as a **plain string**, and apply the math to the aggregate object — do **not** wrap the column in `F()`:

- `Max("points") - 5` → `MAX(points) - 5` (math on the aggregate) ✅
- `F("points") - 5` → `points - 5` (row-level column expression) — different meaning
- `Max(F("points"))` → unnecessary; use `Max("points")`

Filtering on an aggregate alias auto-promotes the condition to `HAVING` (e.g. `filter("wins__@gt" => 5)`).

Full SQL-shape examples: the *Filters and Aggregates* and *Field Expressions* pages in the PormG documentation (<https://pingolee.github.io/PormG.jl>).

---

## 8. Query Inspection & Debugging

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
println(meta[:sql_text])
println(meta[:parameters])

# Inspect SELECT queries without executing
using PormG: inspect_query
inspection = query |> inspect_query()
println(inspection[:sql_text])
println(inspection[:dialect])
```

---

## 9. Multi-Database & Multi-Tenancy

```julia
# Route a single query to a different connection pool
M.Driver.objects.filter("nationality" => "British").db("reporting").list()

# Load multiple connections
PormG.Configuration.load_many(["db/conn_primary.yml", "db/conn_replica.yml"])
```

---

## 10. Aliases & Error Types

### Alias identifier rules

Aliases in `values("alias" => "field")` are always double-quoted in the generated SQL, so mixed case and Unicode letters are preserved verbatim in DataFrame columns and result dicts:

```julia
# Column comes back as :Surname and Symbol("localização"), not :surname or :localizao
df = M.Driver.objects.filter("driverref" => "hamilton").
    values("Surname" => "surname", "localização" => "nationality") |> DataFrame
```

Alias identifiers must start with a Unicode letter or underscore, followed by letters, combining marks, digits, or underscores. Aliases with spaces or punctuation throw `InvalidValueError` (a `PormGError`) when the query is **rendered** — on `list()`, `inspect_query`, or `show_query=:sql`, not at `values(...)` time. They are never silently mangled.

!!! warning "Do not catch `ArgumentError` around PormG calls"
    PormG raises typed `PormGError` subtypes, and they are deliberately **not** `<: ArgumentError`.
    `catch ArgumentError` will not match. Catch `PormGError` for any PormG failure, or a specific
    subtype (`InvalidValueError`, `UnknownFieldError`, `UnsafeMutationError`, …) to react precisely.

---

## 11. Anti-Patterns

| Anti-Pattern | Preferred Alternative |
| :--- | :--- |
| Raw SQL strings | Fluent `filter()`, `values()`, `update()` |
| `query \|> list` (free function) | `query.list()` |
| `delete(query)` (free function) | `query.delete()` |
| `SELECT *` across joins | `.values("*", "joined__field")` explicitly |
| Wrong-case join path for a lowercase-declared field | match the declared case (`constructorid__name`) |
| Loops for batch inserts | `bulk_insert()` or `bulk_copy()` (see `writing.md`) |
| Python-style `annotate()` | `values("alias" => F("field") * 1.5)` |
| `F("points") > 20` in filter | `"points__@gt" => 20` (suffix syntax) |
| `Max(F("id")) - 5` for aggregate math | `Max("id") - 5` (string column; math on the aggregate) |
| Expecting `GROUP BY` from an all-aggregate `values()` | One summary row is intended — `.aggregate()` style |
| Modifying fixture data to fit model | Normalize at import time |
| Skipping `dry_run()` before migrate | Always run `dry_run()` first (see `writing.md`) |
