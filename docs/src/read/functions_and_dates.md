# Functions and Dates

This page covers date extraction, SQL functions, mathematical transforms, and conditional expressions (`Case`/`When`).

---

## Date Functions Overview

PormG provides date-related modifiers through the `__@` suffix system. These work in both `values()` (to transform the selected value) and `filter()` (to create predicates on date components).

### Available Date Transforms

| Transform | Description | Example in `values()` | Example in `filter()` |
| :--- | :--- | :--- | :--- |
| `@year` | Extract year | `"date__@year"` | `"date__@year" => 2023` |
| `@month` | Extract month (1-12) | `"date__@month"` | `"date__@month" => 6` |
| `@day` | Extract day (1-31) | `"date__@day"` | `"date__@day" => 15` |
| `@quarter` | Extract quarter (1-4) | `"date__@quarter"` | `"date__@quarter" => 1` |
| `@quadrimester` | Extract quadrimester (1-3) | `"date__@quadrimester"` | `"date__@quadrimester" => 2` |
| `@date` | Extract date from datetime | `"created_at__@date"` | `"created_at__@date" => Date(2023,1,1)` |
| `@yyyy_mm` | Year-month as string | `"date__@yyyy_mm"` | `"date__@yyyy_mm" => "1991-10"` |

---

## Date Component Selection

Select date parts as separate columns:

```julia
query = M.Race.objects
query.values("raceid", "date", "date__@year", "date__@month", "date__@day")
df = query |> DataFrame

#  Row │ raceid  date        date__year  date__month  date__day
# ─────┼────────────────────────────────────────────────────────
#    1 │      1  1991-03-10        1991            3         10
#    2 │      2  1991-03-24        1991            3         24
```

---

## Date Component Filtering

Filter on extracted date components:

```julia
# All races in 2023
query = M.Race.objects.filter("date__@year" => 2023)

# Races in the second half of the year
query = M.Race.objects.filter("date__@month__@gte" => 6)

# Combine: Q1 races in 1991
query = M.Race.objects.filter("date__@year" => 1991, "date__@quarter" => 1)
```

### Grouped Date Query

```julia
query = M.Race.objects
query.filter("date__@year" => 1991)
query.values(
    "date__@year",
    "date__@month",
    "date__@day",
    "rows" => Count("raceid")
)
query.order_by("date__day")
df = query |> DataFrame
```

Generated SQL (PostgreSQL):
```sql
SELECT EXTRACT(YEAR  FROM "race"."date") AS date__year,
       EXTRACT(MONTH FROM "race"."date") AS date__month,
       EXTRACT(DAY   FROM "race"."date") AS date__day,
       COUNT("race"."raceid")            AS rows
FROM "race"
WHERE EXTRACT(YEAR FROM "race"."date") = $1
GROUP BY 1, 2, 3
ORDER BY "date__day" ASC
```

Output:
```
16×4 DataFrame
 Row │ date__year  date__month  date__day  rows
     │ Decimal?    Decimal?     Decimal?   Int64?
─────┼────────────────────────────────────────────
   1 │       1991            6          2       1
   2 │       1991           11          3       1
   3 │       1991            7          7       1
  ⋮  │     ⋮            ⋮           ⋮        ⋮
  14 │       1991            4         28       1
  15 │       1991            7         28       1
  16 │       1991            9         29       1
                                   10 rows omitted
```

---

## Date Format Filtering

Match dates by formatted strings or Julia `Date` objects:

```julia
using Dates

# Match by year-month string
query = M.Race.objects.filter("date__@yyyy_mm" => "1991-10")

# Match by date string
query = M.Race.objects.filter("date__@date" => "1991-10-20")

# Match by Julia Date object
query = M.Race.objects.filter("date__@date" => Date(1991, 10, 20))
```

### Index-friendly ranges on a `DateField`

Comparison suffixes work on these buckets too, and on a plain `DateField` column PormG rewrites
them into a range **directly on the column** rather than comparing a formatted string:

