# Reading Data with PormG

This section covers the read side of PormG — querying, filtering, joining, aggregating, and transforming data from your database. Every query starts from `Model.objects` and uses a Django-inspired chainable API.

---

## Section Map

| Page | What You'll Learn |
| :--- | :--- |
| [Values and Joins](values_and_joins.md) | Column selection, `__` join traversal, multi-level joins, reverse joins, wildcard `*`, and aliases. |
| [Filters and Aggregates](filters_and_aggregates.md) | `filter()`, lookup operators (`@gt`, `@in`, `@contains`, …), grouping, and `HAVING` clauses. |
| [Functions and Dates](functions_and_dates.md) | SQL functions (`Case`, `Coalesce`, `Concat`, …), date extraction, and math transforms. |
| [Subqueries and CTEs](subqueries_and_ctes.md) | `IN` subqueries, scalar `Subquery`/`Exists` columns, `.with(...)` CTEs and their `"<cte>__<column>"` columns, deep join paths, and CTE + cjoin combinations. |
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
| `query \|> DataFrame` | `DataFrame` | Pipe to `DataFrame` for tabular output (recommended for analysis). Temporal columns hold the same typed values as `.list()` on both engines. |
| `.first()` | `PormGRow` or `nothing` | Returns the first matching row. |
| `.last()` | `PormGRow` or `nothing` | Returns the last matching row (inverts `order_by`; falls back to primary-key descending when no ordering is set). |
| `.earliest(fields...)` | `PormGRow` | Returns the earliest row ordered by `fields`; raises `DoesNotExist` when empty. |
| `.latest(fields...)` | `PormGRow` | Returns the latest row ordered by `fields`; raises `DoesNotExist` when empty. |
| `.get(filters...)` | `PormGRow` | Returns exactly one row, or raises a typed exception. |
| `.count()` | `Int` | Runs `SELECT COUNT(*)` and returns the count. |
| `.aggregate(pairs...)` | `NamedTuple` | Computes whole-queryset aggregates (no `GROUP BY`) and returns them as a single-row named tuple. |
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

Rows returned by `.list()`, `.first()`, `.last()`, `.earliest()`, `.latest()`, `.get()`, `.create()`, `.get_or_create()`, and `.update_or_create()` are `PormGRow` values. They support property access, indexed access, many-to-many relationship accessors, and dirty tracking for `row.save()` and `row.delete()`:

```julia
driver = M.Driver.objects.get("driverref" => "hamilton")

println(driver.forename, " ", driver.surname)

driver.nationality = "British"
driver.save()
```

For framework integrations that require plain dictionaries, use `.list(:dict)`. For tabular analysis, pipe the query to `DataFrame`.

### Serializing rows to JSON

`JSON.json` on a `PormGRow` — or on the `Vector{PormGRow}` that `.list()` returns — emits the row's
columns and nothing else. For rows as returned by a query, that is exactly the JSON `.list(:json)`
produces:

```julia
using JSON

query = M.Driver.objects.filter("nationality" => "Brazilian").
    values("driverref", "surname").
    order_by("driverref")

JSON.json(query.list()) == query.list(:json)   # => true
```

(Both read the row's stored columns, so an edited row — `driver.nationality = "British"` before
`.save()` — serializes what you set, while a fresh `.list(:json)` re-queries the database.)

The difference is where the result can go. `.list(:json)` hands back a `String`, so nesting it inside
a larger response object double-encodes it; serializing the rows directly does not:

```julia
JSON.json((count = query.count(), drivers = query.list()))
# => {"count":32,"drivers":[{"driverref":"barrichello","surname":"Barrichello"}, ...]}
```

Durations go through the same formatter either way, so a `DurationField` reads as `"00:01:49.088"`
rather than as a struct dump, on both engines.

A `DecimalField` goes through the same formatter too, and comes out as a JSON **number** carrying the
digits the value actually has — not as a string, and not re-rounded through a `Float64` on the way out:

```julia
query = M.Constructor_results.objects
query.values("points")
query.order_by("constructorresultsid")
query.limit(5)

query.list(:json)
# => [{"points":14},{"points":8},{"points":9},{"points":5},{"points":2}]
```

