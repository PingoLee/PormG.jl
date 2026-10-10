## `Cast` to a scaled `numeric(p, s)` is refused when PostgreSQL would round and SQLite would not (#1040)

- **Version**: Unreleased
- **PormG ref**: #1040, #1087 ; `src/querybuilder/projection_types.jl` (`_numeric_cast_scale`, `_scale_divergent_operand`, `_precision_overflow_operand`, `_cast_divergent_operand`), `src/querybuilder/functions.jl` (`_cast_divergent_refusal`)
- **Recorded**: 2026-10-08
- **Severity**: breaking. A `Cast` to `numeric(p, s)` (or an `output_field` of one on `Coalesce`/`Greatest`/`Least`) over an operand with more than `s` fractional digits raises `QueryBuildError` where it used to render, and so does a `Cast` of a literal too large for `p` (#1087).

### What changed

PostgreSQL rounds a value cast to `numeric(p, s)` to `s` digits, half away from zero, and
`numeric(p)` to a whole number. SQLite reads the type name as NUMERIC affinity only and keeps every
digit. So a filter, a `GROUP BY` or a comparison over the cast saw rounded values in production and
unrounded ones on SQLite. Measured on PostgreSQL 16.15 and SQLite 3.45.1:

| expression | PostgreSQL | SQLite |
|---|---|---|
| `Cast(<float> 1.5, "numeric(10,0)")` | `2` | `1.5` |
| `Cast(<float> 1.555, "numeric(10,2)")` | `1.56` | `1.555` |
| `Cast(<text> '1.555', "numeric(10,2)")` | `1.56` | `1.555` |
| `Round(<float> 2.675, 2)` / `1.555` / `1.005` | `2.68` / `1.56` / `1.01` | `2.67` / `1.55` / `1.0` |
| `Round(x)`, `Cast(x, "numeric")` | same on both | same on both |

Now refused, when the query is built, on both engines: a cast to `numeric(p, s)`, `decimal(p, s)`,
`dec(p, s)` or `numeric(p)` of a float, a float literal with more than `s` places (#1050 narrowed this from every non-whole literal), a function PostgreSQL computes as
`numeric` (`Avg`, `Round(x, d)` with `d` above `s`, …), a decimal with more places than `s` or of unknown scale, text,
or a JSON value (a whole document or a key lookup).

Also refused (#1087): a `Cast` to `numeric(p, s)` of a literal that does not fit it. Rounded to `s`
places, it needs more than `p - s` digits before the point: `Cast(Value(100), "numeric(3,2)")`, or
`9.999`, which rounds to `10.00`. PostgreSQL raises a numeric field overflow and SQLite stores the
value as it is.

Unchanged: an unscaled `"numeric"`/`"decimal"` or `DecimalField()` target, and an operand that has
nothing to round: an integer (a literal one still has to fit `p`, #1087), `Round(x)`, `Floor(x)`, `Ceil(x)`, a `DecimalField` with at most `s`
places (and `Max`/`Min`/`Abs`/`Coalesce` of one), a `Decimal` literal with at most `s` digits, a
`Float64` literal with at most `s` places (`Value(1.5)` at scale 2, #1050), whatever its count of
significant digits. PostgreSQL converts a float to `numeric` at 15 of them, so a 16th digit differs
and PostgreSQL is the less exact side; that is documented rather than refused (#1087).

Not checked, as for #1028: `Case(…; output_field = "numeric(p,s)")`, whose value is a branch, and an
operand PormG cannot type (an untyped `Case`; a `Subquery` is classified by its projection since
#1124). PostgreSQL still rounds those. Nor is
the overflow of a column or a computed value, which depends on the row: PostgreSQL raises on a row
too large for `p` and SQLite answers it. The literal of a `Coalesce`, `Greatest` or `Least` with an
`output_field` is not checked for overflow either: it is one candidate value among the operands.

### Who this affects

Code that casts a float, text or a computed number to a scaled numeric in SQL. Measured on
2026-10-08: **0** `Cast(` call sites to a scaled numeric and **0** numeric `output_field` call sites
in the consuming apps' Julia code.

### How to find the calls to migrate

```bash
grep -rniE '(numeric|decimal|dec) *\( *[0-9]' --include=*.jl src/ test/
```

Read each hit that is a `Cast` type or an `output_field`. Running the query is the definitive
check: the refusal message names the operand and cites #1040.

### Migrate your app

```julia
# ✗ before — 1.555 reads 1.56 on PostgreSQL and 1.555 on SQLite
M.Result.objects.values("resultid", "pts" => Cast("points", "numeric(10,2)"))
# ✓ after — keep the value on both engines with an unscaled numeric, and round in Julia
df = M.Result.objects.values("resultid", "pts" => Cast("points", "numeric")) |> DataFrame
df.pts = round.(Float64.(df.pts); digits = 2)

# ✓ or round to the scale first: Round(x, d) has at most d places on both engines (#1061)
M.Result.objects.values("resultid", "pts" => Cast(Round("points", 2), "numeric(10,2)"))

# ✓ and give a literal a precision that holds it (#1087)
M.Result.objects.values("resultid", "cap" => Cast(Value(100), "numeric(5,2)"))
```

`Round(x, d)` renders each engine's own `ROUND`, as Django's does. It rounds the decimal form on
PostgreSQL and the binary double on SQLite, so only a decimal tie can differ, in its last digit:
`2.675` gives `2.68` on one and `2.67` on the other. That is documented, not refused.
