## `Round(x, n)` refuses a negative `n` and a text operand; to places it keeps each engine's own `ROUND` (#1044, #1061)

- **Version**: Unreleased
- **PormG ref**: #1044, #1061 ; `src/querybuilder/functions.jl` (`Round`, `_round_text_refusal`), `src/querybuilder/select_nodes.jl` (`_render_function_body`), reusing `src/querybuilder/projection_types.jl` (`_scale_divergent_operand`)
- **Recorded**: 2026-10-08
- **Severity**: breaking. `Round(x, n)` with `n < 0` raises `InvalidValueError` when it is built, and `Round(x, n)` with `n > 0` over text raises `QueryBuildError` when the query is built. Both used to render.

### What changed

`Round(x, n)` to places keeps rendering each engine's own `ROUND`, as Django's `Round` does:
`ROUND(x::numeric, n)` on PostgreSQL, which rounds the exact decimal form, and `ROUND(x, n)` on
SQLite, which rounds the stored double. Those agree except at a decimal tie whose double sits just
below it (`2.675` → `2.68` on PostgreSQL, `2.67` on SQLite), a last-digit difference that is
documented rather than refused (#1061). Two operands change the value itself, not its last digit,
and are now refused on both engines:

| expression | PostgreSQL | SQLite | now |
|---|---|---|---|
| `Round(125, -1)` | `130` | `125.0` (a negative `n` read as 0) | `InvalidValueError` |
| `Round(<text> 'abc', 2)` | error: not a number | `0.0` | `QueryBuildError` |
| `Round(<text> '1.555', 2)` | `1.56` | `1.55` | `QueryBuildError`: cast it first |

A JSON value counts as text. `Round(x)` and `Round(x, n)` over a number are unchanged.

### Who this affects

- Code that rounds to tens, hundreds, … with a negative precision.
- Code that rounds a text column (or a JSON key) holding numbers.

### How to find the calls to migrate

```bash
grep -rnE 'Round\([^)]*, *-[0-9]+\)' --include=*.jl src/ test/
grep -rn 'Round(' --include=*.jl src/ test/
```

For the second, check whether the rounded operand is a text or JSON column.

### Migrate your app

```julia
# ✗ before — 130 on PostgreSQL, 125.0 on SQLite
M.Driver.objects.values("bucket" => Round("number", -1))
# ✓ after — round to tens in Julia
df = M.Driver.objects.values("number") |> DataFrame
df.bucket = round.(df.number, RoundNearestTiesAway; digits = -1)   # 125 → 130.0
```

```julia
# ✗ before — a text column rounded as a number (a non-number errors on PostgreSQL, reads 0 on SQLite)
M.Result.objects.filter("positiontext" => "1").values("x" => Round("positiontext", 1))
# ✓ after — say it is a number
M.Result.objects.filter("positiontext" => "1").values("x" => Round(Cast("positiontext", FloatField()), 1))
```
