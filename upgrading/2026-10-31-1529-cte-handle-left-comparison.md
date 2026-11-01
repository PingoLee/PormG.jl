## A `CTE(...)` handle on the left of a comparison builds the comparison (#1529)

- **Version**: Unreleased
- **PormG ref**: #1529 ; `src/querybuilder/operators.jl` (the `CTEReference` comparison family), `src/querybuilder/types.jl` (`FExpression.field_name`, `isequal(::CTEReference, …)`)
- **Recorded**: 2026-10-31
- **Severity**: behavior change on every engine. `CTE(...) == x` returns a predicate where it returned `false`, and `CTE(...) < x` (and `<=`, `>`, `>=`) builds where it raised `MethodError`.

### What changed

A `CTE(...)` handle had no comparison methods. On the left of an operator it fell through to Julia's
`Base`:

| expression | before | now |
|---|---|---|
| `CTE("r91", "round") == 5` | `false` (a `Bool`) | a predicate, as the pair `"r91__round" => 5` |
| `CTE("r91", "raceid") == F("raceid")` | `false` | a predicate: the correlation |
| `CTE("r91", "round") != 5` | `true` | a predicate |
| `CTE("r91", "round") <= 5` (and `<`, `>`, `>=`) | `MethodError: no method matching isless(…)` | a predicate |
| `filter(CTE("r91", "round") == 5)` | reported the `false` it was handed | filters the rows |
| `CTE("r91", "round"; desc = true) > 5` | `MethodError` | `QueryBuildError`: `desc` belongs to `order_by` |
| `CTE("r91", "round") == 1//2` | `false` | `QueryBuildError`, as `F(...) == 1//2` |
| `h in [h]` for a handle `h` | `true` | `TypeError`: `in` calls `==`, which builds a predicate |
| `[h] == [h]` | `true` | `MethodError`, for the same reason |

`F("r91__round")` is not an alternative spelling: a `__` path cannot reach a CTE from inside
`F(...)` (#492). So the handle is the only way to put a CTE column on the left of an operator. As the
right side (`F("raceid") == CTE("r91", "raceid")`, #444) it already worked. `isequal` on a handle stays
`true` or `false`, so a handle still keys a `Dict` or a `Set`. As with `F` and `Joined` (#541), a
container test that calls `==` (`a in v`, `[a] == [b]`) now raises, since `==` builds a predicate;
`isequal`-based ones (`Set`, `Dict`, `unique`, `findfirst(isequal(a), v)`) keep working.

### Who this affects

Code that wrote a `CTE(...)` handle on the left of `==`, `!=`, `<`, `<=`, `>` or `>=`. Before, such a
query either did not build (an ordering) or filtered on a constant `false`/`true` (an equality).
Code that compared two handles with `==` to test whether they name the same column, or looked one up
with `in`, now gets a predicate or an error. Use `isequal` (or `any(isequal(h), v)`) for that.

### How to find the calls to migrate

```bash
grep -rnE 'CTE\([^)]*\) *(==|!=|<=|>=|<|>)' --include=*.jl src/ test/
```

A container lookup over handles (`h in handles`) has no reliable textual pattern: look for collections
of `CTE(...)` values your code builds and checks.

### Migrate your app

A comparison meant as a query condition needs no change: it now does what it says. A comparison meant
as a Julia test of two handles becomes `isequal`:

```julia
same = isequal(CTE("r91", "raceid"), CTE("r91", "raceid"))   # true, a Bool
q.filter(CTE("r91", "round") <= 5)                             # a condition on the CTE's rows
```
