## A time of day minus a time of day is a duration on PostgreSQL (#1406)

- **Version**: 0.9.0
- **PormG ref**: #1406 ; `src/querybuilder/expression_kind.jl` (`_temporal_result_kind`), `src/querybuilder/engine_facts.jl` (`_subtracts_times`), `src/querybuilder/expression_render.jl`
- **Recorded**: 2026-10-27
- **Severity**: behavior change. On PostgreSQL, a query over `F(<TimeField>) - F(<TimeField>)` that
  applied a number function or a calendar part to the difference, put it beside a number in
  `Coalesce`, or filtered its projected alias by a number literal, used to build. It now raises
  `QueryBuildError` or `InvalidValueError` when the query is built. The difference itself
  still builds, and it reads back as a `Dates.CompoundPeriod`, like a `DurationField`.

### What changed

PostgreSQL computes `time - time` as an `interval`. PormG did not give the difference a type, so the
checks that read an expression's type did not see a duration:

| on `Race`, PostgreSQL | before | now |
|---|---|---|
| `values("d" => F("time") - F("time"))` | built; read as the driver's value | builds; read as a `Dates.CompoundPeriod` |
| `Extract(F("time") - F("time"), "year")` and every calendar part | built, read `0` | `QueryBuildError` (a duration has no calendar date, #1388) |
| `Round`, `Floor`, `Sqrt`, … over the difference | built, failed at the server | `QueryBuildError` (a duration is not a number, #1324) |
| `Coalesce(F("time") - F("time"), "year")` | built | `QueryBuildError` (an interval beside a number, #1321) |
| `filter("d__@gt" => 10)` on the projected difference | built, failed at the server | `InvalidValueError`: compare it with a duration (`Minute(1)`) |
| `Extract(F("time") - F("time"), "epoch")` | built | builds, unchanged |

SQLite and MySQL refuse arithmetic on a time of day (#1323), so nothing changes there.

### How to find the calls to migrate

```bash
grep -rnE 'F\("[a-z_]+"\) - (F\(|")' --include=*.jl src/ test/
```

For each match, check whether both sides are `TimeField` columns.

### Migrate your app

```julia
# ✗ before — PostgreSQL built it and read 0 for every race
q = M.Race.objects
q.filter("year" => 2009)
q.values("raceid", "y" => Extract(F("time") - F("time"), "year"))

# ✓ after — read the duration's seconds, or compare it with a duration
q = M.Race.objects
q.filter("year" => 2009)
q.values("raceid", "s" => Extract(F("time") - F("time"), "epoch"))
```
