## A duration or a time cast to a date is refused on SQLite, which read it as a time on 2000-01-01 (#1325)

- **Version**: 0.9.0
- **PormG ref**: #1325 ; `src/querybuilder/engine_departures.jl` (`_MEANING_DEPARTURES`), `src/querybuilder/projection_types.jl` (`_cast_divergent_operand`)
- **Recorded**: 2026-10-27
- **Severity**: behavior change. Expressions that built on SQLite now raise `QueryBuildError` when the query is built. PostgreSQL is unchanged.

### What changed

A duration and a time of day have no calendar date, so their cast to a date is an error. PostgreSQL
has no `interval::date` and no `time::date`: the query fails when it runs, and that error is the
meaning. SQLite renders the cast as `date(x)`, which reads the stored `HH:MM:SS` text as a time on
January 1st, 2000: a lap time of `00:01:27.452` became `2000-01-01`, a duration of exactly 24 hours
`2000-01-02`, and a longer one NULL. That was a silent different answer.

PormG now refuses the cast on SQLite and builds it as before on PostgreSQL, where the server still
raises. The refusal covers a `DurationField` column, its `Sum` or `Avg`, interval arithmetic
(`F("start_at") - F("start_at")`), a duration literal, a `TimeField` column, `Max`/`Min` of one and a
`Time` literal, cast to `"date"` or `DateField()`, as a `Cast` type and as the `output_field` of
`Case`, `Coalesce`, `Greatest` and `Least`. A date or a timestamp cast to a date builds on every
engine, as before. SQLite already refused a cast to `"timestamp"` or `"time"` of any value. MySQL
refuses the same casts.

Examples on `Result`, whose `fastestlaptime` is a `DurationField`, and `Race`, whose `time` is a
`TimeField`:

| expression | PostgreSQL | SQLite before | SQLite now |
|---|---|---|---|
| `Cast("fastestlaptime", "date")` | raises when the query runs | `2000-01-01` (NULL past 24 hours) | raises `QueryBuildError` (#1325) |
| `Cast("time", "date")` | raises when the query runs | `2000-01-01` | raises `QueryBuildError` (#1325) |
| `Cast("start_at", "date")` | the date | the date | builds, unchanged |

### Who this affects

On SQLite, code that casts a `DurationField`, a `TimeField` or an expression of one to a date, or
passes a date `output_field` over one. The same code already failed on PostgreSQL.

### How to find the calls to migrate

```bash
grep -rnE 'Cast\(|output_field' --include=*.jl src/ test/ | grep -E '"date"|DateField\(\)'
```

For each match, check whether the operand is a duration or a time.

### Migrate your app

```julia
# ✗ before — 2000-01-01 on SQLite, an error on PostgreSQL; now raises QueryBuildError on SQLite (#1325)
q = M.Race.objects
q.values("d" => Cast("time", "date"))

# ✓ after — take the date from a date or a timestamp column
q = M.Race.objects
q.values("d" => Cast("start_at", "date"))
```
