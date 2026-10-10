## `Max`/`Min`/`Avg` in a CTE body type as their operand, not by the alias's name (#1116)

- **Version**: Unreleased
- **PormG ref**: #1116, #1123 ; `src/querybuilder/ctes.jl` (`_set_field_from_sql_function`, `_aggregate_operand_field`)
- **Recorded**: 2026-10-10
- **Severity**: breaking. A CTE body projecting `Max`, `Min` or `Avg` over a function PormG does not type (`Coalesce`, `Floor`, `Concat`, a transform path such as `"dob__@year"`, …) under an alias that happens to name a field of the body's model now raises `QueryBuildError` where it used to build. The same aggregates over a field path, a `Joined(...)` column or `F` arithmetic, which raised `UnknownFieldError`, now build.

### What changed

The CTE types each body column as a field, so a filter on the column binds its value as that type.
For `Max`, `Min` and `Avg` it looked the operand up among the body model's own fields, and when that
failed it fell back to the field the **alias** names. So:

- an operand that is a hop path (`Max("raceid__date")`), a `Joined(...)` handle or `F` arithmetic
  raised `UnknownFieldError: the field v (base column: v) not found`, naming the alias, while the
  same `Max` projected directly built;
- an operand PormG cannot type built only when the alias matched a model field, and was then typed
  as that field: `"points" => Max(Coalesce("points", 0.0))` was a `FloatField` by luck, and
  `"dob" => Max("dob__@year")` was a `DateField` holding a year, so a filter on it bound a date
  against an integer.

The operand now decides, through the same rules a projection in the body follows. A path is its
field, a `Joined(...)` column is the joined field, `F` arithmetic is an integer or a float (#823), and
a function is typed as it is when projected bare: by its declared `output_field`/`Cast` type, or
refused (#812).

| CTE body projects | before | after |
|---|---|---|
| `"last" => Max("raceid__date")` | `UnknownFieldError` | a `DateField` column |
| `"first" => Min(Joined("rc", "date"))` | `UnknownFieldError` | a `DateField` column |
| `"double" => Max(F("points") * 2)` | `UnknownFieldError` | a `FloatField` column |
| `"points" => Max(Coalesce("points", 0.0))` | typed by the alias: `FloatField` | `QueryBuildError` (COALESCE is not typed) |
| `"dob" => Max("dob__@year")` | typed by the alias: `DateField` | `QueryBuildError` |
| `"top" => Max("points")` | `FloatField` | unchanged |

### Who this affects

Code whose `.with(...)` body projects `Max`, `Min` or `Avg` over a function or a transform path
under an alias that is also a field name of the body's model. Running the query is the definitive
check: the build raises `QueryBuildError` naming the function (`COALESCE`, `FLOOR`, `EXTRACT`, …) and
suggesting a declared type.

### How to find the calls to migrate

```bash
grep -rnE '(Max|Min|Avg)\((Coalesce|Floor|Ceil|Abs|Round|Concat|Lower|Upper|Greatest|Least|"[^"]*__@)' --include=*.jl src/ test/
```

Keep the hits that sit inside a queryset passed to `.with(...)`.

### Migrate your app

Name the type the column holds, on the function the aggregate reads:

```julia
# ✗ before — typed by the alias's name
best = M.Result.objects.values("driverid", "points" => Max(Coalesce("points", 0.0)))

# ✓ after — the declared type is the column's type, on both engines
best = M.Result.objects.values("driverid", "points" => Max(Coalesce("points", 0.0, output_field = FloatField())))

# ✓ after — or cast the transform to the type it holds
born = M.Driver.objects.values("nationality", "dob" => Max(Cast("dob__@year", IntegerField())))
```
