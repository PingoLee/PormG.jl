## Pool exhaustion now raises typed `PoolTimeoutError`; expansion ceiling raised to `pool_size × 10`

- **PormG ref**: issue #37 / PR #129 ; `src/ConnectionPool.jl`
- **Recorded**: 2026-07-12
- **Severity**: behavior change (error type changed; pool sizing change)

### What changed

Exhausting the connection pool used to throw a **bare `String`** after a noisy busy-retry loop.
Both the PostgreSQL and SQLite acquire paths now throw `PormG.PoolTimeoutError` (exported; fields
`adapter` / `pool_size` / `max_size` / `attempts` / `elapsed`, with a "raise pool_size" remedy in
`showerror`). The lazy expansion ceiling grew from `pool_size × 5` to `pool_size × 10` (default
pool: 3 base → up to 30 on demand; idle footprint unchanged), and per-retry logging dropped to
`@debug` — a single actionable `@warn` fires only when the pool hits its ceiling.

### How to find the calls to migrate

Grep the app for `catch` blocks that match the old exhaustion message as a string
(e.g. `occursin("No available"` …). Most apps have none — then there is nothing to change; the
new error type and quieter logs just apply.

### Migrate your app

```julia
# ✗ before — the only way to detect exhaustion was string-matching a bare String throw
catch e
    e isa String && occursin("No available", e) && back_off()

# ✓ after — catch the typed error; consider raising pool_size in connection.yml if it fires
catch e
    e isa PormG.PoolTimeoutError || rethrow()
    back_off()
```
