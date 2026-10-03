## SQLite sums, averages and compares intervals by their milliseconds in functions too (#900)

- **Version**: Unreleased
- **Recorded**: 2026-10-02
- **PormG ref**: #900; `src/querybuilder/build_helpers.jl` (`_render_function_typed`),
  `src/querybuilder/execution.jl` (`_render_interval_operand`, `_interval_ms_candidate`),
  `src/querybuilder/build_query.jl` (`_having_alias_formatter`)
- **Severity**: behavior change, mostly on SQLite: a silently wrong value or order becomes the one
  PostgreSQL returns, and `Abs` over an interval is refused there. PostgreSQL renders the same SQL.
  Three things change there: the Julia type of `Sum`/`Avg`, and of `Greatest`/`Least`/`Coalesce`
  over a difference; a filter on a `Sum`/`Avg` alias over an interval, which raised a
  `MethodError` for a duration; and a number against that alias, now a `FilterError` (last two table
  rows).

### What changed

#894 made SQLite sort and compare an interval by its milliseconds for `order_by`, alias filters and
`Max`/`Min`, and left these functions on the `[-]HH:MM:SS[.f]` text. `Sum` and `Avg` added up the
text's leading number, so they counted whole hours and dropped the minutes and seconds of every
value. `Greatest`/`Least` and `Coalesce` compared the text, which is wrong at 100 hours and above and
for negative values. They now compute on the milliseconds (`d` = `F("start_at") - F("date")`):

| Expression, on **SQLite** | before | after |
|---|---|---|
| `Sum("time")`, `Sum(d)` | the sum of the whole hours, a number | the total duration |
| `Avg("time")`, `Avg(d)` | the mean of the whole hours, a number | the mean duration, rounded to the millisecond |
| `Greatest("q1", "q2")`, `Least(d, d2)` over intervals | the last or first value in text order | the longest or shortest |
| `Coalesce("q1", "q2")` ordered or filtered by its alias | sorted and compared the text | sorts and compares the milliseconds |
| `order_by` / a filter on a `Sum`/`Avg` alias over an interval | compared the number of hours | compares the milliseconds |
| `Abs("time")`, `Abs(d)` | the absolute value of the leading hours | `QueryBuildError`, since PostgreSQL has no `abs(interval)` either |
| `Sum`/`Avg` over an interval, and `Greatest`/`Least`/`Coalesce` over a difference, read back (**both engines**) | SQLite: a number or a `String`. PostgreSQL: the driver's value (a `CompoundPeriod`, or a bare `Period` on Postgres.jl) | a `Dates.CompoundPeriod` |
| `values("total" => Sum("time")); filter("total__@gt" => Hour(1))` on **PostgreSQL** | `MethodError` from the number formatter | compares the intervals, binding `"01:00:00"` as a `Max("time")` alias does |
| `filter("total__@gt" => 500)` on that alias | SQLite compared whole hours | `FilterError` on both engines, as for a `Max("time")` alias: the value must be a duration |
| a filter on an alias of a number times an interval (`"t" => F("points") * d`, and `Sum` of it) | PostgreSQL: `MethodError` for a duration. SQLite: a number compared with the text, always true | a duration binds as `"01:00:00"`, and a number is a `FilterError` on both engines |

`Greatest`/`Least`/`Coalesce` use the milliseconds only when every argument is a difference,
interval arithmetic, a `DurationField` or one of these functions (a `NULL` literal aside). With any
other argument they render as before: a text column, a `CTE(...)` column, or a duration literal
(`Coalesce("time", Value(Hour(0)))`, which is still typed but orders as text). So does a declared
`output_field`.

These are unchanged, on purpose:

- `Case` over durations, and a window value function over a duration (`Lag("time", …)`), still sort
  the text on SQLite. Their values are right, and only ordering or filtering on them at 100 hours and
  above, or on negative values, is text order.
- An aggregate over an interval used inside arithmetic (`Sum(d) / Count("id")`,
  `Sum("time") - Max("time")`) still computes on the text on SQLite, so it reads whole hours. Project
  `Avg(d)`, or the `Sum` and the `Count` as separate values, instead.

### How to find the calls to migrate

```bash
grep -rnP '\b(Sum|Avg|Greatest|Least|Coalesce|Abs)\(' src/
```

A hit matters only where its argument is a `DurationField` or a timestamp difference. On SQLite such
code may read a `Sum`/`Avg` as a number of hours, or compensate for the text order. Read the value as
a `Dates.CompoundPeriod` and compare it with `==`. An `Abs` over an interval now raises
`QueryBuildError` on SQLite. It always failed on PostgreSQL. Write `Greatest(d, d * -1)` instead.

### Migrate your app

```julia
# ✗ before: on SQLite the total lap time counted whole hours, so apps summed the milliseconds column
total = M.Lap_times.objects.
    filter("raceid" => 1, "driverid" => 1).
    values("driverid", "total" => Sum("milliseconds")).
    list(:dict)[1][:total]
total_time = Dates.Millisecond(total)
# ✓ after: the duration itself, on both engines
total_time = M.Lap_times.objects.
    filter("raceid" => 1, "driverid" => 1).
    values("driverid", "total" => Sum("time")).
    list(:dict)[1][:total]::Dates.CompoundPeriod

# ✗ before: the magnitude of a gap took the absolute value of its leading hours on SQLite
query.values("raceid", "gap" => Abs(F("start_at") - F("date")))
# ✓ after: the same on both engines
query.values("raceid", "gap" => Greatest(F("start_at") - F("date"), (F("start_at") - F("date")) * -1))
```
