## `@range` / `@nrange` raise `FilterError`, not `InvalidValueError` (#467)

- **Version**: 0.6.0
- **PormG ref**: #467 ; `src/querybuilder/build_helpers.jl`
- **Recorded**: 2026-09-15
- **Severity**: behavior change — only for code that catches a *specific* `PormGError` subtype.

### What changed

#411 made a wrong-typed filter value report the filter path's own `FilterError` instead of
`InvalidValueError`, which is scoped to the insert/update coercion helpers. One arm was left out:
`BETWEEN` / `NOT BETWEEN` formats its two operands in a branch of its own, outside the re-raise
guard, so `@range` and `@nrange` kept reporting the old type. The same user mistake produced a
different error depending on which operator was used.

Both branches now go through one shared re-raise, so there is a single definition rather than two
that can drift.

```julia
M.Race.objects.filter("date__@range" => ["x", "y"])   # DateField, two wrong-typed operands
# before → InvalidValueError
# after  → FilterError
```

Both are `PormGError`, so `catch e; e isa PormGError` is unaffected. Only a `catch` naming
`InvalidValueError` specifically, around a `@range` / `@nrange` **read**, needs to change — the same
edit #411 already asked for on the scalar and membership operators. Well-typed operands bind exactly
as before.

**#576 completed the conversion** — see its entry above, which supersedes the caveat that stood here.
When this entry was written it named three still-leaking shapes — a `Sum(...)` alias, a
`Max(...)`/`Min(...)` alias and a transform suffix — and told you to keep the handlers guarding
them. Those were the three that were known; joined-path filters and the sargable date rewrite were
leaking too and went unmentioned. Do the whole migration in one pass against #576's entry instead.

### How to find the calls to migrate

```bash
grep -rnE '__@n?range' <your app>/ | xargs -r -n1 dirname | sort -u   # the files to check
grep -rnE 'InvalidValueError' <your app>/ | grep -viE 'insert|update|bulk|create|save'
```

A handler that survived #411 because the query used `@range` is the one this reaches.

### Migrate your app

```julia
# ✗ before
try
    M.Race.objects.filter("date__@range" => [from, to]).list()
catch e
    e isa InvalidValueError && return bad_request("bad date range")
    rethrow()
end

# ✓ after
try
    M.Race.objects.filter("date__@range" => [from, to]).list()
catch e
    e isa FilterError && return bad_request("bad date range")
    rethrow()
end
```
