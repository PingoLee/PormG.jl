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
| `@hour` | Extract hour (0-23) | `"start_at__@hour"` | `"start_at__@hour" => 13` |
| `@minute` | Extract minute (0-59) | `"start_at__@minute"` | `"start_at__@minute" => 30` |
| `@second` | Extract whole second (0-59) | `"time__@second"` | `"time__@second" => 0` |
| `@week` | ISO-8601 week of the year (1-53) | `"date__@week"` | `"date__@week" => 10` |
| `@week_day` | Day of the week, 1 = Sunday … 7 = Saturday | `"date__@week_day"` | `"date__@week_day" => 1` |
| `@iso_week_day` | ISO day of the week, 1 = Monday … 7 = Sunday | `"date__@iso_week_day"` | `"date__@iso_week_day" => 7` |
| `@iso_year` | ISO-8601 week-numbering year | `"date__@iso_year"` | `"date__@iso_year" => 2021` |
| `@yyyy_mm` | Year-month as string | `"date__@yyyy_mm"` | `"date__@yyyy_mm" => "1991-10"` |
| `@yyyy_q` | Year-quarter as string | `"date__@yyyy_q"` | `"date__@yyyy_q" => "1991-Q1"` |
| `@yyyy_quad` | Year-quadrimester as string | `"date__@yyyy_quad"` | `"date__@yyyy_quad" => "1991-Q1"` |

### Period number or period label?

`@quarter` and `@quadrimester` extract a **number** — `1`–`4` and `1`–`3` — so they answer "which
quarter", independently of the year. That is what makes `filter("date__@quarter" => 1)` select Q1 of
every season. It is the same shape as Django's `__quarter` lookup and SQL's
`EXTRACT(QUARTER FROM …)` (cast `::integer` on PostgreSQL, so it reads back as an integer on both engines).

`@yyyy_q` and `@yyyy_quad` build the **year-qualified label** (`"1991-Q1"`), the form you want as a
`values()` grouping key when each year's periods must not be merged. They sit beside `@yyyy_mm`,
which works the same way for months.

Both number transforms validate the comparison value: a quarter outside `1`–`4`, or a value that is
not a number at all, raises `InvalidValueError` instead of building SQL that silently matches nothing.

The labels work in every position — `values()`, `filter()` and `order_by()`, projected under an
alias or not:

```julia
q = M.Race.objects
q.values("name", "q" => "date__@yyyy_q")
q.filter("date__@yyyy_q" => "1991-Q1")          # the races of the first quarter of 1991
q.order_by("-date__@yyyy_q")                    # newest label first
```

!!! note "`@yyyy_quad` spells its separator `-Q` too"
    `"1991-Q1"` from `@yyyy_quad` means the first *quadrimester*, not the first quarter — the two
    labels are indistinguishable from the value alone. Alias them explicitly
    (`"quad" => "date__@yyyy_quad"`) when both appear in one projection.

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

### Null checks and ranges after a transform

`@isnull`, `@range` and `@nrange` chain after a transform like any other lookup, as Django's
`date__year__isnull` does:

```julia
# Races of the 1990s
query = M.Race.objects.filter("date__@year__@range" => [1990, 1999])
# renders:  EXTRACT(YEAR FROM "Tb"."date")::integer BETWEEN $1 AND $2

# Races with a sprint: `sprint_date` is NULL on every other race
query = M.Race.objects.filter("sprint_date__@year__@isnull" => false)
# renders:  EXTRACT(YEAR FROM "Tb"."sprint_date")::integer IS NOT NULL
```

The range operands are values of the transform: years for `@year`, `"YYYY-MM"` strings for
`@yyyy_mm`, and each is checked the way a single value is (`"start_at__@hour__@range" => [1, 25]` raises
`InvalidValueError`). A range is not rewritten onto the column the way a comparison on a
`DateField` is (below), so it compares the transform itself.

A date part is NULL exactly when its date is, so `"sprint_date__@year__@isnull" => false` selects
the same rows as `"sprint_date__@isnull" => false`. The year-qualified labels follow the same rule:
`"sprint_date__@yyyy_q"` reads `missing` for a race without a sprint on both engines, never a
partial `"-Q"`.

### Time of day (`@hour`, `@minute`, `@second`)

The time parts work on a `DateTimeField` and on a `TimeField`, in `filter()` and `values()` alike.
They read back as integers on both engines. `@second` is the **whole** second: PostgreSQL truncates
a fractional `45.6` to `45`, as SQLite does, instead of rounding it to `46`.

```julia
# Races that started at 13:00-13:59 (`start_at` is a DateTimeField; see the time-zone note below)
M.Race.objects.filter("start_at__@hour" => 13)

# The same question asked of the TimeField: races scheduled on the half hour
M.Race.objects.filter("time__@minute" => 30)

# How many races started in each hour of the day
q = M.Race.objects
q.values("hour" => "start_at__@hour", "races" => Count("raceid"))
q.filter("start_at__@isnull" => false)
q.order_by("hour")
```

Each part validates its comparison value the same way `@quarter` does. An hour outside `0`–`23`, a
minute or second outside `0`–`59`, a fraction, or a value that is not a number raises `InvalidValueError`,
instead of building SQL that silently matches nothing.

