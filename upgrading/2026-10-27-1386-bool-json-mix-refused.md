## A boolean or a JSON document beside another type in a conditional is refused on every engine (#1386)

- **Version**: 0.9.0
- **PormG ref**: #1386 ; `src/querybuilder/projection_types.jl` (`_temporal_mix_class`, `_temporal_mix`), `src/querybuilder/functions.jl` (`_temporal_mix_refusal`)
- **Recorded**: 2026-10-27
- **Severity**: behavior change. `Coalesce`, `Greatest`, `Least`, `NullIf`, a `Case`, or a `Lag`/`Lead`
  `default` with a boolean beside a value of another type (a number, text, a date, a UUID, a JSON
  document), or a whole JSON document beside another type, used to build on every engine. It now
  raises `QueryBuildError` when the query is built, on every engine.

### What changed

#1321 and #1327 refuse a value that is one of several operands' when two typed operands have
different types. A boolean and a JSON document had no type in that rule, so a mix with either one
built:

| on `New_join_position` | SQLite, MySQL before | PostgreSQL before | now, every engine |
|---|---|---|---|
| `values("v" => Coalesce("boolean_field", "result"))` | the flag's `0`/`1` or the number | fails at the server | `QueryBuildError` |
| `values("v" => Case(When("result" => 1, then = true), default = 0))` | `1` or `0` | fails at the server | `QueryBuildError` |
| `values("v" => Greatest("result", "boolean_field"))` | the larger of the two numbers | fails at the server | `QueryBuildError` |
| `values("v" => Coalesce("boolean_field", "description"))` | the flag's `0`/`1` or the text | fails at the server | `QueryBuildError` |
| `Coalesce(<a JSONField column>, <a number column>)` | the document's text or the number | fails at the server | `QueryBuildError` |
| `values("v" => Case(When("boolean_field" => true, then = 1), default = 0))` | built | built | builds, unchanged |
| `values("v" => Coalesce("boolean_field", false))` | built | built | builds, unchanged |
| `Coalesce(<a JSON key lookup>, <a number column>)` | built | built | builds, unchanged |

The *before* cells follow each engine's type rules; they were not measured on a live database. A
boolean beside a number does not say whether it means the flag or a count. An `output_field` does
not lift the refusal: it casts the value after the engine has met both operands.

### Who this affects

Code that puts a `BooleanField`, a `Bool` literal, a comparison or a whole `JSONField` document beside
a value of another type in `Coalesce`, `Greatest`, `Least`, `NullIf`, `Case`, or a `Lag`/`Lead`
`default`.

### How to find the calls to migrate

```bash
grep -rnE '\b(Coalesce|Greatest|Least|NullIf|Case|Lag|Lead)\(' --include=*.jl src/ test/
```

For each match, check whether one operand is a boolean or a whole JSON document and another is not.

### Migrate your app

```julia
# ✗ before — SQLite answered 0/1 or the result; PostgreSQL failed at the server
q = M.New_join_position.objects
q.values("v" => Coalesce("boolean_field", "result"))

# ✓ after — say what the flag means as a number
q = M.New_join_position.objects
q.values("v" => Case(When("boolean_field" => true, then = 1), default = 0))
```
