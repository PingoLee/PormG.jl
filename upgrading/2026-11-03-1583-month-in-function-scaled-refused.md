## A month inside a function, scaled by a fraction or divided, raises `QueryBuildError` on PostgreSQL (#1583)

- **Version**: 0.10.0
- **PormG ref**: #1583 ; `src/column_ir.jl` (`CInterval.calendar`), `src/querybuilder/expression_kind.jl` (`_literal_kind`, `_unify_kinds`), `src/querybuilder/expression_render.jl` (`_calendar_scale_refused`)
- **Recorded**: 2026-11-03
- **Severity**: behavior change on PostgreSQL only. A `Month` or a `Year` literal among a function's values (a `Case` branch, a `Lag` `default`, a `Subquery` that projects one), then multiplied by a factor that is not whole or divided, built and returned a value. It now raises `QueryBuildError` when the query is built. SQLite and MySQL are unchanged.

### What changed

A month has 28 to 31 days, so 1.5 months, or a month over 2, has no single answer. PostgreSQL computes
one anyway, by spreading the fraction at 30 days a month: `interval '1 month' * 1.5` is
`1 mon 15 days`. That is its convention, not what a month means. #1576 refused it for a month PormG
could see in `F` arithmetic. #1583 made "may hold a month" part of the interval's type, so the rule
now also sees a month through a function, a window function or a subquery.

Here `time` is a `DurationField` and `grid` an `IntegerField` on `Lap_times`. All rows are on
PostgreSQL:

| expression | before | now |
|---|---|---|
| `Case(When("grid" => 1, then = Month(1)), default = F("time")) * 1.5` | builds; a `grid = 1` row reads `1 mon 15 days` | `QueryBuildError` at build |
| the same `Case` divided, `/ 2` | builds; `15 days` | `QueryBuildError` at build |
| `Lag("time", over = WindowOver(order_by = ["lap"]), default = Month(1)) * 1.5` | builds; the first row reads `1 mon 15 days` | `QueryBuildError` at build |
| `Coalesce(Subquery(<one row projecting Value(Month(1))>), F("time")) * 1.5` | builds | `QueryBuildError` at build |
| any of these times a whole number (`* 2`, `* F("grid")`) | builds | builds, unchanged |
| `F("time") * 1.5`, `Max(F("time")) * 1.5` (a stored interval) | builds | builds, unchanged |

On SQLite and MySQL, a month inside a function already raised: an interval there has no month. The
error type there is unchanged.

### Who this affects

PostgreSQL code that puts a `Month` or a `Year` among a function's values and then scales the result
by a float, a decimal with places, or arithmetic that is not whole, or divides it.

### How to find the calls to migrate

```bash
grep -rnE '(Month|Year|Quarter)\(' --include=*.jl . | grep -E 'Case|When|Lag|Lead|default|Subquery|Value\('
```

For each hit, check whether the function's result is then multiplied by something other than an
integer, or divided.

### Migrate your app

Say how long the duration is. A month of fixed length is a number of days. A whole number of months
scales exactly.

```julia
# ✗ before: built; PostgreSQL read 1.5 months as 1 month and 15 days
q = M.Lap_times.objects
q.values("x" => Case(When("grid" => 1, then = Month(1)), default = F("time")) * 1.5)

# ✓ after: a duration of fixed length, which any number scales
q = M.Lap_times.objects
q.values("x" => Case(When("grid" => 1, then = Day(30)), default = F("time")) * 1.5)
```
