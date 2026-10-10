## A boolean value reads back as a `Bool` on SQLite, and a `Case` of booleans is a boolean (#965)

- **Version**: Unreleased
- **PormG ref**: #965, #1122; `src/querybuilder/build_query.jl` (`_field_read_kind`,
  `_function_projection_kind`, `_expression_formatter`, `_boolean_case`), `src/querybuilder/execution.jl`
  (`_field_value_parser`); for #1122, `src/querybuilder/build_select.jl` (`get_select_query`)
- **Recorded**: 2026-10-05
- **Severity**: behavior change, on SQLite. On PostgreSQL the driver already delivered every one of
  these values as a `Bool`. What changes there is a `Case` of booleans: `Max`/`Min` over one now run,
  `Sum`/`Avg` over one are refused at build instead of by the database, and a filter on its alias
  binds through the boolean formatter (`=> 1` binds `true`, `=> 5` raises).

### What changed

SQLite stores a boolean as `0`/`1`, and its driver hands the integer back. #953 typed `Max`/`Min`
over a `BooleanField` so they read back as a `Bool`; nothing else boolean did, not even the column
itself. The values below now read back as a `Bool`, through one rule: the build already knows
which values are booleans (a filter on one binds through the boolean formatter), and that is what
types the read. A function over several operands (`Coalesce`, `Greatest`, `Least`) is a boolean only
when every operand is one.

| On SQLite | before | after |
|---|---|---|
| a `BooleanField` column: `values("is_rookie")`, a read with no `values`, `DataFrame`, the row `create` returns | `Int64` `0`/`1` | `Bool` |
| a comparison projected as a value, `"gained" => F("grid") > F("positionorder")` | `Int64` | `Bool` |
| `Cast(x, "boolean")`, `Coalesce(Max("is_rookie"), false)`, `Greatest`/`NullIf` over booleans | `Int64` | `Bool` |
| `Lag`/`Lead`/`FirstValue`/`LastValue`/`NthValue` over a boolean | `Int64` | `Bool` |
| a projected `Exists(...)` | `Int64` | `Bool` |
| a projected `Value(true)`/`Value(false)`, alone or inside a `Subquery` (#1122; under a CTE it already was) | `Int64` | `Bool` |
| a `Case` whose branches are all `true`/`false` (or `When(…, then = true, otherwise = false)`) | `Int64` | `Bool` |

A `Case` whose branches are all booleans is also a boolean for #953's aggregate rule, on both engines:

| Call | before | after |
|---|---|---|
| `Max(Case([When(…, then = true)], default = false))` | PostgreSQL: `function max(boolean) does not exist` | `BOOL_OR(CASE …)`, a `Bool` on both engines |
| `Sum(…)` / `Avg(…)` of that `Case` | SQLite: the sum of the 0/1; PostgreSQL: a database error | `QueryBuildError` on both engines |
| `values("c" => <that Case>)`, then `filter("c" => 5)` | bound `5` | `FilterError` on both engines, as for any boolean (#949) |
| …then `filter("c" => 1)` on PostgreSQL | bound the integer `1` | binds `true` |

Unchanged: a `Case` over numbers, including the count spelling
`Sum(Case([When(…, then = 1)], default = 0))`; a `Case` mixing `true` with a number (PostgreSQL
rejects it anyway); and how a boolean is bound in a filter. On SQLite, `Cast(x, "boolean")` over an
integer other than 0 or 1 still returns that integer, because SQLite's `CAST AS BOOLEAN` keeps it.

### How to find the calls to migrate

The column change reaches every boolean column an app reads on SQLite, so search for code that
handles a flag as a number rather than for the calls that read it:

```bash
# a flag compared, matched or converted as an integer
grep -rnE '(==|!=|===|!==)\s*[01]\b|Int(64)?\(\s*\w+\[:\w+\]\s*\)|::Int(64)?\b' src/
# a DataFrame column declared or converted to an integer type
grep -rnE 'Vector\{Int(64)?\}|convert\(\s*Vector\{Int' src/
```

Most of that code keeps working, because `Bool <: Integer` in Julia: `row[:is_rookie] == 1` is still
`true`, and `sum(df.is_rookie)` still counts. What changes is anything that looks at the type or the
printed value: a method typed `::Int64`, `===` against `1`, a `DataFrame` column's `eltype`, and
JSON output, which becomes `true`/`false` where it was `1`/`0`. An app
that only runs on PostgreSQL sees only the changes to a `Case` of booleans: its aggregates and its
alias filter.

### Migrate your app

```julia
# ✗ before — on SQLite the flag arrived as 0/1, so the app compared it with ===
rows = M.Result.objects.values("resultid", "gained" => F("grid") > F("positionorder")).list()
gainers = [r[:resultid] for r in rows if r[:gained] === 1]

# ✓ after — a Bool on both engines
gainers = [r[:resultid] for r in rows if r[:gained]]
```

```julia
# ✗ before — Sum over a Case of booleans: a 0/1 sum on SQLite, a database error on PostgreSQL
q = M.Result.objects
q.values("raceid", "podiums" => Sum(Case([When("positionorder__@lte" => 3, then = true)], default = false)))

# ✓ after — count with a Case over numbers
q.values("raceid", "podiums" => Sum(Case([When("positionorder__@lte" => 3, then = 1)], default = 0)))
```