```julia
# Every race from October 1991 onwards
query = M.Race.objects.filter("date__@yyyy_mm__@gte" => "1991-10")
# renders:  "Tb"."date" >= $1        with $1 = "1991-10-01"

# Every race up to and including December 1991
query = M.Race.objects.filter("date__@yyyy_mm__@lte" => "1991-12")
# renders:  "Tb"."date" < $1         with $1 = "1992-01-01"
```

The same applies to a date column reached **through a join**, at any depth and through any relation
— a foreign key, a reverse relation, or a many-to-many:

```julia
# Results from races in October 1991 — the range lands on the joined table's column
query = M.Result.objects.filter("raceid__date__@yyyy_mm" => "1991-10")
# renders:  ("Tb_1"."date" >= $1 AND "Tb_1"."date" < $2)

# Drivers born from 1960 onwards
query = M.Result.objects.filter("driverid__dob__@year__@gte" => 1960)
# renders:  "Tb_1"."dob" >= $1       with $1 = "1960-01-01"
```

(The `Tb_N` alias is assigned per query in join order — a query joining both paths above would
reach `dob` through `"Tb_2"`.)

Because the column is not wrapped in a function call, an index on it applies and the query
planner can estimate how many rows the filter selects — on a large table this is the difference
between an index range scan and a full scan with a poisoned join plan.

Note that `@lte` includes the *whole* final bucket (it becomes `<` the following period's first
day), while `@lt` excludes the named bucket entirely. The same holds for `@year`.

`@year` requires a whole year in the range 1–9999 — an `Integer`, a whole-valued number, or a
numeric string. A value no single date can express (a fraction, a year outside that range, or a
`Bool`) raises a `FilterError` rather than silently comparing against an unusable bound.

!!! note "Scope of the rewrite"
    The rewrite applies to `@yyyy_mm`, `@date` and `@year` on a **plain `DateField`**, whether the
    column sits on the queried model or is reached through a join. Two things keep the original
    rendering: a `DateTimeField`, because `to_char` on a timestamp renders in the session time zone
    and the range boundaries would shift around midnight; and the `@month`/`@day`/`@quarter`/
    `@quadrimester` buckets, which repeat every year rather than covering one contiguous range over
    the column.

    For every value the bucket can express, the rewrite selects the same rows as before — only the
    query plan changes. The one behavioural difference is at the edges: because the comparison is
    now computed as a date bound, a value that no date bound can represent (`"1991-13"`, a
    fractional or out-of-range year, a `Bool`) raises a `FilterError` instead of building SQL that
    silently matched nothing. Joined paths and columns on the queried model behave identically here.

---

## String Functions

`PormG.Functions` provides string manipulation functions that work in `values()`:

| Function | Description | Example |
| :--- | :--- | :--- |
| `Lower("field")` | Convert to lowercase | `"name_lower" => Lower("surname")` |
| `Upper("field")` | Convert to uppercase | `"name_upper" => Upper("surname")` |
| `Length("field")` | String length | `"name_len" => Length("surname")` |
| `Concat(args...)` | Concatenate fields/values | `"full" => Concat("forename", Value(" "), "surname")` |
| `Trim("field")` | Trim leading/trailing whitespace | `"clean" => Trim("name")` |
| `LTrim("field")` | Trim leading whitespace | `"clean" => LTrim("name")` |
| `RTrim("field")` | Trim trailing whitespace | `"clean" => RTrim("name")` |
| `Replace("field", old, new)` | Replace substring | `"fixed" => Replace("name", "-", " ")` |

```julia
using PormG.Functions: Concat, Value, Lower, Upper, Length

query = M.Driver.objects
query.values(
    "full_name" => Concat("forename", Value(" "), "surname"),
    "name_upper" => Upper("surname"),
    "name_length" => Length("surname")
)
query.limit(5)
df = query |> DataFrame
```

Generated SQL (PostgreSQL):
```sql
SELECT CONCAT("driver"."forename", $1::text, "driver"."surname")  AS full_name,
       UPPER("driver"."surname")                                  AS name_upper,
       LENGTH("driver"."surname")                                 AS name_length
FROM "driver"
LIMIT 5
```

