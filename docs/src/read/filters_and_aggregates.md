# Filters and Aggregates

This page covers lookup operators, filtering, exclusion patterns, grouping, and `HAVING` clauses.

---

## The `__@` Suffix System

PormG uses the `__@` suffix on field names for both **comparison operators** and **transform functions**:

- `field__@operator` — Compare a field to a value (e.g., `"points__@gt" => 10`).
- `field__@function` — Transform a field before comparing or selecting (e.g., `"dob__@year" => 1960`).

These work in both `filter()` and `values()`.

---

## Comparison Operators

| Operator | SQL | Description | Example |
| :--- | :--- | :--- | :--- |
| *(none)* | `= value` | Exact match | `"nationality" => "British"` |
| `@gt` | `> value` | Greater than | `"points__@gt" => 10` |
| `@gte` | `>= value` | Greater than or equal | `"points__@gte" => 10` |
| `@lt` | `< value` | Less than | `"positionorder__@lt" => 3` |
| `@lte` | `<= value` | Less than or equal | `"positionorder__@lte" => 10` |
| `@ne` | `<> value` | Not equal | `"status__@ne" => "Retired"` |
| `@in` | `IN (...)` | Value in set | `"nationality__@in" => ["British", "French"]` |
| `@nin` | `NOT IN (...)` | Value not in set | `"nationality__@nin" => ["British", "German"]` |
| `@range` | `BETWEEN a AND b` | Between two bounds | `"driverid__@range" => [1, 50]` |
| `@isnull` | `IS NULL / IS NOT NULL` | Null check | `"dob__@isnull" => true` |
| `@contains` | `LIKE '%val%'` | Case-sensitive substring | `"name__@contains" => "Monaco"` |
| `@icontains` | `ILIKE '%val%'` | Case-insensitive substring | `"name__@icontains" => "monaco"` |
| `@iunaccent_contains` | `immutable_unaccent(col) ILIKE immutable_unaccent('%val%')` | Accent- & case-insensitive substring (PostgreSQL only) | `"surname__@iunaccent_contains" => "raikkonen"` |
| `@iunaccent_exact` | `LOWER(immutable_unaccent(col)) = LOWER(immutable_unaccent(val))` | Accent- & case-insensitive equality (PostgreSQL only) | `"surname__@iunaccent_exact" => "raikkonen"` |

### Transform Functions (Modifiers)

| Transform | Description | Use in `filter()` | Use in `values()` |
| :--- | :--- | :--- | :--- |
| `@year` | Extract year from date | `"dob__@year" => 1960` | `"dob__@year"` |
| `@month` | Extract month | `"dob__@month" => 3` | `"dob__@month"` |
| `@day` | Extract day | `"date__@day" => 21` | `"date__@day"` |
| `@quarter` | Extract quarter (1-4) | `"date__@quarter" => 1` | `"date__@quarter"` |
| `@quadrimester` | Extract quadrimester (1-3) | `"date__@quadrimester" => 2` | `"date__@quadrimester"` |
| `@date` | Extract date from datetime | `"created__@date" => Date(...)` | `"created__@date"` |
| `@yyyy_mm` | Year-month string | `"date__@yyyy_mm" => "1991-10"` | `"date__@yyyy_mm"` |
| `@round` | Round numeric value | — | `"points__@round"` |
| `@floor` | Floor numeric value | — | `"points__@floor"` |
| `@ceil` | Ceiling numeric value | — | `"points__@ceil"` |
| `@sqrt` | Square root | — | `"driverid__@sqrt"` |
| `@abs` | Absolute value | — | `"points__@abs"` |
| `@power` | Power function | — | see `Power()` |
| `@mod` | Modulo | — | see `Mod()` |

---

## Basic Comparisons

### Exact Match

```julia
df = M.Driver.objects.filter("nationality" => "Brazilian") |> DataFrame
```

### Greater Than / Less Than

```julia
query = M.Result.objects
query.filter("positionorder__@lt" => 3)
df = query |> DataFrame
```

### Not Equal

```julia
query = M.Result.objects
query.filter("statusid__status__@ne" => "Retired")
```

---

## Range Filters

`@range` translates to SQL `BETWEEN` and accepts exactly two bounds (as a Vector or Tuple):

```julia
# Vector syntax
query = M.Driver.objects.filter("driverid__@range" => [1, 5])
df = query |> DataFrame

# Tuple syntax
query = M.Driver.objects.filter("driverid__@range" => (10, 15))
df = query |> DataFrame
```

