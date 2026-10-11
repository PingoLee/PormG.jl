## `mark_failed` / `remove_migration_record` refuse a version with no record, and a plan that repeats a label is refused (#733)

- **Version**: Unreleased
- **PormG ref**: #733 ; `src/migrations/runner.jl` (`_require_recorded_version`, `mark_failed`, `remove_migration_record`, `_read_plan_dict`)
- **Recorded**: 2026-10-11
- **Severity**: behavior change. Two repair calls and the plan reader raise
  `InvalidMigrationError` where they used to succeed silently.

### What changed

| Call | before | after |
|---|---|---|
| `PormG.Migrations.mark_failed("db", version)` with a version that has no history row | matched zero rows, logged success (and created the history table on a fresh database) | `InvalidMigrationError`; nothing is written |
| `PormG.Migrations.remove_migration_record("db", version)` with such a version | the same | `InvalidMigrationError`; nothing is written |
| `migrate` / `dry_run` on a plan file whose dict repeats a label | kept only the last statement under that label, silently | `InvalidMigrationError` naming the label |

`makemigrations` never writes a repeated label; only a hand-edited plan can hold one.

### Who this affects

Repair scripts that call `mark_failed` or `remove_migration_record` with a version that may not
be recorded (a typo, a version from another database, a re-run after the record was already
removed), and teams that edit pending plan files by hand.

### How to find the calls to migrate

```bash
grep -rnE 'mark_failed\(|remove_migration_record\(' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before — a mistyped version "succeeded" and changed nothing
PormG.Migrations.remove_migration_record("db", "2026031012000000")

# ✓ after — it raises; check what is recorded first
PormG.Migrations.status("db")
PormG.Migrations.remove_migration_record("db", "20260310120000000")
```