Output:
```
5×3 DataFrame
 Row │ full_name          name_upper  name_length
     │ String?            String?     Int32?
─────┼────────────────────────────────────────────
   1 │ Lewis Hamilton     HAMILTON              8
   2 │ Nick Heidfeld      HEIDFELD              8
   3 │ Nico Rosberg       ROSBERG               7
   4 │ Fernando Alonso    ALONSO                6
   5 │ Heikki Kovalainen  KOVALAINEN           10
```

---

## Mathematical Functions

PormG supports math through explicit function calls:

| Function | Description | Example |
| :--- | :--- | :--- |
| `Abs("field")` | Absolute value | `Abs("points")` |
| `Round(expr, n)` | Round to `n` decimal places | `Round(Value(10.556), 2)` |
| `Floor("field")` | Floor (round down) | `Floor("points")` |
| `Ceil("field")` | Ceiling (round up) | `Ceil("points")` |
| `Sqrt("field")` | Square root | `Sqrt("driverid")` |
| `Exp("field")` | Exponential (e^x) | `Exp("points")` |
| `Ln("field")` | Natural logarithm | `Ln("points")` |
| `Power("field", n)` | Raise to power n | `Power("driverid", Value(2))` |
| `Mod("field", n)` | Modulo (remainder) | `Mod("driverid", Value(3))` |

```julia
using PormG.Functions: Power, Round, Value, Abs

query = M.Driver.objects
query.values(
    "driverid",
    "squared" => Power("driverid", Value(2)),
    "precise" => Round(Value(10.556), 2),
    "abs_val" => Abs("number")
)
query.filter("driverid" => 1)
df = query |> DataFrame
```

!!! note
    For cross-database compatibility, avoid examples that depend on ambiguous floating-point half-rounding behavior (e.g., rounding `0.5`).

---

## Conditional Functions

### `Coalesce` — First Non-Null Value

```julia
using PormG.Functions: Coalesce

query = M.Driver.objects
query.values(
    "display_name" => Coalesce("code", "surname")
)
```

### `NullIf` — Return NULL If Equal

```julia
using PormG.Functions: NullIf

# Return NULL if code is an empty string
query = M.Driver.objects
query.values(
    "clean_code" => NullIf("code", "")
)
```

### `Greatest` / `Least` — Max/Min of Values

```julia
using PormG.Functions: Greatest, Least, Value

query = M.Result.objects
query.values(
    "adjusted_points" => Greatest("points", Value(0)),
    "capped_points"   => Least("points", Value(25))
)
```

### `Cast` — Type Conversion

```julia
using PormG.Functions: Cast

query = M.Result.objects
query.values(
    "points_int" => Cast("points", "INTEGER")
)
```

### `Extract` — Extract Date/Time Part

```julia
using PormG.Functions: Extract

query = M.Race.objects
query.values(
    "race_year" => Extract("date", "year"),
    "race_dow"  => Extract("date", "dow")
)
```

### `ToChar` — Format as String

```julia
using PormG.Functions: ToChar

query = M.Race.objects
query.values(
    "formatted_date" => ToChar("date", "YYYY-MM")
)
```

---

## Case / When Expressions

`Case` and `When` enable SQL `CASE WHEN ... THEN ... ELSE ... END` expressions.

Plain Julia values — including strings — can be passed to `then`, `otherwise`, and `default` directly.
No `Value()` wrapper is required.

!!! note
    If no branch matches and neither `otherwise` nor `default` is set, the expression returns `NULL`.
    Always provide a fallback when the column must be non-null.

### Binary When (single condition, two outcomes)

For a simple yes/no expression, pass `otherwise` directly to `When`. PormG wraps it in a full
`CASE … END` automatically — no `Case` wrapper needed:

```julia
using PormG.Functions: When

# Did the driver win at least one race in their standing?
query = M.Driver_standings.objects
query.values(
    "driverid__surname",
    "points",
    "wins",
    "race_winner" => When("wins__@gt" => 16, then = "Yes", otherwise = "No")
)
query.filter("raceid__year" => 2023)
query.order_by("-points").limit(5)
df = query |> DataFrame
```