A whole value reads as `14`, not `14.0`, and a fractional one keeps its scale — `{"points":0.5}`.

**On PostgreSQL that is exact at any declared width.** A
`DecimalField(max_digits = 24, decimal_places = 2)` holding `12345678901234567.89` serializes with all
nineteen digits, where routing it through a `Float64` would have rendered `1.2345678901234568e16`.
LibPQ delivers a `NUMERIC` as a `Decimals.Decimal`, so nothing on the path narrows it.

**On SQLite it is exact up to fifteen digits, and PormG refuses anything wider.** SQLite has no exact
decimal type. A `DECIMAL(p, s)` column gets SQLite's `NUMERIC` affinity, which converts the value as it
is stored into an `Int64` or a `Float64` — preferring an integer conversion, and silently dropping what
will not fit. Measured on a column declared wider than that:

```
declared DECIMAL(24, 2), inserted   SQLite stores   read back
  14                                integer         14                      (Int64)
  0.5                               real            0.5                     (Float64)
  1.000000000000000000001           integer         1                       (Int64)
  123456789012345.67                real            1.2345678901234567e14   (Float64)
  12345678901234567.89              integer         12345678901234568       (Int64)
```

Note the third row: the fractional part is not rounded, it is discarded, and the value becomes a plain
`1`. Nothing on the read path can recover that, which is why the fix is on the declaration: a `Float64`
keeps fifteen significant digits exactly, so **`makemigrations` raises `BackendCapabilityError` for a
`DecimalField` with `max_digits` above 15 on SQLite** rather than create a column like the one above.
Every decimal column PormG creates on SQLite therefore holds the values it accepts exactly — and
because it does, PormG reads each one back as the **`Decimals.Decimal` that was written**, the same
type PostgreSQL returns, rather than the `Int64`/`Float64` SQLite stored it as. A column created
outside PormG, or before this refusal existed, still behaves as the table shows and reads back raw:
SQLite may already have rounded what it holds, and a `Decimal` rebuilt from that would only look
exact. Use PostgreSQL where more than fifteen digits is the point.

!!! note "Both engines emit the same JSON text"
    For every column PormG creates, a `DecimalField` reaches `.list(:json)` as a `Decimal` on both
    engines, so both emit the same digits: `{"amount":1234567.89}`. Before, SQLite handed back a
    `Float64`, which Julia renders in exponent form from a million up (`{"amount":1.23456789e6}`).

    Three values still arrive on SQLite as the number it computed, not a `Decimal`, and render that
    way: an **aggregate or arithmetic** result over the column (`Sum("amount")`, `F("amount") * 2`),
    computed through a double; a row returned by **`create()`** (and `get_or_create` /
    `update_or_create`), which is read back without the query parsers, like temporal columns are; and
    a column **wider than fifteen digits** created outside PormG.

This applies to a **column's own value**. A decimal nested inside a container — a PostgreSQL
`numeric[]`, which LibPQ delivers as a `Vector{Decimal}` — is not reached, and still serializes through
a `Float64`. That is the same limit the duration formatter above has, and it is unchanged by this.

!!! note "Reading it back"
    The digits are exact in the JSON *document*. Whether they survive the consumer is the consumer's
    parser: JavaScript's `JSON.parse` converts every number to a double, so a value wider than about
    sixteen significant digits is rounded on arrival. Nothing PormG emits can prevent that — reach
    for a big-decimal JSON parser on that side if the width matters.

!!! warning "No lazy FK traversal — project related columns up front"
    PormG never lazily loads a related row. Accessing a `ForeignKey` or `OneToOneField`
    you did not project (`row.driverid`, or traversing further with
    `row.driverid.forename`) raises a `LazyTraversalError`. Project what you need up
    front with `values(...)`, then read it off the row by its key:

    ```julia
    # ✗ raises: driverid was not projected, and PormG won't lazily load it
    row = M.Result.objects.values("resultid", "points").first()
    driver_name = row.driverid.forename

    # ✓ project the related column, then read it
    row = M.Result.objects.values("resultid", "driverid__forename").first()
    driver_name = row[:driverid__forename]

    # ✓ or project the raw foreign-key value
    row = M.Result.objects.values("resultid", "driverid").first()
    driver_id = row[:driverid]
    ```

