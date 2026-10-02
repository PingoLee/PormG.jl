## Interval arithmetic: SQLite computes on milliseconds; PostgreSQL types the result (#881)

- **Version**: Unreleased
- **Recorded**: 2026-10-02
- **PormG ref**: #881; `src/querybuilder/execution.jl` (`_render_interval_left`, `_render_interval_right`,
  `_render_interval_shift`, `_finalize_render`), `src/querybuilder/types.jl` (`_IntervalMs`),
  `src/Dialect.jl` (`_sqlite_interval_ms`, `_sqlite_interval_text`)
- **Severity**: behavior change. Most rows below turn a SQLite refusal or a silently wrong SQLite
  value into the right one. Two change what PostgreSQL reads back, and one SQLite shape is refused.

### What changed

On SQLite an interval (a timestamp difference, or a `DurationField` column inside arithmetic) is
computed as a whole number of milliseconds, and only the finished value becomes the stored
`HH:MM:SS` text. On PostgreSQL the SQL is unchanged, but interval arithmetic is now typed as an
interval, so it reads back as one.

| Expression | before | after |
|---|---|---|
| `d > Hour(1)`, `d < d2`, `F("time") < d` on **SQLite** (`d` = `F("start_at") - F("date")`) | `QueryBuildError` | a numeric comparison |
| `d + d`, `d * 2`, `2 * d`, `d / 2`, `F("points") * d`, `d + Hour(1)`, `d + F("time")` on **SQLite** | `QueryBuildError` | the interval, read back as a `Dates.CompoundPeriod` |
| `F("date") + d`, `F("start_at") - F("time")`, `d + F("date")` on **SQLite** | `QueryBuildError` | the shifted timestamp |
| `F("time") * 2`, `F("time") + F("time")` on **SQLite** | a number (the leading hours, doubled) | the interval |
| `(d + d) > Hour(1)` on **PostgreSQL** | `QueryBuildError` (the sum was untyped, so the duration was "not against an interval") | an interval comparison |
| `d + d`, `d * 2`, `F("time") * 2`, `d + Hour(1)` projected on **PostgreSQL** | the driver's own value (a `Period`, or a `CompoundPeriod`) | always a `Dates.CompoundPeriod` |
| `F("date") + F("time")`, `F("date") + d` projected on **PostgreSQL** | the driver's own value | a timestamp read like a `DateTimeField(type = "TIMESTAMP")` column |
| `F("time") + 1` on **SQLite** | a number (1 added to the leading hours) | `QueryBuildError`, as PostgreSQL has no `interval + integer` |
| `d == Hour(6)` on **SQLite** | compared the text | compares milliseconds, which matches the same rows |

Still refused on SQLite: a month or a year added to a difference (no fixed length), an extremum over a
`DurationField` combined with an interval (`Max("time") + d`), and a window function inside an
interval. `order_by` on a projected difference, `Max`/`Min`/`Sum`/`Avg` over one, and a bare
`DurationField` compared with a duration (`F("time") > Minute(2)`) still use the stored text.

### How to find the calls to migrate

`F(...)` arithmetic with another column or a number:

```bash
grep -rnP 'F\("[^"]+"\)\)?\s*[-+*/]\s*(F\(|\d)' src/
```

A hit matters if one side is a `DurationField` or a timestamp difference, and if either the app read
the projected value back on PostgreSQL by its Julia type, or the query runs on SQLite.

### Migrate your app

```julia
# ✗ before: on PostgreSQL a projected `d * 2` could arrive as a bare Period
gap = row[:double_gap]::Dates.Hour
# ✓ after: it is always a CompoundPeriod; compare durations with ==, never ===
row[:double_gap] == Dates.Hour(12)

# ✗ before: a workaround that avoided comparing a difference on SQLite
filter((F("start_at") - F("date")) == Hour(6))
# ✓ after: ordering works on both engines
filter((F("start_at") - F("date")) > Hour(6))
```
