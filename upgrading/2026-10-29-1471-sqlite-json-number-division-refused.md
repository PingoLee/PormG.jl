## `/` over a JSON key's number is refused on SQLite, which divided it as integers (#1471)

- **Version**: Unreleased
- **PormG ref**: #1471 ; `src/querybuilder/expression_render.jl` (`_division_sql`), `src/querybuilder/projection_types.jl` (`_json_number_side`), `src/querybuilder/engine_departures.jl`
- **Recorded**: 2026-10-29
- **Severity**: behavior change on SQLite. A query that built and returned a value now raises `QueryBuildError` when it is built. PostgreSQL and MySQL are unchanged.

### What changed

A JSON number has no integer type, so a quotient over one means a quotient that keeps its fraction.
SQLite's `json_extract` returns the integer the document holds. `Floor`, `Ceil`, `Abs`, `Max`,
`Coalesce`, `Sum` and arithmetic over the key keep that integer, so SQLite divided it as an integer:
over `{"wins": 121}`, `Floor("metadata__wins") / 2` returned `60`, where PostgreSQL returns `60.5`.
Nothing reported the difference.

SQLite now refuses a `/` with such a side, on either side of the operator, and the message names the
cast to write. A side that names its number still builds: `Round` and `Avg` (a REAL on SQLite), and a
`Cast` or an `output_field`.

| query on SQLite (`metadata` holds `{"wins": 121}`) | before | now |
|---|---|---|
| `values("v" => Floor("metadata__wins") / 2)` | `60` | `QueryBuildError` |
| `values("v" => F("metadata__wins") / 2)` | `60` | `QueryBuildError` |
| `values("v" => Sum("metadata__wins") / 2)` | `60` | `QueryBuildError` |
| `values("v" => Cast("metadata__wins", "numeric") / 2)` | `60.5` | `60.5` (unchanged) |
| `values("v" => Round("metadata__wins") / 2)` | `60.5` | `60.5` (unchanged) |

### Who this affects

Code on SQLite that divides a value taken from a JSON key, directly or through one of the functions
above, including inside a CTE body or a `Subquery`.

### How to find the calls to migrate

```bash
grep -rnE '__[A-Za-z_0-9]+"\)? *\)? */' --include=*.jl src/ test/
```

and look for a JSONField path on the left or the right of `/`. The error message reads
`` / of … the JSON key `…` means a quotient that keeps its fraction``.

### Migrate your app

```julia
# ✗ before — SQLite divided the integer the key holds
q = M.Constructor.objects
q.values("name", "half" => Floor("metadata__wins") / 2)

# ✓ after — state the number type; this keeps the fraction on every engine
q = M.Constructor.objects
q.values("name", "half" => Floor(Cast("metadata__wins", "numeric")) / 2)
```

If the integer quotient is what the code meant, say so: `Cast("metadata__wins", BigIntegerField()) / 2`
divides as integers on every engine.