---

### Serializing a model, a query or a field

Rows are the thing worth serializing; a *model* is not. Handing one to `JSON.json` gives you a short
marker naming it, never its schema:

```julia
JSON.json(M.Driver)                      # => {"pormg_model":"driver"}
JSON.json(M.Driver.fields["surname"])    # => {"pormg_field":"CharField"}
JSON.json(M.Driver.objects)              # => {"pormg_query":"driver"}
```

That is a deliberate floor, not an export format. The model graph is cyclic and densely
cross-referenced, so serializing it by reflection re-walks every path through it — on the F1
schema these docs use, one model produced 2,175,304 characters, and a real application schema
exhausted memory. The marker makes that unrepresentable: nothing PormG hands a serializer can contain
another PormG value.

Nothing you would want in a response is affected, because a model never belonged in one. If you need
schema information as data, read it off the model directly rather than serializing the model:
`M.Driver.field_names` for the columns, or `keys(M.Driver.fields)` for every declared field —
`field_names` covers only fields that own a real column, so it omits a `ManyToManyField`.

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

## Handler Mutation Model

Every query handler follows four rules. They are where PormG deliberately differs from
Django's clone-per-call querysets, so they are worth internalizing once:

1. **`Model.objects` returns a fresh handler on every access.** Two mentions of
   `M.Driver.objects` are two independent queries — state never leaks between them.
2. **Chain methods mutate the handler in place** and return that same handler (not a
   copy). Assigning a chain to a second variable aliases the same query.
3. **`.copy()` is the branching escape hatch** — deep-copy a base query, then extend
   each copy independently (example below).
4. **Terminal methods never mutate the handler.** `count`, `exists`, `list`, `first`,
   `get`, and the `show_query`/`inspect_query` inspection paths all execute on an
   internal copy of the handler. A handler stays reusable after any read terminal —
   `q.first()` does not leave a `limit(1)` behind, inline filters passed to
   `q.get("field" => v)` do not persist, and `q.update(...)` after `q.first()` is valid.

### Re-call semantics: which methods accumulate

Calling the same chain method twice is not always the same operation. The semantics
follow Django: `filter` accumulates, while `values`/`order_by` replace their previous
call (Django documents this as "each `order_by()` call will clear any previous ordering").

```julia
q = M.Result.objects
q.filter("raceid__year" => 2019)
q.filter("positionorder" => 1)           # accumulates: year = 2019 AND positionorder = 1

q.values("driverid__surname")
q.values("driverid__surname", "points")  # replaces: only surname + points are selected

q.order_by("points")
q.order_by("-points")                    # replaces: ORDER BY points DESC only
```

### Branching with `.copy()`

```julia
base_query = M.Result.objects.filter("positionorder" => 1)

# Reuse for different projections — each copy evolves independently
winners_by_driver = base_query.copy().values("driverid__surname", "wins" => Count("resultid"))
winners_by_team   = base_query.copy().values("constructorid__name", "wins" => Count("resultid"))
```

---

## Chainable Methods Reference

