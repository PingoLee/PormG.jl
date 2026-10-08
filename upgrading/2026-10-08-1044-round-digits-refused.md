## `Round(x, n)` is refused over a value with more than `n` places, and a negative `n` is refused (#1044)

- **Version**: Unreleased
- **PormG ref**: #1044 ; `src/querybuilder/functions.jl` (`Round`, `_round_divergent_refusal`), `src/querybuilder/select_nodes.jl` (`_render_function_body`), reusing `src/querybuilder/projection_types.jl` (`_scale_divergent_operand`)
- **Recorded**: 2026-10-08
- **Severity**: breaking. `Round(x, n)` with `n > 0` over an operand that can carry more than `n` places raises `QueryBuildError` where it used to render, and `Round(x, n)` with `n < 0` raises `InvalidValueError` when it is built.

### What changed

`Round(x, n)` renders `ROUND(x::numeric, n)` on PostgreSQL, which rounds the value's decimal form (a
float converts to `numeric` at 15 significant digits), and `ROUND(x, n)` on SQLite, which rounds the
binary double. So a projection, a filter, a `GROUP BY` or a comparison on it saw different values in
production and on SQLite. Measured on PostgreSQL 16.15 and SQLite 3.45.1:

| expression | PostgreSQL | SQLite |
|---|---|---|
| `Round(<float> 2.675, 2)` / `1.555` / `1.005` | `2.68` / `1.56` / `1.01` | `2.67` / `1.55` / `1.0` |
| `Round(<float> 1.15, 1)` | `1.2` | `1.1` |
| `Round(<numeric(10,3)> 2.675, 2)` | `2.68` | `2.67` (SQLite holds a REAL) |
| `Round(<float> 1.5 / 0.1 / 2.25, 2)` | same on both | same on both |
| `Round(<numeric(10,3)> 1.15, 2)` | same on both, but refused all the same: the declared scale, not the value, decides | |
| `Round(125, -1)` | `130` | `125.0` (SQLite takes a negative `n` as 0) |
| `Round(x)` | same on both | same on both |

Now refused, when the query is built, on both engines: `Round(x, n)` with `n > 0` over a float column,
a float literal with more than `n` places, arithmetic over a float, a function PostgreSQL computes as
`numeric` (`Avg`, `Sqrt`, `Mod` of a float, …), a `DecimalField` with more than `n` places, a nested cast to a
wider scale, text, or a JSON value. This is the operand set #1040 refuses for a cast to
`numeric(p, n)`, read by the same classifier. `Round(x, n)` with `n < 0` is refused for every operand,
an integer included.

Unchanged: `Round(x)` and `Round(x, 0)`, and `Round(x, n)` over an integer, a whole number (`Floor`,
`Ceil`, `Round(x)`), a `DecimalField` with at most `n` places, or a literal that fits `n` places.

Not checked, as for #1028 and #1040: an operand PormG cannot type (an untyped `Case`, a
`Subquery`). The engines can still round those differently.

### Who this affects

Code that rounds a float, an average or another computed number to decimal places in SQL. Measured
on 2026-10-08: **0** `Round(` call sites in the consuming apps' Julia code.

### How to find the calls to migrate

```bash
grep -rnE 'Round\([^)]*, *-?[0-9]+\)' --include=*.jl src/ test/
```

The pattern misses a call that spans lines or nests parentheses, so also read every `Round(` hit.
Running the query is the definitive check: the refusal message names the operand and cites #1044.

### Migrate your app

```julia
# ✗ before — 2.675 reads 2.68 on PostgreSQL and 2.67 on SQLite
M.Result.objects.values("resultid", "pts" => Round("points", 2))
# ✓ after — fetch the value and round it in Julia: one answer whichever engine served the row.
# RoundNearestTiesAway rounds an exact half away from zero as both engines did (Julia's default
# rounds it to even: round(0.125; digits = 2) is 0.12). Julia's answer need not match either
# engine's old one: 2.675 gives 2.68 as PostgreSQL did, 1.005 gives 1.0 as SQLite did.
df = M.Result.objects.values("resultid", "points") |> DataFrame
df.pts = round.(df.points, RoundNearestTiesAway; digits = 2)

# ✓ or round to a whole number in SQL, which agrees on both engines
M.Result.objects.values("resultid", "pts" => Round("points"))

# ✗ before — 130 on PostgreSQL, 125.0 on SQLite
M.Driver.objects.values("bucket" => Round("number", -1))
# ✓ after
df = M.Driver.objects.values("number") |> DataFrame
df.bucket = round.(df.number, RoundNearestTiesAway; digits = -1)   # 125 → 130.0
```
