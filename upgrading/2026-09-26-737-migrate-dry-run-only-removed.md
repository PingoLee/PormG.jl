## `migrate(…; dry_run_only = true)` is removed — use `dry_run(…)` (#737)

- **Version**: Unreleased
- **Recorded**: 2026-09-26
- **PormG ref**: #737; `src/migrations/runner.jl` (`migrate`, `dry_run`)
- **Severity**: breaking (keyword argument removed)

### What changed

`migrate(…; dry_run_only = true)` returned a `DryRunResult`, so `migrate` had two return types. It
was also not dry: it created the `pormg_migrations` table and installed the configured extensions
before returning. `migrate` now always returns a `MigrationResult`, and the keyword is gone.
Passing it is a `MethodError` (``no method matching migrate(…; dry_run_only::Bool)``), through either
`migrate(db; …)` or `migrate(connection, settings; …)`.

`dry_run("db")` returns the same `DryRunResult` (checksum, ordered statements, destructive
statements), and it only reads the plan file.

### How to find the calls to migrate

```bash
grep -rn 'dry_run_only' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before — also wrote the history table and the extensions
r = PormG.Migrations.migrate("db"; dry_run_only = true)

# ✓ after — reads the plan, writes nothing
r = PormG.Migrations.dry_run("db")
```
