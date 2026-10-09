## `Round(x, n)` to places renders one double formula on both engines; text and a negative `n` are refused (#1044, #1061)

- **Version**: Unreleased
- **PormG ref**: #1044, #1061 ; `src/querybuilder/functions.jl` (`Round`, `_round_text_refusal`), `src/querybuilder/select_nodes.jl` (`_render_function_body`), `src/Dialect.jl` (`ROUND`'s vector arm), reusing `src/querybuilder/projection_types.jl` (`_scale_divergent_operand`)
- **Recorded**: 2026-10-08
- **Severity**: breaking. `Round(x, n)` with `n > 0` over a value with more than `n` places answers differently on PostgreSQL than before (`1.005` → `1.0`, was `1.01`) and reads back as a `Float64` there (was a `Decimal`). Over text it raises `QueryBuildError`, and `n < 0` or `n > 22` raises `InvalidValueError` when it is built.

### What changed

`Round(x, n)` rendered `ROUND(x::numeric, n)` on PostgreSQL, which rounds the value's decimal form
(a float converts to `numeric` at 15 significant digits), and `ROUND(x, n)` on SQLite, which rounds
the binary double. So a projection, a filter, a `GROUP BY` or a comparison on it saw different values
in production and on SQLite. Measured on PostgreSQL 16.15 and SQLite 3.45.1:

| expression | PostgreSQL | SQLite |
|---|---|---|
| `Round(<float> 2.675, 2)` / `1.555` / `1.005` | `2.68` / `1.56` / `1.01` | `2.67` / `1.55` / `1.0` |
| `Round(<float> 1.15, 1)` | `1.2` | `1.1` |
| `Round(<numeric(10,3)> 2.675, 2)` | `2.68` | `2.67` (SQLite holds a REAL) |
| `Round(125, -1)` | `130` | `125.0` (SQLite takes a negative `n` as 0) |
| `Round(x)` | same on both | same on both |

Now `Round(x, n)` with `n > 0` over a value that can carry more than `n` places (a float column, a
float literal with more places, arithmetic over a float, a function such as `Avg`, `Sqrt` or `Mod`, a
`DecimalField` with more than `n` places, a nested cast to a wider scale, or anything built over a
`Subquery` or a `Case`, bare or inside `Coalesce`, arithmetic and the like) renders one formula. Both engines compute it in the
same IEEE double arithmetic:

```sql
sign(x) * floor(abs(x) * 10^n + 0.5) / 10^n + 0.0
```

It was measured bit for bit equal on PostgreSQL 16.15 and SQLite 3.53.4 over 1,200,020 values with
`n` ∈ {1, 2, 3, 4, 6}, and it equals Julia's `round(x, RoundNearestTiesAway; digits = n)` on every one of
them:

| expression | PostgreSQL, before | SQLite, before | both engines, now |
|---|---|---|---|
| `Round(<float> 2.675, 2)` | `2.68` | `2.67` | `2.68` |
| `Round(<float> 1.555, 2)` | `1.56` | `1.55` | `1.56` |
| `Round(<float> 1.005, 2)` | `1.01` | `1.0` | `1.0` (the double nearest `1.005` is below it) |
| `Round(<float> 1.15, 1)` | `1.2` | `1.1` | `1.2` |
| `Round(<numeric(10,3)> 2.675, 2)` | `2.68` (a `Decimal`) | `2.67` | `2.68` (a `Float64`) |

Its value is a double on both engines, so on PostgreSQL it reads back as a `Float64` where it read
back as a `Decimal`.

Unchanged: `Round(x)` and `Round(x, 0)`, and `Round(x, n)` over an integer, a whole number (`Floor`,
`Ceil`, `Round(x)`), a `DecimalField` with at most `n` places, or a literal that fits `n` places. That
value already has at most `n` places, so it keeps the engine's own `ROUND` and its type. A value
that comes through a `Subquery` or a `Case` takes the formula even when it is an integer, and reads
back as a double, unless a `Cast` (or a `Coalesce`/`Greatest`/`Least` `output_field`) names an
integer type or a `numeric(p, s)` with `s ≤ n` (`Round(Cast(Subquery(q), IntegerField()), 2)` keeps
`ROUND`; wrap a `Case` in a `Cast`).

Refused:

- `Round(x, n)` with `n > 0` over text (a text column, a string literal, a JSON value) raises
  `QueryBuildError` when the query is built. PostgreSQL parses the text as a number, and SQLite reads
  text that is not a number as 0.
- `Round(x, n)` with `n < 0` raises `InvalidValueError` for every operand, an integer included.
- `n > 22` raises `InvalidValueError` too. The formula scales by `10^n` as a double, and PostgreSQL
  raises on an overflow where SQLite returns `Inf`; up to 22 `10^n` is exact and only an `|x|` above
  1e286 could overflow it.

`Cast(Round(x, n), "numeric(p, s)")` with `s ≥ n` now passes the #1040 check for every operand that
renders, since its value has at most `n` places on both engines.

### Who this affects

- Code that rounds a float, an average or another computed number to decimal places in SQL on
  PostgreSQL, and either compares the result against a pinned value (an answer at a decimal tie can
  move, as `1.005` does) or expects a `Decimal` back.
- Code that rounds text to places in SQL.
- Code that uses a negative precision.

Measured on 2026-10-08: **0** `Round(` call sites in the consuming apps' Julia code.

### How to find the calls to migrate

```bash
grep -rnE 'Round\([^)]*, *-?[0-9]+\)' --include=*.jl src/ test/
```

The pattern misses a call that spans lines or nests parentheses, so also read every `Round(` hit.

### Migrate your app

```julia
# ✓ unchanged spelling: the same number on both engines now (a Float64 on PostgreSQL too)
M.Result.objects.values("resultid", "pts" => Round("points", 2))

# ✗ before — read back as a Decimal on PostgreSQL
df.pts .== Decimal("2.68")
# ✓ after — a Float64 on both engines
df.pts .== 2.68

# ✗ before — text rounded to places
M.Driver.objects.values("x" => Round("code", 1))
# ✓ after — say which number it is first
M.Driver.objects.values("x" => Round(Cast("code", FloatField()), 1))

# ✗ before — 130 on PostgreSQL, 125.0 on SQLite
M.Driver.objects.values("bucket" => Round("number", -1))
# ✓ after
df = M.Driver.objects.values("number") |> DataFrame
df.bucket = round.(df.number, RoundNearestTiesAway; digits = -1)   # 125 → 130.0
```
