## `makemigrations` raises when it cannot read the live schema, instead of logging and returning `nothing` (#1018)

- **Version**: Unreleased
- **PormG ref**: #1018 ; `src/migrations/planner.jl` (`makemigrations`)
- **Recorded**: 2026-10-11
- **Severity**: behavior change. A call that returned `nothing` now raises.

### What changed

`makemigrations` reads the live schema before it plans. When that read failed (a permission error,
a dropped connection, a catalog query the server refused), both engines printed the error, logged
it with `@error`, and **returned `nothing`** — the same value a successful run returns — without
writing a plan. The read's own error now propagates, as it already did from `migrate`'s
precondition and from `check()`.

| | before | after |
|---|---|---|
| The schema read fails | `@error` logged, `nothing` returned, no plan written | the read's error is raised (typically a `DatabaseError` subtype), no plan written |
| An empty database | planned every model | unchanged: its catalog reads as no tables |

### Who this affects

A deploy or CI script that calls `makemigrations` and continues when it returns, relying on the log
line to notice a failed read. Such a script now stops with the error.

### How to find the calls to migrate

```bash
grep -rnE 'makemigrations\(' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before — a failed read looked like "nothing to plan"
PormG.Migrations.makemigrations("db")
PormG.Migrations.migrate("db"; interactive = false)

# ✓ after — the failed read raises from makemigrations. Let it stop the deploy, or catch it
#   explicitly if the script has a fallback
try
    PormG.Migrations.makemigrations("db")
catch e
    e isa PormG.DatabaseError || rethrow()
    @error "schema read failed; not migrating" exception = e
    exit(1)
end
PormG.Migrations.migrate("db"; interactive = false)
```
