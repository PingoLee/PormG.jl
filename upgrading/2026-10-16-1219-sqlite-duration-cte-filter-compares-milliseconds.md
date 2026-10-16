## A filter on a duration CTE column compares its length on SQLite, not its text (#1219)

- **Version**: Unreleased
- **PormG ref**: #1219 ; `src/querybuilder/filter_nodes.jl` (`_is_sqlite_duration_column`)
- **Recorded**: 2026-10-16
- **Severity**: behavior change, SQLite only. A filter on a CTE column that holds a duration can return different rows, and binds milliseconds instead of text. PostgreSQL is unchanged.

### What changed

SQLite stores a duration as text (`HH:MM:SS[.sss]`), and a CTE body leaves one as its text too: a
`DurationField` it projects, and a duration it computes, such as `Sum("fastestlaptime")`. A filter on
the model column has compared milliseconds since #894, because that text sorts wrongly at 100 hours
and above (`"100:00:00"` sorts before `"99:00:00"`) and for negative durations. A filter on the CTE
column compared the text with the value's text, so it returned other rows than the column it was
built from.

It now converts the CTE column to milliseconds and binds the value's milliseconds, as a model column
does. The lookups are the same: `@gt`, `@gte`, `@lt`, `@lte`, `@range`, `@nrange`, and an `F`
right-hand side. Equality and `@in` still compare the stored text, which is exact for a value written
in the canonical form.

Examples on `Result`, whose `fastestlaptime` is a `DurationField`, under
`q.with("r" => body, join_field = "raceid" => "raceid")`:

| body projects | filter | SQLite before | SQLite now |
|---|---|---|---|
| `"fast" => "fastestlaptime"` | `"r__fast__@gt" => Minute(1)` | `"R1_1"."fast" > ?` with `"00:01:00"` | the column's milliseconds `> ?` with `60000` |
| `"fast" => Sum("fastestlaptime")` | `"r__fast__@lt" => Hour(100)` | a total of `"120:00:00"` matched (text order) | it does not match (`432000000 < 360000000` is false) |
| either | `"r__fast" => Minute(1)` | the text, `= ?` with `"00:01:00"` | unchanged |

### Who this affects

On SQLite, code that filters a CTE column holding a duration with an ordering lookup, where a value
is 100 hours or longer, or negative. Shorter non-negative values were already ordered the same way
by their text, so their rows do not change; only the bound value and the SQL do.

### How to find the calls to migrate

```bash
grep -rnE '\.with\(' --include=*.jl src/ test/
```

For each CTE, check whether a column holds a duration and whether a filter orders it (`__@gt`,
`__@lt`, `__@range`, …).

### Migrate your app

```julia
# Before: on SQLite a total of 120 h sorted below 100 h as text and matched
# Now: compared by length, as the model column is; no change is needed to get PostgreSQL's rows
body = M.Result.objects
body.values("raceid", "fast" => Sum("fastestlaptime"))
q = M.Result.objects
q.with("r" => body, join_field = "raceid" => "raceid")
q.filter("r__fast__@lt" => Hour(100))
```
