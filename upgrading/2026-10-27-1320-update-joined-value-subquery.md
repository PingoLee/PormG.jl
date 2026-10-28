## `update` writes `Joined(…)`, `Subquery(…)` and `Value(…)` into any field, number fields included (#1320)

- **Version**: 0.9.0
- **PormG ref**: #1320 ; `src/querybuilder/value_validation.jl` (`_SetExpression`, `_refuse_expression_value`), `src/querybuilder/execution_write.jl` (`update`), `src/querybuilder/expression_render.jl`
- **Recorded**: 2026-10-27
- **Severity**: behavior change. Calls that raised `InvalidValueError` now build: a `Joined` column into a number field, and a `Subquery` or a `Value(x)` into any field. A few calls raise a different error: a non-number `Joined` column or `Subquery` into a number field raises #1297's `QueryBuildError`; on SQLite, one with more decimal places than a `DecimalField` raises #1279's; a `CTE` column into a number field raises update's own no-WITH refusal (#433); `create` and the bulk writers refuse a `Joined` column or a `Subquery` with #1283's message.

### What changed

`update` writes an `F` expression or a SQL function into its SET clause as SQL. A `Joined(alias, column)`
from a `cjoin_on` built the same way into a text field, but into a number field the field's literal
check refused it before any SQL, even when the column holds a number. A bare `Subquery(…)` and a
`Value(x)` were refused into every field, text included.

| call, `grid` an `IntegerField` | before | after |
|---|---|---|
| `update("grid" => Joined("d", "driverid"))` | `InvalidValueError` ("expected Int64, … got JoinedReference") | `SET "grid" = "d"."driverid"`, through UPDATE … FROM |
| `update("grid" => Subquery(standings))` | `InvalidValueError` | `SET "grid" = (SELECT …)`, its values bound in SET |
| `update("positiontext" => Subquery(…))` | `InvalidValueError` | builds |
| `update("grid" => Value(3))`, `update("positiontext" => Value("P1"))` | `InvalidValueError` | the same statement as `update("grid" => 3)`: `Value(x)` writes `x` |
| `update("grid" => Joined("d", "dob"))`, a `Subquery` over a UUID | `InvalidValueError` | `QueryBuildError`, #1297's refusal of a non-number |
| `update("points" => Joined("d", "height"))`, more places than `points` | `InvalidValueError` | builds on PostgreSQL and MySQL; `QueryBuildError` on SQLite (#1279) |
| `update("grid" => CTE("ev", "grid"))` | `InvalidValueError` | `QueryBuildError`: `update` emits no WITH clause (#433), as into a text field |
| `create("grid" => Joined(…))`, `bulk_insert` with a `Subquery` cell | `InvalidValueError`, the literal check's text | `InvalidValueError`, #1283's text naming the type |
| `create("grid" => Value(3))` | `InvalidValueError` | unchanged |

`Value(x)` wraps a literal, so `update` writes `x`: the same checks, the same formatter and the same
bind as the bare literal. `update("grid" => Value(Date(2021, 3, 28)))` raises the `InvalidValueError`
that `update("grid" => Date(2021, 3, 28))` raises. A `Value` around an expression
(`Value(F("grid"))`, `Value(Subquery(…))`) still raises `InvalidValueError`, now one that says `Value`
wraps a literal: write the expression itself.

### Who this affects

Code that catches `InvalidValueError` around an `update` that writes a `Joined` column, a `Subquery`
or a `Value(…)`: the call now runs, or raises `QueryBuildError` where the value is no number. Code that
catches it around `create` or a bulk writer given a `Joined` column or a `Subquery` still catches it,
but the message changed.

### How to find the calls to migrate

```bash
grep -rnE '\.update\(.*(Joined|Subquery|Value)\(' --include=*.jl src/ test/
grep -rnE 'catch.*InvalidValueError' --include=*.jl src/ test/
```

### Migrate your app

```julia
# ✗ before — a workaround for the refusal: wrap the column in a function
query.update("grid" => Coalesce(Joined("d", "driverid"), 0))
# ✓ after — write the column itself
query.update("grid" => Joined("d", "driverid"))
```
