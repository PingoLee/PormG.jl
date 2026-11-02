## A month or a year beside an interval on SQLite or MySQL raises `BackendCapabilityError` (#1553)

- **Version**: Unreleased
- **PormG ref**: #1553 ; `src/capabilities.jl`, `src/querybuilder/expression_render.jl`
- **Recorded**: 2026-11-01
- **Severity**: behavior, only for SQLite or MySQL code that catches the error by its type. The same calls still raise; the type changed. Nothing that built before builds differently.

### What changed

A `Month` or a `Year` has no fixed length, so SQLite and MySQL cannot compute one as an interval
value: there PormG holds an interval as its milliseconds (SQLite) or microseconds (MySQL). Only
PostgreSQL's `interval` keeps months apart. #1553 made a duration an interval value of its own:
`F("grid") * Month(1)`, `F("time") - Year(1)`. The month refusal is now the backend capability
`calendar_intervals`, listed on the Backends page, and the shapes that refused a month
before raise the same capability error. Before, they raised a `QueryBuildError`.

| call | before | now |
|---|---|---|
| on SQLite or MySQL: `(F("start_at") - F("date")) + Month(1)`, or `- Year(1)` | `QueryBuildError` ("has no fixed length") | `BackendCapabilityError` |
| on SQLite or MySQL: `(F("start_at") - F("date")) > Month(1)`, inside an expression | `QueryBuildError` | `BackendCapabilityError` |
| on SQLite or MySQL: `F("grid") * Month(1)`, `F("time") - Month(1)` (new in #1553) | `QueryBuildError` / `InvalidValueError` | `BackendCapabilityError` |
| the first two rows on PostgreSQL | builds | builds, unchanged |
| the third row on PostgreSQL | `QueryBuildError` / `InvalidValueError` | builds (`make_interval(months => …)`), new in #1553 |
| on every engine: `F("date") + Month(1)`, a date shifted by a month | builds | builds, unchanged |

`BackendCapabilityError` is a `PormGError`, not a `QueryBuildError`, so a `catch` that tests for
`QueryBuildError` no longer matches these calls.

### Who this affects

Only code that runs a month or a year beside an interval on SQLite or MySQL **and** catches the
refusal as a `QueryBuildError`. Code that lets the error propagate, or catches `PormGError`, needs
nothing.

### How to find the calls to migrate

```bash
# a month or a year in arithmetic beside an F expression
grep -rnE '(Month|Year)\([^)]*\)' --include=*.jl . | grep -E 'F\(|CTE\('
# the catches that test for QueryBuildError
grep -rnE 'QueryBuildError' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before: the month refusal caught as a QueryBuildError on SQLite
try
  q = M.Race.objects
  q.values("late" => (F("start_at") - F("date")) + Month(1))
  q.list()
catch e
  e isa PormG.QueryBuildError || rethrow()
end

# ✓ after: it is a BackendCapabilityError (a PormGError); catch that type
try
  q = M.Race.objects
  q.values("late" => (F("start_at") - F("date")) + Month(1))
  q.list()
catch e
  e isa PormG.BackendCapabilityError || rethrow()
end
```
