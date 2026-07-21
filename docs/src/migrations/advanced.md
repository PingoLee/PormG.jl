# Advanced Migrations

Beyond schema changes, PormG supports custom SQL migrations, repair operations, and data migrations using transactions.

## Manual SQL in Pending Migrations

If you need to perform custom SQL (e.g., creating views, adding initial data, or complex indexing), you can manually edit the generated `pending_migrations.jl` file. Add your SQL as `OrderedDict` entries after the auto-generated ones:

```julia
# Inside pending_migrations.jl
custom_entries = OrderedDict{String, String}(
    "Normalize nationality" =>
    \"\"\"UPDATE drivers SET nationality = 'Unknown' WHERE nationality IS NULL;\"\"\"
)
```

!!! warning "Manual Editing"
    Always keep the `OrderedDict` structure. PormG will compute checksums for your custom entries and record them in the history table.

---

## Repair Operations

If a migration fails or requires manual intervention, you can use repair commands to update the history table without re-running SQL:

```julia
# Mark a version as manually applied. Supply the migration's SQL (`sql_content`) so the
# recorded checksum is computed from — and later verifiable against — the real statements.
# Passing neither `sql_content` nor an explicit `checksum` is refused: a fabricated digest
# could never be verified and would silently defeat integrity checks.
PormG.Migrations.mark_applied("db", "20260310120000", "manual_fix";
    sql_content = \"\"\"ALTER TABLE drivers ADD COLUMN nationality VARCHAR(255);\"\"\")

# Already have the digest? Pass it explicitly instead of the SQL:
# PormG.Migrations.mark_applied("db", "20260310120000", "manual_fix"; checksum = "…64-hex…")

# Mark a version as failed
PormG.Migrations.mark_failed("db", "20260310120000")

# Remove a migration record entirely (use with caution)
PormG.Migrations.remove_migration_record("db", "20260310120000")
```

---

## Data Migrations with Transactions

For complex logic that requires Julia-side data processing, use `run_in_transaction` to ensure atomicity:

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

---

## Best Practices

- **Incremental Changes:** Run migrations frequently for small updates rather than one large update.
- **Review Plans:** Use `dry_run()` before applying to catch any accidental drops.
- **Version Control:** Commit your `applied_migrations/` folder.
- **Backups:** Always back up production databases before running schema changes.
- **Destructive Guard:** Never bypass the destructive guard in CI/CD without manual approval of the migration plan.
