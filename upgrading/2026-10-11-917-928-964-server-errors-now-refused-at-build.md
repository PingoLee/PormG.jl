## Shapes that failed at the server are refused when the query is built: an aggregate or window in a WHERE filter or a join condition, a bare `When`, a column given to `@isnull` / `@range` (#808, #895, #917, #928, #964)

- **Version**: Unreleased
- **PormG ref**: #808, #895, #917, #928, #964 ; `src/querybuilder/build_filter.jl` (`_guard_no_aggregate_predicate`, `_guard_where_operand`, `_guard_no_aggregate_on_condition`), `src/querybuilder/types.jl` (`_is_window_expr`), `src/querybuilder/select_nodes.jl` (`_render_function_typed`)
- **Recorded**: 2026-10-11
- **Severity**: behavior change. The calls below never ran; they now fail earlier and with a
  different error type: `QueryBuildError` (or `FilterError`) from PormG, before any statement is
  sent, instead of a `DatabaseError` from the server.

### What changed

Each of these rendered SQL that neither engine accepts. They are now refused at build time, with a
message that names the spelling that works:

| Query | before | after |
|---|---|---|
| An aggregate in a WHERE-bound filter: `filter((Count("resultid") + 1) > 2)`, `filter("grid" => Max("grid"))` (#895) | `WHERE ((COUNT(…) + $1) > $2)`, `WHERE "grid" = MAX("grid")`, refused by the server | `QueryBuildError`; the message names the alias spelling that renders `HAVING` |
| An aggregate in a join condition: `cjoin_on(…; on = [OP(Count("resultid"), ">", 1)])`, `on("driverid", "number" => Max("grid"))` (#917) | `ON … AND (COUNT(…) > $1)`, refused by the server | `QueryBuildError`; the message points to computing it in a CTE and joining on its column |
| A WHERE-bound filter whose value is a `Case` with a window in a `When` condition: `filter("lap__@gt" => Case([When(Q((Rank(over = w) + 0) > 1), then = 1)], default = 0))` (#928) | `WHERE "lap" > CASE WHEN (((RANK() OVER (…) + $1) > $2)) …`, refused by the server | `QueryBuildError` with the CTE advice |
| A `When` with no `otherwise`, used as a value: `Count(When("positionorder" => 1, then = 1))` (#964) | `COUNT(WHEN … THEN …)`, refused by the server | `QueryBuildError` naming `When(…, otherwise = y)` and `Case([When(…)], default = y)` |
| A column expression as the value of `@isnull` or `@range`: `filter("grid__@isnull" => F("number"))` (#808) | `"grid" ISNULL "number"`, a one-sided `BETWEEN` for `@range`, refused by the server | `FilterError`: `isnull` takes `true` or `false`, `range` two values |

`inspect_query` / `show_query` on these queries raise the same error instead of returning the SQL.
A projected `Case` whose condition holds a window is also no longer added to `GROUP BY` (#928).

### Who this affects

Code that wraps one of these queries in `try … catch e::DatabaseError` (or a subtype) and expected
the failure to arrive from the server. The query itself never returned rows, so no result changes.

### How to find the calls to migrate

```bash
grep -rnE '(isa|::) *(PormG\.)?(DatabaseError|StatementError|OperationalError)\b' --include=*.jl .
grep -rnE '(Count|Sum|Avg|Max|Min)\(When\(' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before — a bare When as a value; the server rejected the statement
M.Result.objects.values("raceid", "wins" => Count(When("positionorder" => 1, then = 1)))

# ✓ after — give it a Case (or an `otherwise`), as the QueryBuildError says
M.Result.objects.values("raceid", "wins" => Count(Case([When("positionorder" => 1, then = 1)])))
```
