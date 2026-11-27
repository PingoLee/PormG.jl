## A copied query copies a nested query as it copies itself: values the caller passed to it stay shared (#1684)

- **Version**: Unreleased
- **PormG ref**: #1684 ; `src/querybuilder/types.jl`
- **Recorded**: 2026-11-27
- **Severity**: behavior change, only for a caller that changes a value it passed to a query nested inside another query
  after copying the outer one. Every copy renders the same SQL and parameters at the time it is made, as before.

### What changed

`.copy()` (and every copy PormG makes of a query: an `Exists` render, `inspect_query`) is now made at the query's types
instead of through Julia's generic `deepcopy` walk, so it also runs in a `juliac --trim` binary.

A query copies its own `on()` conditions and `__@in` querysets by sharing the values the caller passed (the vector given
to `on("circuitid", "country__@in" => countries)`, the queryset given to `filter("circuitid__@in" => monaco)`): the copy
gets its own lists, holding the caller's values. That was already so for the outer query, and for a `Subquery` used as a
filter value. A query nested **in the projection, in an `F` expression, in an `order_by` term, or in a value written by
`update`** was instead cloned completely by the generic walk, the caller's values included. It is now copied by the same
rule as the outer query. CTE bodies (`.with(…)`) already followed this rule since #1833.

| the call | before | now |
|---|---|---|
| `countries = ["Monaco"]`; `sub = M.Race.objects.on("circuitid", "country__@in" => countries).filter("circuitid" => OuterRef("circuitid")).values("round")`; `q = M.Circuit.objects.values("name", "r" => Subquery(sub))`; `dup = q.copy()`; `push!(countries, "Brazil")` | `dup` renders as before the `push!` (one bound country) | `dup` renders with both countries, as `q` does |
| the same with `sub.filter("raceid__@in" => inner)` and a later `inner.filter(…)` | `dup` unchanged | `dup` sees `inner`'s new filter, as `q` does |
| any of the above with the nested query used as a filter value (`filter("circuitid" => Subquery(sub))`), or with the outer query's own `on()` | `dup` sees the change | unchanged: `dup` sees the change |

Fluent calls on the outer query or on the copy (`filter`, `order_by`, `values`, `on`, …) still never reach the other one.

### How to find the calls to migrate

Look for a value (a vector, a queryset) passed to `on()` or `__@in` inside a `Subquery`/`Exists` that sits in `values()`,
`order_by()` or an `F` expression, and changed after the outer query was copied:

```
grep -rn "\.copy()" --include=*.jl .
```

### Migrate your app

```julia
# ✗ before: relied on the copy holding its own clone of `countries`
# ✓ after: pass the copy a value of its own, or build the nested query again
countries = ["Monaco"]
sub = M.Race.objects.on("circuitid", "country__@in" => copy(countries)).
    filter("circuitid" => OuterRef("circuitid")).values("round")
```
