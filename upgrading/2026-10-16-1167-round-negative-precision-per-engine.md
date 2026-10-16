## `Round(x, n)` with a negative `n` rounds to tens on PostgreSQL and is a capability error on SQLite (#1167)

- **Version**: Unreleased
- **PormG ref**: #1167, #1044 ; `src/capabilities.jl` (`negative_round_precision`), `src/querybuilder/functions.jl` (`Round`), `src/querybuilder/select_nodes.jl` (`_render_function_body`), `src/Dialect.jl` (`ROUND`)
- **Recorded**: 2026-10-16
- **Severity**: behavior change. `Round(x, n)` with `n < 0` no longer raises `InvalidValueError` when the expression is built. On PostgreSQL the query builds and rounds to tens, hundreds, …; on SQLite it raises `BackendCapabilityError` when the query is built.

### What changed

A negative precision means rounding to tens, hundreds, …: `Round(125, -1)` is `130`. PostgreSQL's
`ROUND(numeric, -1)` computes that. SQLite's `ROUND` has no negative precision and reads one as 0
(`125.0`). Since #1044 PormG refused the expression on every engine. It is now a row in the backend
capability table, `negative_round_precision`, so only the engine without it refuses, as Django's
`Round` does on SQLite:

| expression | PostgreSQL | SQLite |
|---|---|---|
| `Round("number", -1)` (an integer column, `125`) | `130`, an integer: `ROUND((x)::numeric, -1)::integer` | `BackendCapabilityError` |
| `Round("points", -1)` (a float column, `125.0`) | `130.0`: `ROUND((x)::numeric, -1)` | `BackendCapabilityError` |
| `Round(x, -1)` built, not run | an `FObject`, no error | an `FObject`, no error |

`Round(x)` and `Round(x, n)` with `n ≥ 0` are unchanged.

### Who this affects

- Code that catches the `InvalidValueError` `Round(x, n)` raised for a negative `n`. On SQLite that
  error is now a `BackendCapabilityError`, raised when the query is built, not when `Round` is
  called. On PostgreSQL nothing is raised.

### How to find the calls to migrate

```bash
grep -rnE 'Round\(.*, *-[0-9]' --include=*.jl src/ test/
grep -rn 'InvalidValueError' --include=*.jl src/ test/ | grep -i round
```

### Migrate your app

```julia
# ✗ before — every engine: InvalidValueError when Round is called
try
    M.Driver.objects.values("bucket" => Round("number", -1))
catch e
    e isa InvalidValueError || rethrow()
end
# ✓ after — PostgreSQL rounds to tens; on SQLite the query raises BackendCapabilityError
M.Driver.objects.values("bucket" => Round("number", -1)) |> DataFrame
```
