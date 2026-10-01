# Advanced Migrations

This page covers the history-table repair operations, and changing data with Julia code around a migration.

The migration engine plans and applies **schema** changes only. It has no data-migration step: no recorded, ordered place in a plan for an `UPDATE` or a backfill. Until it has one, change data with your own code, as described in [Changing Data Around a Migration](#Changing-Data-Around-a-Migration).

---

## Repair Operations

If a migration fails or requires manual intervention, you can use repair commands to update the history table without re-running SQL:

```julia
# Mark a version as manually applied. Supply the migration's SQL (`sql_content`) so the
# recorded checksum is computed from — and later verifiable against — the real statements.
# Passing neither `sql_content` nor an explicit `checksum` is refused: a fabricated digest
# could never be verified and would silently defeat integrity checks.
PormG.Migrations.mark_applied("db", "20260310120000000", "manual_fix";
    sql_content = """ALTER TABLE driver ADD COLUMN nationality VARCHAR(255);""")

# Already have the digest? Pass it explicitly instead of the SQL:
# PormG.Migrations.mark_applied("db", "20260310120000000", "manual_fix"; checksum = "…64-hex…")

# Mark a version as failed
PormG.Migrations.mark_failed("db", "20260310120000000")

# Remove a migration record entirely (use with caution)
PormG.Migrations.remove_migration_record("db", "20260310120000000")
```

`mark_failed` and `remove_migration_record` change a record that already exists. When no record has
the version you pass, they raise `InvalidMigrationError` and change nothing. `status("db")` lists the
recorded versions.

---

## Changing Data Around a Migration

For a data change that goes with a schema change, such as filling a column the last migration added,
use `run_in_transaction`, so the change commits whole or not at all:

```julia
using PormG, LibPQ   # load SQLite instead for a SQLite app

PormG.run_in_transaction("db") do
    # Fetch data
    drivers = M.Driver.objects.filter("code__@isnull" => true).list()

    # Process and Update
    for d in drivers
        code = uppercase(first(d[:surname], 3))
        M.Driver.objects.filter("driverid" => d[:driverid]).update("code" => code)
    end
end
```

This code runs **outside** the migration engine, so none of its guarantees apply:

- **Nothing records it.** No row goes into `pormg_migrations`, and `status()` does not know it ran.
- **It runs every time your code runs it.** Write it so a second run changes nothing. Here the
  `code__@isnull` filter does that: a driver that already has a code is not selected again.
- **It takes no migration lock.** Run it after `migrate()` has returned, not alongside it, and from
  one process.

---

## Best Practices

- **Incremental Changes:** Run migrations frequently for small updates rather than one large update.
- **Review Plans:** Use `dry_run()` before applying to catch any accidental drops.
- **Version Control:** Commit your `applied_migrations/` folder.
- **Backups:** Always back up production databases before running schema changes.
- **Destructive Guard:** Never bypass the destructive guard in CI/CD without manual approval of the migration plan. In a non-interactive context a destructive plan throws `DestructiveMigrationError` unless you pass `destructive=true`; catch it (or set the flag) deliberately rather than blanket-suppressing it.
