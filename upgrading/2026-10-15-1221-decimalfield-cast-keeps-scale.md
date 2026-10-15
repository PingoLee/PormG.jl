## `Cast(x, DecimalField(…))` and `output_field = DecimalField(…)` cast to the field's own precision and scale (#1221)

- **Version**: Unreleased
- **PormG ref**: #1221 ; `src/querybuilder/functions.jl` (`_field_cast_type`, `Cast`, `_output_field_type`)
- **Recorded**: 2026-10-15
- **Severity**: behavior change. On PostgreSQL the value is rounded to the field's scale where it was not; on SQLite an operand with more places than the scale now raises `QueryBuildError` (#1040) where it built.

### What changed

A field object used as a `Cast` type or as an `output_field` used to contribute only its type name.
For a `DecimalField` that was `"DECIMAL"`, so `max_digits` and `decimal_places` were dropped and the
cast rendered an unscaled `decimal`: neither engine applied the scale the declaration names, and the
same declaration spelled as the string `"numeric(10,1)"` meant something else.

A `DecimalField` now casts to its own `numeric(max_digits, decimal_places)`, as its column is declared
and as Django's `Cast` renders it. `DecimalField()` is `(10, 2)`. The field spelling and the string
spelling are one declaration: the same SQL on each engine, and the same rules for a declared scale
(#1040) and a literal the precision cannot hold (#1087), on `Cast` and on the `output_field` of `Case`,
`Coalesce`, `Greatest` and `Least`. This supersedes the line of the #1040 entry that listed a
`DecimalField()` target as unchanged, unscaled.

Examples on `Result` (`points` is a `FloatField`, `grid` an `IntegerField`):

| expression | before (`::decimal`, `CAST(… AS DECIMAL)`) | PostgreSQL now | SQLite now |
|---|---|---|---|
| `Cast(F("points") * 1.5, DecimalField(max_digits = 10, decimal_places = 1))` | unscaled, every digit | `::numeric(10,1)`, rounded to 1 place | raises `QueryBuildError` (#1040) |
| `Cast("points", DecimalField())` | unscaled, every digit | `::numeric(10,2)`, rounded to 2 places | raises `QueryBuildError` (#1040) |
| `Coalesce(F("points") * 1.5, 0; output_field = DecimalField())` | unscaled | rounded to 2 places | raises `QueryBuildError` (#1040) |
| `Cast("grid", DecimalField())` | builds | builds, `numeric(10,2)` | builds |
| `Cast(Round("points", 2), DecimalField())` | builds | builds | builds |
| `Cast("points", "numeric")` | builds, unscaled | builds, unscaled | builds, unscaled |

A refusal message names the cast by its type, so `Cast(…, "DECIMAL")` reads `Cast(…, "numeric(10,2)")`.

### Who this affects

Code that passes a `DecimalField(...)` object, with or without `max_digits` / `decimal_places`, as a
`Cast` type or as an `output_field`. A string type (`"numeric(10,2)"`, `"numeric"`) is unchanged.

### How to find the calls to migrate

```bash
grep -rnE '(Cast\(.*|output_field *= *)DecimalField\(' --include=*.jl src/ test/
```

For each match, decide whether you meant the scale. If you did, round the operand to it on SQLite;
if you did not, cast to the string `"numeric"`.

### Migrate your app

```julia
# ✗ before — rendered an unscaled decimal; now numeric(10,2): rounded on PostgreSQL, refused on SQLite (#1040)
q = M.Result.objects
q.values("bonus" => Cast(F("points") * 1.5, DecimalField()))

# ✓ after — the scale you meant, reached by rounding first, on every engine …
q = M.Result.objects
q.values("bonus" => Cast(Round(F("points") * 1.5, 2), DecimalField()))

# ✓ … or no scale at all
q = M.Result.objects
q.values("bonus" => Cast(F("points") * 1.5, "numeric"))
```
