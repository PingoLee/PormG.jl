# PormG Usage — Reading Data

Supporting file for [`SKILL.md`](SKILL.md). Read it when **writing a query**: filters, lookups,
joins, `Q`/`F`, aggregates, the SQL function library, dates. Subqueries, CTEs and window functions
are in [`advanced.md`](advanced.md). Full detail:
[Reading](https://pingolee.github.io/PormG.jl/stable/read/),
[API reference](https://pingolee.github.io/PormG.jl/stable/api/).

## The query handler

`M.Model.objects` returns a fresh, mutable handler. Chainable methods modify it and return it, so
both spellings below build the same query:

```julia
rows = M.Driver.objects.
    filter("nationality" => "Brazilian").
    order_by("surname").
    limit(10).
    list()

q = M.Driver.objects
q.filter("nationality" => "Brazilian")
q.order_by("surname")
q.limit(10)
rows = q.list()
```

Repeated `filter()` calls **accumulate** (AND). `values()` and `order_by()` **replace** what was set
before. `q.copy()` branches a handler without disturbing the original.

`object(M.Driver)` is the function form of `M.Driver.objects`. In the REPL, `?object` prints the
whole fluent-API reference; `?query.filter` cannot, because the methods are synthesized.

### Chainable methods

| Method | Effect |
| :--- | :--- |
| `.filter(pairs..., Q(...), F(...) == F(...))` | `WHERE`, ANDed; accumulates |
| `.values("field", "alias" => expr, ...)` | Projection. `"*"` = every column of the main table |
| `.order_by("field", "-field")` | Sort; `-` = descending |
| `.limit(n)` / `.offset(n)` / `.page(limit, offset)` | Paging (positional `Integer`s only) |
| `.distinct()` | `SELECT DISTINCT` |
| `.db("key")` | Run on another configured connection |
| `.on("path", pairs...; join_type)` | Extra predicates on an existing join's `ON` |
| `.cjoin(...)` / `.cjoin_on(...)` / `.with(...)` | Custom joins and CTEs — see [`advanced.md`](advanced.md) |
| `.select_for_update(; nowait, skip_locked)` | Row lock — see [`writing.md`](writing.md) |
| `.copy()` | Deep copy of the handler |

### Terminal methods

| Method | Returns |
| :--- | :--- |
| `.list()` | `Vector{PormGRow}` — `row.field`, `row[:field]`, `row.pk`, `row.save()`, `row.delete()` |
| `.list(:dict)` / `.list(:json)` | `Vector{Dict{Symbol,Any}}` / a JSON `String` |
| `q \|> DataFrame` | `DataFrame` (typed temporal columns) — prefer it for analytics |
| `.first()` / `.last()` | `PormGRow` or `nothing` |
| `.earliest("f")` / `.latest("f")` | `PormGRow`; raise `DoesNotExist` when empty |
| `.get(pairs...)` | Exactly one `PormGRow`, or `DoesNotExist` / `MultipleObjectsReturned` |
| `.count()` / `.exists()` | `Int` / `Bool` |
| `.aggregate("alias" => Agg(...), ...)` | One `NamedTuple` of scalars, no `GROUP BY` |

A row holds only what was projected, and **PormG never lazy-loads a relation**:

- A projected `ForeignKey` reads as the raw key: `row.driverid` is an `Int`, not a driver.
- A `ForeignKey` the row did not project (`values("points")`, then `row.driverid`) raises
  `LazyTraversalError`.
- For the related columns, project the path and read it back under the same name:
  `values("driverid__surname")` → `row.driverid__surname`.

## Lookups: `__` traverses, `__@` operates

```julia
M.Result.objects.filter("driverid__nationality" => "British")          # join through the FK
M.Result.objects.filter("raceid__circuitid__country" => "Monaco")      # two hops
M.Result.objects.
    values("driverid__forename", "driverid__surname", "raceid__year", "points").
    order_by("-points")
```

| Operator | SQL | Example |
| :--- | :--- | :--- |
| *(none)* | `=` | `"nationality" => "British"` |
| `__@gt` `__@gte` `__@lt` `__@lte` | `>` `>=` `<` `<=` | `"points__@gte" => 10` |
| `__@ne` | `<>` | `"positiontext__@ne" => "R"` |
| `__@in` / `__@nin` | `IN` / `NOT IN` | `"nationality__@in" => ["British", "French"]` |
| `__@range` | `BETWEEN` | `"driverid__@range" => [1, 50]` |
| `__@isnull` | `IS NULL` / `IS NOT NULL` | `"number__@isnull" => true` |
| `__@contains` / `__@icontains` | `LIKE` / case-insensitive | `"name__@icontains" => "monaco"` |
| `__@startswith` `__@endswith` (+ `i` forms) | prefix / suffix match | `"surname__@istartswith" => "ver"` |
| `__@ncontains`, `__@nistartswith`, … | negated twins of every pattern lookup | |

`__@in` also accepts a one-column query instead of a vector. That is a subquery; see
[`advanced.md`](advanced.md). PostgreSQL-only lookups — `@iunaccent_contains`/`@iunaccent_exact` and
the JSONB `@jcontains`/`@has_key` family — raise `BackendCapabilityError` on SQLite.

### Date transforms

They work in `values()`, `filter()` and `order_by()`:

| Transform | Gives | Example |
| :--- | :--- | :--- |
| `__@year` `__@month` `__@day` | number | `"dob__@year" => 1960` |
| `__@quarter` / `__@quadrimester` | 1–4 / 1–3 | `"date__@quarter" => 1` |
| `__@date` | date part of a datetime | `"start_at__@date" => Date(2009, 3, 29)` |
| `__@yyyy_mm` / `__@yyyy_q` / `__@yyyy_quad` | year-qualified label | `"date__@yyyy_mm" => "1991-10"` |

Use `@quarter` for "Q1 of every year", and `@yyyy_q` as a grouping key when years must not merge.

## `Q` / `Qor`: boolean logic

```julia
M.Driver.objects.filter(Qor("nationality" => "British", "nationality" => "Brazilian"))

M.Result.objects.filter(
    Q("points__@gt" => 10),
    Qor("driverid__nationality" => "British", "driverid__nationality" => "Brazilian"),
)
```

`Q(...)` ANDs its pairs, `Qor(...)` ORs them, and they nest.

## `F`: database-side expressions

```julia
M.Result.objects.filter(F("grid") == F("positionorder"))              # field vs field
M.Result.objects.values("driverid__surname", "bonus" => F("points") * 0.1)
M.Result.objects.filter("resultid" => 1).update("points" => F("points") + 1)   # atomic
```

For a comparison against a constant, use the operator suffix (`"points__@gt" => 20`), not
`F("points") > 20`.

**Date arithmetic** takes a `Dates` period, or `Interval(...)` for a time-of-day duration string:

```julia
using Dates
M.Race.objects.values("name", "a_week_later" => F("date") + Day(7))
M.Race.objects.values("name", "plus_90m" => F("start_at") + Interval("01:30:00"))
```

`Interval(Month(1))` is identical to `Month(1)`. Its string form is the escape hatch for time-based
intervals. (If you also use `Intervals.jl`, write `PormG.QueryBuilder.Interval`.)

## Aggregates

`Count`, `Sum`, `Avg`, `Max`, `Min` from `PormG.Functions`. In `values()`, the **non-aggregate
columns become the `GROUP BY`**:

```julia
using PormG.Functions: Count, Sum, Max, Min

# Wins per constructor
M.Result.objects.
    filter("positionorder" => 1).
    values("constructorid__name", "wins" => Count("resultid")).
    order_by("-wins")

# A filter on an aggregate alias becomes HAVING
M.Result.objects.
    filter("positionorder" => 1, "wins__@gt" => 50).
    values("constructorid__name", "wins" => Count("resultid"))
```

When **every** column is an aggregate there is no `GROUP BY`, so the query returns one summary row.
`.aggregate(...)` returns the same thing as a `NamedTuple`:

```julia
M.Result.objects.filter("constructorid" => 131).
    aggregate("best" => Max("points"), "n" => Count("resultid"))   # (best = 50.0, n = …)
```

**Arithmetic goes on the aggregate, not inside it.** Constants are bound as parameters:

- `Sum("points") - 10` → `SUM(points) - $1` ✅
- `Max("points") - Min("points")` ✅
- `Max(F("points"))` → unnecessary; write `Max("points")`
- `F("points") - 5` → a *row-level* expression, which means something different

**Aggregating across a to-many join** (a reverse FK like `"driver_standings__…"`, or a
many-to-many) repeats the base rows. `COUNT`/`SUM`/`AVG` over a column those rows multiply therefore
raises `QueryBuildError` rather than returning an inflated number. Counting the related table's own
column is fine: `Count("driver_standings__driverid")`. Otherwise pass `distinct = true`, or use one
correlated `Subquery` per relation — see [`advanced.md`](advanced.md).

## The SQL function library

Everything below lives in `PormG.Functions`. Every function takes a field path (string), an `F(...)`,
another function, or a literal wrapped in `Value(...)`, and works in `values()`, `filter()`,
`order_by()` and `update()`.

```julia
using PormG.Functions: Concat, Value, Upper, Lower, Length, Replace, Trim

M.Driver.objects.
    filter("nationality" => "Brazilian").
    values("full_name"  => Concat("forename", Value(" "), "surname"),
           "shout"      => Upper("surname"),
           "len"        => Length("surname"),
           "ref"        => Replace("driverref", Value("_"), Value("-")))
```

| Group | Functions |
| :--- | :--- |
| String | `Concat(a, b, …)`, `Upper`, `Lower`, `Length`, `Replace(col, find, repl)`, `Trim`, `LTrim`, `RTrim` |
| Math | `Abs`, `Round(col, digits)`, `Floor`, `Ceil`, `Sqrt`, `Power(x, y)`, `Exp`, `Ln`, `Mod(a, b)` |
| Null / compare | `Coalesce(a, b, …)`, `NullIf(a, b)`, `Greatest(a, b, …)`, `Least(a, b, …)` |
| Type / format | `Cast(col, "INTEGER")`, `Extract(col, "YEAR")`, `ToChar(col, "YYYY-MM")`, `Value(x)` |
| Conditional | `Case([When(...), …]; default)`, `When(cond; then, otherwise)` |
| Aggregate | `Count`, `Sum`, `Avg`, `Max`, `Min` |
| Window | `WindowOver`, `WindowSpec`, `Rank`, `DenseRank`, `RowNumber`, `Lag`, `Lead`, `FirstValue`, `LastValue`, `NthValue` — see [`advanced.md`](advanced.md) |

```julia
using PormG.Functions: Coalesce, Round, Greatest, Case, When, ToChar

M.Result.objects.
    filter("raceid" => 1).
    values("driverid__surname",
           "number"    => Coalesce("number", Value(0)),
           "pts"       => Round("points", 1),
           "floor0"    => Greatest("points", Value(0)),
           "podium"    => When("positionorder__@lte" => 3, then = "yes", otherwise = "no"),
           "race_date" => ToChar("raceid__date", "YYYY-MM-DD"))
```

- `When(...; otherwise = …)` is a complete two-way `CASE` on its own. Use `Case([When(...), When(...)];
  default = …)` for more branches.
- `ToChar` accepts any PostgreSQL format on PostgreSQL. On SQLite only a portable subset works, and
  anything else raises `BackendCapabilityError`.
- **Portable `Extract` parts** are `"YEAR"`, `"MONTH"`, `"DAY"`, `"HOUR"`, `"MINUTE"`, `"SECOND"`,
  `"DOW"` and `"DOY"`, in any case. PostgreSQL accepts any `EXTRACT` field, but SQLite raises
  `BackendCapabilityError` for anything outside those eight. For plain date parts the
  `__@year`-style transforms are simpler still.

Full reference: [Functions and Dates](https://pingolee.github.io/PormG.jl/stable/read/functions_and_dates/).

## Aliases

`values("alias" => ...)` aliases are always double-quoted, so their case and Unicode letters survive
into DataFrame columns. An alias must start with a letter or `_`. One with spaces or punctuation
raises `InvalidValueError` when the query is **rendered** (`list()`, `inspect_query`), not at
`values()` time.
