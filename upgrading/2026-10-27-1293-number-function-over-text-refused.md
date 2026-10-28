## A number function over text is refused on every engine (#1293)

- **Version**: Unreleased
- **PormG ref**: #1293 ; `src/querybuilder/projection_types.jl` (`_check_operand_domain`, `_text_math_refusal`)
- **Recorded**: 2026-10-27
- **Severity**: behavior change. On SQLite, `Round`, `Floor`, `Ceil`, `Sqrt`, `Exp`, `Ln`, `Power`, `Mod`, `Abs`, `Sum` and `Avg` over text used to build and compute on the text read as a number (`0` for text that is no number). They now raise `QueryBuildError` when the query is built. On PostgreSQL and MySQL the same query used to fail at the server, or compute the number the text spells, and now fails at build time.

### What changed

Text is no number, and the query does not say it holds numbers. PostgreSQL rejects text that is no
number at the server and rounds `'125'` silently. SQLite reads `'Senna'` as `0`. `Round(x, n)` with
`n ≠ 0` was already refused over text (#1061), but `Round(x)` was not, and neither were the other
number functions.

Every number function now refuses an operand the type walk names text, on every engine: a
`CharField` or `TextField` column, `Concat`, `Upper`/`Lower`, `ToChar`, a `"date__@yyyy_mm"` label, a
string literal (`Value("12")`). A function nested inside another is refused too
(`Cast(Floor("positiontext"), "integer")`). A JSON key lookup (`"payload__points"`) is a value
PormG cannot type, and builds as before.

Examples on `Result`, whose `positiontext` is a `CharField`:

| expression | before (SQLite) | before (PostgreSQL) | now |
|---|---|---|---|
| `Round("positiontext")` | the text read as a number, `0` for `"R"` | fails at the server for `"R"`, rounds `"3"` | `QueryBuildError` (#1293) |
| `Floor("positiontext")`, `Mod("positiontext", 2)` | as above | as above | `QueryBuildError` (#1293) |
| `Sum("positiontext")`, `Avg("positiontext")` | the sum of the numbers the texts spell | fails at the server | `QueryBuildError` (#1293) |
| `Round("positiontext", 2)` | `QueryBuildError` (#1061) | `QueryBuildError` (#1061) | unchanged |
| `Floor(Cast("positiontext", FloatField()))` | builds | builds | builds, unchanged |

### Who this affects

Code that applies a number function to a text column or a text expression, on any engine.

### How to find the calls to migrate

```bash
grep -rn -E '(Round|Floor|Ceil|Sqrt|Exp|Ln|Power|Mod|Abs|Sum|Avg)\(' --include=*.jl src/ test/
```

For each match, check whether the operand is text.

### Migrate your app

```julia
# ✗ before — SQLite read "R" (retired) as 0; now raises QueryBuildError (#1293)
q = M.Result.objects
q.values("p" => Floor("positiontext"))

# ✓ after — say the text holds numbers, or use the number column
q = M.Result.objects
q.values("p" => Floor(Cast("positiontext", FloatField())))
q.values("p" => "positionorder")
```