These methods modify the query builder and return the handler for further chaining. The
**On re-call** column states what a second call of the same method does (see the
[handler mutation model](#Handler-Mutation-Model) above):

| Method | Description | On re-call |
| :--- | :--- | :--- |
| `.filter(key => value, ...)` | Add WHERE conditions. Multiple pairs are ANDed. | **Accumulates** (ANDed) |
| `.values("field1", "field2", ...)` | Select specific columns. Use `"*"` for all main-table columns. | **Replaces** previous call |
| `.order_by("field", "-field")` | Sort results. Prefix with `-` for descending. | **Replaces** previous call |
| `.limit(n)` | Limit the number of returned rows. | Last value wins |
| `.offset(n)` | Skip the first `n` rows. | Last value wins |
| `.page(limit)` / `.page(limit, offset)` | Pagination in one call. `.page(n)` sets `LIMIT` only and leaves `.offset()` untouched; `.page(n, m)` sets both. Any other shape raises `QueryBuildError`. | Last value wins |
| `.distinct()` | Add `SELECT DISTINCT` to the query. | Last value wins |
| `.db("key")` | Route the query to a different connection pool. | Last value wins |
| `.with("name" => subquery)` | Attach a Common Table Expression (CTE); reference its columns as `"name__column"`, or with `CTE(name, path)` when the name collides with a model field. | Adds another CTE |
| `.cjoin("field" => "Model")` | Add a custom join at query time. | Adds another join |
| `.on("path", key => value)` | Add predicates to the ON clause of an existing join. | Adds more predicates |
| `.copy()` | Deep-copy the query object for reuse. | — |

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

# Same thing in one call — .page(limit, offset)
page2_alt = M.Driver.objects.order_by("surname").page(20, 20).list()

# .page(n) is limit-only: it sets LIMIT and leaves any offset already on the handler alone
top20 = M.Driver.objects.order_by("surname").page(20).list()
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

---

## At the REPL

Models, queries and rows print as readable summaries, so you can build a query one step at a time and look at it as you go.

Typing a model shows its columns as the database holds them — the SQL type, the relations, and the schema flags:

```julia-repl
julia> M.Driver
PormG model · driver · db "db_sl"
  driverid     IDField       BIGINT  pk  unique  index
  driverref    CharField     VARCHAR(250)
  number       IntegerField  INTEGER  null
  code         CharField     VARCHAR(250)
  forename     CharField     VARCHAR(250)
  surname      CharField     VARCHAR(250)
  dob          DateField     DATE
  nationality  CharField     VARCHAR(250)
  url          CharField     VARCHAR(250)
  reverse: driver_standings, lap_times, pit_stops, qualifying, result, sprint_results
  query: driver.objects.filter(…)
```

The `reverse:` line lists the accessors other models installed on this one through their `ForeignKey`s — those are the names you traverse backwards with, as described in [Values and Joins](values_and_joins.md).

A query handler shows the clauses you have set so far:

```julia-repl
julia> q = M.Result.objects.filter("driverid__surname" => "Senna", "positionorder__@lte" => 3).
           values("year" => "raceid__year", "race" => "raceid__name", "pts" => "points").
           order_by("-points").limit(20)
PormG query · result
  filter    driverid__surname => "Senna", positionorder <= 3
  values    year, race, pts
  order_by  -points
  page      limit 20
  not executed — .list() · .count() · DataFrame(q) · SQL: show_query(q)
```

The `values` line names the **output columns** — the aliases you gave — not the field paths behind them, so it reads as the columns the result will actually carry.

!!! note "Displaying a query never touches the database"
    Unlike Django, where `repr(queryset)` executes the query and prints the first rows, printing a PormG query builds nothing and connects to nothing. The last line names the calls that do: `.list()` to fetch rows, `.count()` for a count, `DataFrame(q)` for a table, and [`show_query`](#Query-Inspection) for the SQL. This keeps display free of hidden side effects and consistent with the [async-first](../async.md) contract — a query only reaches the database when you say so.

Rows print as themselves, with the primary key first:

```julia-repl
julia> row = M.Driver.objects.filter("surname" => "Senna").values("driverid", "forename", "surname", "nationality").first()
PormG row · driver · 4 columns
  driverid     102
  forename     "Ayrton"
  nationality  "Brazilian"
  surname      "Senna"
```

And `list()` uses standard Julia vector display, one row per line — so a long result set elides in the middle the way any Julia vector does:

```julia-repl
julia> M.Driver.objects.filter("surname" => "Fittipaldi").values("driverid", "forename", "surname").list()
4-element Vector{PormGRow}:
 Row(driver: driverid=104, forename="Christian", surname="Fittipaldi")
 Row(driver: driverid=224, forename="Emerson", surname="Fittipaldi")
 Row(driver: driverid=290, forename="Wilson", surname="Fittipaldi")
 Row(driver: driverid=850, forename="Pietro", surname="Fittipaldi")
```

For a tabular view of a result set, pipe to `DataFrame` instead — see [Choosing an Output Format](#Choosing-an-Output-Format) above.

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

!!! tip
    For write operations (create, update, delete, bulk), see the [Writing](../write/index.md) section.