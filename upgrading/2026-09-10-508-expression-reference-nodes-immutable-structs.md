## Expression and reference nodes are immutable `struct`s (#508)

- **Version**: 0.6.0
- **PormG ref**: #508 ; `src/querybuilder/types.jl`, `src/querybuilder/build_helpers.jl`, `src/querybuilder/ctes.jl`, `src/querybuilder/execution.jl`, `src/querybuilder/memos.jl`
- **Recorded**: 2026-09-10
- **Severity**: breaking

### What changed

Seven expression and reference node types are declared `struct` rather than `mutable struct`:
`SQLText` (what `Value(x)` returns), `OperObject`, `FExpression` (what `F(x)` returns),
`OuterRefObject`, `CTEReference`, `FObject` (what `Sum`/`Count`/`Lower`/… return) and
`WindowFunction`.

Assigning to a slot on one of these is now an error at the call site instead of a silent rewrite. The
`F` docstring has promised since #493 that *"every operator builds a new expression and leaves its
operands untouched"*; until now that was held by convention, and the convention had already broken
twice — #457 (a reused `F` handle rendered `(("note" > ?) < ?)`) and #508 phase 1 (a `Value` handle
shared by two queries rewrote the first query's alias).

**The emitted SQL is unchanged.** A 76-shape corpus rendered on both engines produces byte-identical
SQL and byte-identical parameter vectors against the previous release.

Four types stay mutable deliberately, and none is an expression node: `SQLField` (a build product),
`SQLOrder` (an ordering term), and `WindowSpec` / `QObject` / `QorObject` (containers whose in-place
assembly is documented API — `push!` on a `Q` is unaffected).

Seven hand-written `Base.deepcopy` methods were deleted with them. `deepcopy` on any of the seven now
goes through Base, which is *deeper*, not shallower — no app edit is needed, and this is recorded
only so nobody re-adds one.

### How to find the calls to migrate

```bash
grep -rnE '\.(operation|operand|field_name|column|custom_as|_as|aggregate|formatter|function_name|over|path|desc)[[:space:]]*=[^=]' --include='*.jl' .
```

Measured across both consuming apps when this landed: **zero** hits.

### Migrate your app

```julia
# ✗ before — writing a slot on a node you built
s = Sum("points")
s._as = "total"
query.values(s)

f = F("points")
f.operation = "+"
f.operand = 1
query.update("points" => f)

# ✓ after — every node is a value; build the one you want
query.values("total" => Sum("points"))
query.update("points" => F("points") + 1)
```
