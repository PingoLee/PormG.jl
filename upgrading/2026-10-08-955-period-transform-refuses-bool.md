## A period transform refuses a `Bool` value instead of reading it as `1` (#955)

- **Version**: Unreleased
- **PormG ref**: #955 ; `src/Models.jl` (`_format_period_sql`)
- **Recorded**: 2026-10-08
- **Severity**: behavior. A `Bool` compared against a period transform raises `InvalidValueError` where it used to bind `1` or `0`.

### What changed

The range-checked period transforms bound their value through `format_number_sql`. That function
maps `true` to `1` on purpose, for a numeric column given a flag. No period is a flag, though:
`"start_at__@hour" => true` silently meant 1 AM, and `"date__@quarter" => true` meant the first
quarter. `false` meant hour `0`, or for a 1-based period it was refused as out of range.

| call | before | after |
|---|---|---|
| `filter("start_at__@hour" => true)` | the 01:00–01:59 rows | `InvalidValueError` |
| `filter("date__@quarter" => true)` | the first quarter | `InvalidValueError` |
| `filter("start_at__@minute__@in" => Any[5, true])` | minutes 5 and 1 | `InvalidValueError` |

It covers every transform with a range: `@quarter`, `@quadrimester`, `@hour`, `@minute`, `@second`,
`@week`, `@week_day` and `@iso_week_day`. An integer, a numeric string and `missing` are unchanged.

### Who this affects

Code that passes a `Bool` to one of those transforms, which was always a mistake that returned rows.
Measured on 2026-10-08: **0** call sites in the consuming apps. None of their 29 transform call
sites uses a period transform.

### How to find the calls to migrate

```bash
grep -rnE '__@(quarter|quadrimester|hour|minute|second|week|week_day|iso_week_day)"\s*=>\s*(true|false)' --include=*.jl src/ test/
```

The pattern only sees a literal. A `Bool` held in a variable shows up when the query runs, as an
`InvalidValueError` naming the transform.

### Migrate your app

```julia
# ✗ before — `true` bound as 1
M.Race.objects.filter("start_at__@hour" => true)
# ✓ after — write the period you mean
M.Race.objects.filter("start_at__@hour" => 1)
```
