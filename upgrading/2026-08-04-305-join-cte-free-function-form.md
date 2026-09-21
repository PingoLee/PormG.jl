## The join/CTE free-function form is withdrawn — fluent only (#305)

- **Version**: 0.4.0
- **PormG ref**: #305; `src/QueryBuilder.jl`, `src/querybuilder/ctes.jl`,
  `src/querybuilder/object_manager.jl`, `docs/src/api.md`,
  `docs/src/read/subqueries_and_ctes.md`
- **Recorded**: 2026-08-04
- **Severity**: **breaking (name removal)** — narrow: it affects only code that calls `With(...)` or
  `cjoin(...)` as free functions. Part of the `0.3.x` pre-publish wave.

### What changed

The join/CTE builders had two surfaces: the fluent `.with(...)` / `.cjoin(...)` / `.cjoin_on(...)` /
`.on(...)`, and a free-function form. Only two of the four ever had the second one documented
(`With` was `export`ed from `PormG.QueryBuilder`, `cjoin` was declared `public`), which is why
`on`/`cjoin_on` had to be carved out as permanent exceptions to the naming rule #281 introduced.

**The fluent form is now the only public surface.** All four are internal, renamed under that rule:

```
With  →  _with        cjoin     →  _cjoin
on    →  _on          cjoin_on  →  _cjoin_on
```

A second parallel API is not free: it has to keep working, keep being documented, and keep being
kept in step with the fluent one. #272 is what the drift looks like when it is not — `page` and
`page!` diverged silently until a user hit it. Withdrawing the form before the General-registry
publish is cheap; afterwards it would not be.

`on` and `cjoin_on` lose nothing user-visible — they were never exported, never `public`, and never
documented as functions.
# `With(...)` as a free function — the only form that was exported, so the only one likely in an app
rg -n '(^|[^.\w])With\(' --glob '*.jl'

# the explicit import that made it reachable
rg -n 'using PormG\.QueryBuilder: .*With|import PormG\.QueryBuilder: .*With' --glob '*.jl'

# `cjoin(...)` as a free function. Over-matches: the fluent `.cjoin(` in a trailing-dot chain
# lands on its own line, so read the hits rather than assuming every one needs an edit.
rg -n '(^|[^.\w])cjoin\(' --glob '*.jl'

# The QUALIFIED form. The two patterns above exclude anything preceded by `.`, so they cannot
# see this one — and it is the spelling the old docs offered as the alternative
# ("or qualify: PormG.QueryBuilder.With(...)"), so it is the likeliest to be in an app.
rg -n 'QueryBuilder\.(With|cjoin|cjoin_on|on)\(' --glob '*.jl'
```

### Before → after

```julia
# before — free-function form, needing an explicit import
using PormG.QueryBuilder: With

races_91 = M.Race.objects.filter("year" => 1991).values("raceid")
q = M.Result.objects
With(q.object, "r91", races_91, join_field = "raceid" => "raceid")
q.filter("positionorder" => 1)

# after — the fluent method, no import needed
races_91 = M.Race.objects.filter("year" => 1991).values("raceid")
q = M.Result.objects.
    with("r91" => races_91, join_field = "raceid" => "raceid").
    filter("positionorder" => 1)
```

Note the argument shape differs: the free function took the CTE name and sub-query as two positional
arguments plus `q.object` (the underlying `SQLObject`); the fluent method takes a `Pair` and operates
on the handler. Same for `cjoin(query, "result" => "Result")` → `query.cjoin("result" => "Result")`.
