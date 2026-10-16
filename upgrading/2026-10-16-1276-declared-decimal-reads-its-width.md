## A declared decimal over decimal columns is compared at the width it declares (#1276)

- **Version**: Unreleased
- **PormG ref**: #1276 ; `src/querybuilder/expression_kind.jl` (`_declared_stored_decimal`)
- **Recorded**: 2026-10-16
- **Severity**: behavior change, SQLite only. A `Coalesce`, `Greatest` or `Least` over `DecimalField` columns, declared with a decimal `output_field`, can read back through a different parser. PostgreSQL is unchanged: its driver hands back the `numeric` it computed.

### What changed

`Coalesce`, `Greatest` and `Least` hold one of their operands' own values. Over `DecimalField` columns
that agree on one width, declared as a decimal, the value is one SQLite stored, so it reads through
the stored column's parser (#648, #1212): the written `Decimal`, or SQLite's raw `REAL` when the stored
value does not fit the width, exactly as the column reads alone. Any other declaration is the computed
number it means and reads through the computed parser (#1121): a `Decimal` of 15 significant digits.

The declaration used to be compared by its type name only, which dropped the size, so any decimal
`output_field` counted as `DecimalField()`'s `(10, 2)`. It is now compared at the width it declares:

| `output_field`, over two columns of one width | parser before | parser now |
|---|---|---|
| `"numeric(10,2)"` or `DecimalField()`, over `DecimalField()` (10, 2) columns | stored (10, 2) | stored (10, 2), unchanged |
| `"numeric(15,4)"`, over `DecimalField(max_digits = 15, decimal_places = 4)` columns | computed | stored (15, 4): as the column reads |
| `"numeric(12,4)"`, over `DecimalField()` (10, 2) columns | stored (10, 2) | computed |
| bare `"numeric"` or `"decimal"`, which declares no width, over any decimal columns | stored (10, 2) over (10, 2) columns, computed otherwise | computed |

The two parsers agree on every value that fits its column's width with at most 15 significant
digits, which covers the values PormG writes to a column it created. They differ where SQLite holds
a value the width does not: measured on SQLite 3.45, `1234567.123456789` stored in a
`DecimalField(15, 4)` column read back through `Coalesce("v", "v"; output_field = "numeric(15,4)")` as
`Decimal("1234567.12345679")` before, and as the raw `1234567.123456789` (a `Float64`) now, the value
`v` alone reads as.

### Who this affects

On SQLite, code that projects `Coalesce`, `Greatest` or `Least` over `DecimalField` columns with a
decimal `output_field` whose width differs from `(10, 2)` or is left out, and reads values the
column's width does not hold.

### How to find the calls to migrate

```bash
grep -rnE '(Coalesce|Greatest|Least)\(' --include=*.jl src/ test/ | grep -E 'output_field *= *("(numeric|decimal)|DecimalField)'
```

### Migrate your app

```julia
# Before: read as a 15-digit Decimal on SQLite (the declaration counted as (10, 2), not the column's)
# Now: reads as the column itself reads, a Decimal, or the raw REAL past the column's width
q = M.Constructor_results.objects
q.values("p" => Coalesce("points", "points"; output_field = "numeric(15,4)"))

# To keep the 15-digit Decimal on every row, declare no width, which is the computed number:
q = M.Constructor_results.objects
q.values("p" => Coalesce("points", "points"; output_field = "numeric"))
```