---

## String Matching

### Case-Sensitive (`@contains`)

```julia
query = M.Result.objects
query.filter("raceid__circuitid__name__@contains" => "Monaco")
count = query.count()
```

### Case-Insensitive (`@icontains`)

```julia
query = M.Result.objects
query.filter("raceid__circuitid__name__@icontains" => "monaco")
count = query.count()
```

> [!NOTE]
> `@icontains` uses `ILIKE` on PostgreSQL. On SQLite it renders `pormg_lower(col) LIKE pormg_lower(val)`,
> where `pormg_lower` is a Unicode-aware case-folding function PormG registers on every SQLite
> connection — so accented text folds case on SQLite as it does on PostgreSQL
> (`"surname__@icontains" => "RÄIKKÖNEN"` finds `"Räikkönen"` on both backends). It folds case but
> preserves accents; for accent-insensitive matching use the PostgreSQL-only `@iunaccent_*` lookups below.

### Prefix / Suffix (`@startswith`, `@endswith`)

Case-sensitive anchored matches — `@startswith` renders `LIKE 'value%'` and `@endswith` renders `LIKE '%value'` (the wildcard is added on one side only):

```julia
# Surnames beginning with "Ver" (e.g. Verstappen)
M.Driver.objects.filter("surname__@startswith" => "Ver")

# Surnames ending in "sen" (e.g. Häkkinen → no; Raikkonen → no; Magnussen → yes)
M.Driver.objects.filter("surname__@endswith" => "sen")
```

Both escape `%` and `_` in the bound value, so user input is matched literally.

### Accent-Insensitive (`@iunaccent_contains`, `@iunaccent_exact`)

**PostgreSQL only.** These lookups match while ignoring both diacritics and case, so an ASCII query finds accented data:

```julia
# Substring: finds "Räikkönen" from the ASCII spelling
M.Driver.objects.filter("surname__@iunaccent_contains" => "raikkonen")

# Equality: finds "Räikkönen" regardless of accents/case, but only as a whole value
M.Driver.objects.filter("surname__@iunaccent_exact" => "RAIKKONEN")
```

