## `PormG.QueryBuilder` export prune — `query`/`update`/`page` no longer dumped; `OP` internal; `With` import-only (#202)

- **Version**: 0.3.0
- **PormG ref**: issue #202 (follow-up to #35) ; `src/QueryBuilder.jl`, `src/documentation/querybuilder.jl`, `docs/src/{api,read/subqueries_and_ctes}.md`
- **Recorded**: 2026-07-25
- **Severity**: **breaking (submodule export surface)** — affects only code that does a **bare**
  `using PormG.QueryBuilder` and relied on the dumped names, or imported `OP`. The top-level
  `using PormG` surface is unchanged, and the idiomatic `.with()` / `"field__@op"` forms are unchanged.

### What changed

Curating the `#35` export surface one level deeper, inside the `PormG.QueryBuilder` submodule:

- **`query`, `update`, `page` are no longer exported** — a bare `using PormG.QueryBuilder` no longer
  dumps these three generic names into scope (the exact collision class `#35` removed at top level).
  They stay **defined**: explicit `import PormG.QueryBuilder: page` / `using PormG.QueryBuilder: update`
  still work, and the fluent `.page()` / `.update()` methods are unaffected.
- **`OP` is now internal** — un-exported *and* un-documented. Build operator predicates with the
  public string form `"field__@op" => value`; `OP` stays reachable as `PormG.QueryBuilder.OP` for the
  rare function-expression case.
- **`With` is import-only** — reachable via `using PormG.QueryBuilder: With` (the docs teach this); the
  idiomatic form is the fluent `.with(name => subquery; join_field=…)`.

### How to find the calls to migrate

```
rg -n 'using +PormG\.QueryBuilder\s*$' <app>/src     # bare submodule dump that relied on query/update/page
rg -n '\bOP\(' <app>/src                              # OP used after a bare submodule `using`
```

### Migrate your app

```julia
# ✗ before — the bare dump brought query/update/page (+ OP/With) into scope
using PormG.QueryBuilder

# ✓ after — import exactly the names you use
using PormG.QueryBuilder: page, With        # (whichever you actually reference)
q.filter("points__@gte" => 20)              # operator predicates: prefer the string form over OP(...)
```

Apps that use only the top-level `using PormG` surface, or the fluent `.page()` / `.update()` /
`.with()` methods, need **no** change.