Generated SQL (PostgreSQL):
```sql
SELECT "driver"."surname"           AS driverid__surname,
       "driver_standings"."points"  AS points,
       "driver_standings"."wins"    AS wins,
       CASE WHEN "driver_standings"."wins" > $1
            THEN $2::text
            ELSE $3::text
       END                          AS race_winner
FROM "driver_standings"
INNER JOIN "driver" ON "driver_standings"."driverid" = "driver"."driverid"
INNER JOIN "race"   ON "driver_standings"."raceid"   = "race"."raceid"
WHERE "race"."year" = $4
ORDER BY "points" DESC
LIMIT 5
-- parameters: [16, "Yes", "No", 2023]
```

Output:
```
5×4 DataFrame
 Row │ driverid__surname  points    wins    race_winner
     │ String?            Float64?  Int32?  String?
─────┼──────────────────────────────────────────────────
   1 │ Verstappen            575.0      19  Yes
   2 │ Verstappen            549.0      18  Yes
   3 │ Verstappen            524.0      17  Yes
   4 │ Verstappen            491.0      16  No
   5 │ Verstappen            466.0      15  No
```

### Multi-branch Case Expression

For multiple conditions, wrap a vector of `When` fragments in `Case`. The `default` on `Case`
provides the `ELSE` branch:

```julia
using PormG.Functions: Case, When

query = M.Driver.objects
query.values(
    "surname",
    "region" => Case([
        When("nationality" => "British",     then = "UK"),
        When("nationality__@in" => ["French", "Italian", "Spanish"], then = "Europe"),
        When("nationality" => "Brazilian",   then = "South America")
    ], default = "Other")
)
query.limit(10)
df = query |> DataFrame
```

Output:
```
10×2 DataFrame
 Row │ surname    region
     │ String?    String?
─────┼────────────────────
   1 │ Hamilton   UK
   2 │ Heidfeld   Other
   3 │ Rosberg    Other
  ⋮  │     ⋮         ⋮
   8 │ Räikkönen  Other
   9 │ Kubica     Other
  10 │ Glock      Other
              4 rows omitted
```

### Case with Q() and F() Logic

For more complex conditions, combine `Case`/`When` with `Q()` for boolean logic and `F()` for field references:

```julia
using PormG: Q, F
using PormG.Functions: Case, When, Sum, Value

query = M.Result.objects
query.filter("driverid__forename" => "Mika")
query.values(
    "raceid__circuitid__name",
    "under_30_victories" => Sum(
        Case(
            When(
                Q(
                    F("raceid__date") <= F("driverid__dob") + 10957,  # ~30 years in days
                    "positionorder" => 1
                ),
                then = 1
            ),
            default = 0
        )
    )
).filter("under_30_victories__@gt" => 0)
df = query |> DataFrame
```

Generated SQL (PostgreSQL):
```sql
SELECT "circuit"."name"  AS raceid__circuitid__name,
       SUM(CASE WHEN ("race"."date" <= ("driver"."dob" + ($1::bigint || ' days')::interval)
                 AND  "result"."positionorder" = $2)
                THEN $3::bigint
                ELSE $4::bigint
       END)              AS under_30_victories
FROM "result"
INNER JOIN "race"    ON "result"."raceid"   = "race"."raceid"
INNER JOIN "circuit" ON "race"."circuitid"  = "circuit"."circuitid"
INNER JOIN "driver"  ON "result"."driverid" = "driver"."driverid"
WHERE "driver"."forename" = $5
GROUP BY 1
HAVING SUM(CASE WHEN ... END) > $6
-- parameters: [10957, 1, 1, 0, "Mika", 0]
```

Output:
```
8×2 DataFrame
 Row │ raceid__circuitid__name          under_30_victories
     │ Union{Missing, String}           Decimals.Decimal?
─────┼─────────────────────────────────────────────────────
   1 │ Albert Park Grand Prix Circuit                    1
   2 │ Autódromo José Carlos Pace                        1
   3 │ Circuit de Barcelona-Catalunya                    1
   4 │ Circuit de Monaco                                 1
   5 │ Circuito de Jerez                                 1
   6 │ Hockenheimring                                    1
   7 │ Nürburgring                                       1
   8 │ Red Bull Ring                                     1
```

This generates a `SUM(CASE WHEN ... THEN 1 ELSE 0 END)` pattern — very useful for computing conditional counts within grouped queries.