They require the `unaccent` extension and its `immutable_unaccent` helper, declared once in `connection.yml` and installed by `migrate()` — see [PostgreSQL Extensions](../configuration/connection_yml.md#postgresql-extensions). On SQLite these lookups raise an `ArgumentError`.

There is no `@iunaccent_in`; OR the equality lookup with [`Qor`](q_objects.md) for accent-insensitive set membership:

```julia
M.Driver.objects.filter(Qor(
    "surname__@iunaccent_exact" => "raikkonen",
    "surname__@iunaccent_exact" => "hakkinen",
))
```

> [!NOTE]
> `immutable_unaccent(col)` is not sargable without a matching index. For large tables add a `pg_trgm` GIN index (for `@iunaccent_contains`) or a btree on `lower(immutable_unaccent(col))` (for `@iunaccent_exact`) — see [PostgreSQL Extensions](../configuration/connection_yml.md#postgresql-extensions).

---

## IN and NOT IN

### Value In Set

```julia
query = M.Result.objects
query.filter("raceid__circuitid__name__@in" => ["Circuit de Monaco", "Silverstone"])
```

### Value Not In Set

```julia
query = M.Driver.objects
query.filter("nationality__@nin" => ["British", "German"])
```

### Subquery IN

You can also pass a query object to `@in` for a server-side `IN (SELECT ...)`:

```julia
engine_statuses = M.Status.objects.filter("status" => "Engine").values("statusid")

query = M.Result.objects
query.filter("statusid__@in" => engine_statuses)
```

The subquery must project exactly one column — see [Subqueries and CTEs](subqueries_and_ctes.md) for the full column-count rule and SQL-function projection examples.

### Correlated EXISTS

Use `Exists(subquery)` with `OuterRef("field")` when the child query must compare against the current row of the outer query. PormG renders the child query as `EXISTS (SELECT 1 ... LIMIT 1)` and keeps child filter values parameterized.

```julia
using PormG: Exists, OuterRef, Qor

fast_laps = M.Lap_times.objects.filter(
    "raceid" => OuterRef("raceid"),
    "driverid" => OuterRef("driverid"),
    "milliseconds__@lte" => 90_000,
)

fast_pit_stops = M.Pit_stops.objects.filter(
    "raceid" => OuterRef("raceid"),
    "driverid" => OuterRef("driverid"),
    "milliseconds__@lte" => 30_000,
)

query = M.Result.objects
query.filter(Qor(Exists(fast_laps), Exists(fast_pit_stops)))
query.values("resultid", "raceid__name", "driverid__surname")
```

Generated SQL (PostgreSQL):

```sql
SELECT
    "Tb"."resultid" as resultid,
    "T1"."name" as raceid__name,
    "T2"."surname" as driverid__surname
FROM "result" as "Tb"
INNER JOIN "races" as "T1" ON "Tb"."raceid" = "T1"."raceid"
INNER JOIN "drivers" as "T2" ON "Tb"."driverid" = "T2"."driverid"
WHERE (EXISTS (SELECT 1
FROM "lap_times" as "R1"
WHERE "R1"."raceid" = "Tb"."raceid" AND
   "R1"."driverid" = "Tb"."driverid" AND
   "R1"."milliseconds" <= $1
LIMIT 1) OR EXISTS (SELECT 1
FROM "pit_stops" as "R2"
WHERE "R2"."raceid" = "Tb"."raceid" AND
   "R2"."driverid" = "Tb"."driverid" AND
   "R2"."milliseconds" <= $2
LIMIT 1))
-- Parameters: [90000, 30000]
```

`OuterRef("pk")` resolves to the outer model's primary key field automatically:

```julia
# Find results that have at least one linked test-deletion row
del_sub = M.Just_a_test_deletion.objects.filter(
    "test_result" => OuterRef("pk"),
)
query = M.Result.objects.filter(Exists(del_sub))
```

Generated SQL (PostgreSQL):

```sql
SELECT
    *
FROM "result" as "Tb"
WHERE EXISTS (SELECT 1
FROM "just_a_test_deletion" as "R1"
WHERE "R1"."test_result" = "Tb"."resultid"
LIMIT 1)
```

#### Combining EXISTS with outer scalar filters

Additional filters on the outer query AND with the EXISTS predicate in the usual way:

```julia
fast_laps = M.Lap_times.objects.filter(
    "raceid"             => OuterRef("raceid"),
    "driverid"           => OuterRef("driverid"),
    "milliseconds__@lte" => 90_000,
)

# All results for driver 1 that also have a fast lap — EXISTS AND scalar
query = M.Result.objects.filter(Exists(fast_laps), "driverid" => 1)
```

Generated SQL (PostgreSQL):

```sql
SELECT
    *
FROM "result" as "Tb"
WHERE EXISTS (SELECT 1
FROM "lap_times" as "R1"
WHERE "R1"."raceid" = "Tb"."raceid" AND
   "R1"."driverid" = "Tb"."driverid" AND
   "R1"."milliseconds" <= $1
LIMIT 1) AND
   "Tb"."driverid" = $2
-- Parameters: [90000, 1]
```

#### Reusing a subquery object

The same subquery object can be passed to `Exists` in multiple outer queries without mutation. Each outer query builds its own independent correlated subquery:

```julia
lap_sub = M.Lap_times.objects.filter(
    "raceid"             => OuterRef("raceid"),
    "driverid"           => OuterRef("driverid"),
    "milliseconds__@lte" => 90_000,
)

all_fast     = M.Result.objects.filter(Exists(lap_sub))                       # all results with a fast lap
driver2_fast = M.Result.objects.filter(Exists(lap_sub), "driverid" => 2)      # narrowed to driver 2
```

Generated SQL for `driver2_fast` (PostgreSQL):

```sql
SELECT
    *
FROM "result" as "Tb"
WHERE EXISTS (SELECT 1
FROM "lap_times" as "R1"
WHERE "R1"."raceid" = "Tb"."raceid" AND
   "R1"."driverid" = "Tb"."driverid" AND
   "R1"."milliseconds" <= $1
LIMIT 1) AND
   "Tb"."driverid" = $2
-- Parameters: [90000, 2]
```

### Filter Values from Web Frameworks

PormG accepts `SubString{String}` wherever a `String` filter value is expected, so values parsed directly from HTTP query strings (e.g. via `split`, `HTTP.URIs`, or Genie parameters) can be passed without an explicit `String(...)` conversion:

```julia
# SubString from a query-string parser — no conversion needed
nationality = split("nationality=British", "=")[2]  # SubString{String}
query = M.Driver.objects.filter("nationality" => nationality)

# @in with a split list also works
codes = split("hamilton,vettel,alonso", ",")  # Vector{SubString{String}}
query = M.Driver.objects.filter("driverref__@in" => codes)
```

---

## Null Checks

```julia
# Find drivers with no date of birth recorded
query = M.Driver.objects.filter("dob__@isnull" => true)

# Find drivers that DO have a date of birth
query = M.Driver.objects.filter("dob__@isnull" => false)
```

---

## Multiple Filters (AND Logic)

Multiple pairs inside one `filter()` call are combined with `AND`:

```julia
query = M.Result.objects
query.filter("statusid__status" => "Finished", "resultid" => 26745)
query.values(
    "resultid",
    "raceid__circuitid__name",
    "driverid__forename",
    "constructorid__name",
    "statusid__status",
    "grid",
    "laps"
)
results = query.list()
```

Successive `.filter()` calls also use AND — they are additive:

```julia
query = M.Result.objects
query.filter("statusid__status" => "Finished")
query.filter("positionorder" => 1)   # Adds another AND condition
```

For OR logic, use [`Qor()`](q_objects.md):

```julia
using PormG: Qor

query = M.Result.objects
query.filter(Qor("constructorid" => 1, "constructorid" => 9))
```

---

## Ordering and NULL Placement

`order_by(...)` sorts the result. Prefix a field with `-` for descending; pass several fields to break ties left to right:

```julia
# By nationality (A→Z), then surname (A→Z) within each nationality
query = M.Driver.objects
query.values("surname", "nationality")
query.order_by("nationality", "surname")
```

### Where NULLs land

Nullable sort keys are normalized to sort **the same way on PostgreSQL and SQLite** (the two
backends have *opposite* native defaults, which used to make `order_by(...).first()` return
different rows on each). PormG standardizes on PostgreSQL's convention — **NULL sorts as the
largest value** — on every backend:

| Direction | NULL placement |
|-----------|----------------|
| `order_by("field")` (ASC)  | NULLs **last**  |
| `order_by("-field")` (DESC) | NULLs **first** |

```julia
# nationality is nullable. Ascending → the rows with a NULL nationality come LAST,
# identically on PostgreSQL and SQLite.
M.Driver.objects.values("surname", "nationality").order_by("nationality").list()
```

### Overriding placement per term

Pass a `SQLOrder` object with `nulls = :first` or `nulls = :last` to force placement independently
of the sort direction:

```julia
using PormG.QueryBuilder: SQLOrder, SQLField

# Ascending by nationality, but push NULL nationalities to the FRONT
M.Driver.objects.values("surname", "nationality").order_by(
    SQLOrder(SQLField("nationality", "nationality"); orientation = "ASC", nulls = :first)
).list()
```

`orientation` must be `"ASC"` or `"DESC"` (case-insensitive); any other value — including a
user-supplied sort-direction string forwarded as-is — raises an `ArgumentError` at construction
instead of reaching the SQL.

On SQLite builds older than 3.30.0 (which lack `NULLS FIRST/LAST` syntax) PormG emits the portable
`(field IS NULL)` sort prefix, so the placement is identical there too.

!!! note
    `nulls` normalization and the `SQLOrder(...; nulls=…)` override apply to the query's top-level
    `ORDER BY`. Ordering **inside** a window frame (`WindowOver(order_by=…)`) is not yet normalized —
    its NULL placement still follows each backend's native default.

!!! note "Ordering a `distinct()` query"
    When a query uses `distinct()`, every `order_by(...)` column must be part of the
    projection (`values(...)`). Ordering a `DISTINCT` result by an unprojected column — or by a
    *function* of a projected column, e.g. `order_by("created_at__@date")` while only `created_at` is
    selected — is rejected by PostgreSQL and the SQL standard, so PormG raises on both backends rather
    than let SQLite return nondeterministic rows. Add the exact ordering expression to `values(...)`,
    or drop `distinct()`.

---

## Counting

`count()` is a terminal that returns a scalar `Int` for the current query (filters included). It has four forms:

```julia
# Total rows
M.Driver.objects.count()                                 # SELECT COUNT(*)

# Distinct rows — dedupes whole rows (wraps SELECT DISTINCT * in an outer COUNT(*))
M.Driver.objects.distinct().count()                      # same as:
M.Driver.objects.count(distinct=true)

# Non-null values of one column
M.Driver.objects.count("nationality")                    # SELECT COUNT("nationality")

# Distinct values of one column (e.g. "how many nationalities are represented?")
M.Driver.objects.count("nationality", distinct=true)     # SELECT COUNT(DISTINCT "nationality")
```

Filters apply to every form:

```julia
# How many distinct nationalities among drivers who have raced for constructor 1?
M.Result.objects.filter("constructorid" => 1).count("driverid__nationality", distinct=true)
```

> [!NOTE]
> `count("col", distinct=true)` is the scalar, single-query equivalent of the `Count("col", distinct=true)` aggregate used inside [`values()`](#aggregations-and-grouping) — reach for the terminal form when you just want the number, and the aggregate form when you want it grouped alongside other columns.

---

## Aggregations and Grouping

`PormG.Functions` provides five aggregate functions: `Count`, `Sum`, `Avg`, `Max`, and `Min`.

When aggregate values appear in `values()`, PormG **automatically groups by the non-aggregated columns**.

```julia
using PormG.Functions: Count, Sum, Max, Min

query = M.Result.objects
query.values(
    "statusid__status",
    "raceid__circuitid__name",
    "driverid__forename",
    "constructorid__name",
    "count_grid" => Count("grid"),
    "max_grid"   => Max("grid"),
    "min_grid"   => Min("grid")
)
query.filter("statusid__status" => "Finished", "driverid__forename" => "Ayrton")
query.order_by("raceid__circuitid__name")
df = query |> DataFrame
```

### How Grouping Works

PormG detects which columns in `values()` are aggregates and which are plain fields. It generates:

```sql
SELECT ..., COUNT("Tb"."grid") as count_grid, ...
FROM "result" as "Tb" ...
GROUP BY 1, 2, 3, 4   -- groups by non-aggregate columns
```

You do **not** write `GROUP BY` manually — PormG handles it.

> [!TIP]
> Window functions (`Rank`, `RowNumber`, `Lag`, …) can coexist with aggregates in the same `values()` call. PormG keeps window aliases out of `GROUP BY` automatically. See [Window Functions](window_functions.md).

### Aggregating Without Grouping

When **every** column in `values()` is an aggregate, there are no non-aggregate columns to group by — so PormG emits **no `GROUP BY`** and the query collapses to a single summary row over the whole (optionally filtered) table. This is the equivalent of Django's `.aggregate()`.

```julia
# Highest score, lowest score, and number of results for one constructor
query = M.Result.objects
query.filter("constructorid" => 131)
query.values(
    "max_points"    => Max("points"),
    "min_points"    => Min("points"),
    "total_results" => Count("resultid")
)
df = query |> DataFrame   # one-row DataFrame
```

Generated SQL (PostgreSQL):
```sql
SELECT
    MAX("Tb"."points") as "max_points",
    MIN("Tb"."points") as "min_points",
    COUNT("Tb"."resultid") as "total_results"
FROM "result" as "Tb"
WHERE "Tb"."constructorid" = $1
-- Parameters: [131]
```

The `WHERE` filter still applies row-by-row *before* aggregation; it is the absence of plain (non-aggregate) **projection** columns that removes the `GROUP BY`. Add any plain column back into `values()` and PormG groups by it again, exactly as shown in the section above.

These aggregates can carry arithmetic too — e.g. `"id_span" => Max("resultid") - Min("resultid")`, or subtract a constant like `Max("resultid") - 1000`. See [Aggregate Arithmetic](field_expressions.md#aggregate-arithmetic).

### Aggregating Across To-Many Relations (Fan-Out Guard)

Joining a **to-many** relation — a reverse foreign key (one parent → many children) or a many-to-many — repeats each parent row once per related row *before* aggregation. An aggregate over a **parent/base** column would therefore be silently multiplied. PormG refuses this at build time rather than return a confidently-wrong number:

```julia
# ✗ raises: counts the DRIVER pk, but the driver_standings join repeats each driver row once per standing
query = M.Driver.objects
query.values("nationality", "n" => Count("driverid"))
query.filter("driver_standings__position__@gte" => 1)
query |> DataFrame   # ArgumentError: PormG fan-out guard (#74): the aggregate n is inflated because …
```

The legitimate case — aggregating the **related** table's own column (e.g. counting the related rows) — is exactly the intended fan-out and works normally:

```julia
# ✓ counts each driver's standings rows — the fan-out IS the answer
query = M.Driver.objects
query.values("driverid", "standings" => Count("driver_standings__driverid"))
df = query |> DataFrame
```

**The rule.** When a to-many join is present, `COUNT` / `SUM` / `AVG` raise if they aggregate a column the join row-multiplies (a base/parent column, or *any* column when two or more to-many relations are joined). To resolve it, pick one:

1. **Aggregate the related table's own column** — count/sum the related rows directly, as above.
2. **Pass `distinct=true`** if de-duplicated counting is what you want: `Count("driverid", distinct=true)` renders `COUNT(DISTINCT …)`.
3. **Compute the aggregate in a correlated subquery** so the base rows are never multiplied.

**Not affected.** Ordinary forward (to-one) `ForeignKey` traversals never trip the guard — only *to-many* joins (reverse FK / many-to-many) multiply rows. Aggregating across a normal FK is always fine:

```julia
# ✓ to-one join (Result → Constructor); no fan-out — results per constructor
query = M.Result.objects
query.values("constructorid__name", "n" => Count("resultid"))
query.filter("raceid" => 1)
df = query |> DataFrame
```

**Exemptions.** `Max` and `Min` are immune to row duplication and are never blocked; an aggregate built with `distinct=true` is treated as an explicit opt-in.

!!! note
    The guard is deliberately fail-loud: an aggregate it cannot prove safe (for example one wrapping a multi-column expression) raises rather than risk a silent wrong number. A first-class, explicit correlated-subquery construct for pattern 3 is under design discussion ([#92](https://github.com/PingoLee/PormG.jl/issues/92)).

---

## HAVING Clauses

When you filter on an aggregate alias, PormG automatically promotes the condition to `HAVING`:

```julia
query = M.Result.objects
query.values(
    "raceid__circuitid__name",
    "driverid__forename",
    "constructorid__name",
    "count_grid" => Count("grid")
)
query.filter("statusid__status" => "Finished", "count_grid__@lte" => 3)
df = query |> DataFrame
```

PormG generates:

```sql
SELECT
   "Tb_2"."name" as raceid__circuitid__name,
   "Tb_3"."forename" as driverid__forename,
   "Tb_4"."name" as constructorid__name,
   COUNT("Tb"."grid") as count_grid
FROM "result" as "Tb"
 INNER JOIN "race" AS "Tb_1" ON "Tb"."raceid" = "Tb_1"."raceid"
 INNER JOIN "circuit" AS "Tb_2" ON "Tb_1"."circuitid" = "Tb_2"."circuitid"
 INNER JOIN "driver" AS "Tb_3" ON "Tb"."driverid" = "Tb_3"."driverid"
 INNER JOIN "constructor" AS "Tb_4" ON "Tb"."constructorid" = "Tb_4"."constructorid"
 INNER JOIN "status" AS "Tb_5" ON "Tb"."statusid" = "Tb_5"."statusid"
WHERE "Tb_5"."status" = $1
GROUP BY 1, 2, 3
HAVING COUNT("Tb"."grid") <= 3
```

Notice how PormG separates:
- **`WHERE`** — row-level conditions (`status = 'Finished'`)
- **`HAVING`** — aggregate conditions (`COUNT(grid) <= 3`)

### Aggregate Arithmetic in HAVING

You can filter on computed aggregate expressions too:

```julia
query = M.Result.objects
query.values(
    "constructorid__name",
    "avg_perf" => Sum("points") / Count("resultid")
)
query.filter("avg_perf__@gt" => 5)
```

For more complex expressions, see [Field Expressions](field_expressions.md).

---

## Common Aggregation Patterns

### Wins Per Constructor

```julia
df = M.Result.objects.
    filter("positionorder" => 1).
    values("constructorid__name", "wins" => Count("resultid")).
    order_by("-wins") |> DataFrame
```

### Total Points Per Driver

```julia
df = M.Result.objects.
    values("driverid__surname", "total_pts" => Sum("points")).
    order_by("-total_pts").
    limit(20) |> DataFrame
```

### Best Finish Per Driver at a Specific Circuit

```julia
df = M.Result.objects.
    filter("raceid__circuitid__name" => "Circuit de Monaco").
    values(
        "driverid__surname",
        "best_finish" => Min("positionorder"),
        "races" => Count("resultid")
    ).
    order_by("best_finish") |> DataFrame
```

---

## Next Steps

- **[Functions and Dates](functions_and_dates.md)** — Use `Case`, `Coalesce`, `Concat`, date extraction, and math functions.
- **[Q Objects](q_objects.md)** — Build complex OR/AND logic beyond what `filter()` pairs support.
- **[Field Expressions](field_expressions.md)** — Field-to-field comparisons with `F()` and aggregate ratios.