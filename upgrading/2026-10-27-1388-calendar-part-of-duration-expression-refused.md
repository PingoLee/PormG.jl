## A calendar part over a duration expression is refused on every engine (#1388)

- **Version**: Unreleased
- **PormG ref**: #1388 ; `src/querybuilder/select_nodes.jl` (`_check_temporal_operand`, `_check_temporal_expression`), `src/Dialect.jl` (`_duration_calendar_refusal`)
- **Recorded**: 2026-10-27
- **Severity**: behavior change. On PostgreSQL and SQLite, `Extract` with a calendar part (`year`, `month`, `quarter`, `dow`, `week`, `doy` and every other part except the time-of-day, `TIMEZONE` and `EPOCH` ones), or `ToChar(…, "YYYY-MM")`, over a duration expression used to build. On SQLite it returned a value read from the duration as if it were a date, and on PostgreSQL it returned the interval's own fields (`0` for a year, `1` for a quarter, `"0000-00"`) or failed at the server. It now raises `QueryBuildError` when the query is built.

### What changed

#1070 refused every part except `EPOCH` over a `DurationField` column, because a duration has no
calendar date. It read the column's field, so an expression that is a duration got through: a
timestamp difference, interval arithmetic, or a `Sum` or `Avg` of a duration. The check now asks the
expression's type for the calendar parts, and refuses a duration on every engine.

Measured on the F1 fixture before the change, for the 8252 results with a fastest lap:

| expression on `Result` | SQLite before | PostgreSQL before | now, every engine |
|---|---|---|---|
| `values("v" => Extract(F("fastestlaptime") * 2, "year"))` | `2000` | `0` | `QueryBuildError` |
| `values("v" => Extract(F("fastestlaptime") * 2, "month"))` | `1` | `0` | `QueryBuildError` |
| `values("v" => Extract(F("fastestlaptime") * 2, "quarter"))` | `BackendCapabilityError` | `1` | `QueryBuildError` |
| `values("v" => Extract(F("fastestlaptime") * 2, "dow"))` | `6` | fails at the server | `QueryBuildError` |
| `values("v" => ToChar(F("fastestlaptime") * 2, "YYYY-MM"))` | `"2000-01"` | `"0000-00"` | `QueryBuildError` |
| the same parts over `Sum("fastestlaptime")` or `F("start_at") - F("date")` on `Race` | as above, or `NULL` above 24 hours | as above | `QueryBuildError` |
| `Extract(F("fastestlaptime") * 2, "hour")`, `"minute"`, `"second"` | built | built | builds, unchanged |
| `Extract(F("fastestlaptime") * 2, "epoch")` | refused (no `EPOCH`) | built | unchanged |
| `Extract(F("raceid__date") + F("fastestlaptime"), "year")`, a timestamp | built | built | builds, unchanged |

The clock parts (`hour`, `minute`, `second`, `milliseconds`, `microseconds`) of a duration expression
are not changed here. Whether they keep building is still open on #1388.

On MySQL (unreleased), these shapes were already refused (#1324). The message now says a duration has
no calendar date, instead of naming `Extract(d, "epoch")`.

### Who this affects

Code that applies a calendar part to a duration expression:
- `Extract(<expr>, "year" | "month" | "quarter" | "dow" | …)` or `ToChar(<expr>, "YYYY-MM")`;
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
`Extract(d, "epoch")` on PostgreSQL and MySQL.
