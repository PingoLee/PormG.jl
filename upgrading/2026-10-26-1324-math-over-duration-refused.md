## A number function over a duration is refused on every engine (#1324)

- **Version**: Unreleased
- **PormG ref**: #1324 ; `src/querybuilder/functions.jl` (`_operand_domain`), `src/querybuilder/projection_types.jl` (`_check_operand_domain`, `_duration_math_refusal`), `src/querybuilder/engine_facts.jl` (`_duration_seconds_spelling`), `src/querybuilder/select_nodes.jl`, `src/Dialect.jl` (`_mysql_part_of_interval_refusal`)
- **Recorded**: 2026-10-26
- **Severity**: behavior change. On SQLite, `Round`, `Floor`, `Ceil`, `Sqrt`, `Exp`, `Ln`, `Power` and `Mod` over a `DurationField`, or over an expression that is a duration, used to build and return a number computed on the duration's `HH:MM:SS` text. They now raise `QueryBuildError` when the query is built. On PostgreSQL the same query used to fail at the server and now fails at build time. `Abs` over a duration was already refused on SQLite; it is now refused on PostgreSQL too, with a new message.

### What changed

A math function means a number, and a duration is not one. Each engine computed something else. For
a 2009 fastest lap of `1:27.706`:

| expression on `Result` | SQLite before | PostgreSQL before | now, every engine |
|---|---|---|---|
| `values("v" => Round(F("fastestlaptime")))` | `0.0` | fails at the server | `QueryBuildError` |
| `values("v" => Sqrt(F("fastestlaptime")))` | `NULL` | fails at the server | `QueryBuildError` |
| `values("v" => Floor(F("fastestlaptime")))`, `Ceil(…)` | `NULL` | fails at the server | `QueryBuildError` |
| `values("v" => Power(F("fastestlaptime"), 2))`, `Ln(…)`, `Exp(…)`, `Mod(…, 3)` | computed on the text | fails at the server | `QueryBuildError` |
| `filter(Round(F("fastestlaptime")) > 60)` | compares `0.0` | fails at the server | `QueryBuildError` |
| `values("v" => Abs(F("fastestlaptime")))` | `QueryBuildError` | fails at the server | `QueryBuildError`, new message |
| `values("v" => Round(F("fastestlaptime") * 2))`, `Sqrt(Sum("fastestlaptime"))` | computed on the text | fails at the server | `QueryBuildError` |
| `values("v" => Sum("fastestlaptime"))`, `Avg(…)` | built | built | builds, unchanged |

The refusal says why on every engine, and names the spelling that has a meaning where one exists:

- for a duration's seconds, `Extract(d, "epoch")` on PostgreSQL and MySQL, with the function applied
  to that. SQLite has no `EPOCH` part, so there the message says no spelling exists;
- for `Abs`, the magnitude: `Greatest(d, d * -1)`.

`Sum` and `Avg` mean a duration's total and mean, and keep building on every engine.

On MySQL (unreleased), a date part of a duration expression, such as
`Extract(F("start_at") - F("date"), "hour")` or `Extract(Sum("fastestlaptime"), "second")`, is
refused too. MySQL holds the duration as its count of microseconds, and the part would read that count
as a date or a time. `Extract(…, "epoch")` builds there. PostgreSQL and SQLite do not change for these.

### Who this affects

Code that applies `Round`, `Floor`, `Ceil`, `Sqrt`, `Exp`, `Ln`, `Power`, `Mod` or `Abs` to a
`DurationField`, to interval arithmetic (`F("fastestlaptime") * 2`, a timestamp difference), or to a
`Sum` or `Avg` of a duration.

### How to find the calls to migrate

```bash
grep -rnE '\b(Round|Floor|Ceil|Sqrt|Exp|Ln|Power|Mod|Abs)\(' --include=*.jl src/ test/
```

For each match, check whether its operand is a `DurationField`, a difference of two timestamps, a
product of a duration, or a `Sum`/`Avg` of a duration.

### Migrate your app

```julia
# ✗ before — SQLite read 0.0 for every lap
q = M.Result.objects
q.filter("raceid__year" => 2009)
q.values("driverid__surname", "lap_s" => Round(F("fastestlaptime")))

# ✓ after, PostgreSQL and MySQL — round the duration's seconds
q = M.Result.objects
q.filter("raceid__year" => 2009)
q.values("driverid__surname", "lap_s" => Round(Extract("fastestlaptime", "epoch")))
```

On SQLite, read the duration (`values("fastestlaptime")`) and compute on it in Julia.
