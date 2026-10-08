## `Cast` to a scaled `numeric(p, s)` is refused when PostgreSQL would round and SQLite would not (#1040)

- **Version**: Unreleased
- **PormG ref**: #1040 ; `src/querybuilder/projection_types.jl` (`_numeric_cast_scale`, `_scale_divergent_operand`, `_cast_divergent_operand`), `src/querybuilder/functions.jl` (`_cast_divergent_refusal`)
- **Recorded**: 2026-10-08
- **Severity**: breaking. A `Cast` to `numeric(p, s)` (or an `output_field` of one on `Coalesce`/`Greatest`/`Least`) over an operand with more than `s` fractional digits raises `QueryBuildError` where it used to render.

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
`dec(p, s)` or `numeric(p)` of a float, a float literal with more than `s` places or more than 15
significant digits (#1050 narrowed this from every non-whole literal), a function PostgreSQL computes as
`numeric` (`Avg`, `Round(x, 2)`, …), a decimal with more places than `s` or of unknown scale, text,
or a JSON value (a whole document or a key lookup).

Unchanged: an unscaled `"numeric"`/`"decimal"` or `DecimalField()` target, and an operand that has
nothing to round: an integer, `Round(x)`, `Floor(x)`, `Ceil(x)`, a `DecimalField` with at most `s`
places (and `Max`/`Min`/`Abs`/`Coalesce` of one), a `Decimal` literal with at most `s` digits, a
`Float64` literal with at most `s` places and 15 significant digits (`Value(1.5)` at scale 2, #1050).

Not checked, as for #1028: `Case(…; output_field = "numeric(p,s)")`, whose value is a branch, and an
operand PormG cannot type (an untyped `Case`, a `Subquery`). PostgreSQL still rounds those.

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

# ✓ or round to a whole number in SQL, which agrees on both engines
M.Result.objects.values("resultid", "pts" => Cast(Round("points"), "numeric(10,0)"))
```

`Round(x, 2)` is not a way out: it rounds the float's decimal form on PostgreSQL and the binary
double on SQLite, so `2.675` gives `2.68` on one and `2.67` on the other.
