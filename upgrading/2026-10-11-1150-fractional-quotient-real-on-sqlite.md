## A decimal or mixed quotient is a fraction on SQLite too, and `NullIf(<integer>, <fraction>)` stays an integer on PostgreSQL (#1150)

- **Version**: 0.8.0
- **PormG ref**: #1150 ; `src/querybuilder/expression_render.jl` (`_division_sql`), `src/querybuilder/expression_kind.jl` (`_operation_kind`), `src/Dialect.jl` (`NULLIF`), `src/querybuilder/projection_types.jl`, `src/querybuilder/engine_departures.jl`
- **Recorded**: 2026-10-11
- **Severity**: behavior change. On SQLite, a quotient over a `DecimalField`, a declared decimal or a value mixing whole numbers and fractions returns its fraction (`4.5`) on the rows where it returned an integer (`4`): in a projection, a filter (which can select different rows), an `update()` and an aggregate. On PostgreSQL, `NullIf(<integer>, <fraction>)` returns the integer's type, so a quotient over it divides as integers.

### What changed

`/` means the quotient of its operands' types, and two integers divide as integers on both engines.
A float or a decimal on either side makes it a fraction, which PostgreSQL computes. SQLite did not,
on every row: it stores a whole `DecimalField` value (`9.00`) as an INTEGER, and a value that is one
of several (`Coalesce`, `Case`, `Greatest`/`Least`, a `Lag`/`Lead` `default`) is the row's own
integer where an integer supplied it, so `x / 2` divided those rows as integers. Under a cast earlier
releases of this train refused it on SQLite; a bare quotient split silently.

SQLite now casts the dividend of such a quotient to `REAL`. A side that is a `REAL` on every row
already — a float literal, a `FloatField` column — needs no cast, and renders as before:

| expression | SQL on SQLite before | after |
|---|---|---|
| `F("points") / 2` on `Constructor_results` (a `DecimalField`) | `("Tb"."points" / ?)` | `(CAST("Tb"."points" AS REAL) / ?)` |
| `Coalesce("grid", 0.5) / 2` | `(COALESCE("Tb"."grid", ?) / ?)` | `(CAST(COALESCE("Tb"."grid", ?) AS REAL) / ?)` |
| `Cast("grid", "numeric") / 2` | `(CAST("Tb"."grid" AS NUMERIC) / ?)` | `(CAST(CAST("Tb"."grid" AS NUMERIC) AS REAL) / ?)` |
| `F("points") / 2` on `Result` (a `FloatField`), `F("points") / 2.0` | unchanged | unchanged |

On the F1 fixture (a constructor result of `9.00` points; a grid of `15`):

| expression | SQLite before | SQLite after | PostgreSQL |
|---|---|---|---|
| `F("points") / 2` on `Constructor_results` | `4` | `4.5` | `4.5` |
| `filter(F("points") / 2 > 4)` | excludes the `9.00` row | includes it | includes it |
| `Coalesce("grid", 0.5) / 2` | `7` | `7.5` | `7.5` |
| `Lag("grid"; default = 1.5, …) / 2` | `7` | `7.5` | `7.5` |

The quotient also reads back as the same Julia type on both engines (#1121, same train): a `Decimal`
over a decimal (`F("points") / 2` on `Constructor_results`, `Cast("grid", "numeric") / 2`) and a
`Float64` over a value that mixes integers and floats (`Coalesce("grid", 0.5) / 2`, the `Lag`
above). Before #1121, SQLite read the decimal quotient as a `Float64`.

`NullIf(a, b)` is `a` or NULL, so it has `a`'s type. PostgreSQL resolves it with `b` for the `=` it is
defined by, so `NULLIF(<integer>, 0.5)` was a `numeric`, read as a `Decimal`, and kept the half once
divided. PormG now renders `(NULLIF(x, $1::double precision))::integer` there: `NullIf("grid", 0.5) / 2`
is `7` on both engines.

The refusals change with it. A quotient over a decimal or a mixed value, cast to text, builds on
every engine (it is the same value written two ways); cast to an integer or to `numeric(p, s)` it is
a fraction, refused on SQLite as any fraction is (#1028, #1040); concatenated, refused on every
engine as a number. `Cast(Round(F("grid") / 2), IntegerField())` over a zero-scale decimal builds:
it rounds `7.5` to `8` on both.

A `REAL` keeps about 15 significant digits. A quotient over a very wide `DecimalField` can differ
from PostgreSQL's exact `numeric` past that digit, which is representation, not meaning.

### Who this affects

Code that runs on SQLite and divides a `DecimalField`, a `Cast(…, "numeric")`, or a `Coalesce`/`Case`/
`Greatest`/`Least`/`Lag`/`Lead` whose values mix integers and fractions, by anything that is not a
float, and relies on the integer it got for whole values — in `values()`, `filter()`, `update()` or an
aggregate. On PostgreSQL, code that reads `NullIf(<integer column>, <float>)` as a `Decimal` or
divides it expecting the fraction.

### How to find the calls to migrate

```bash
grep -rn ' / ' --include=*.jl src/ test/
grep -rn 'NullIf(' --include=*.jl src/ test/
```

For each division, check whether a side is one of the shapes above and the divisor is not a float
literal; for each `NullIf`, whether its first operand is an integer and its second a fraction.

### Migrate your app

```julia
# ✗ before — SQLite: 4 for a 9.00 constructor result, PostgreSQL: 4.5
M.Constructor_results.objects.values("constructorresultsid", "half" => F("points") / 2)

# ✓ after — 4.5 on both engines; for an integer quotient, say so on every engine
M.Constructor_results.objects.values("constructorresultsid", "half" => F("points") / 2)
M.Constructor_results.objects.values("constructorresultsid", "half" => Floor(F("points") / 2))
```
