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
query.values("raceId", "date", "date__@year", "date__@month", "date__@day")
df = query |> DataFrame

#  Row │ raceId  date        date__year  date__month  date__day
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
    "rows" => Count("raceId")
)
query.order_by("date__day")
df = query |> DataFrame
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

# Match by Julia Date object (recommended)
query = M.Race.objects.filter("date__@date" => Date(1991, 10, 20))
```

---

## String Functions

PormG exports string manipulation functions that work in `values()`:

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
using PormG: Concat, Value, Lower, Upper, Length

query = M.Driver.objects
query.values(
    "full_name" => Concat("forename", Value(" "), "surname"),
    "name_upper" => Upper("surname"),
    "name_length" => Length("surname")
)
query.limit(5)
df = query |> DataFrame
```

---

## Mathematical Functions

PormG supports math through both `__@` modifiers and explicit function calls:

### Via `__@` Modifiers

```julia
query = M.Driver.objects
query.values(
    "driverId",
    "rounded_id" => "driverId__@round",
    "sqrt_val"   => "driverId__@sqrt"
)
query.filter("driverId" => 1)
df = query |> DataFrame
```

### Via Explicit Function Calls

| Function | Description | Example |
| :--- | :--- | :--- |
| `Abs("field")` | Absolute value | `Abs("points")` |
| `Round(expr, n)` | Round to `n` decimal places | `Round(Value(10.556), 2)` |
| `Floor("field")` | Floor (round down) | `Floor("points")` |
| `Ceil("field")` | Ceiling (round up) | `Ceil("points")` |
| `Sqrt("field")` | Square root | `Sqrt("driverId")` |
| `Exp("field")` | Exponential (e^x) | `Exp("points")` |
| `Ln("field")` | Natural logarithm | `Ln("points")` |
| `Power("field", n)` | Raise to power n | `Power("driverId", Value(2))` |
| `Mod("field", n)` | Modulo (remainder) | `Mod("driverId", Value(3))` |

```julia
using PormG: Power, Round, Value, Abs

query = M.Driver.objects
query.values(
    "driverId",
    "squared" => Power("driverId", Value(2)),
    "precise" => Round(Value(10.556), 2),
    "abs_val" => Abs("number")
)
query.filter("driverId" => 1)
df = query |> DataFrame
```

> [!NOTE]
> For cross-database compatibility, avoid examples that depend on ambiguous floating-point half-rounding behavior (e.g., rounding `0.5`).

---

## Conditional Functions

### `Coalesce` — First Non-Null Value

```julia
using PormG: Coalesce

query = M.Driver.objects
query.values(
    "display_name" => Coalesce("code", "surname")
)
```

### `NullIf` — Return NULL If Equal

```julia
using PormG: NullIf

# Return NULL if code is an empty string
query = M.Driver.objects
query.values(
    "clean_code" => NullIf("code", "")
)
```

### `Greatest` / `Least` — Max/Min of Values

```julia
using PormG: Greatest, Least, Value

query = M.Result.objects
query.values(
    "adjusted_points" => Greatest("points", Value(0)),
    "capped_points"   => Least("points", Value(25))
)
```

### `Cast` — Type Conversion

```julia
using PormG: Cast

query = M.Result.objects
query.values(
    "points_int" => Cast("points", "INTEGER")
)
```

### `Extract` — Extract Date/Time Part

```julia
using PormG: Extract

query = M.Race.objects
query.values(
    "race_year" => Extract("year", "date"),
    "race_dow"  => Extract("dow", "date")
)
```

### `To_char` — Format as String

```julia
using PormG: To_char

query = M.Race.objects
query.values(
    "formatted_date" => To_char("date", "YYYY-MM")
)
```

---

## Case / When Expressions

`Case` and `When` enable SQL `CASE WHEN ... THEN ... ELSE ... END` expressions:

### Basic Case Expression

```julia
using PormG: Case, When, Value

query = M.Driver.objects
query.values(
    "surname",
    "region" => Case([
        When("nationality" => "British", then = Value("UK")),
        When("nationality__@in" => ["French", "Italian", "Spanish"], then = Value("Europe")),
        When("nationality" => "Brazilian", then = Value("South America"))
    ], default = Value("Other"))
)
query.limit(10)
df = query |> DataFrame
```

### Case with Q() and F() Logic

For more complex conditions, combine `Case`/`When` with `Q()` for boolean logic and `F()` for field references:

```julia
using PormG: Case, When, Sum, Q, F, Value

query = M.Result.objects
query.filter("driverId__forename" => "Mika")
query.values(
    "raceId__circuitId__name",
    "under_30_victories" => Sum(
        Case(
            When(
                Q(
                    F("raceId__date") <= F("driverId__dob") + 10957,  # ~30 years in days
                    "positionOrder" => 1
                ),
                then = 1
            ),
            default = 0
        )
    )
)
df = query |> DataFrame
```

This generates a `SUM(CASE WHEN ... THEN 1 ELSE 0 END)` pattern — very useful for computing conditional counts within grouped queries.

### Case in Filters

`Case` expressions can also be used in `filter()` for conditional predicates.

---

## Combining Functions

Functions can be nested and combined with aggregates:

```julia
using PormG: Count, Concat, Value, Upper

# Count races per nationality, with formatted output
query = M.Driver.objects
query.values(
    "region" => Upper("nationality"),
    "driver_count" => Count("driverId")
)
query.order_by("-driver_count")
query.limit(10)
df = query |> DataFrame
```

---

## Next Steps

- **[Subqueries and CTEs](subqueries_and_ctes.md)** — Decompose complex queries with `WITH` clauses.
- **[Field Expressions](field_expressions.md)** — Database-side arithmetic and field-to-field comparisons.
- **[Filters and Aggregates](filters_and_aggregates.md)** — Lookup operators and `HAVING` clause details.