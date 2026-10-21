## A duration literal compares and reads back as an interval (#1316)

- **Version**: Unreleased
- **PormG ref**: #1316 ; `src/querybuilder/field_resolution.jl` (`_infer_parameter_sql_type`), `src/querybuilder/expression_render.jl` (`_projected_interval_source`)
- **Recorded**: 2026-10-21
- **Severity**: behavior change, both engines. An ordering filter on a `Value(<duration>)` alias keeps the rows the durations' order keeps, where it kept the rows their text's order kept, with no error. On PostgreSQL a projected `Value(<duration>)`, and a `Case` whose branches are duration literals, read back as a `Dates.CompoundPeriod` where they read back as a `String`. On SQLite such a filter on a literal with a fraction of a millisecond raises `QueryBuildError` where it built.

### What changed

A duration literal projected under an alias (`values("v" => Value(Hour(100)))`) and filtered by an
ordering lookup (`"v__@gt" => Hour(99)`) compared two texts:

- on SQLite, the `HH:MM:SS` text, which sorts in the duration's order only below 100 hours and for
  non-negative values (`"100:00:00" > "99:00:00"` is false);
- on PostgreSQL, two parameters with no type, which PostgreSQL compares as text
  (`"5 hours" > "40 hours"` is true).

On SQLite both sides now bind as milliseconds, as a timestamp difference's alias does (#894, #907).
On PostgreSQL every duration literal binds as an `interval` (`$1::interval`), as a date literal binds
as a `date`: a `Value(...)`, a `Case` branch, a `Coalesce` or `Greatest` argument, a `Lag` default.
So it compares as an interval and reads back as one. Beside a `DurationField` column PostgreSQL
already typed the literal from the column, so those values do not change.

A literal with a fraction of a millisecond (`Nanosecond(1500)`) has no millisecond form on SQLite,
so an ordering filter on its alias is refused there, as it is for a `Case` over durations (#1311).
Equality (`==`, `@in`) still compares its text. `order_by` on such an alias orders one constant, and
is unchanged.

Measured on the F1 fixture, `values("resultid", "v" => Value(a))` filtered by `"v__@gt" => b` and
`"resultid__@lte" => 5`, rows kept (5 when the comparison holds):

| `a` > `b` | engine | before | now |
|---|---|---|---|
| `Hour(100)` > `Hour(99)` | both | 0 | 5 |
| `Hour(5)` > `Hour(40)` | PostgreSQL | 5 | 0 |
| `Hour(-1)` > `Hour(-2)` | both | 0 | 5 |
| `Hour(2)` > `Hour(1)` | both | 5 | 5 |

Read back on PostgreSQL:

| projection | before | now |
|---|---|---|
| `"v" => Value(Hour(1) + Minute(30))` | `"1 hour, 30 minutes"` (`String`) | `Dates.CompoundPeriod` (1 hour, 30 minutes) |
| `"c" => Case(When("resultid" => 1, then = Hour(100)), default = Minute(90))` | `"100 hours"` (`String`) | `Dates.CompoundPeriod` (100 hours) |

### Who this affects

Code that projects a duration literal with `Value(...)` and filters its alias with `@gt`, `@gte`,
`@lt`, `@lte` or `@range`. On PostgreSQL, code that reads a projected duration literal, or a `Case`
whose branches are all duration literals, and expects a `String`.

### How to find the calls to migrate

```bash
grep -rnE 'Value\((Dates\.)?(Week|Day|Hour|Minute|Second|Millisecond|Microsecond|Nanosecond|Month|Year)' --include=*.jl src/ test/
grep -rnE 'then *= *(Dates\.)?(Week|Day|Hour|Minute|Second|Month|Year)\(' --include=*.jl src/ test/
```

For each match, check whether the projected value is read as text, or whether its alias is filtered.

### Migrate your app

```julia
# ✗ before — kept no row on either engine; PostgreSQL read the Case back as the String "100 hours"
q = M.Result.objects
q.values("resultid", "v" => Value(Hour(100)))
q.filter("v__@gt" => Hour(99))

# ✓ after — the same call keeps every row, and a duration literal reads back as a
# Dates.CompoundPeriod on both engines. Code that parsed the PostgreSQL text reads the period instead:
r = M.Result.objects
r.values("c" => Case(When("resultid" => 1, then = Hour(100)), default = Minute(90)))
Dates.toms.((r |> DataFrame).c)   # was a vector of String on PostgreSQL
```