!!! note "Transforms read a timestamp in UTC"
    Every transform reads a `DateTimeField` in **UTC**, on both engines. SQLite stores the
    timestamp in UTC. On PostgreSQL a `DateTimeField` is a `timestamptz` by default, read in the
    connection's session time zone, and both PostgreSQL drivers open every connection with
    `TimeZone=UTC`. So `start_at__@hour` is the UTC hour, and `@date` and `@day` are the UTC day.
    A `DateTimeField(type="TIMESTAMP")` and a `TimeField` carry no time zone, so they return the
    stored wall-clock value on both engines.

    Do not add `-c TimeZone=…` to the connection's `options`. PostgreSQL would then read every
    `timestamptz` in that zone, and `@hour`, `@date`, `@day` and `ToChar` would return different
    values from SQLite. With the `LibPQ` driver, **any** `options=` in the connection string
    replaces the driver's own session settings, even one that only sets `search_path`. If you
    need `options`, start it with all three:
    `-c DateStyle=ISO,YMD -c IntervalStyle=iso_8601 -c TimeZone=UTC`. Without the first two,
    reading dates and `DurationField` values breaks as well. The `Postgres` driver keeps its own
    settings and appends your `options` after them. The `time_zone` setting in `connection.yml` does not change this; it only
    sets the clock for `auto_now` / `auto_now_add` values.

