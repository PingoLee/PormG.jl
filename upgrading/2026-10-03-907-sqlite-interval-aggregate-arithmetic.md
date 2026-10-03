## SQLite computes interval aggregates inside arithmetic, duration literals and `When` conditions in milliseconds (#907)

- **Version**: Unreleased
- **Recorded**: 2026-10-03
- **PormG ref**: #907; `src/querybuilder/execution.jl` (`_render_function_operand_typed`,
  `_render_interval_operand`, `_duration_literal_ms`), `src/querybuilder/build_query.jl`
  (`_render_interval_alias_predicate`), `src/querybuilder/build_helpers.jl` (`_get_filter_query`)
- **Severity**: behavior change, mostly on SQLite: a silently wrong value or row set becomes the one
  PostgreSQL returns, and refusals are lifted or added where PostgreSQL agrees. PostgreSQL renders
  the same SQL for every shape it rendered before. Three things change there: the Julia type of an
  aggregate over an interval inside arithmetic, and of a date shifted by one (`F("date") + Sum(d)`
  reads back as a timestamp); and a filter on the alias of such arithmetic
  (`values("x" => Sum("time") * 2); filter("x__@gt" => Hour(1))`), which raised a `MethodError` from
  the number formatter and now compares intervals (last table rows).

### What changed

#900 gave `Sum`/`Avg`, `Max`/`Min` and `Greatest`/`Least`/`Coalesce` over an interval a millisecond
form on SQLite, but only where the function is projected on its own. Three shapes stayed on the
`[-]HH:MM:SS[.f]` text, which reads whole hours and sorts `"100:00:00"` before `"99:00:00"`. They now
compute on the milliseconds (`d` = `F("start_at") - F("date")`):

| Expression, on **SQLite** | before | after |
|---|---|---|
| `Sum(d) / Count("id")`, `Sum("time") - Max("time")`, `Count("id") * Sum("time")` | the leading hours of the text, divided, subtracted or multiplied: a number | the duration |
| `Count("id") + Sum("time")`, and `-` or `/` | the count combined with the text's leading hours | `QueryBuildError`, as `count + d` is: PostgreSQL has no such operator and fails when the statement runs |
| `Max("time") + d`, `F("date") + Sum(d)` | `QueryBuildError` | the interval, and the shifted timestamp |
| `Coalesce("time", Value(Hour(0)))`, `Greatest(d, Value(Hour(99)))`, ordered or filtered by its alias | sorted and compared the text | sorts and compares the milliseconds; the literal binds as a number of milliseconds |
| `values("t" => Sum("time"), "c" => Case(When(Q("t__@gt" => Hour(1)); then = 1); default = 0))`, and the same over `Max("time")` | compared the text with `"01:00:00"` | compares the milliseconds |
| `values("x" => Sum("time") * 2); filter("x__@gt" => Hour(1))` on **PostgreSQL** | `MethodError` from the number formatter | compares the intervals |
| an aggregate over an interval inside arithmetic, read back (**both engines**) | SQLite: a number or a `String`. PostgreSQL: the driver's value (a `CompoundPeriod`, or a bare `Period` on Postgres.jl) | a `Dates.CompoundPeriod` |

A duration literal with a month, a year or a fraction of a millisecond has no exact millisecond form,
and keeps the function on the text as before. A `When` condition reads the alias's milliseconds only
when the alias comes before the `Case` in `values(...)`.

### How to find the calls to migrate

```bash
grep -rnP '\b(Sum|Avg|Max|Min)\([^)]*\)\s*[-+*/<>]|[-+*/]\s*(Sum|Avg|Max|Min)\(|\b(Greatest|Least|Coalesce)\(.*\bValue\(|\bWhen\(' src/
```

A hit matters only where an argument is a `DurationField` or a timestamp difference. On SQLite such
code may read the result as a number of hours, compensate for the text order, or work around the
`Max("time") + d` refusal. Read the value as a `Dates.CompoundPeriod` and compare it with `==`.

### Migrate your app

```julia
# ✗ before: on SQLite `Sum(d) / Count(…)` divided the text's leading hours, so apps divided in Julia
row = M.Race.objects.
    filter("year" => 2009).
    values("circuitid", "total" => Sum(F("start_at") - F("date")), "n" => Count("raceid")).
    list(:dict)[1]
per_race = Dates.Millisecond(round(Int, Dates.toms(row[:total]) / row[:n]))
# ✓ after: one expression, a duration on both engines
row = M.Race.objects.
    filter("year" => 2009).
    values("circuitid", "per_race" => Sum(F("start_at") - F("date")) / Count("raceid")).
    list(:dict)[1]
row[:per_race]::Dates.CompoundPeriod
```
