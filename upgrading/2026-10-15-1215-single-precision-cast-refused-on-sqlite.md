## `Cast(x, "real")` and a `"real"` `output_field` are refused on SQLite, which has no single-precision float (#1215)

- **Version**: 0.9.0
- **PormG ref**: #1215 ; `src/querybuilder/engine_departures.jl` (`_MEANING_DEPARTURES`), `src/querybuilder/projection_types.jl` (`_single_precision_cast`, `_cast_divergent_operand`)
- **Recorded**: 2026-10-15
- **Severity**: behavior change. Expressions that built on SQLite now raise `QueryBuildError` when the query is built. PostgreSQL is unchanged.

### What changed

A cast to PostgreSQL's single-precision float means the value rounded to a 4-byte float, which reads
back as a `Float32`. SQLite has no 4-byte float: `CAST(x AS REAL)` keeps the 8-byte double. So the
same query returned a different type on each engine, and for a value with no exact binary form a
different value too: `0.1` is `0.1f0` on PostgreSQL, which is no longer `0.1` once widened to a
`Float64` (`Float64(0.1f0) != 0.1`), and stays `0.1` on SQLite.

PormG now refuses the cast on SQLite, the engine that cannot compute it, and builds it as before on
PostgreSQL. The refusal covers every spelling PostgreSQL resolves to `real`: `"real"`, `"float4"` and
`"float(p)"` for `p` from 1 to 24, as a `Cast` type and as the `output_field` of `Case`, `Coalesce`,
`Greatest` and `Least`. Every operand is refused, an integer column included, because PostgreSQL
returns a `Float32` whatever it rounded.

Examples on `Result`:

| expression | PostgreSQL | SQLite before | SQLite now |
|---|---|---|---|
| `Cast("points", "real")` | `Float32` | `Float64` | raises `QueryBuildError` (#1215) |
| `Cast("grid", "float4")` | `Float32` | `Float64` | raises `QueryBuildError` (#1215) |
| `Coalesce("points", "grid"; output_field = "real")` | `Float32` | `Float64` | raises `QueryBuildError` (#1215) |
| `Cast("points", "float8")`, `Cast("points", FloatField())`, `Cast("points", "float(25)")` | `Float64` | `Float64` | builds, unchanged |

A CTE column declared `float4` is refused on SQLite the same way.

### Who this affects

On SQLite, code that casts to `"real"`, `"float4"` or `"float(p)"` with `p` up to 24, or passes one
as an `output_field`. Code that only runs on PostgreSQL is unaffected.

### How to find the calls to migrate

```bash
grep -rnEi '"(real|float4|float\((1?[0-9]|2[0-4])\))"' --include=*.jl src/ test/
```

For each match inside a `Cast(...)` or an `output_field = ...`, decide whether you need single
precision. If you do not, cast to a double.

### Migrate your app

```julia
# ✗ before — a Float32 on PostgreSQL, a Float64 on SQLite; now raises QueryBuildError on SQLite (#1215)
q = M.Result.objects
q.values("p" => Cast("points", "real"))

# ✓ after — a double is a Float64 on every engine
q = M.Result.objects
q.values("p" => Cast("points", FloatField()))      # or Cast("points", "float8")
```
