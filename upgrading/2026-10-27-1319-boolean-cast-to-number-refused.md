## A boolean cast to a float or a `numeric` is refused on SQLite, which cast the integer it stores (#1319)

- **Version**: 0.9.0
- **PormG ref**: #1319 ; `src/querybuilder/engine_departures.jl` (`_MEANING_DEPARTURES`), `src/querybuilder/projection_types.jl` (`_cast_divergent_operand`)
- **Recorded**: 2026-10-27
- **Severity**: behavior change. Expressions that built on SQLite now raise `QueryBuildError` when the query is built. PostgreSQL is unchanged.

### What changed

A boolean is a number only as the integer `1` or `0`, and its cast to an integer gives that on every
engine. PostgreSQL has no cast from a boolean to a float or a `numeric`: `boolean::float8` and
`boolean::numeric` fail when the query runs, and that error is the meaning, as for an interval
(#1259) or a date (#1260). SQLite stores a boolean as `1` / `0` and cast that integer: `1.0` as a
float, `1` as a `numeric`. That was a number the query never stated.

PormG now refuses the cast on SQLite and builds it as before on PostgreSQL, where the server still
raises. The refusal covers a `BooleanField` column, an extremum over one and a boolean expression,
cast to a float or a `numeric`, scaled or not (`FloatField()`, `DecimalField()`, `"float8"`,
`"numeric"`, `"numeric(p, s)"`, …), as a `Cast` type and as the `output_field` of `Case`, `Coalesce`,
`Greatest` and `Least`. A cast to `"real"` keeps the #1215 refusal it already had on SQLite. MySQL,
whose boolean is a `TINYINT(1)`, refuses the same casts.

| expression (`x` a `BooleanField`) | PostgreSQL | SQLite before | SQLite now |
|---|---|---|---|
| `Cast(x, "float8")`, `Cast(x, FloatField())` | raises when the query runs | `1.0` / `0.0` | raises `QueryBuildError` (#1319) |
| `Cast(x, "numeric")`, `Cast(x, "numeric(10,2)")` | raises when the query runs | `1` / `0` | raises `QueryBuildError` (#1319) |
| `Cast(x, IntegerField())` | `1` / `0` | `1` / `0` | builds, unchanged |

### Who this affects

On SQLite, code that casts a boolean to a float or a `numeric` type, or passes such an `output_field`
over one. The same code already failed on PostgreSQL.

### How to find the calls to migrate

```bash
grep -rnE 'Cast\(|output_field' --include=*.jl src/ test/ | grep -iE 'Float|Decimal|"(real|float[48]?|double precision|numeric|decimal)'
```

For each match, check whether the operand is a `BooleanField` or a boolean expression.

### Migrate your app

```julia
# ✗ before — 1.0 on SQLite, an error on PostgreSQL; now raises QueryBuildError on SQLite (#1319)
q.values("v" => Cast(x, "float8"))

# ✓ after — cast to the integer first, which every engine computes alike
q.values("v" => Cast(Cast(x, IntegerField()), "float8"))

# ✓ or state the values (a NULL stays NULL)
q.values("v" => Case([When(x => true, then = Value(1.0)), When(x => false, then = Value(0.0))]))
```
