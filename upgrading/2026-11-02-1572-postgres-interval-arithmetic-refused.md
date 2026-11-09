## Interval arithmetic with no meaning raises `QueryBuildError` at build on PostgreSQL too (#1572)

- **Version**: 0.10.0
- **PormG ref**: #1572 ; `src/querybuilder/expression_render.jl` (`_render_interval_left`, `_render_interval_right`)
- **Recorded**: 2026-11-02
- **Severity**: behavior change. On PostgreSQL, these shapes built and then failed when the statement ran, with a `StatementError`. They now raise `QueryBuildError` when the query is built, before any SQL is sent. On SQLite and MySQL, a date times or divided by a `DurationField` column now raises too, where it built.

### What changed

Some interval arithmetic has no meaning: an interval plus a number has no unit, and an interval times an
interval is no quantity at all. SQLite and MySQL already refused these shapes when the query was built
(#881, #1130). PostgreSQL rendered them, and then rejected the SQL, because it has no
`interval + bigint`, `interval * interval` or `double precision / interval` operator. Now all three
engines refuse them at build, with the same message, naming the engine at hand.

Here `time` is a `DurationField`, `lap` an `IntegerField`, and `milliseconds` an `IntegerField` on
`Lap_times`:

| expression | before, on PostgreSQL | now, on PostgreSQL |
|---|---|---|
| `F("time") + 5`, `F("time") - F("lap")` (an interval ± a number) | `StatementError` when run | `QueryBuildError` at build |
| `F("lap") + F("time")`, `F("lap") - F("time")` (a number ± an interval) | `StatementError` when run | `QueryBuildError` at build |
| `F("time") * F("time")`, `F("time") / F("time")` | `StatementError` when run | `QueryBuildError` at build |
| `F("milliseconds") / F("time")` (a number divided by an interval) | `StatementError` when run | `QueryBuildError` at build |
| `F("raceid__date") * F("time")`, `/` (a date times an interval) | `StatementError` when run | `QueryBuildError` at build |
| `Max("time") * Max(<a BooleanField>)`, either way round (an interval times a boolean) | `StatementError` when run | `QueryBuildError` at build |
| any of the above, nested under a duration value: `(F("time") + 5) * Hour(1)` | `StatementError` when run | `QueryBuildError` at build |

On SQLite and MySQL every row was already a `QueryBuildError`, except one. A date times or divided by a
stored `DurationField` column built there and multiplied the stored values. It raises
`QueryBuildError` now, as on PostgreSQL.

What has a meaning is unchanged on every engine: an interval times or divided by a number
(`F("time") * 2`, `F("lap") * F("time")`), intervals added or subtracted, and a date shifted by one
(`F("raceid__date") + F("time")`). Comparing a number with an interval is not arithmetic, and keeps
the SQL it had.

A `CTE(...)` column holding a duration is refused in the same shapes as a `DurationField` column, on
the right too (`F("points") + CTE("c", "u")`, #1581), and a number times one scales it as it scales the
column. A bitwise operator on an interval raises `QueryBuildError` as well; that one built in the last
release, and has its own entry (#1581).

### Who this affects

On PostgreSQL, code that builds one of these queries and handles the failure when it runs, by catching
`StatementError` or `DatabaseError`. The query never returned rows, so no result changes. The error now
arrives earlier, from `list()`, `show_query` or any terminal, as a `QueryBuildError`. On SQLite and
MySQL, code that multiplies or divides a date by a `DurationField` column.

### How to find the calls to migrate

```bash
# F arithmetic beside a DurationField column or a timestamp difference
grep -rnE 'F\("[a-z_]+"\) *[-+*/] *(F\(|[0-9])' --include=*.jl .
# catches that test for a run-time failure
grep -rnE 'StatementError|DatabaseError' --include=*.jl .
```

For each hit, check whether one side is a `DurationField` column or a timestamp difference.

### Migrate your app

Say what the arithmetic means. A number of seconds beside an interval is a duration: write it as one.

```julia
# ✗ before: built, then failed on PostgreSQL when it ran
q = M.Lap_times.objects
q.values("slower" => F("time") + 5)
q.list()   # StatementError on PostgreSQL; QueryBuildError on SQLite and MySQL

# ✓ after: five seconds is a duration
q = M.Lap_times.objects
q.values("slower" => F("time") + Second(5))
q.list()
```