!!! note "A plain `DateField` has no time of day"
    `@hour`, `@minute` and `@second` read a `DateTimeField` or a `TimeField`. On a `DateField`
    they raise `QueryBuildError` when the query is built — see
    [Which columns a transform reads](#Which-columns-a-transform-reads).

### Weeks (`@week`, `@week_day`, `@iso_week_day`, `@iso_year`)

The week parts use Django's numbering, and they return the same number on PostgreSQL and SQLite:

| Transform | Returns | Numbering |
| :--- | :--- | :--- |
| `@week` | the ISO-8601 week | `1`–`53`; week 1 is the week holding the year's first Thursday |
| `@iso_year` | the ISO-8601 week-numbering year | the year that week belongs to |
| `@iso_week_day` | the ISO day of the week | `1` = Monday … `7` = Sunday |
| `@week_day` | the day of the week | `1` = Sunday … `7` = Saturday |

The engines' own functions do not agree on these numbers. SQLite's `%W` is not the ISO week, and
PostgreSQL's `DOW` counts from `0`. PormG renders each part to the numbering in the table, not to
either engine's default.

`@week` and `@iso_year` belong together. Near New Year a date can sit in a week of the neighbouring
year: 2021-01-01 is in ISO week 53 of **2020**, and 2024-12-30 is in week 1 of **2025**. To group by
week across seasons, group by both. `@year` alongside `@week` would split such a week in two.

```julia
# Races held on a Sunday (`date` is a DateField)
M.Race.objects.filter("date__@week_day" => 1)

# The same question in ISO numbering, where Sunday is 7
M.Race.objects.filter("date__@iso_week_day" => 7)

# How many races each ISO week of the 2021 season held
q = M.Race.objects
q.filter("date__@iso_year" => 2021)
q.values("week" => "date__@week", "races" => Count("raceid"))
q.order_by("week")
```

A week outside `1`–`53`, a day outside `1`–`7`, a fraction, or a value that is not a number raises
`InvalidValueError`, the same as the other period transforms.

### Which columns a transform reads

Each transform checks its column when the query is built, in `values()`, `filter()` and
`order_by()` alike:

| Transforms | Column |
| :--- | :--- |
| `@hour`, `@minute`, `@second` | a `DateTimeField` or a `TimeField` |
| every other date transform — `@year`, `@month`, `@day`, `@date`, `@quarter`, `@quadrimester`, the week parts and the `@yyyy_*` labels | a `DateField` or a `DateTimeField` |

Any other model field raises `QueryBuildError` naming the column and its type. Over text or a
number that SQL used to fail on PostgreSQL, while SQLite read whatever the column's text happened
to hold, so a date stored in a `CharField` worked there and nowhere else. A `DurationField` is
refused too: PostgreSQL extracts from an interval, but SQLite reads its stored text as a clock,
so the engines disagreed. `Extract` (below) still reads a duration on PostgreSQL.

```julia
M.Driver.objects.filter("surname__@month" => 3)   # QueryBuildError: `surname` is a CharField
M.Race.objects.values("h" => "date__@hour")       # QueryBuildError: a DateField has no time of day
```

The check covers columns PormG can name a field for: a model field, or one reached through a
join (`"raceid__date__@week"`). A column of unknown type, such as an expression or a subquery, is
passed through as written. A relation is passed through too, because its value is the related
row's key. The public `Extract` and `ToChar` functions are not
transforms and are not checked: `Extract("duration", "epoch")` on a `DurationField` is valid
PostgreSQL.

A period transform also refuses a `Bool` value. `"start_at__@hour" => true` raises
`InvalidValueError` rather than meaning `1`.

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
SELECT EXTRACT(YEAR  FROM "race"."date")::integer AS date__year,
       EXTRACT(MONTH FROM "race"."date")::integer AS date__month,
       EXTRACT(DAY   FROM "race"."date")::integer AS date__day,
       COUNT("race"."raceid")                     AS rows
FROM "race"
WHERE ("race"."date" >= $1 AND "race"."date" < $2)   -- the @year filter is rewritten to a sargable range
GROUP BY 1, 2, 3
ORDER BY "date__day" ASC
```

Output:
```
16×4 DataFrame
 Row │ date__year  date__month  date__day  rows
     │ Int32?      Int32?       Int32?     Int64?
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
    the column. The year-qualified `@yyyy_q` / `@yyyy_quad` labels do cover a contiguous range but
    are not rewritten either — only `@yyyy_mm`, `@date` and `@year` are.

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
| `Concat(vector)` | Same, operands in a vector | `"full" => Concat(["forename", "surname"])` |
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
LIMIT $2
-- parameters: [" ", 5]
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

A NULL operand is **skipped** — read as an empty string — on both engines, as in Django, so a
`Concat` is never NULL: a driver with no `number` gives `"# "` for
`Concat(Value("#"), "number", Value(" "))`. PostgreSQL's `CONCAT` skips a NULL itself; on SQLite
each operand renders as `COALESCE(operand, '')`, joined with `||`. To get NULL instead, say so with
a `Case`, which is NULL when no branch matches:

```julia
using PormG.Functions: Case, When, Concat, Value

q = M.Driver.objects
q.values("driverref", "car" => Case(When("number__@isnull" => false, then = Concat(Value("#"), "number"))))
```

Text, integer and date operands read the same on both engines. A boolean, a float or a decimal
operand raises `QueryBuildError`, because each engine writes it differently: PostgreSQL's `CONCAT`
gives `t`, `25` and `3.00` where SQLite's `||` gives `1`, `25.0` and `3`. A concatenated value could
otherwise read one way in tests on SQLite and another in production. The refusal covers a
`BooleanField`, `FloatField` or `DecimalField` column (joined paths too), a `true`/`1.5`/`Decimal`
literal, and an expression of one of those types: a comparison or `Q(...)` condition, a `Cast` to a
float or decimal type, arithmetic, an extremum or a window value over a float, and the functions
PostgreSQL computes as `numeric` (`Avg`, `Round`, `Mod`, `Sqrt`, `Exp`, `Ln`, `Power`), which SQLite
answers as a REAL (`1` vs `1.0`). A literal is refused when the `Concat` is built, and a column when
the query is.

Three more operand types are refused the same way, because their text differs too:

| Operand | PostgreSQL | SQLite |
|---|---|---|
| a timestamp (`DateTimeField`, `F("start_at") + Day(1)`, a `DateTime` literal) | `2009-03-29 06:00:00+00` | `2009-03-29T06:00:00.000+00:00` |
| an interval (`DurationField`, a timestamp difference, `Sum` of a duration, a `Period` literal) | its `IntervalStyle`: `PT25.021S`, `1 day 02:00:00` | `00:00:25.021` |
| a whole JSON document (`JSONField`) | `{"a": [1, 2]}` | `{"a":[1,2]}` |

A date, a time and a uuid read the same text on both engines and pass. A JSON key lookup
(`"payload__driver"`) passes too: it reads the same text when the value at the key is a string, but a
boolean or a nested value can still differ (`true` vs `1`), and PormG cannot know which a key holds.
The check covers only types PormG can name: an operand it cannot type (a `Subquery` over a number,
an untyped `Case`, an extremum over timestamp arithmetic, `Greatest`/`Least` over computed timestamps
or intervals) passes.

`Cast(…, CharField())` is not a way around this, because a cast to text makes the same split (`25`
against `25.0`). It is refused too (see the `Cast` section below). Write the text you mean
instead:

- For a boolean, use a `Case`.
- For a timestamp, name the format with `ToChar`: `ToChar("start_at", "YYYY-MM-DD HH:MI:SS")` gives
  `2009-03-29 06:00:00` on both engines.
- For a number, an interval or a document, fetch the value and format it in Julia, where you choose
  the digits:

```julia
using PormG.Functions: Case, When, Concat, Value

q = M.Result.objects
q.filter("raceid" => 18)
# A yes/no: name its two texts with a `Case`.
q.values("driverid__driverref", "points",
         "outcome" => Concat("driverid__driverref", Value(": "),
                             Case(When("points__@gt" => 0, then = Value("scored")), default = "no points")))
df = q |> DataFrame
# A number: `points` is a FloatField (1.5 for a shared fastest lap), so its text is yours to choose.
df.label = df.driverid__driverref .* "-" .* string.(df.points)
```

`Concat` takes its operands either variadically or as a single vector — the two spellings build the
same expression and render the same SQL. Each example below starts from a fresh handle, because
`values()` **replaces** the projection rather than adding to it:

```julia
# Vector form, equivalent to the variadic call above
q = M.Driver.objects
q.values("full_name" => Concat(["forename", Value(" "), "surname"]))

# A vector of plain column names works too, which is what a parsed request usually gives you
cols = split("cols=forename,surname", "=")[2]
q2 = M.Driver.objects
q2.values("full_name" => Concat(collect(split(cols, ","))))
```

---

## Mathematical Functions

PormG supports math through explicit function calls:

| Function | Description | Example |
| :--- | :--- | :--- |
| `Abs("field")` | Absolute value | `Abs("points")` |
| `Round(expr, n)` | Round to `n` decimal places (to a whole number by default) | `Round("points")` |
| `Floor("field")` | Floor (round down) | `Floor("points")` |
| `Ceil("field")` | Ceiling (round up) | `Ceil("points")` |
| `Sqrt("field")` | Square root | `Sqrt("driverid")` |
| `Exp("field")` | Exponential (e^x) | `Exp("points")` |
| `Ln("field")` | Natural logarithm | `Ln("points")` |
| `Power("field", n)` | Raise to power n | `Power("driverid", 2)` |
| `Mod("field", n)` | Modulo (remainder) | `Mod("driverid", 3)` |

```julia
using PormG.Functions: Power, Round, Value, Abs

query = M.Driver.objects
query.values(
    "driverid",
    "squared" => Power("driverid", 2),
    "rounded" => Round(Value(10.556)),        # 11 on both engines
    "abs_val" => Abs("number")
)
query.filter("driverid" => 1)
df = query |> DataFrame
```

### Rounding to decimal places

`Round(x)` gives the same whole number on PostgreSQL and SQLite. Each engine's own `ROUND` to `n`
places does not, for a value with more than `n` places: PostgreSQL's rounds the value's decimal
form, SQLite's the binary double. Measured on PostgreSQL 16.15 and SQLite 3.45.1:

| native `ROUND(v, 2)` | PostgreSQL | SQLite |
|---|---|---|
| `2.675` | `2.68` | `2.67` |
| `1.555` | `1.56` | `1.55` |
| `1.005` | `1.01` | `1.0` |

So over such a value (a float column, a float literal with more places, arithmetic over one, a
function such as `Avg` or `Sqrt`, or anything built over a `Subquery` or a `Case`, bare or inside
`Coalesce`, arithmetic and the like) `Round(x, n)` renders one formula instead, which both engines
compute in the same IEEE double arithmetic (#1061):

```sql
sign(x) * floor(abs(x) * 10^n + 0.5) / 10^n
```

It rounds half away from zero, and it gives the same double on both engines. It also matches
Julia's `round(x, RoundNearestTiesAway; digits = n)`: measured bit for bit on PostgreSQL 16.15 and
SQLite 3.53.4 over 1,200,020 values, `n` ∈ {1, 2, 3, 4, 6}. `2.675` and `1.555` round to `2.68` and `1.56`.
`1.005` gives `1.0`, because the double nearest `1.005` is just below it. Its value is a double on
both engines, so it reads back as a `Float64`. A `GROUP BY` or a filter on it matches the same rows
in development and in production.

An integer, a whole number, a `DecimalField` with at most `n` places (or `Max`, `Min` or `Coalesce`
over one), and a literal that fits are already rounded. They render the engine's own `ROUND` and
keep their type, so a `DecimalField` still reads back as a `Decimal` on PostgreSQL. A bare
`Subquery` over a decimal column is read the same way: within its places it keeps `ROUND`, and past
them it is refused (below). PormG does not read the places of anything else that comes through a
`Subquery` or a `Case`. Such a value takes the formula, and reads back as a double even when it is
an integer or a decimal: the formula leaves a value that already fits unchanged. To keep its type,
name it with a `Cast` (or a `Coalesce`/`Greatest`/`Least` `output_field`) as an integer type or a
`numeric(p, s)` with `s ≤ n`: `Round(Cast(Subquery(q), IntegerField()), 2)` keeps the engine's
`ROUND`. A `Case`'s own `output_field` is not read here, so wrap the `Case` in a `Cast`.

One limit applies: the formula is the same on both engines, but its operand has to be the same too.
`Avg` over floats is summed differently by the two engines (SQLite compensates its rounding errors,
PostgreSQL does not), so a mean that lands within a hair of a tie (`…5` at the last place) can still
round apart. A column, a literal, or arithmetic over them is the same value on both.

A decimal that PormG cannot show fits `n` places is refused: `Round(x, n)` raises `QueryBuildError`
when the query is built. PostgreSQL would round it exactly as a decimal (`1.005` → `1.01`), SQLite
holds it as a double (`1.0`, #648), and the formula would put PostgreSQL's exact value through a
double without being asked. That covers:

- a decimal with more than `n` places: a `DecimalField`, a `Decimal` literal, a cast to `numeric`;
- a decimal whose places PormG does not read: a `Sum`, arithmetic, a window value or a CTE column
  over a `DecimalField`. This one is refused **even when it would fit**:
  `Round(Sum("points"), 2)` over `Constructor_standings.points`, a two-place `DecimalField`, raises.

Say what you want instead:

- `Round(Cast(x, FloatField()), n)` accepts the double, and gives the formula's answer on both engines.
- `Round("points", 2)` on that two-place column is exact already, and keeps the `Decimal`.
- Or fetch the value and round it in Julia.

Two kinds of decimal operand take the formula instead, so they round as a double on PostgreSQL too:

- `Avg` and `Mod` of a `DecimalField`, which PormG reads as computed numbers;
- a decimal reached through a `Case`, or through a `Subquery` other than a bare one over a decimal
  column (wrapped, or projecting a `Sum`), as above.

Text is not a number to round. `Round(x, n)` over a text column, a string literal or a JSON value
raises `QueryBuildError` when the query is built. Say which number it is first with
`Round(Cast(x, FloatField()), n)`. A negative `n` raises `InvalidValueError` when the expression is
built: SQLite takes it as 0 (`Round(125, -1)` is `125.0`) and PostgreSQL rounds to tens (`130`). An
`n` above 22 raises it too: the formula scales by `10^n` as a double, and an overflow raises on
PostgreSQL where SQLite returns `Inf`.

```julia
using PormG.Functions: Avg, Round

# Each driver's mean points over the 2009 season, to two places: the same number on both engines.
query = M.Result.objects
query.filter("raceid__year" => 2009)
query.values("driverid__surname", "avg_points" => Round(Avg("points"), 2))
query.order_by("-avg_points")
df = query |> DataFrame
```

---

## Conditional Functions

The operands of `Coalesce`, `NullIf`, `Greatest` and `Least` (and of `Power` and `Mod` above) are
read by their type. A string is a column path, and the path can end in a transform:
`Coalesce("fp1_date", "start_at__@date")` falls back to the date of the race start. That holds
wherever the function sits. It can be projected in `values(...)`, on a filter's right-hand side
(also inside `Q`/`Qor` and a `When` condition), in a `Case`/`When` branch, in `F` arithmetic, in a
window's `partition_by`, as a `Lag`/`Lead` `default`, or as an `update(...)` value:

```julia
using PormG.Functions: Coalesce

# Races whose date equals the first-practice date or, when there is none, the date of the start
M.Race.objects.filter("date" => Coalesce("fp1_date", "start_at__@date"))
```

A CTE column is the exception. Outside a projection, a function names it with the
`CTE("name", "column")` handle; the `"name__column"` string works only inside `values(...)`. A
transform on a CTE column is not available in these positions with either spelling.

A number (of any integer width), a `Bool`, a `Date`, a `DateTime`, a `ZonedDateTime` or a `Time` is a literal
that PormG binds as a parameter. A **string literal** needs `Value(...)`: `NullIf("code", "")`
would read `""` as a column name. Any other value raises `QueryBuildError` when the expression is
built.

`Coalesce`, `Greatest` and `Least` take two or more arguments. With fewer, they raise
`QueryBuildError` when the expression is built: one argument is the argument itself, so write the
column with `F("points")` directly.

On SQLite a date or time literal binds as the same text its column stores (`Date(2021, 3, 28)` is
`"2021-03-28"`), and an integer of any width binds as a 64-bit integer, so a comparison with a
`DateField` column picks the same rows as on PostgreSQL. The *result* reads back as the column does
on both engines (#824) when every argument is of one type: `Coalesce("date", Date(2021, 3, 28))` and
`Greatest("date", "fp1_date")` give a `Date`, and `NullIf` takes its first argument's type. A
`Subquery(...)` argument counts as its one column (#888). When the
argument types differ, PormG does not guess: PostgreSQL resolves one result type itself
(`Coalesce("date", "start_at")` is a timestamp there), or refuses the call outright (a date beside a
text column), while SQLite returns the stored text of whichever argument won.

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
using PormG.Functions: NullIf, Value

# Return NULL if code is an empty string. `Value` makes "" a literal, not a column.
query = M.Driver.objects
query.values(
    "clean_code" => NullIf("code", Value(""))
)
```

### `Greatest` / `Least` — Max/Min of Values

```julia
using PormG.Functions: Greatest, Least

query = M.Result.objects
query.values(
    "adjusted_points" => Greatest("points", 0),
    "capped_points"   => Least("points", 25)
)

# A date literal works the same way: the later of the race date and 1 January 2021.
using Dates
query = M.Race.objects
query.filter("year" => 2020)
query.values("name", "not_before_2021" => Greatest("date", Date(2021, 1, 1)))
```

`Greatest` and `Least` skip a `NULL` argument on both engines. The result is `NULL` only when
every argument is `NULL`. The 2018 Hungarian Grand Prix has a race date and no practice dates:

```julia
query = M.Race.objects
query.filter("raceid" => 1000)
query.values("latest" => Greatest("date", "fp1_date"), "none" => Greatest("fp1_date", "fp2_date"))
query.list(:dict)
# [Dict(:latest => Date("2018-07-29"), :none => missing)]
```

PostgreSQL's `GREATEST` and `LEAST` behave this way natively. SQLite has neither function, and its
scalar `MAX(a, b)` returns `NULL` when any argument is, so on SQLite PormG renders one `COALESCE` per
rotation of the arguments: `Greatest(a, b)` becomes
`MAX(COALESCE(a, b), COALESCE(b, a))`. A literal argument binds once per place it appears. The SQL
grows with the square of the argument count, so with `n` arguments each one is rendered `n` times;
a `Subquery` argument runs once per rotation.

A single argument is refused (see the start of this section). On SQLite, `MAX(x)` and `MIN(x)` with
one argument are the *aggregates*, so a one-argument `Greatest` used to collapse the result to one
row.

### `Cast` — Type Conversion

```julia
using PormG.Functions: Cast, Round
using PormG.Models: IntegerField

query = M.Result.objects
query.values(
    "points_int" => Cast(Round("points"), IntegerField()),   # a field object: each engine's own spelling
    "points_num" => Cast("points", "numeric")                # or a type string
)
```

A field object is the preferred target, as in Django: PormG renders it in each engine's spelling
(`BinaryField()` is `bytea` on PostgreSQL and `BLOB` on SQLite). A type **string** is accepted
when it has this shape:

- a single type name — `"integer"`, `"bigint"`, `"text"`, `"timestamptz"`, or your own type such
  as an enum — or one of `"double precision"`, `"character varying"`, `"bit varying"`,
  `"timestamp with time zone"`, `"timestamp without time zone"`, `"time with time zone"`,
  `"time without time zone"` (any case);
- optionally followed by a size, `(n)` or `(n, m)`: `"varchar(20)"`, `"numeric(10,2)"`,
  `"timestamp(3) with time zone"`;
- on PostgreSQL only, optionally followed by array brackets: `"integer[]"`. SQLite has no array
  types and raises `BackendCapabilityError`.

SQLite has no date or time types either. There, a cast to `"date"` (or `DateField()`) renders
`date(x)`, which returns the `YYYY-MM-DD` text a `DateField` stores and cuts a timestamp to its
date, as PostgreSQL's `::date` does. Both engines read the result back as a `Date`. Cast a date or
timestamp column: on other input SQLite does not raise where PostgreSQL does. Text that is no date
gives `NULL`, an impossible date rolls over (`'2020-02-30'` is 1 March), and a number is read as a
Julian day (`0` is in 4714 BC). Every other
time target raises `BackendCapabilityError` on SQLite: `timestamp`, `timestamptz`, `time`,
`interval` and their spellings, and `DateTimeField()`, `TimeField()`, `DurationField()`. A plain
SQLite `CAST` to one of them returns a number (`2020` for `'2020-03-29 10:11:12'`), not a
different spelling of the value. Project the column itself instead.

```julia
using PormG.Functions: Cast

# The race date as a Date, on both engines
M.Race.objects.filter("year" => 2020).values("raceid", "day" => Cast("date", "date"))
```

Any other string raises `InvalidValueError` when the expression is built, on both engines. A type
name is a keyword in the SQL and cannot be a bind parameter, so PormG only writes a spelling it has
parsed, never the text it was given. That also refuses a few spellings PostgreSQL itself accepts: a
schema-qualified or quoted name (`public.mood`, `"Mood"`), `interval year to month`, a negative
scale, and a `COLLATE` clause. The same rules apply to the `output_field=` string of `Case`,
`Coalesce`, `Concat`, `Greatest` and `Least`.

#### A cast the engines apply differently is refused

A cast to text, to an integer or to a scaled `numeric(p, s)` goes through each engine's own
conversion, and for some operands the two disagree. Measured on PostgreSQL 16.15 and SQLite 3.45.1:

| Expression | PostgreSQL | SQLite |
|---|---|---|
| `Cast("points", CharField())`, a float `10.0` | `'10'` | `'10.0'` |
| `Cast(<bool> true, CharField())` | `'true'` | `'1'` |
| `Cast(<decimal> 14, CharField())`, a `numeric(10,2)` | `'14.00'` | `'14'` |
| `Cast(<float> 1.5, IntegerField())` | `2` (rounds) | `1` (truncates) |
| `Cast(<numeric> 2.5, IntegerField())` | `3` | `2` |
| `Cast(<float> 1.5, "numeric(10,0)")` | `2` (rounds to the scale) | `1.5` |
| `Cast(<float> 1.555, "numeric(10,2)")`, or the text `'1.555'` | `1.56` | `1.555` |

So PormG raises `QueryBuildError` when the query is built, on both engines, for:

- a cast to text (`CharField()`, `TextField()`, `"text"`, `"varchar(20)"`, …) of any operand
  `Concat` refuses: a boolean, a float, a decimal, a function PostgreSQL computes as `numeric`, a
  timestamp, an interval, or a whole JSON document;
- a cast to an integer (`IntegerField()`, `BigIntegerField()`, `"integer"`, `"bigint"`, `"int8"`,
  …) of a float, a decimal or a `numeric` function. A boolean casts to `1`/`0` on both engines and
  passes;
- a cast to `numeric(p, s)` or `decimal(p, s)` (and `numeric(p)`, whose scale is 0) of an operand
  that can carry more than `s` digits after the point: a float column, a float literal with more
  than `s` places or more than 15 significant digits (PostgreSQL converts a float to `numeric` at
  15, so `12345678901234.56` is `12345678901234.6` there), a
  function PostgreSQL computes as `numeric` (`Round(x, d)` with `d` above `s` included), a decimal with more places
  than `s` or of unknown scale, and text, which PostgreSQL parses and rounds while SQLite keeps it
  (#1040). A JSON value counts as text: PostgreSQL casts the key's text, SQLite the number.
  `dec(p, s)` is the same type as `numeric(p, s)`. PostgreSQL rounds to the scale and SQLite reads the type name only, so a filter or a
  `GROUP BY` over the cast would see different values. An integer, a whole number (`Round(x)`,
  `Floor`, `Ceil`), a `DecimalField` with at most `s` places, and a `Decimal` or float literal with
  at most `s` digits after the point (`Value(1.5)` at scale 2 reads `1.5` on both, #1050) pass, and so does a function whose value is one of them (`Max`, `Min`, `Abs`,
  `Coalesce`, `Greatest`, `Least`, `NullIf`). An operand PormG cannot
  type (an untyped `Case`, a `Subquery`) passes, as it does for the other two rules.

To get an integer, say how to round first. `Round(x)`, `Floor(x)` and `Ceil(x)` give the same whole
number on both engines for every stored value measured (PostgreSQL's `round` is the `numeric` one,
half away from zero, as SQLite's is), so a cast over them passes. `Mod` of whole numbers and `+`,
`-`, `*` of them pass too, since they have nothing to round. `Round(x, 2)` keeps a fraction, so a
cast to an integer over it is refused. One caveat: PostgreSQL turns a float into `numeric` at 15 significant digits
before it rounds, so a computed value a hair below a half (`2.4999999999999996`) can still round up
there and down on SQLite. For
text, the way out is the same as for `Concat`: a `Case` for a boolean, `ToChar` for a timestamp, and
Julia formatting for the rest.

For a scaled `numeric`, round first. `Round(x, d)` gives the same value on both engines (#1061,
*Rounding to decimal places* above), and that value has at most `d` places, so a cast to a scale of
at least `d` over it passes: `Cast(Round("points", 2), "numeric(10,2)")`. Over text or a wider decimal,
make it a float first: `Cast(Round(Cast(x, FloatField()), 2), "numeric(10,2)")`. A cast to an unscaled
`"numeric"` (or `DecimalField()`) keeps the value on both engines and passes as it is.

A cast to any other type (`"numeric"`, `"double precision"`, `"date"`) is not checked: it is not a
text conversion, and `Concat` refuses the result if you then use it as text.

```julia
using PormG.Functions: Cast, Ceil, Floor, Round
using PormG.Models: IntegerField

# Cast("points", IntegerField()) is refused: 1.5 would be 2 on PostgreSQL and 1 on SQLite.
# Race 2, the 2009 Malaysian GP, was stopped early and scored half points.
M.Result.objects.filter("raceid" => 2).values(
    "resultid", "points",
    "nearest" => Cast(Round("points"), IntegerField()),   # 1.5 → 2 on both engines
    "down"    => Cast(Floor("points"), IntegerField()),   # 1.5 → 1
    "up"      => Cast(Ceil("points"), IntegerField()))    # 1.5 → 2
```

#### `output_field`

`Case`, `Coalesce`, `Greatest` and `Least` cast their result to the `output_field` they are given, on
both engines, as `Cast` does. The SQLite date rule above applies to them too: a `date` renders
`date(…)`, and a timestamp, time, interval or array type raises `BackendCapabilityError` on SQLite.
The value, a filter on it, and a CTE column typed by it therefore all agree. Before the #852 fix,
`Coalesce`, `Greatest` and `Least` rendered no cast on SQLite, and `Greatest` and `Least` rendered
none on PostgreSQL either:

```julia
# The best of a result's grid slot and one, as a bigint on both engines:
# (GREATEST(…))::bigint on PostgreSQL, CAST(MAX(…) AS BIGINT) on SQLite
M.Result.objects.values("resultid", "slot" => Greatest("grid", 1; output_field = "bigint"))
```

The rule above applies to these casts too: `Coalesce`, `Greatest` and `Least` with an `output_field`
of text, an integer or a scaled `numeric(p, s)` refuse the same operands `Cast` does.
`Greatest("points", 0; output_field = "integer")` is refused, and `Greatest(Floor("points"), 0;
output_field = "integer")` passes. `Case` is not checked, because its value is one of its branches,
which PormG does not type. That includes `Case(…; output_field = "numeric(10,1)")`, which PostgreSQL
rounds and SQLite does not: round the branches yourself, or leave the scale off.

`Concat` renders no cast on either engine, because its result is always text. Its `output_field`
must therefore be a text type (`CharField()`, `TextField()`, `"text"`, `"varchar(20)"`). Any other
type raises `InvalidValueError` when the expression is built, since the SQL would never apply it.
To get a number out of a concatenation, cast the result:

```julia
using PormG.Functions: Cast, Concat, Value

# Season 2020, round 7 → the text '202007' → the integer 202007 (rounds 1–9 only, for the padding)
M.Race.objects.filter("year" => 2020, "round__@lt" => 10).
    values("raceid", "season_round" => Cast(Concat("year", Value("0"), "round"), "integer"))
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

The part is case-insensitive (`"year"` and `"YEAR"` are the same). `YEAR`, `MONTH`, `DAY`, `HOUR`,
`MINUTE`, `SECOND`, `DOW`, `DOY`, `WEEK`, `ISOYEAR` and `ISODOW` run on both engines, numbered as
PostgreSQL numbers them. Any other PostgreSQL `EXTRACT` field raises `BackendCapabilityError` on
SQLite — see [PostgreSQL](../postgres.md).

A part that is not an `EXTRACT` field at all raises `InvalidValueError` when the expression is
built, on both engines. The field is a keyword in the SQL and cannot be a bind parameter, so PormG
only ever writes a spelling from its own list, never the text it was given. The accepted fields are
`CENTURY`, `DAY`, `DECADE`, `DOW`, `DOY`, `EPOCH`, `HOUR`, `ISODOW`, `ISOYEAR`, `JULIAN`,
`MICROSECONDS`, `MILLENNIUM`, `MILLISECONDS`, `MINUTE`, `MONTH`, `QUARTER`, `SECOND`, `TIMEZONE`,
`TIMEZONE_HOUR`, `TIMEZONE_MINUTE`, `WEEK` and `YEAR`. PostgreSQL's plural and abbreviated
synonyms (`years`, `mon`, `hr`, …) are not accepted — spell the field.

To change the result type, wrap the extract in `Cast`. `EPOCH` is fractional, so PormG leaves it
uncast by default:

```julia
using PormG.Functions: Cast, Extract

# PostgreSQL: seconds since 1970 for each race date, as a bigint
M.Race.objects.values("raceid", "start_epoch" => Cast(Extract("date", "epoch"), "bigint"))
```

### `ToChar` — Format as String

```julia
using PormG.Functions: ToChar

query = M.Race.objects
query.values(
    "formatted_date" => ToChar("date", "YYYY-MM")
)
```

`ToChar` renders `to_char(x, …)` on PostgreSQL and `strftime(…)` on SQLite, and every format in
the table below produces the **same text on both engines** for a given instant. PormG spells the
format for each engine itself: `HH` is the 24-hour clock on both, and the `T` separator and the
`.SSS` milliseconds render as written.

| `format` | renders as |
|---|---|
| `"YYYY"`, `"MM"`, `"DD"`, `"HH"`, `"MI"`, `"SS"` | one component: `2009`, `03`, `29`, `06`, `00`, `00` |
| `"YYYY-MM"`, `"YYYY-MM-DD"` | `2009-03`, `2009-03-29` |
| `"DD/MM/YYYY"`, `"DD-MM-YYYY"` | `29/03/2009`, `29-03-2009` |
| `"HH:MI"`, `"HH:MI:SS"`, `"HH:MI:SS.SSS"` | `06:00`, `06:00:00`, `06:00:00.000` |
| `"YYYY-MM-DD HH:MI:SS"`, `"YYYY-MM-DD HH:MI:SS.SSS"` | `2009-03-29 06:00:00`, `2009-03-29 06:00:00.000` |
| `"YYYY-MM-DDTHH:MI:SS"`, `"YYYY-MM-DDTHH:MI:SS.SSS"` | `2009-03-29T06:00:00`, `2009-03-29T06:00:00.000` |

```julia
# The 2009 Australian Grand Prix started at 06:00 UTC — the same string on either engine
query = M.Race.objects
query.filter("raceid" => 1)
query.values("start" => ToChar("start_at", "YYYY-MM-DDTHH:MI:SS.SSS"))
query.list(:dict)   # [Dict(:start => "2009-03-29T06:00:00.000")]
```

!!! warning "Any other format is PostgreSQL-only"
    A format outside the table is passed to `to_char` as written — a native template such as
    `"HH12:MI AM"` works on PostgreSQL — and raises `BackendCapabilityError` on SQLite, naming
    the supported formats. On PostgreSQL `to_char` renders a `timestamptz` in the session time
    zone, which PormG opens in UTC. Do not override it with `-c TimeZone=…` in the connection's
    `options`, or the two engines will disagree on the hour.

---

## Case / When Expressions

`Case` and `When` enable SQL `CASE WHEN ... THEN ... ELSE ... END` expressions.

Plain Julia values — including strings — can be passed to `then`, `otherwise`, and `default` directly.
No `Value()` wrapper is required.

!!! note
    If no branch of a `Case` matches and it has no `default`, the expression returns `NULL`.
    Always provide a fallback when the column must be non-null.

A `When` with no `otherwise` is a `Case` branch, not a value. Used on its own, for example
`Count(When("positionorder" => 1, then = 1))` or `"c" => When(…)` in `values`, it raises
`QueryBuildError` when the query is built: alone it would render `WHEN … THEN …` with no `ELSE` and no
`END`, which neither engine parses. Give it its own `otherwise`, or put it in a `Case` with a `default`.

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
LIMIT $5
-- parameters: [16, "Yes", "No", 2023, 5]
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

For more complex conditions, combine `Case`/`When` with `Q()` for boolean logic and `F()` for field references. An arithmetic `F` expression is not a `When` condition: `When(F("laps") - 50, …)` is refused, and `When((F("laps") - 50) > 0, …)` is the spelling (see [Arithmetic is not a condition](field_expressions.md#Arithmetic-is-not-a-condition)). The same goes for a function whose result is not boolean: `When(Lower("surname"), …)` is refused, and `When(Lower("surname") == "senna", …)` is the spelling.

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
       SUM(CASE WHEN ("race"."date" <= (("driver"."dob" + make_interval(days => $1::integer)))::date
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

### A Column as the Branch Value

`then`, `default` and `otherwise` take a column expression as well as a value. A plain value is
bound as a parameter; `F("points")` renders as the column itself, so the branch returns each row's
own value. That turns the conditional count above into a conditional **sum**:

```julia
using PormG: F
using PormG.Functions: Case, When, Sum

# Points each driver scored in the races they won, 2009 season
query = M.Result.objects
query.filter("raceid__year" => 2009)
query.values(
    "driverid__surname",
    "win_pts" => Sum(Case([When("positionorder" => 1, then = F("points"))], default = 0))
)
query.filter("win_pts__@gt" => 0)
query.order_by("-win_pts")
df = query |> DataFrame
```

Generated SQL (PostgreSQL):
```sql
SELECT "Tb_1"."surname" AS driverid__surname,
       SUM(CASE WHEN "Tb"."positionorder" = $1 THEN "Tb"."points" ELSE $2::bigint END) AS win_pts
FROM "result" AS "Tb"
INNER JOIN "driver" AS "Tb_1" ON "Tb"."driverid" = "Tb_1"."driverid"
INNER JOIN "race"   AS "Tb_2" ON "Tb"."raceid"   = "Tb_2"."raceid"
WHERE "Tb_2"."year" = $3
GROUP BY 1
HAVING SUM(CASE WHEN "Tb"."positionorder" = $4 THEN "Tb"."points" ELSE $5::bigint END) > $6
ORDER BY "win_pts" DESC NULLS FIRST
```

Output:
```
6×2 DataFrame
 Row │ driverid__surname  win_pts
─────┼────────────────────────────
   1 │ Button                55.0
   2 │ Vettel                40.0
   3 │ Webber                20.0
   4 │ Hamilton              20.0
   5 │ Barrichello           20.0
   6 │ Räikkönen             10.0
```

`THEN "Tb"."points"` carries no placeholder: the branch is a column, not a value. Button's `55.0`
is his six 2009 wins, one of them the half-points Malaysian Grand Prix. Arithmetic works in the
branch too — `then = F("points") * 2` binds the `2` in its place in the SQL text, after the
condition's own value.

The column in the branch is part of the projection, so it groups like one: beside an aggregate it
must sit inside the aggregate (as `F("points")` does here, inside `Sum`) or be listed in
`values()` — see
[A Column Beside an Aggregate in One Expression](filters_and_aggregates.md#A-Column-Beside-an-Aggregate-in-One-Expression).

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
LIMIT $4
-- parameters: [2010, 10, 8, 5]
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
LIMIT $1
-- parameters: [10]
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