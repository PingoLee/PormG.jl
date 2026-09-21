## `first()` / `get()` no longer mutate the handler (#199)

- **Version**: 0.2.3
- **PormG ref**: issue #199 ; `src/querybuilder/execution.jl` (`first`, `get`),
  `docs/src/read/index.md` (new *Handler Mutation Model* section)
- **Recorded**: 2026-07-24
- **Severity**: footgun fix — **no action expected**. Classified non-breaking: the only affected
  code exploits `first()`'s documented limit-leak workaround or `get()`'s *undocumented*
  filter-persistence side effect.

### What changed

All read terminals now share one contract: they execute on an internal copy and never mutate the
handler. Previously `first()` permanently set `limit(1)` on the handler and `get(q, filters...)`
permanently appended its inline filters to it — `count`/`exists`/`list` already copied. Re-call
semantics of chain methods are unchanged (and now documented): `filter` accumulates,
`values`/`order_by` replace their previous call.

```julia
# ✗ before — handler reuse after first()/get() silently carried leaked state:
q = M.Driver.objects.filter("nationality" => "British")
q.first()                                # left limit=1 on q
q.list()                                 # returned 1 row (leaked limit)
q.update("nationality" => "English")     # threw: UPDATE with LIMIT is not supported

r = M.Result.objects
r.get("resultid" => 1)                   # appended the inline filter to r
r.count()                                # counted WHERE resultid = 1 (leaked filter)

# ✓ after — the handler is untouched; same calls, no leaked state:
q.first()                                # q unchanged (limit stays 0)
q.list()                                 # all matching rows
q.update("nationality" => "English")     # valid on the same handler

r.get("resultid" => 1)                   # r unchanged
r.count()                                # counts ALL results
```

### How to find the calls to migrate

Nothing to migrate unless an app **reuses a handler after** `.first()`/`.get()` *and relies on the
leaked state* (a limit-1 `list()`, or inline `get` filters narrowing later calls). Grep each app for
a handler variable used again after one of these terminals:

```
rg -n '\.(first|get)\(' <app>/src        # then eyeball: is that handler variable used again below?
```

One-handler-per-query code (the documented style) is unaffected.
