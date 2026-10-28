## A calendar or time-of-day part over a duration expression is refused on every engine (#1388)

- **Version**: 0.9.0
- **PormG ref**: #1388 ; `src/querybuilder/select_nodes.jl` (`_check_temporal_operand`, `_check_temporal_expression`, `_duration_part_refusal`), `src/Dialect.jl` (`_duration_calendar_refusal`)
- **Recorded**: 2026-10-27
- **Severity**: behavior change. On PostgreSQL and SQLite, `Extract` with any part except `EPOCH` (a calendar part such as `year`, `month`, `quarter`, `dow`; a time-of-day part, `hour`, `minute`, `second`, `milliseconds`, `microseconds`; a `TIMEZONE` part), or `ToChar(…, "YYYY-MM")`, over a duration expression used to build. On SQLite a calendar part returned a value read from the duration as if it were a date, and a time-of-day part `NULL` for a duration over 24 hours or a negative one. On PostgreSQL a calendar part returned the interval's own fields (`0` for a year, `1` for a quarter, `"0000-00"`) or failed at the server, and a time-of-day part a component that depends on how the interval was formed. It now raises `QueryBuildError` when the query is built.

### What changed

#1070 refused every part except `EPOCH` over a `DurationField` column, because a duration has no
calendar date and no time of day. It read the column's field, so an expression that is a duration got
through: a timestamp difference, interval arithmetic, or a `Sum` or `Avg` of a duration. The check now
asks the expression's type, and refuses a duration under the same parts as the column, on every
engine.

Measured on the F1 fixture before the change, for the 8252 results with a fastest lap:

| expression on `Result` | SQLite before | PostgreSQL before | now, every engine |
|---|---|---|---|
| `values("v" => Extract(F("fastestlaptime") * 2, "year"))` | `2000` | `0` | `QueryBuildError` |
| `values("v" => Extract(F("fastestlaptime") * 2, "month"))` | `1` | `0` | `QueryBuildError` |
| `values("v" => Extract(F("fastestlaptime") * 2, "quarter"))` | `BackendCapabilityError` | `1` | `QueryBuildError` |
| `values("v" => Extract(F("fastestlaptime") * 2, "dow"))` | `6` | fails at the server | `QueryBuildError` |
| `values("v" => ToChar(F("fastestlaptime") * 2, "YYYY-MM"))` | `"2000-01"` | `"0000-00"` | `QueryBuildError` |
| the same parts over `Sum("fastestlaptime")` or `F("start_at") - F("date")` on `Race` | as above, or `NULL` above 24 hours | as above | `QueryBuildError` |
| `Extract(F("fastestlaptime") * 2, "hour")`, `"minute"`, `"second"` | built | built | `QueryBuildError` |
| `Extract(F("fastestlaptime") * 2, "epoch")` | refused (no `EPOCH`) | built | unchanged |
| `Extract(F("raceid__date") + F("fastestlaptime"), "year")`, a timestamp | built | built | builds, unchanged |

The time-of-day parts were measured on the same fixture, SQLite against PostgreSQL, before the change:

| expression | SQLite before | PostgreSQL before |
|---|---|---|
| `Extract(F("fastestlaptime") * 2, "hour")` on `Result`, every row | equal to PostgreSQL | the interval's hours |
| `Extract(Sum("fastestlaptime"), "hour")` over every lap, `208:11:49.316` | `NULL` | `208` |
| `Extract(F("start_at") - F("fp1_date"), "hour")` on `Race`, 62 hours | `NULL` | `14` (`2 days 14:00:00`) |
| `Extract(F("fastestlaptime") * -1, "hour")` | `NULL` | `0` |

SQLite answered only below 24 hours, and PostgreSQL's hour depends on whether the interval was split
into days, so a time-of-day part has no single meaning over a duration.

On MySQL (unreleased), these shapes were already refused (#1324). A calendar part's message now says a
duration has no calendar date, and a time-of-day part's says it has no time of day and names
`Extract(d, "epoch")` for its seconds.

### Who this affects

Code that applies a calendar or time-of-day part to a duration expression:
- `Extract(<expr>, "year" | "month" | "quarter" | "dow" | "hour" | "minute" | "second" | …)` or
  `ToChar(<expr>, "YYYY-MM")`;
- where the expression is a difference of two timestamps, arithmetic on a `DurationField`, or a `Sum`
  or `Avg` of one.

A `DurationField` column was already refused (#1070), through `Extract` and the `__@` transforms alike.

### How to find the calls to migrate

```bash
grep -rnE '\b(Extract|ToChar)\(' --include=*.jl src/ test/
```

For each match, check whether its operand is a timestamp difference, arithmetic on a duration, or a
`Sum`/`Avg` of a duration.

### Migrate your app

A duration has no calendar part to read. If you meant the date the duration reaches, add it to a date
or a timestamp first. The result is a timestamp, and its calendar parts build:

```julia
# ✗ before — SQLite read 2000 for every row, PostgreSQL 0
q = M.Result.objects
q.filter("raceid__year" => 2009)
q.values("driverid__surname", "y" => Extract(F("fastestlaptime") * 2, "year"))

# ✓ after — the year of the date plus the duration
q = M.Result.objects
q.filter("raceid__year" => 2009)
q.values("driverid__surname", "y" => Extract(F("raceid__date") + F("fastestlaptime"), "year"))
```

To read the duration itself, project it (`values("fastestlaptime")`) or read its seconds with
`Extract(d, "epoch")` on PostgreSQL and MySQL. For its hours, divide those seconds:

```julia
# ✗ before — SQLite read NULL for a duration over 24 hours
q = M.Result.objects
q.filter("raceid__year" => 2009)
q.values("driverid__surname", "h" => Extract(F("fastestlaptime") * 2, "hour"))

# ✓ after (PostgreSQL, MySQL) — the duration's seconds, converted in Julia
q = M.Result.objects
q.filter("raceid__year" => 2009)
q.values("driverid__surname", "s" => Extract(F("fastestlaptime") * 2, "epoch"))
```
