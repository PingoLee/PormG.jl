## `==`, `<`, `>`, … on a function or window node build a SQL comparison instead of a Julia `Bool` (#895, #919)

- **Version**: Unreleased
- **PormG ref**: #895, #919 ; `src/querybuilder/operators.jl` (the `FObject` / `WindowFunction` comparisons)
- **Recorded**: 2026-10-11
- **Severity**: behavior change. A Julia comparison whose left side is a SQL function or window node
  returns a different value: an expression, or a `QueryBuildError`, where it used to return a `Bool`
  or raise `MethodError`.

### What changed

`F(...)` has built SQL comparisons for a long time (`F("grid") > 1`). A function node — `Lower`,
`Upper`, `Coalesce`, `Count`, `Sum`, `Max`, … — and a window node (`Rank`, `Lag`, …) did not: `==`
fell back to Julia's identity comparison and `<`/`>` raised `MethodError`. They now build the same
comparison `F` does:

| Expression | before | after |
|---|---|---|
| `Lower("surname") == "senna"` | `false` (a `Bool`) | an `FExpression`; `filter(Lower("surname") == "senna")` renders `WHERE (LOWER("surname") = $1)` |
| `Count("resultid") > 1`, `Rank(over = w) > 1` | `MethodError` | an `FExpression`. `filter(Count(…) > 1)` is refused with `QueryBuildError` (filter the alias to get a `HAVING`), and a window comparison works in a SELECT-side `Case` |
| `Lower("surname") == nothing`, `Count("x") == missing` | `false` | `QueryBuildError` |
| `isequal(a, b)` and `hash` — so `unique`, `Dict` and `Set` over nodes | identity | unchanged |

Comparing two nodes with `==` is no longer an identity test, so `node in nodes` and
`findfirst(==(node), nodes)` over a vector of function nodes raise `QueryBuildError` instead of
returning an answer.

### Who this affects

Julia code that compares a function or window node as a value: `node == nothing` (or `!= nothing`),
`node in list`, `findfirst(==(node), list)`. A filter written with such a comparison now does
what it says instead of receiving `false`.

### How to find the calls to migrate

```bash
grep -rnE '(Lower|Upper|Trim|Coalesce|Concat|Count|Sum|Avg|Max|Min|Rank|Lag|Lead)\([^)]*\) *[!=]=[^=]' --include=*.jl .
grep -rnE '[!=]= *nothing' --include=*.jl .
```

The second grep is broad: check whether the left operand can be a PormG function node.

### Migrate your app

```julia
node = Lower("surname")

# ✗ before — a Julia identity test; now this builds SQL or raises
node == nothing && error("no expression")

# ✓ after — test identity explicitly
isnothing(node) && error("no expression")
```
