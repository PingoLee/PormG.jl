# Functions and Dates

This page covers field modifiers, SQL functions, and date-oriented querying.

## Date Functions vs Date Operators

In PormG, date-related modifiers can appear in both `values()` and `filter()`:

- In `values()`, they transform the selected value.
- In `filter()`, they become part of the predicate.

```julia
query = M.Race.objects
query.values("raceid", "date", "date__@year", "date__@month", "date__@day")
df = query |> DataFrame

query.filter("date__@year" => 2023)
query.filter("date__@month__@gte" => 6)
```

## Date Component Filtering

```julia
query = M.Race.objects
query.filter("date__@year" => 1991)
query.values("date__@year", "date__@month", "date__@day", "rows" => Count("raceid"))
query.order_by("date__day")
df = query |> DataFrame
```

## Date Format Filtering

```julia
using Dates

query = M.Race.objects
query.filter("date__@yyyy_mm" => "1991-10")

query = M.Race.objects
query.filter("date__@date" => "1991-10-20")

query = M.Race.objects
query.filter("date__@date" => Date(1991, 10, 20))
```

## Mathematical Functions

PormG supports math functions both through `__@` modifiers and explicit function calls.

```julia
query = M.Driver.objects
query.values(
    "driverid",
    "rounded_id" => "driverid__@round",
    "sqrt_val" => "driverid__@sqrt",
    "custom_pow" => Power("driverid", Value(2)),
    "precise_round" => Round(Value(10.556), 2)
)
query.filter("driverid" => 1)
df = query |> DataFrame
```

For cross-database tests, avoid examples that depend on ambiguous floating-point half-rounding.

## Logical and Conditional Functions

Useful scalar and logical functions include:

- `Coalesce`
- `Greatest`
- `Least`
- `NullIf`
- `Case`
- `When`

```julia
using PormG.QueryBuilder: Case, When, Value

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

## Combining Functions with Conditions

`Case` and `When` can also use `Q()` and `F()` for richer logic.

```julia
using PormG.QueryBuilder: Case, When, Sum, Q, F

query = M.Result.objects
query.filter("driverid__forename" => "Mika")
query.values(
    "raceid__circuitid__name",
    "under_30_victories" => Sum(
        Case(
            When(
                Q(
                    F("raceid__date") <= F("driverid__dob") + 10957,
                    "positionorder" => 1
                ),
                then = 1
            ),
            default = 0
        )
    )
)
df = query |> DataFrame
```