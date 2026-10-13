## A filter on a computed CTE column binds the type the column means: a summed duration takes a `Period`, a comparison a `Bool` (#1034)

- **Version**: Unreleased
- **PormG ref**: #1034 ; `src/querybuilder/ctes.jl` (`_meant_column_field`), `src/querybuilder/expression_kind.jl` (`_kind_field`)
- **Recorded**: 2026-10-13
- **Severity**: behavior change. Some filters on a CTE column that raised now build, and some that built now raise `InvalidValueError`. Number columns bind as before.

### What changed

The outer query treats each `CTE(...)` column as a field, and that field formats the value a filter
compares with it. For a computed column PormG used to infer the field from the function's name:
`Count` and `Sum` were integers whatever they summed, and `F` arithmetic an integer or a float. The
field now follows what the column's expression means, which is the same on PostgreSQL and SQLite:

| CTE body projects | field before | field now |
|---|---|---|
| `Sum` of a `DurationField` (`Sum("fastestlaptime")`) | integer | duration |
| `Sum` of a `FloatField` | integer | float |
| `Sum` of a `DecimalField` | integer | decimal |
| `Avg` of an integer field | integer | float |
| `F` arithmetic with a decimal side (`F("points") * 2` on `Constructor_results`) | float | decimal |
| an `F` comparison (`F("grid") < F("positionorder")`) | float | boolean |

Unchanged: `Count`, a `Sum` of integers, `Min`/`Max`, `Avg` of a float or a decimal (a decimal keeps
its operand's declared width), a plain field path, a `Joined(...)` column, a `Value(...)`, and a
declared type (`Cast`, `output_field`).

What that does to a filter on the column, on both engines:

| filter | before | now |
|---|---|---|
| `"r__fast__@gt" => Minute(1)` on a summed duration | raised `MethodError` (`format_number_sql(::Minute)`) | binds the duration |
| `"r__fast__@gt" => 60` on a summed duration | bound the number `60` (on SQLite a text value compared with a number, true on every row) | raises `InvalidValueError`, as on a `DurationField` column |
| `"r__ahead" => true` on a comparison | bound `1` | binds `true` |
| `"r__ahead" => 2` on a comparison | bound `2` | raises `InvalidValueError`, as on a `BooleanField` column |
| any number against a float, decimal or integer column | bound as a number | unchanged |

The values the columns read back as are unchanged: since #1121 the read follows the body's own
expression, not this field.

On SQLite a duration CTE column is compared as its text, whether it projects a `DurationField` or, now,
a sum of one; that was already so for the first and is tracked separately.

### Who this affects

Code that filters on a CTE column whose body projects a `Sum` of a duration,
float or decimal field, an `Avg` of an integer field, decimal `F` arithmetic, or an `F` comparison:

- a filter that passed a bare number for a summed duration, or an integer other than `0`/`1` for a
  comparison, now raises;
- a filter that passed a `Period` for a summed duration now builds where it raised.

### How to find the calls to migrate

```bash
grep -rnE '\.with\(' --include=*.jl src/ test/
grep -rnE 'Sum\("[a-z_]*(time|duration|laptime)' --include=*.jl src/ test/
```

For each `.with(...)` body, check the computed columns against the first table, then the filters on
`"<cte>__<column>"` keys against the second.

### Migrate your app

```julia
# ✗ before — a bare number for a summed duration (on SQLite, true on every row)
body = M.Result.objects
body.values("raceid", "fast" => Sum("fastestlaptime"))
q = M.Result.objects
q.with("r" => body, join_field = "raceid" => "raceid")
q.filter("r__fast__@gt" => 60)

# ✓ after — a Period, as on a DurationField column
body = M.Result.objects
body.values("raceid", "fast" => Sum("fastestlaptime"))
q = M.Result.objects
q.with("r" => body, join_field = "raceid" => "raceid")
q.filter("r__fast__@gt" => Minute(1))
```
