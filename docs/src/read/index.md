# Reading Data with PormG

This section covers the read side of PormG — querying, filtering, joining, aggregating, and transforming data from your database. Every query starts from `Model.objects` and uses a Django-inspired chainable API.

---

## Section Map

| Page | What You'll Learn |
| :--- | :--- |
| [Values and Joins](values_and_joins.md) | Column selection, `__` join traversal, multi-level joins, reverse joins, wildcard `*`, and aliases. |
| [Filters and Aggregates](filters_and_aggregates.md) | `filter()`, lookup operators (`@gt`, `@in`, `@contains`, …), grouping, and `HAVING` clauses. |
| [Functions and Dates](functions_and_dates.md) | SQL functions (`Case`, `Coalesce`, `Concat`, …), date extraction, and math transforms. |
| [Subqueries and CTEs](subqueries_and_ctes.md) | `IN` subqueries, scalar `Subquery`/`Exists` columns, `With(...)` CTEs, deep join paths, and CTE + cjoin combinations. |
| [Field Expressions](field_expressions.md) | `F()` for field-to-field comparisons, arithmetic, aggregate ratios, aliasing, and atomic updates. |
| [Window Functions](window_functions.md) | `Rank`, `RowNumber`, `Lag`, `Lead`, `FirstValue`, `LastValue`, `NthValue` — per-row analytics without collapsing rows. |
| [Q Objects](q_objects.md) | Complex boolean logic with `Q` (AND), `Qor` (OR), nesting, dynamic construction, and `F()` integration. |

---

## Query Execution and Outputs

PormG provides several terminal methods to execute a query and return data in different formats:

| Method | Return Type | Description |
| :--- | :--- | :--- |
| `.list()` | `Vector{PormGRow}` | Returns model-aware rows with dot-access and relationship accessors. |
| `.list(:dict)` | `Vector{Dict{Symbol, Any}}` | Returns plain dictionaries for framework integrations. |
| `.list(:json)` | `String` | Returns results as a JSON string for API responses. |
| `query \|> DataFrame` | `DataFrame` | Pipe to `DataFrame` for tabular output (recommended for analysis). |
| `.first()` | `PormGRow` or `nothing` | Returns the first matching row. |
| `.get(filters...)` | `PormGRow` | Returns exactly one row, or raises a typed exception. |
| `.count()` | `Int` | Runs `SELECT COUNT(*)` and returns the count. |
| `.exists()` | `Bool` | Returns `true` if at least one row matches. |

### Choosing an Output Format

```julia
query = M.Result.objects
query.filter("driverid__nationality" => "Brazilian", "positionorder" => 1)
query.values("driverid__surname", "raceid__name")

# As model-aware rows — best for ORM-style iteration
results = query.list()
for row in results
    println(row[:driverid__surname], " won at ", row[:raceid__name])
end

# As plain dictionaries — useful when another framework requires Dict values
dicts = query.list(:dict)

# As a DataFrame — best for analysis
df = query.values("driverid__surname", "raceid__year") |> DataFrame

# As JSON — best for API responses
json_str = query.list(:json)

# Just the count
n = query.count()      # => 42

# Just a boolean check
has_any = query.exists()  # => true
```

Rows returned by `.list()`, `.first()`, `.get()`, `.create()`, and `.update_or_create()` are `PormGRow` values. They support property access, indexed access, many-to-many relationship accessors, and dirty tracking for `row.save()`:

```julia
driver = M.Driver.objects.get("driverref" => "hamilton")

println(driver.forename, " ", driver.surname)

driver.nationality = "British"
driver.save()
```

For framework integrations that require plain dictionaries, use `.list(:dict)`. For tabular analysis, pipe the query to `DataFrame`.

---

## Query Styles

PormG supports both a **fluent interface** (recommended) and a legacy **pipe style**.

### Fluent Interface (Recommended)

Chain methods directly and finish with a terminal call:

```julia
# Full chain with terminal call
drivers = M.Driver.objects.
    filter("nationality" => "Brazilian").
    order_by("surname").
    limit(10).
    list()

# Route a query to another configured database pool
results = M.Result.objects.
    db("client_42").
    filter("points__@gt" => 10).
    list()
```

### Pipe Style (Legacy)

The pipe style is still supported but the fluent form is preferred in docs and user-facing code:

```julia
query = M.Driver.objects |> filter("nationality" => "Brazilian")
df = query |> DataFrame
```

---

## Chainable Methods Reference

These methods modify the query builder and return the handler for further chaining:

| Method | Description |
| :--- | :--- |
| `.filter(key => value, ...)` | Add WHERE conditions. Multiple pairs are ANDed. |
| `.values("field1", "field2", ...)` | Select specific columns. Use `"*"` for all main-table columns. |
| `.order_by("field", "-field")` | Sort results. Prefix with `-` for descending. |
| `.limit(n)` | Limit the number of returned rows. |
| `.offset(n)` | Skip the first `n` rows. |
| `.page(n)` | Convenience for pagination (requires `.limit()` to be set first). |
| `.distinct()` | Add `SELECT DISTINCT` to the query. |
| `.db("key")` | Route the query to a different connection pool. |
| `.with("name" => subquery)` | Attach a Common Table Expression (CTE). |
| `.cjoin("field" => "Model")` | Add a custom join at query time. |
| `.on("path", key => value)` | Add predicates to the ON clause of an existing join. |
| `.copy()` | Deep-copy the query object for reuse. |

