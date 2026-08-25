# Subqueries and CTEs

This page covers nested queries with `IN (SELECT ...)`, scalar correlated subqueries projected as columns (`Subquery` / `Exists`), Common Table Expressions (`WITH`), CTE join types, deep join paths, and mixing CTEs with custom joins.

---

## Subqueries in Filters

Pass a query object to `@in` to create a server-side `IN (SELECT ...)` predicate:

```julia
# Build the subquery
subquery = M.Status.objects
subquery.filter("status" => "Engine")
subquery.values("statusid")

# Use it in the main query
query = M.Result.objects
query.filter("statusid__@in" => subquery)
query.values("resultid", "statusid", "statusid__status", "grid", "driverid")
df = query |> DataFrame
```

This generates:

```sql
SELECT ... FROM "result" as "Tb" ...
WHERE "Tb"."statusid" IN (SELECT "Tb"."statusid" FROM "status" as "Tb" WHERE "Tb"."status" = $1)
```

!!! tip
    Subqueries run entirely on the server — PormG does not materialize the subquery in Julia. This is much more efficient for large datasets.

---

## Subquery Column Constraint

An `@in` subquery **must project exactly one column**. PormG validates this before generating SQL and throws a `FilterError` if the subquery selects more than one field.

```julia
# Wrong — two columns will throw FilterError
bad_sub = M.Status.objects.values("statusid", "status")
query.filter("statusid__@in" => bad_sub)
# ERROR: 'statusid__@in' requires a subquery that returns exactly one column
#        (currently selects 2 columns: statusid, status)
#        call .values("field_name") on the subquery to narrow it to one column.

# Correct — exactly one column
good_sub = M.Status.objects.filter("status" => "Engine").values("statusid")
query.filter("statusid__@in" => good_sub)
```

### SQL Function Projections

You can use a SQL function alias as the single column. PormG counts a `"alias" => Function(...)` pair as one column, so the validator accepts it:

```julia
using PormG.Functions: Max

# Subquery that returns the single highest driver id
top_id_sub = M.Driver.objects.values("top_id" => Max("driverid"))

# Returns only the driver whose id equals the maximum id
query = M.Driver.objects.filter("driverid__@in" => top_id_sub)
df = query |> DataFrame
```

Generated SQL:
```sql
SELECT * FROM "drivers" AS "Tb"
WHERE "Tb"."driverid" IN (
    SELECT MAX("R1"."driverid") AS top_id FROM "drivers" AS "R1"
)
```

!!! note
    SQL function projections (like `Max`, `Min`, `Count`) compile to inline SQL with no bind parameters. `result[:parameters]` will be empty for such subqueries.

---

## Subqueries with Additional Filters

Combine subquery `@in` with other filter conditions:

```julia
subquery = M.Status.objects
subquery.filter("status" => "Engine")
subquery.values("statusid")

query = M.Result.objects
query.filter("statusid__@in" => subquery, "driverid__@lte" => 7)
query.values(
    "resultid",
    "statusid",
    "statusid__status",
    "grid",
    "driverid",
    "raceid__date__@quarter"
)
query.order_by("raceid__date__quarter")
df = query |> DataFrame
```

---

## Scalar correlated subqueries

A **scalar correlated subquery** computes one value per outer row — "each driver's standings count", "each driver's latest position" — inside its own sub-`SELECT`, correlated to the outer query with `OuterRef`. Project it as a column with `"alias" => Subquery(inner)` inside `values()`:

```julia
# Inner query: correlated via OuterRef, projects exactly ONE column
standings = M.Driver_standings.objects
standings.filter("driverid" => OuterRef("driverid"))
standings.values("t" => Count("driverstandingsid"))

query = M.Driver.objects
query.values(
    "surname",
    "total_standings" => Subquery(standings),   # scalar subquery column
    "has_standings"   => Exists(standings),     # boolean subquery column
)
df = query |> DataFrame
```

Generated SQL (PostgreSQL; SQLite renders `?` placeholders):

```sql
SELECT
    "Tb"."surname" as "surname",
  (SELECT
    COUNT("R1"."driverstandingsid") as "t"
FROM "driver_standings" as "R1"
WHERE "R1"."driverid" = "Tb"."driverid"
) as "total_standings",
  EXISTS (SELECT 1
FROM "driver_standings" as "R2"
WHERE "R2"."driverid" = "Tb"."driverid"
LIMIT 1) as "has_standings"
FROM "driver" as "Tb"
```

