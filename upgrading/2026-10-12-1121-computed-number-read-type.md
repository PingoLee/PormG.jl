## A computed number reads back as the type it means, on every engine: `Avg` over integers is a `Float64`, a decimal aggregate a `Decimal` (#1121)

- **Version**: Unreleased
- **PormG ref**: #1121 ; `src/querybuilder/expression_kind.jl` (`_MeaningKinds`, `_output_kind`, `_numeric_read_kind`), `src/querybuilder/build_select.jl`, `src/value_repr.jl`, `src/Dialect.jl` (`_parse_sqlite_computed_decimal`, `_parse_computed_float`)
- **Recorded**: 2026-10-12
- **Severity**: behavior change. The Julia type a caller receives changes for these projections, and the conversion can change the last digits. On PostgreSQL, several calls that read a `Decimal` now read a `Float64`, the nearest double to the `numeric` (a `numeric` holding more than about 16 significant digits loses them). On SQLite, the decimal family that read a `Float64` now reads a `Decimal` of that double's first 15 significant digits (`0.30000000000000004` reads as `0.3`).

### What changed

A number the database computes used to come back as whatever type the driver delivered, and the
engines compute these calls differently. PostgreSQL computes `avg(integer)`, and every function PormG
renders over `(x)::numeric`, as a `numeric`, so the driver delivers a `Decimal`. SQLite computes the
same calls as a double, and so is a sum or an average of a `DecimalField`. So one query read a
`Decimal` on PostgreSQL and a `Float64` on SQLite.

The type now follows what the call means, which is Django's `output_field` for it, and it is the same
on both engines:

| projected expression | PostgreSQL before | SQLite before | both engines now |
|---|---|---|---|
| `Avg("grid")` (an integer) | `Decimal` `11.5` | `Float64` `11.5` | `Float64` `11.5` |
| `Round("points", 1)`, `Abs`/`Floor`/`Ceil` of a `FloatField` | `Decimal` | `Float64` | `Float64` |
| `Mod("grid", 2)`, `Sqrt("grid")`, `Power("grid", 2)`, `Exp`, `Ln` over an integer or a float | `Decimal` `1` | `Float64` `1.0` | `Float64` `1.0` |
| `Sum`/`Avg`/`Abs`/`Round`/`Floor`/`Ceil` of a `DecimalField` (`Constructor_results.points`) | `Decimal` `5.5` | `Float64` `5.5` | `Decimal` `5.5` |
| arithmetic with a decimal side (`F("points") * 2`, `F("points") / 2` on `Constructor_results`) | `Decimal` `11` | `Float64` `11.0` | `Decimal` `11` |

The same holds for the column of a `CTE(...)` whose body computes one of these, for a `Subquery(...)`
that projects one, for arithmetic over one (`Avg("grid") * 2` is a `Float64`), for a window value
over one (`Lag(Sum("points"))`), and for a `Coalesce`, `Greatest`, `Least`, `NullIf` or `Case` with
one among its values (`Coalesce(Avg("grid"), 0)` is a `Float64`). It holds in
`list()`, `list(:dict)`, `list(:json)` and `DataFrame(query)`.

On SQLite, PormG builds the `Decimal` from the double SQLite computed, to **15 significant digits**,
as Django's SQLite backend does: a sum of `0.1` and `0.2` reads as `0.3`. Its last digits can differ
from PostgreSQL's exact `numeric` (`Avg` of the 2008 Australian Grand Prix's constructor points is
`3.5454545454545455` there and `3.54545454545455` on SQLite). That is each engine's spelling of the
number, not a different value.

Unchanged: a column (a `DecimalField` keeps its declared width and exact parser, a `FloatField` reads
as before), an extremum or window value of a column (`Max("points")`), a `Coalesce`/`Greatest`/`Least`/
`NullIf`/`Case` over columns and literals only (`Coalesce("grid", "points")`), `Round` over an integer,
and every integer result. Integer widths still follow the engine.

### Who this affects

- On PostgreSQL: code that reads `Avg` over an integer column, or `Round`/`Mod`/`Sqrt`/`Exp`/`Ln`/
  `Power`/`Abs`/`Floor`/`Ceil` over an integer or a float, as a `Decimal`. That includes arithmetic
  with a `Decimal` (`x + Decimal("0.5")` now mixes a `Float64` and a `Decimal`), a type assertion or
  dispatch on `Decimal`.
- On SQLite: code that reads a sum, an average, a rounded value or arithmetic over a `DecimalField`
  as a `Float64` (`x isa Float64`, `Float64` arithmetic, a `Vector{Float64}` built from the column).

### How to find the calls to migrate

```bash
grep -rnE '(Avg|Sum|Round|Mod|Sqrt|Exp|Ln|Power|Abs|Floor|Ceil)\(' --include=*.jl src/ test/
grep -rnE 'isa (Decimals\.)?Decimal|isa Float64|::(Decimals\.)?Decimal|::Float64' --include=*.jl src/ test/
```

For each projected call, check the operand's field type against the table above, and whether the code
that reads the value assumes the old type.

### Migrate your app

```julia
# ✗ before — PostgreSQL: Decimal 11.5; SQLite: Float64 11.5
q = M.Result.objects
q.filter("raceid" => 18)
q.values("avg_grid" => Avg("grid"))
avg_grid = only(q.list(:dict))[:avg_grid]
avg_grid isa Decimals.Decimal && (avg_grid = Float64(avg_grid))

# ✓ after — a Float64 on both engines
q = M.Result.objects
q.filter("raceid" => 18)
q.values("avg_grid" => Avg("grid"))
avg_grid = only(q.list(:dict))[:avg_grid]
```
