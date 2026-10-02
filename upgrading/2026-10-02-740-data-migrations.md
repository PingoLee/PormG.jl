## Data migrations: `Data (pre)`/`Data (post)` plan steps and `run_once`; `DryRunResult` and `MigrationStatus` gain a field (#740)

- **Version**: Unreleased
- **Recorded**: 2026-10-02
- **PormG ref**: #740; `src/migrations/runner.jl` (`run_once`, `_order_statements`, `dry_run`, `DryRunResult`, `status`, `MigrationStatus`), `src/migrations/planner.jl` (`makemigrations`), `src/Dialect.jl` (`pormg_migrations_data`)
- **Severity**: behavior change, narrow. `run_once` is additive. A plan with no label starting `Data (` runs and checksums exactly as before; `DryRunResult` and `MigrationStatus` each gain a positional field.

### What changed

**Data steps in a plan.** An entry whose label starts `Data (pre):` now runs before every schema
statement of the plan, and one starting `Data (post):` after every one. Before, such an entry was an
ordinary statement in the catch-all bucket, ordered by the name of the binding it sat in, so a
backfill could run before its own plan's `ADD COLUMN`.

- A label that reads like a data step but is neither prefix exactly (`Data (Pre):`, `data (post):`,
  a missing colon) now raises `InvalidMigrationError`. Before, it ran in the catch-all bucket.
- `makemigrations` now raises `InvalidMigrationError` instead of overwriting, or moving aside to
  `.discarded`, a pending plan that holds such a step. Apply the plan with `migrate()` first, or move
  the steps out; `discard_pending_migration()` still discards it on request.
- `dry_run()` names the steps: `DryRunResult` gains `data_steps`, its fifth field.

**`run_once`.** `PormG.Migrations.run_once("db", name) do conn … end` runs a Julia step once per
database — on PostgreSQL under the advisory lock `migrate` takes — recorded by name in a new table,
`pormg_migrations_data`.
The `pormg_migrations` table is unchanged. `status()` lists the steps: `MigrationStatus` gains
`data_steps`, its seventh field.

### How to find the calls to migrate

```bash
grep -rniE 'DryRunResult\(|MigrationStatus\(|"data *\(' --include=*.jl .
```

### Migrate your app

```julia
# before
PormG.Migrations.DryRunResult(checksum, statements, destructive, lossy_alters)
PormG.Migrations.MigrationStatus(applied, failed, superseded, pending, has_table, signals)

# after
PormG.Migrations.DryRunResult(checksum, statements, destructive, lossy_alters, data_steps)
PormG.Migrations.MigrationStatus(applied, failed, superseded, pending, has_table, signals, data_steps)
```

A hand-edited plan whose labels read like `Data (…)` is now ordered by them, or refused when one is
misspelt. Rename such an entry if it was not meant as a data step. Data code run with
`run_in_transaction` at boot can move to `run_once`, which records it and runs it once.
