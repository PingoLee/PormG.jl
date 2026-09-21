## Typed exceptions across the query surface — raw-`String` throws are now `ArgumentError`/`ErrorException` (#197)

- **Version**: 0.2.0
- **PormG ref**: issue #197 ; `src/querybuilder/` (`build_helpers.jl`, `build_joins.jl`, `build_query.jl`,
  `ctes.jl`, `deletion.jl`, …), `src/Configuration.jl`, `src/migrations/planner.jl`
- **Recorded**: 2026-07-23
- **Severity**: **breaking (error type)** — ~46 raw-string `throw("...")` sites now raise typed
  exceptions. No new exported types (existing `ArgumentError`/`ErrorException` +
  `DoesNotExist`/`MultipleObjectsReturned`/pool errors cover the surface).

### What changed

Every `throw("...")` in the query builder — a bare `String`, which is **not** an `Exception` — plus
stragglers in `Configuration.jl` and `migrations/planner.jl` now throws a typed exception:

- `ArgumentError` for user misuse (bad args, unsupported `values()` pairs, malformed lookups, …);
- `ErrorException` (via the internal `_unsupported_conn` helper) for internal dispatch fallbacks;
- `bulk_insert`'s catch blocks now `@error` + `rethrow()`, so the original driver exception survives
  instead of being reduced to a string.

A raw `String` throw escaped every `catch e; e isa Exception` a package user could write — so any
error handling that expected a real exception silently failed to match. Now `e isa Exception` (and
`e isa ArgumentError`) behave as expected.

### How to find the calls to migrate

Grep each app for `catch` blocks that **string-match** a PormG error rather than catching a type:

```
rg -n "catch" <app>/src | rg -iE "isa String|occursin\("
```

Only handlers that string-matched a PormG throw are affected. A `catch e … rethrow()`, or a handler
already keyed on `ArgumentError`/`ErrorException`/`DoesNotExist`/`PoolTimeoutError`, needs no change.

### Migrate your app

```julia
# ✗ before — the throw was a bare String; `e isa String` was the only way to match, and
#            `e isa Exception` never fired
catch e
    e isa String && occursin("<PormG error text>", e) && handle()

# ✓ after — catch the typed exception; read the text off `.msg`
catch e
    e isa ArgumentError && occursin("<PormG error text>", e.msg) && handle()
```

If a handler only needs "PormG rejected this call", `e isa Exception` (or the narrower
`e isa ArgumentError`) now suffices — no string matching required.