`OuterRef("driverid")` binds the inner query's filter to the **outer** query's column — that is the correlation. `Exists(...)` (already familiar from [filters](filters_and_aggregates.md)) can likewise be projected as a per-row boolean column (SQLite returns `0`/`1` integers, PostgreSQL booleans).

### Why: the fan-out-safe aggregate

This is the supported fix the [aggregate fan-out guard](filters_and_aggregates.md#Aggregating-Across-To-Many-Relations-(Fan-Out-Guard)) points to. A to-many join repeats each outer row once per related row, so a naive join aggregate over a base column is silently multiplied — PormG raises instead. Moving the aggregate into a correlated `Subquery` dissolves the fan-out entirely: the aggregate runs in its own scalar subquery and the outer rows are never row-multiplied.

It also **composes** — multiple independent aggregates in one query, something a join-based rewrite cannot do without multiplying the counts against each other:

```julia
standings = M.Driver_standings.objects
standings.filter("driverid" => OuterRef("driverid"))
standings.values("t" => Count("driverstandingsid"))

results = M.Result.objects
results.filter("driverid" => OuterRef("driverid"))
results.values("t" => Count("resultid"))

query = M.Driver.objects
query.values(
    "surname",
    "n_standings" => Subquery(standings),   # each count stays exact —
    "n_results"   => Subquery(results),     # no interaction between the two relations
)
df = query |> DataFrame
```

### Latest-value scalars (non-aggregate)

The inner projection does not have to be an aggregate — any one-column query works. Use the inner query's own `order_by` + `limit(1)` for the "latest related value per row" pattern:

```julia
# Each driver's most recent standings position
latest = M.Driver_standings.objects
latest.filter("driverid" => OuterRef("driverid"))
latest.values("position")
latest.order_by("-driverstandingsid")
latest.limit(1)

query = M.Driver.objects
query.values("surname", "latest_position" => Subquery(latest))
df = query |> DataFrame
```

For an outer row with **no** related rows, an aggregate scalar returns its natural value (`Count` → `0`), while a plain-column scalar is SQL `NULL` → `missing` in the DataFrame.

### Rules and limitations

- **Exactly one column.** The inner query must project exactly one column via `.values(...)` (the inner alias is cosmetic). Zero or several columns raise a `QueryBuildError` at build time. The same one-column rule applies to `@in` subqueries, where it surfaces as a `FilterError` — the type names which argument you got wrong (a projection here, a filter there). Catch `PormGError` to handle both.
- **The alias is mandatory.** Always project as a pair: `"alias" => Subquery(...)`. A bare `Subquery(...)` inside `values()` raises.
- **At most one row.** The database requires a scalar subquery to return ≤ 1 row ("more than one row returned by a subquery used as an expression" at execution otherwise). An aggregate always satisfies this; for a plain column add `order_by` + `limit(1)` — PormG emits a build-time warning for the non-aggregate/no-limit case but does not block it.
- **One level of correlation.** `OuterRef` resolves against the immediately enclosing query only, so a `Subquery`/`Exists` projected *inside another subquery* raises rather than risk silently correlating to the wrong level. Multi-level correlation is a possible future extension.
- **Correlate on base columns.** `OuterRef("driverid")` against a plain outer column is the canonical, supported case. A joined-path `OuterRef` (e.g. `OuterRef("constructorid__name")`) adds a join to the outer query and is not part of the validated #92 surface.
- **Outer `GROUP BY` — backend divergence, be careful.** Combining a correlated `Subquery` with an outer aggregate/`GROUP BY` is only well-defined when the correlated column is itself grouped (e.g. group by `driverid` and correlate on `OuterRef("driverid")` — this works on both backends). If the correlated column is **not** grouped, PostgreSQL fails loud (`subquery uses ungrouped column … from outer query`), but **SQLite silently evaluates the subquery against an arbitrary row of each group** — a plausible-looking wrong number. PormG emits a build-time warning whenever a projected `Subquery`/`Exists` coexists with a grouped projection; the warning is a false positive when the correlated column is in the group. A precise fail-loud guard is tracked in [#194](https://github.com/PingoLee/PormG.jl/issues/194).
- **Untested SQL edges.** A CTE *inside* a subquery is not blocked, but not validated by the test suite either.

### CTE-aggregate vs scalar `Subquery`

Both are explicit, fan-out-safe ways to attach related aggregates. Pick by shape:

| | CTE aggregate + `join_field` | Scalar `Subquery` column |
|---|---|---|
| Result shape | one pre-aggregated table, joined once | one scalar per outer row |
| Multiple independent aggregates | one CTE each + join-key management per CTE | just add another `values()` pair |
| Reusing the aggregated set (filter/order on it) | ✓ natural (`HAVING`-style via the CTE) | ✗ recompute per use |
| Join-key bookkeeping | explicit `join_field` | none — correlation via `OuterRef` |
| Latest-value (non-aggregate) per row | awkward (needs window functions) | ✓ `order_by` + `limit(1)` |

**Performance.** A correlated subquery is evaluated once **per outer row** (SQLite in particular never decorrelates it). For a filtered outer set — one driver, a season's entrants — it is ideal. For a full-table scan projecting several aggregates over large related tables, the CTE aggregate (computed once, joined once) usually wins; measure before choosing at scale.

### Positioning: explicit, not magic

Django offers two paths for related-set aggregates: the implicit `annotate(Count("relation"))` — which silently row-multiplies when two annotations are combined (the documented "Cartesian product trap") — and the explicit `Subquery()` + `OuterRef()` its own docs recommend as the fix. PormG ships **only** the explicit path (with the same recognizable names) and goes one step further: the [#74 guard](filters_and_aggregates.md#Aggregating-Across-To-Many-Relations-(Fan-Out-Guard)) turns the silent-fan-out form into a hard error. This is the same explicit-subquery camp as jOOQ (`DSL.field(select …)`) and SQLAlchemy (`.scalar_subquery()`), with correlation always spelled out via `OuterRef` — never inferred.

---

## Common Table Expressions (CTEs)

CTEs (SQL `WITH` clauses) are useful when a query becomes easier to reason about in stages. PormG supports CTEs through the `.with()` method.

### Why Use CTEs?

- **Readability** — Break complex queries into named stages.
- **Aggregation** — Pre-compute aggregates and join them back to the main query.
- **Reuse** — Reference the same subquery multiple times without duplication.

---

## Basic CTE with JOIN

Define a subquery, give it a name, and join it to the main query via `join_field`:

```julia
using PormG.Functions: Count

# Define the CTE: count results per driver (where status = 1)
driver_stats = M.Result.objects
driver_stats.filter("statusid" => 1)
driver_stats.values("driverid", "total_results" => Count("resultid"))

# Main query: join the CTE to Result via driverid
main_query = M.Result.objects
main_query.with("stats" => driver_stats, join_field="driverid" => "driverid")

main_query.filter("resultid__@lte" => 100)
main_query.values("resultid", "driverid", "stats__total_results")
df = main_query |> DataFrame
```

The `.with()` method:
1. Emits the subquery as a `WITH stats AS (SELECT ...)` clause.
2. Creates a `LEFT JOIN stats ON result.driverid = stats.driverid`.
3. Makes `stats__total_results` available for selection via `values()`.

!!! note "A CTE's columns are its projection aliases"
    A CTE is a **derived table**: the only columns it exposes are the names its `values()` call
    produces. That matters when a projected field declares
    [`db_column`](../fields.md#Database-Column-Mapping) — the physical name is consumed *inside*
    the `WITH` body, so the outer query names the **field**, never the column.

    Suppose `Race` declared `name = Models.CharField(db_column = "race_name")`:

    ```julia
    # The CTE body renders `"race_name" AS "name"` — `name` is the column it exposes.
    races_91 = M.Race.objects.filter("year" => 1991).values("raceid", "name")

    q = M.Result.objects
    q.with("r91" => races_91, join_field="raceid" => "raceid")
    q.filter("r91__name" => "Brazilian Grand Prix")   # → the CTE's "name" column, not "race_name"
    q.values("resultid", "race" => "r91__name")
    ```

    Give the projection a custom alias (`values("rname" => "name")`) and *that* becomes the outer
    name (`r91__rname`). The `join_field` follows the same split: its **second** element names a
    CTE column and is a field name, while the first names a real column on the main table and does
    resolve through `db_column`.

---

## Correlating a CTE with `F()` (no `join_field`)

When you omit `join_field`, the CTE is emitted but not keyed to the main table. Referencing one
of its columns with `F("<cte>__col")` then **`CROSS JOIN`s** the CTE, and the `F()` filter you
write supplies the correlation verbatim in `WHERE` — the natural, Django-flavored way to express
a correlated CTE:

```julia
# Races from the 1991 season
races_91 = M.Race.objects.filter("year" => 1991).values("raceid")

# Winners of those races — correlate Result.raceid with the CTE's raceid via F()
q = M.Result.objects
q.with("r91" => races_91)                       # no join_field
q.filter("raceid" => F("r91__raceid"),          # ← the correlation
         "positionorder" => 1)
q.values("resultid", "raceid")
df = q |> DataFrame
```

renders (SQLite shown; PostgreSQL uses `$N` placeholders):

```sql
WITH "r91" AS (SELECT "raceid" FROM "race" WHERE "year" = ?)
SELECT "R1"."resultid", "R1"."raceid"
FROM "result" AS "R1"
CROSS JOIN "r91" AS "R1_1"
WHERE "R1"."raceid" = "R1_1"."raceid" AND "R1"."positionorder" = ?
```

Notes:
- **`CROSS JOIN + WHERE` is inner by nature** — only rows the correlation matches are returned.
  To keep unmatched main-table rows (a *nullable* left join against a CTE), use an explicit
  `join_field` (+ `join_type="LEFT"`) as shown above instead.
- The correlation is ordinary `F()`, so multiple correlations and inequality/range predicates
  work too, e.g. `filter("date__@gte" => F("r91__start"), "date__@lte" => F("r91__end"))`.
- **Cartesian-product guard.** Referencing a CTE column with *no* constraining filter is a
  Cartesian product; PormG emits a `@warn` naming the CTE. Add a correlating `filter(...)`, or
  pass `join_field`.
- **Give a CTE a name that collides with nothing.** Two collisions bite. A **model field**: join
  resolution consults the CTE registry *before* the model's own fields, so `.with("raceid" => …)` on
  a model that *has* a `raceid` foreign key makes `raceid__*` mean the CTE, and the field's real join
  is shadowed silently. A **join key**: a `cjoin` path, a `cjoin_on` alias, or an `on()` path spelled
  the same way hands that join's predicates to the CTE. When an `ON` predicate ends up on an unkeyed
  (CROSS-joined) CTE either way, PormG refuses the query rather than dropping the predicate and
  matching every row (#424) — a `CROSS JOIN` has no `ON` clause to carry one. Rename the CTE, or give
  it a `join_field` so it emits a real `ON` clause.

---

## CTE with Multiple Aggregated Fields

```julia
using PormG.Functions: Count, Sum

# CTE with multiple aggregates
stats = M.Result.objects
stats.filter("raceid__@lte" => 100)
stats.values(
    "driverid",
    "total_results"         => Count("resultid"),
    "total_grid_positions"  => Sum("grid")
)

# Join CTE to Driver model
query = M.Driver.objects
query.with("driver_stats" => stats, join_field="driverid" => "driverid")

query.filter("driverid__@lte" => 50)
query.values(
    "driverid",
    "forename",
    "surname",
    "driver_stats__total_results",
    "driver_stats__total_grid_positions"
)
df = query |> DataFrame
```

---

## Multiple CTEs

Attach multiple CTEs to the same query:

```julia
# CTE 1: Recent races
recent_races = M.Race.objects
recent_races.filter("year__@gte" => 2020)
recent_races.values("raceid", "name", "year")

# CTE 2: Top drivers
top_drivers = M.Driver.objects
top_drivers.filter("driverid__@lte" => 100)
top_drivers.values("driverid", "forename", "surname")

# Main query with both CTEs
query = M.Result.objects
query.with("recent" => recent_races, join_field="raceid" => "raceid")
query.with("top_d" => top_drivers, join_field="driverid" => "driverid")

query.values("resultid", "recent__name", "top_d__forename", "points")
query.filter("recent__name__@isnull" => false, "top_d__forename__@isnull" => false)
df = query |> DataFrame
```

Each `.with()` call adds another `WITH` clause and `JOIN` to the final SQL.

---

## Choosing Join Types for CTEs

By default, CTEs use `LEFT JOIN`. Use `join_type="INNER"` to filter out non-matching rows:

```julia
using PormG.Functions: Sum

high_scorers = M.Result.objects
high_scorers.filter("points__@gte" => 10)
high_scorers.values("driverid", "max_points" => Sum("points"))

query = M.Driver.objects
query.with(
    "high_scorers" => high_scorers,
    join_field="driverid" => "driverid",
    join_type="INNER"   # Only include drivers who have high scores
)

query.values("driverid", "forename", "max_points" => "high_scorers__max_points")
query.filter("driverid__@lte" => 100)
df = query |> DataFrame
```

### Available CTE Join Types

| Join Type | Behavior |
| :--- | :--- |
| `"LEFT"` | Default. All main-table rows are kept; unmatched CTE columns are `missing`. |
| `"INNER"` | Only rows that match the CTE are returned. |

The SQL builder can also render `"RIGHT"` and `"FULL"` join keywords, but these are not the primary documented workflow.

---

## Deep Join Paths in CTE Links

The `join_field` can contain a multi-level path with `__`. PormG builds the intermediate joins needed to connect the main query to the CTE:

```julia
using PormG.Functions: Count

# CTE: count drivers per nationality
nat_stats = M.Driver.objects
nat_stats.values("nationality", "driver_count" => Count("driverid"))

# Main query: join CTE via a deep path (Result → Driver → nationality)
query = M.Result.objects
query.with("stats" => nat_stats, join_field="driverid__nationality" => "nationality")

query.filter("raceid__year" => 2023)
query.values("raceid__name", "driverid__surname", "stats__driver_count")
df = query |> DataFrame
```

PormG automatically:
1. Joins `Result → Driver` (via the `driverid` ForeignKey).
2. Links `Driver.nationality` to `stats.nationality` (the CTE join column).

---

## CTE Without a JOIN

If you call `.with("name" => subq)` without providing `join_field`, PormG still emits the CTE in the `WITH` clause but does **not** join it to the main table:

```julia
subq = M.Status.objects.filter("status" => "Engine").values("statusid")

query = M.Result.objects
query.with("engine_statuses" => subq)   # Declared but not joined
```

This is valid SQL, but the CTE data won't be accessible through `values()`. The main use case is combining a CTE declaration with a subquery filter:

```julia
query = M.Result.objects
query.with("sub" => subq)
query.filter("statusid__@in" => subq)   # Reuse the subquery in a filter
```

!!! tip
    Always provide `join_field` when you want CTE data accessible via `.values()`. Without it, the CTE is emitted but produces no additional projectable columns.

---

## Mixing CTEs and Custom Joins

PormG allows CTEs and custom joins (`.cjoin()`) in the same query. Parameter ordering is deterministic across these combinations:

```julia
# 1. Define the CTE
top_const = M.Constructor.objects.
    filter("constructorid__@lte" => 5).
    values("constructorid", "name")

# 2. Build the chain with CTE, cjoin, filters, and values
df = M.Result.objects.
    with("tc" => top_const, join_field="constructorid" => "constructorid").
    cjoin("driverid" => "Driver", filters=["nationality" => "German"]).
    filter("positionorder" => 1).
    values("resultid", "tc__name", "driverid__surname") |> DataFrame
```

### Chaining Multiple Custom Joins

```julia
df = M.Result.objects.
    cjoin("driverid" => "Driver", filters=["nationality" => "Brazilian", "forename" => "Ayrton"]).
    cjoin("raceid" => "Race", filters=["year" => 1991]).
    filter("positionorder" => 1).
    values("resultid", "driverid__surname", "raceid__name") |> DataFrame
```

See [Custom Joins](custom_joins.md) for the full `.cjoin()` and `.on()` documentation.

---

## Summary

| Feature | Syntax | Use Case |
| :--- | :--- | :--- |
| Subquery `IN` | `"field__@in" => subquery` | Filter by a set computed on the server. |
| Scalar subquery column | `values("n" => Subquery(inner))` | Fan-out-safe per-row aggregate / latest value. |
| Boolean subquery column | `values("has_x" => Exists(inner))` | Per-row existence flag. |
| CTE with JOIN | `.with("name" => subq, join_field=...)` | Pre-aggregate data and join it. |
| CTE without JOIN | `.with("name" => subq)` | Declare for use in filters only. |
| CTE INNER JOIN | `join_type="INNER"` | Only keep matching rows. |
| Deep join path | `join_field="a__b" => "field"` | Link CTE via multi-level relationships. |
| CTE + cjoin | `.with(...)` + `.cjoin(...)` | Combine all join strategies. |

---

## Next Steps

- **[Custom Joins](custom_joins.md)** — Full `cjoin()` and `on()` documentation.
- **[Field Expressions](field_expressions.md)** — Use `F()` for arithmetic and computed columns.
- **[Q Objects](q_objects.md)** — Complex boolean logic in filters.