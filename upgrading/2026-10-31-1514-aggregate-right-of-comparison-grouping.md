## A comparison with an aggregate on its right takes the mixed-grouping guard, as on its left (#1514)

- **Version**: Unreleased
- **PormG ref**: #1514 ; `src/querybuilder/operators.jl` (`_compare`, the `JoinedReference` comparisons)
- **Recorded**: 2026-10-31
- **Severity**: behavior change (narrow). A projection that rendered SQL the server rejects now raises `QueryBuildError` when it is built, on every engine.

### What changed

#1514 lets a function sit on the right of a comparison operator (`Lower("forename") == Lower("surname")`,
`F("points") > Coalesce("grid", 0)`). That part is additive: those calls raised before. With it, the
comparison now counts an aggregate on its right, as it already counted one on its left. A projection
that compares a column with an aggregate, and does not group that column, meets the #798
mixed-grouping guard whichever side the aggregate is on.

One spelling already built before #1514: an aggregate inside arithmetic on the right,
`values("name", "b" => F("laps") > Max("points") * 2)`. It rendered a `GROUP BY` over the aggregate
expression, which every engine rejects when the query runs. It now raises the #798 `QueryBuildError`
when the query is built, as its mirror `Max("points") * 2 < F("laps")` already did.

| projection | before | now |
|---|---|---|
| `values("name", "b" => F("laps") > Max("points") * 2)`, run | a server error | `QueryBuildError` (#798) when it is built |
| the same, `show_query`/`inspect_query` | returned the SQL | `QueryBuildError` (#798) |
| `values("name", "b" => Max("points") * 2 < F("laps"))` | `QueryBuildError` (#798) | unchanged |

A `filter` with an aggregate on either side was already refused (#895), and still is.

### Who this affects

Code that projects a comparison of a column with an expression holding an aggregate (`Max`, `Sum`,
`Count`, …) on the right, without grouping that column. That query could not run before.

### How to find the calls to migrate

```bash
grep -rnE '(==|!=|<=|>=|<|>) *\(?(Max|Min|Sum|Avg|Count)\(' --include=*.jl src/ test/
```

For each hit inside a `values(…)`, check whether the left side reads a column that is not grouped.

### Migrate your app

Compute the aggregate one query level down and compare its column, as #798's entry describes:

```julia
best = M.Result.objects
best.values("raceid", "top" => Max("points"))
q = M.Result.objects
q.with("best" => best, join_field = "raceid" => "raceid")
q.values("resultid", "won" => F("points") == CTE("best", "top"))
```
