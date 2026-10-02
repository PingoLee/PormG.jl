## `Coalesce`/`Greatest`/`Least` raise with fewer than two arguments (#859)

- **Version**: Unreleased
- **PormG ref**: #859 ; `src/querybuilder/functions.jl` (`_check_operand_count`)
- **Recorded**: 2026-10-01
- **Severity**: breaking (narrow). A call with fewer than two arguments used to build, and now raises `QueryBuildError` when the expression is built.

### What changed

One argument is never useful to these three functions, because the result is the argument itself.
It was not harmless either. SQLite's `max(x)` and `min(x)` are scalar only with two or more
arguments. With one argument they are the aggregates, so a one-argument `Greatest` collapsed the
whole result to a single row:

| call | PostgreSQL before | SQLite before | after, both engines |
|---|---|---|---|
| `Greatest(x)`, `Least(x)` | `x` on every row | `MAX(x)` / `MIN(x)`: **one row**, with no `GROUP BY` and no warning | raises `QueryBuildError` |
| `Coalesce(x)` | `x` on every row | fails at the database: SQLite's `coalesce` needs two arguments | raises `QueryBuildError` |
| no arguments | fails at the database | fails at the database | raises `QueryBuildError` |

Two or more arguments behave exactly as before. Django's `Coalesce`, `Greatest` and `Least` refuse
fewer than two expressions in the same way.

### Who this affects

Apps that call one of the three functions with a single argument, or with a computed argument list
that can hold one element. Before the change, the consuming apps were measured at **0** call sites
of any of the three (code search; the `coalesce` hits there are Julia's own `Base.coalesce`).

### How to find the calls to migrate

```bash
grep -rnE '(Coalesce|Greatest|Least)\(' --include='*.jl' <your-app>/src
```

Look for calls with one argument, and for a splat (`Greatest(cols...)`) whose list can be that short.
A test run surfaces every remaining one, since the error is raised when the expression is built:
`Greatest must take at least two expressions; got 1.`

### Migrate your app

Write the argument itself:

```julia
# ✗ before: on SQLite this was the aggregate MAX(points), a single row
M.Result.objects.values("resultid", "best" => Greatest("points"))

# ✓ after: the column, on every row
M.Result.objects.values("resultid", "best" => F("points"))
```

For a computed list, branch on its length, or append a neutral second operand that cannot win, as
in `Greatest(cols..., 0)` for non-negative values. That operand also changes a `NULL` result: both
engines skip a `NULL` argument (#844), so a single `NULL` column then gives `0`, not `NULL`.
