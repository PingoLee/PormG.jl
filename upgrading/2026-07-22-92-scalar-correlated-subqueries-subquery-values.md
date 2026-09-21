## Scalar correlated subqueries: `Subquery(...)` in `values()`; unsupported `values()` pairs now throw (#92)

- **PormG ref**: issue #92 (the supported fix for the #74 fan-out guard) ; `src/querybuilder/types.jl`,
  `src/querybuilder/object_manager.jl`, `src/querybuilder/build_query.jl`, `src/querybuilder/build_helpers.jl`,
  `src/QueryBuilder.jl`, `src/PormG.jl`
- **Recorded**: 2026-07-22
- **Severity**: **additive feature + one latent-bug fix to check.** New top-level export `Subquery`;
  `Exists(...)` is now also projectable in `values()`. The check: `values()` used to **silently drop** an
  unsupported `"alias" => <value>` pair — that column just vanished from the result. It now throws an
  `ArgumentError`. Only code that was already getting a wrong/missing column is affected.

### What changed

- **New:** `"alias" => Subquery(inner)` inside `values()` projects a scalar correlated subquery as a
  column. The inner query correlates via `OuterRef(...)` and must project exactly **one** column; an
  aggregate (`Count`, `Sum`, …) or a plain column with `order_by` + `limit(1)` both work. This is the
  fan-out-safe way to attach related-set aggregates — the construct the #74 guard's error message points
  to. Multiple independent `Subquery` columns compose in one query with no fan-out interaction.
- **New:** `"alias" => Exists(inner)` inside `values()` projects a per-row boolean column (SQLite `0`/`1`,
  PostgreSQL booleans). Previously `Exists` was filter-only.
- **Fail-loud fix:** an unsupported right side in a `values()` pair (e.g. `"x" => 42`, or any type the
  projection doesn't handle) now raises `ArgumentError` at `values()` time instead of being silently
  dropped from the SELECT list. Likewise, a **function pair that fails validation** (e.g.
  `"x" => Concat("surname", 42)` — constructs, but `_check_function` rejects the `Int`) used to be
  logged and silently dropped; it now propagates the original error (typically a `MethodError`) after
  logging the failing alias.
- Guard rails: the inner query must project exactly one column (else `ArgumentError`); the alias is
  mandatory (bare `Subquery(...)` throws); a `Subquery`/`Exists` projected *inside another subquery*
  throws (`OuterRef` resolves one level only); a non-aggregate inner with no `LIMIT` emits a build-time
  `@warn` (possible multi-row scalar).

### How to find the calls to migrate

Nothing to migrate for the new feature (additive). For the silent-drop fix, look for `values()` pairs whose
right side is not a field name, SQL function, `Value(x)`, `Subquery(...)`, or `Exists(...)`:

```
rg -n 'values\(' <app> | rg '=>'      # then eyeball non-standard right-hand sides
```

An affected call site was already broken (the column silently missing from results) — the throw makes it
visible.

### Migrate your app

- Nothing required. Optionally adopt `Subquery` where an app worked around the #74 guard with a
  CTE-aggregate join that only needed one scalar per row.