!!! tip "Beyond integer days"
    The `+ 10957` above adds a whole number of **days**. To add other calendar or time units,
    pass a Julia `Dates` duration — `F("driverid__dob") + Year(30)` instead of `+ 10957` — or the
    [`Interval`](field_expressions.md#The-Interval-helper) helper. See
    [Date Arithmetic](field_expressions.md#Date-Arithmetic) for the cross-database SQL these render.

### Case in Filters

`Case` expressions can be used as the right-hand side of a `filter()` predicate to apply
dynamic thresholds. For example, the F1 points system awarded points to the top 10 finishers
from 2010 onwards, but only the top 8 before that:

```julia
using PormG.Functions: Case, When

# Keep only results where the driver finished inside the points-scoring positions,
# applying the correct threshold for each era.
query = M.Result.objects
query.filter(
    "positionorder__@lte" => Case([
        When("raceid__year__@gte" => 2010, then = 10),  # modern era: top 10
    ], default = 8)                                     # classic era: top 8
)
query.values("raceid__year", "driverid__surname", "positionorder", "points")
query.order_by("raceid__year", "positionorder")
query.limit(5)
df = query |> DataFrame
```

Generated SQL (PostgreSQL):
```sql
SELECT "race"."year"        AS raceid__year,
       "driver"."surname"   AS driverid__surname,
       "result"."positionorder" AS positionorder,
       "result"."points"    AS points
FROM "result"
INNER JOIN "race"   ON "result"."raceid"   = "race"."raceid"
INNER JOIN "driver" ON "result"."driverid" = "driver"."driverid"
WHERE "result"."positionorder" <= CASE
    WHEN "race"."year" >= $1 THEN $2::bigint
    ELSE $3::bigint
END
ORDER BY raceid__year ASC, positionorder ASC
LIMIT 5
-- parameters: [2010, 10, 8]
```

Output:
```
5×4 DataFrame
 Row │ raceid__year  driverid__surname  positionorder  points
     │ Int32?        String?            Int32?         Float64?
─────┼──────────────────────────────────────────────────────────
   1 │         1950  Farina                         1       9.0
   2 │         1950  Fangio                         1       9.0
   3 │         1950  Farina                         1       9.0
   4 │         1950  Parsons                        1       9.0
   5 │         1950  Fangio                         1       8.0
```

All rows are from 1950 (classic era), so the CASE evaluates to `ELSE 8` — only finishers in positions 1–8 are returned. The CASE expression is evaluated per row against each race's own year, so a modern race would use threshold 10 and a classic race would use threshold 8.

---

## Combining Functions

Functions can be nested and combined with aggregates:

```julia
using PormG.Functions: Count, Concat, Value, Upper

# Count races per nationality, with formatted output
query = M.Driver.objects
query.values(
    "region" => Upper("nationality"),
    "driver_count" => Count("driverid")
)
query.order_by("-driver_count")
query.limit(10)
df = query |> DataFrame
```

Generated SQL:
```sql
SELECT UPPER("driver"."nationality") AS region,
       COUNT("driver"."driverid")    AS driver_count
FROM "driver"
GROUP BY 1
ORDER BY "driver_count" DESC
LIMIT 10
```

Output:
```
10×2 DataFrame
 Row │ region         driver_count
     │ String?        Int64?
─────┼─────────────────────────────
   1 │ BRITISH                 166
   2 │ AMERICAN                158
   3 │ ITALIAN                  99
  ⋮  │       ⋮             ⋮
   8 │ BELGIAN                  23
   9 │ SWISS                    23
  10 │ SOUTH AFRICAN            23
               4 rows omitted
```

---

## Next Steps

- **[Subqueries and CTEs](subqueries_and_ctes.md)** — Decompose complex queries with `WITH` clauses.
- **[Field Expressions](field_expressions.md)** — Database-side arithmetic and field-to-field comparisons.
- **[Window Functions](window_functions.md)** — `Rank`, `Lag`, `Lead`, and friends for per-row analytics.
- **[Filters and Aggregates](filters_and_aggregates.md)** — Lookup operators and `HAVING` clause details.