---

## Basic Retrieval Examples

### Simple Filter and List

```julia
# Return model-aware rows
data = M.Status.objects.filter("status" => "Engine").list()

# Return a DataFrame
df = M.Status.objects.filter("status" => "Engine") |> DataFrame
```

### Count and Existence Checks

```julia
count  = M.Status.objects.filter("status" => "Engine").count()
exists = M.Status.objects.filter("status" => "Engine").exists()
```

### Pagination

```julia
# Page 1: first 20 results
page1 = M.Driver.objects.order_by("surname").limit(20).list()

# Page 2: skip 20, take 20
page2 = M.Driver.objects.order_by("surname").limit(20).offset(20).list()
```

### Distinct Results

```julia
nationalities = M.Driver.objects.values("nationality").distinct().list()
```

!!! warning "`distinct()` + `order_by()`: the sort key must be projected"
    Under `distinct()`, every column you `order_by(...)` must appear in `values(...)`. Ordering a
    `DISTINCT` query by a column outside its projection is rejected by PostgreSQL (and the SQL
    standard), and returns rows in a nondeterministic order on SQLite — so PormG raises the same clear
    error on both backends:

    ```julia
    # ✗ raises: surname is not in the SELECT DISTINCT projection
    M.Driver.objects.values("nationality").distinct().order_by("surname").list()

    # ✓ include the sort key in values() (distinct over both columns) …
    M.Driver.objects.values("nationality", "surname").distinct().order_by("surname").list()

    # ✓ … or drop distinct() if you meant "one row per nationality, ordered by an aggregate"
    ```

### Copying a Query for Reuse

```julia
base_query = M.Result.objects.filter("positionorder" => 1)

# Reuse for different projections
winners_by_driver = base_query.copy().values("driverid__surname", "wins" => Count("resultid"))
winners_by_team   = base_query.copy().values("constructorid__name", "wins" => Count("resultid"))
```

---

## Query Inspection

You can inspect the generated SQL without executing the query:

```julia
query = M.Result.objects.
    filter("driverid__nationality" => "Brazilian").
    values("driverid__surname", "points").
    order_by("-points")

# Get just the SQL string
sql = query.list(show_query=:sql)

# Get full metadata (SQL, parameters, dialect, operation)
meta = query.list(show_query=:dict)

# Benchmark the builder with zero overhead
@time query.list(show_query=:none)

# Dedicated inspection API with heuristic intent detection
inspection = query.inspect()
println(inspection[:sql_text])
println(inspection[:operation])  # => :select
```

| `show_query` Mode | Returns |
| :--- | :--- |
| `:execute` | Default — executes the query and returns results. |
| `:sql` | SQL string only (`String`). |
| `:dict` | Full metadata dictionary (`Dict`) with keys `:sql_text` (the SQL string), `:parameters` (the bound values array), `:dialect`, and `:operation`. |
| `:inspection` | Alias of `:dict`, provided for inspection-focused workflows that want the same metadata shape as `inspect_query()`. |
| `:params` | Parameters array only. |
| `:none` | `nothing` (zero-overhead benchmarking). |

`show_query` is supported on terminal methods such as `list()`, `first()`, `get()`, `count()`, `exists()`, `delete()`, `update()`, `bulk_insert()`, and `bulk_update()`.

---

## Database Routing

If you use multiple configured pools, select the target database per query:

```julia
# Route to a staging database
q = M.Driver.objects.db("staging").filter("code" => "SEN")

# Route to a tenant database (with lazy resolution)
results = M.Result.objects.db("client_42").filter("positionorder" => 1).list()
```

See [Configuration: Dynamic Multi-Tenancy](../configuration/dynamic.md) for setting up connection resolvers.

---

## Reading Roadmap

If you are learning the API from scratch, the recommended order is:

1. **[Values and Joins](values_and_joins.md)** — Start with column selection and `__` join traversal.
2. **[Filters and Aggregates](filters_and_aggregates.md)** — Add lookup operators, grouping, and `HAVING`.
3. **[Functions and Dates](functions_and_dates.md)** — Use SQL functions, date extraction, and `Case`/`When`.
4. **[Subqueries and CTEs](subqueries_and_ctes.md)** — Decompose complex queries with `IN` subqueries and `WITH`.
5. **[Field Expressions](field_expressions.md)** — Reach for `F()` when you need column-to-column logic or arithmetic.
6. **[Q Objects](q_objects.md)** — Use `Q()`/`Qor()` only when plain filter pairs stop being expressive enough.

> [!TIP]
> For write operations (create, update, delete, bulk), see the [Writing](../write/index.md) section.