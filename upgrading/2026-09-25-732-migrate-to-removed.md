## `Migrations.migrate_to` removed: it always threw, and wrote to the database first (#732)

- **Version**: Unreleased
- **Recorded**: 2026-09-25
- **PormG ref**: #732; `src/migrations/runner.jl`, `src/Migrations.jl` (export)
- **Severity**: breaking (exported function removed)

### What changed

`PormG.Migrations.migrate_to(db, version)` was exported and documented as "apply pending migrations
up to (and including) a specific version", but it could never do that. The state-based engine keeps
**one** pending plan (`makemigrations` overwrites `pending_migrations.jl`), and a version is minted
only when a plan is applied, so there is no pending version to name. The function returned
`nothing` for a version already applied and threw `InvalidMigrationError` for anything else. Before
either, it ran `init_migrations`, which is `CREATE TABLE pormg_migrations`, even under
`change_db: false`. Its `interactive` and `destructive` keywords were never read.

It is removed, export included. Any call is now an `UndefVarError`. Applying the pending plan is
`migrate`.

### How to find the calls to migrate

```bash
grep -rn "migrate_to" --include=*.jl .
```

Running the app finds them too: ``UndefVarError: `migrate_to` not defined``.

### Migrate your app

```julia
# ✗ before — raised InvalidMigrationError for any version not already applied
PormG.Migrations.migrate_to("db", "20260925101500000")

# ✓ after — apply the pending plan
PormG.Migrations.migrate("db")
```
