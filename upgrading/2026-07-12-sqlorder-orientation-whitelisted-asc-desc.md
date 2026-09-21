## `SQLOrder` orientation is now whitelisted — only `"ASC"`/`"DESC"` (case-insensitive) construct and render

- **PormG ref**: issue #77 / PR #133 ; `src/querybuilder/types.jl`, `src/querybuilder/build_query.jl`
- **Recorded**: 2026-07-12
- **Severity**: behavior change (new `ArgumentError`; closes an injection seam)

### What changed

A directly constructed `SQLOrder` used to accept **any** string as `orientation` and interpolate
it verbatim into the rendered `ORDER BY` — a SQL-injection seam for apps forwarding a
user-controlled sort direction. Every construction path (and render, guarding post-construction
mutation) now normalizes (`uppercase` + `strip`) and whitelists against `"ASC"`/`"DESC"`, raising
`ArgumentError` for anything else. The documented string API — `.order_by("field")` /
`.order_by("-field")` — was always safe and is unchanged.

### How to find the calls to migrate

Grep the app for direct `SQLOrder(` construction. Only call sites passing a *dynamic*
(user- or data-derived) `orientation` need action; literal `"ASC"`/`"DESC"` in any case keep
working.

### Migrate your app

```julia
# ✗ before — a user-controlled direction string reached the SQL verbatim
dir = params["dir"]   # e.g. "ASC; DROP TABLE results" used to render as-is
query.order_by(SQLOrder(SQLField("points", "points"); orientation = dir))

# ✓ after — map untrusted input onto the whitelist yourself (or handle the ArgumentError)
query.order_by(SQLOrder(SQLField("points", "points");
    orientation = lowercase(dir) == "desc" ? "DESC" : "ASC"))
```
