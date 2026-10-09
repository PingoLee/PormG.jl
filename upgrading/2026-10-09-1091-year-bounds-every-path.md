## `@year` and `@yyyy_mm` values are checked on every path, and a JSON path refuses `Inf` / `NaN` (#1091)

- **Version**: Unreleased
- **PormG ref**: #1091 ; `src/Models.jl` (`format_year_sql`, `format_yyyy_mm`), `src/querybuilder/functions.jl` (`_EXTRACT_PART_ROWS`), `src/querybuilder/filter_operators.jl` (`_render_sargable_date_range`, `_year_bucket_bounds`, `_yyyy_mm_bucket_bounds`, `_json_numeric_rhs`)
- **Recorded**: 2026-10-09
- **Severity**: behavior. A `@year` outside 1–9999 under `=` or `@in`, a `Bool` year, and a `@yyyy_mm` month that does not exist now raise `InvalidValueError` on every column and lookup, where most paths bound them and matched nothing. A JSON path compared with `Inf` or `NaN` raises too. A `DateField` year comparison outside 1–9999 now builds instead of raising.

### What changed

The `@year` and `@yyyy_mm` checks ran only inside the range rewrite PormG applies to `=`, `<`,
`<=`, `>`, `>=` on a plain `DateField`. Off that path (`@in`, a `DateTimeField`) the value went
through a plain number or text formatter and was bound as given: a year of `99999`, `true` as year
`1`, a month `"1991-13"`. None of them can match a row, so the query returned nothing. Each now has
its own formatter, with the split the other date parts use (#1088). The range is checked under `=`
and `@in`; a value that is no year or no month is refused under every lookup. For a comparison, a
year is a bound: a `DateField` comparison whose year no date can express skips the rewrite and
compares the extracted year, so it selects no rows, or every row, on both engines.

A JSON path compared with a non-finite float bound it as given. PostgreSQL's `numeric` orders `NaN`
above every number, while SQLite binds a `NaN` as `NULL`, so the engines returned different rows. A
numeric column already refused it.

| call | before | after |
|---|---|---|
| `filter("date__@year__@in" => [99999])` on a `DateField` | matched nothing | `InvalidValueError` (`kind = :range`) |
| `filter("start_at__@year" => 99999)` on a `DateTimeField` | matched nothing | `InvalidValueError` (`kind = :range`) |
| `filter("start_at__@year" => true)` | year `1` | `InvalidValueError` (`kind = :type`) |
| `filter("start_at__@yyyy_mm" => "1991-13")`, and with `@lt` | matched nothing | `InvalidValueError` (`kind = :format`), on every lookup |
| `filter("date__@yyyy_mm__@lte" => "1991-13")` on a `DateField` | `InvalidValueError` (`kind = :range`) | `InvalidValueError` (`kind = :format`) |
| `filter("date__@year__@gte" => 1991.7)` on a `DateField` | `InvalidValueError` (`kind = :range`) | `InvalidValueError` (`kind = :format`) |
| `filter("date__@year__@gte" => 99999)` on a `DateField` | `InvalidValueError` | builds: the extracted year, no rows (`@lt`: every row) |
| `values("y" => Extract("date", "YEAR")); filter("y" => 99999)` | matched nothing | `InvalidValueError` (`kind = :range`); `"y__@gte" => 99999` builds |
| `filter(F("start_at__@year") == 99999)` | matched nothing | `InvalidValueError` (`kind = :range`), with #1083 |
| `values("m" => Max(Extract("date", "YEAR"))); filter("m__@gte" => 2009.5)` | compared with 2009.5 | `InvalidValueError` (`kind = :format`) |
| `filter("payload__wins__@gte" => NaN)`, `=> Inf`, and `"payload__wins" => NaN` | bound as given; rows differ per engine | `InvalidValueError` (`kind = :range`) |

### Who this affects

- Code that filters `@year` with `=` or `@in` and a year that can fall outside 1–9999, or with a
  `Bool` or a fraction: on a timestamp column, with `@in` on a date column, through an alias of
  `Extract(…, "YEAR")`, or as `F("…__@year") == …`.
- Code that filters `@yyyy_mm` with a label whose month can be outside `01`–`12`.
- Code that compares a JSON path with a float that can be `Inf` or `NaN`.
- Code that matched `kind == :range` for a fractional year or a non-existent month: it is `:format`.

### How to find the calls to migrate

```bash
grep -rnE '__@(year|yyyy_mm)' --include=*.jl src/ test/                 # pairs, F("…__@year"), aliases
grep -rnE 'Extract\([^)]*"(YEAR|year)"' --include=*.jl src/ test/        # an Extract alias or comparison
grep -rn 'JSONField' --include=*.jl src/      # the JSON columns; then grep each one's "<column>__…" filters
```

For a `@year` or `@yyyy_mm` filter, check whether the value can come from outside the range (user
input, a computed value). For a JSON path, check whether a float operand can be non-finite. Running
the query is the definitive check: the refusal names the field and the kind.

### Migrate your app

```julia
# ✗ before — a year taken from a request, which can be out of range: matched nothing
M.Race.objects.filter("start_at__@year" => year)
# ✓ after — validate it first, or catch the refusal
1 <= year <= 9999 || throw(ArgumentError("year must be 1 to 9999"))
M.Race.objects.filter("start_at__@year" => year)

# ✗ before — a NaN threshold was bound; PostgreSQL and SQLite returned different rows
query = M.Result.objects
query.filter("payload__wins__@gte" => threshold)
# ✓ after — decide what a missing threshold means, and filter only on a finite one
query = M.Result.objects
isfinite(threshold) && query.filter("payload__wins__@gte" => threshold)
```
