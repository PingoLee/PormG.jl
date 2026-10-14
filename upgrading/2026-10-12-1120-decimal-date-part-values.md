## A `Decimal` date-part value is checked by its digits: a fraction is `InvalidValueError`, a whole one binds (#1120)

- **Version**: 0.8.0
- **PormG ref**: #1120 ; `src/Models.jl` (`_format_period_sql`, `_decimal_integer`), `src/querybuilder/filter_operators.jl` (`_year_bucket_bounds`)
- **Recorded**: 2026-10-12
- **Severity**: behavior. A `Decimals.Decimal` value for a date part (`@year`, `@month`, `@hour`, `@week`, …) raised a raw `ArgumentError`, or blamed the year range, where it now raises `InvalidValueError(:format)` for a fraction and binds for a whole number.

### What changed

A `Decimal` is an `AbstractFloat` with no `isinteger` of its own. Base's float `isinteger` says a
fraction with enough places (`1e-30`, `3.0000000000000000000001`) is whole, and the conversions after
it parse the decimal's text, which fails on any point. So a `Decimal` date-part value either raised an
error that is not a `PormGError` or gave the wrong reason. Whether it is whole is now read from its
digits.

| call | before | after |
|---|---|---|
| `filter("date__@month" => Decimal(0, 30, -1))` (`3.0`) | `ArgumentError: invalid BigInt: "3.0"` | binds `3`, as `3` does |
| `filter("date__@month" => Decimal(0, big(30000000000000000000001), -22))` (`3.0000000000000000000001`) | `ArgumentError: invalid BigInt` | `InvalidValueError` "not a valid month" (`:format`), as `3.5` gets |
| `filter("date__@hour" => Decimal(0, 1, -30))` (`1e-30`) | `ArgumentError: invalid BigInt` | `InvalidValueError` (`:format`) |
| `filter("date__@year" => Decimal(0, 20240, -1))` (`2024.0`) on a `DateField` | `ArgumentError: invalid base 10 digit '.'` | binds the year `2024`, as `2024` does |
| `filter("date__@year" => Decimal(0, big(20240000000000000000000000001), -25))` on a `DateField` | `InvalidValueError` "The year is out of the range a date bound can express" | `InvalidValueError` "not a whole year" (`:format`) |

A `Decimal` with no fractional digits (`Decimal(0, 3, 0)`) and a `3.5` were already handled, and
still are.

### Who this affects

Code that passes a `Decimals.Decimal` as a date-part filter value, and code that catches
`ArgumentError` around one. Such a value usually comes from a `DecimalField` read back from the
database.

### How to find the calls to migrate

```bash
grep -rnE '__@(year|quarter|quadrimester|month|week|week_day|iso_week_day|day|dow|doy|hour|minute|second)' --include=*.jl .
```

For each match, check whether the value can be a `Decimal`.

### Migrate your app

Nothing to change for a whole value: it now binds. Catch `PormG.InvalidValueError` rather than
`ArgumentError` around a value that may be a fraction.
