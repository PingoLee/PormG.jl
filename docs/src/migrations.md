# Database Migrations in PormG

PormG provides a structured way to manage database schema changes through migrations, inspired by Django but tailored for Julia and PostgreSQL/SQLite workflows.

## What Are Migrations?
Migrations are version-controlled scripts that describe changes to your database schema. They allow you to:
- Create new tables and fields
- Alter or remove existing fields
- Apply incremental changes
- Keep your database schema in sync with your Julia models
- Track migration history with checksums and status

## How it Works: State-Based Reconciliation
PormG follows a **State-Based** migration philosophy (similar to tools like Flyway or Atlas, rather than purely change-based like Django). 
1. **Introspection**: PormG inspects your live database schema.
2. **Comparison**: It compares the live schema against your in-memory Julia `Models`.
3. **Diffing**: It calculates the "delta" required to move the database to the state defined in your code.
4. **Generation**: It produces a standalone Julia script (`pending_migrations.jl`) containing the DDL commands.

## Migration History Table

PormG uses a `pormg_migrations` table as the **canonical runtime source of truth** for tracking applied migrations. This table is created automatically when you run `migrate()` or `init_migrations()`.

Each migration record contains:
- **version**: A unique timestamp-based identifier (YYYYMMDDHHmmssSSS)
- **name**: A human-readable migration name
- **checksum**: SHA-256 hash of the SQL content for integrity verification
- **sql_content**: The full SQL that was applied
- **applied_at**: Timestamp of when the migration was applied
- **status**: One of `applied`, `failed`
- **is_destructive**: Whether the migration contained DROP operations

Filesystem archives (`applied_migrations/`) remain useful for version control and review, but the history table is authoritative.

## Database-Specific Behavior

### SQLite: Table Recreation
SQLite has limited `ALTER TABLE` support (it cannot change types or modify nullability/unique constraints directly on existing tables). 

To handle these types of changes, PormG automatically:
- Creates a new temporary table with the desired schema.
- Migrates existing data from the old table to the new one.
- Re-creates indexes and foreign keys.
- Drops the old table and renames the new one.

This process is transparent to the user but may take longer on very large tables.

!!! note "SQLite Limitation"
    Advisory locking is not available for SQLite. Migration safety is single-instance only.
    Do not run concurrent migrations against the same SQLite database.

### PostgreSQL: Advisory Locking
PostgreSQL migrations automatically acquire an advisory lock (`pormg_migrations_{db_name}`) to prevent concurrent migration execution. This ensures safe deployment in multi-instance environments.

## Migration Workflow

1. **Define Your Connection**
  - By default, PormG uses the `db` folder to store `connection.yml`, migration files, and models.
  - For more information on configuring your connection, see the [Configuration Documentation](index.md).

2. **Define Your Models**
  - Edit your models in `db/models.jl` (or your chosen models file).

3. **Bootstrap the History Table** (first time only)
  ```julia
  PormG.Migrations.init_migrations("db_2")
  ```
  This is called automatically by `migrate()`, but you can run it explicitly.

4. **Generate Migrations**
  ```julia
  PormG.Migrations.makemigrations("db_2")
  ```
  This generates `db_2/migrations/pending_migrations.jl`.

5. **Review Pending Migrations**
  - Always review the generated migration plan before applying.
  - Use `dry_run()` for a detailed analysis:
    ```julia
    result = PormG.Migrations.dry_run("db_2")
    println(result)
    ```
  This shows all SQL statements, detects destructive operations, and computes checksums without modifying the database.

  - For an interactive review workflow, you can open the Tachikoma dashboard after `makemigrations()`:
    ```julia
    using Tachikoma
    using PormG

    PormG.@import_models "db_2/models.jl" models
    import .models as M

    PormG.tui("db_2"; models_module=M)
    ```
  The dashboard currently provides:
  - a **Migrations** pane for `status()`, `dry_run()`, `init_migrations()`, and `migrate()`
  - an **Inspection** pane for `inspect_query()` against your loaded model module
  Run `makemigrations()` before launching the dashboard when you want to review a newly generated `pending_migrations.jl` file.

6. **Check Status**
  ```julia
  s = PormG.Migrations.status("db_2")
  println(s)
  ```
  Reports applied migrations, failed migrations, pending files, and drift signals.

7. **Apply Migrations**
   ```julia
   PormG.Migrations.migrate("db_2")
   ```
   Applied migrations are recorded in `pormg_migrations` and archived to `db_2/migrations/applied_migrations/`.

## Destructive Operations Safety

PormG detects destructive SQL operations (DROP TABLE, DROP COLUMN, TRUNCATE) and **blocks them by default**. To apply migrations containing destructive operations, you must explicitly opt in:

```julia
# This will be rejected:
PormG.Migrations.migrate("db_2", interactive=false)
# → Error: Migration contains destructive operation(s). Pass destructive=true to confirm.

# Explicitly allow destructive operations:
PormG.Migrations.migrate("db_2", interactive=false, destructive=true)
```

The dry-run output also highlights destructive statements for review.

## Automation & CI/CD

In automated environments where user input is not possible:

```julia
# Non-interactive, safe migrations only
PormG.Migrations.makemigrations("my_db", interactive=false)
PormG.Migrations.migrate("my_db", interactive=false)

# Non-interactive with destructive operations allowed
PormG.Migrations.migrate("my_db", interactive=false, destructive=true)
```

## Terminal Dashboard

PormG includes an optional Tachikoma-based terminal dashboard through the `PormGTachikomaExt` package extension.
This is useful when you want a terminal-first migration review flow instead of reading `dry_run()` output as plain text.

### Requirements

Load Tachikoma before calling `PormG.tui()`:

```julia
using PormG
using Tachikoma
```

If Tachikoma is not loaded, `PormG.tui()` falls back to a stub that throws an explanatory error.

The dashboard currently requires a Unix-like environment.
At the moment, Tachikoma's app loop uses Unix-style file descriptor operations such as `dup`, so `PormG.tui()` is not usable on native Windows yet.
Use Linux, macOS, or WSL for the dashboard workflow.

### Launching the Dashboard

The dashboard takes:
- the database definition folder, such as `"db_2"`
- an optional `models_module` for query inspection

```julia
using Pkg
Pkg.activate(".")

using PormG
using Tachikoma

PormG.Configuration.load("db_2")
PormG.@import_models "db_2/models.jl" models
import .models as M

PormG.tui("db_2"; models_module=M)
```

### What the Dashboard Does

- **Migrations pane**: review `status()`, run `dry_run()`, bootstrap `init_migrations()`, and apply `migrate()`
- **Inspection pane**: inspect generated SQL, parameters, dialect, and parameter buckets through `inspect_query()`

### Current Limitation

The dashboard does **not** generate migration plans by itself yet.
The intended workflow is still:

```julia
PormG.Migrations.makemigrations("db_2")
PormG.tui("db_2"; models_module=M)
```

That means `makemigrations()` remains the step that creates `pending_migrations.jl`, while the dashboard is the place to review and apply it.

From the interactive test REPL started by `test/integration/common_setup.jl`, the correct variable is `PORMG_DB_FOLDER`, not `DB_KEY`:

```julia
PormG.tui(PORMG_DB_FOLDER; models_module=M)
```

On native Windows this will now fail immediately with a clear platform error instead of surfacing a lower-level symbol loading error.

## Repair Operations

If a migration fails partially or requires manual intervention:

```julia
# Mark a version as manually applied (after manual SQL execution)
PormG.Migrations.mark_applied("db_2", "20260310120000", "manual_fix")

# Mark a version as failed (after investigation)
PormG.Migrations.mark_failed("db_2", "20260310120000")

# Remove a migration record entirely (use with caution)
PormG.Migrations.remove_migration_record("db_2", "20260310120000")

# Check current status after repair
PormG.Migrations.status("db_2")
```

## Example: Full Migration Script

Below is an example script to create and migrate your database:

```julia
using Pkg
Pkg.activate(".")
using PormG
PormG.Configuration.load("db_2")

# Check current status
PormG.Migrations.status("db_2")

# Generate migration plan
PormG.Migrations.makemigrations("db_2")

# Review what will be applied
PormG.Migrations.dry_run("db_2")

# Apply the migrations
PormG.Migrations.migrate("db_2")

# Verify
PormG.Migrations.status("db_2")
```

### Example: Full Migration Script with Dashboard

This variant is useful for local debugging when you want to generate the plan in code and then inspect it interactively:

```julia
using Pkg
Pkg.activate(".")

using PormG
using Tachikoma

DB_KEY = "test/integration/db_sl"

PormG.Configuration.load(DB_KEY)
PormG.@import_models "test/integration/db_sl/models.jl" SL_Models
import .SL_Models as M

PormG.Migrations.init_migrations(DB_KEY)
PormG.Migrations.makemigrations(DB_KEY)

# Review and optionally apply from the dashboard
PormG.tui(DB_KEY; models_module=M)
```

## Advanced Usage

### Manual SQL in Pending Migrations
If you need to perform custom SQL actions (e.g., data migrations, creating views), you can manually edit the generated `pending_migrations.jl` file. Add your SQL as additional `OrderedDict` entries:

```julia
# Inside pending_migrations.jl — add after the auto-generated entries:
custom_data_fix = OrderedDict{String, String}(
    "Data fix: normalize nationality" =>
    \"\"\"UPDATE drivers SET nationality = 'Unknown' WHERE nationality IS NULL;\"\"\"
)
```

!!! warning "Future Enhancement"
    A first-class data migration action API is planned for a future release.
  For now, manual SQL edits in `pending_migrations.jl` are the supported approach for statement-based SQL.
  Ordered multi-file targeted execution and richer procedural migration bodies are not implemented yet.

### Data Migrations with Transactions
For complex logic beyond schema changes, use `run_in_transaction` directly:

```julia
PormG.run_in_transaction(PormG.Configuration.get_settings("db_2").connections) do
    # Custom Julia logic
    PormG.ConnectionPool.fetch(PormG.Configuration.get_settings("db_2").connections, 
        "UPDATE drivers SET code = UPPER(SUBSTRING(surname, 1, 3)) WHERE code IS NULL;")
end
```

## Best Practices
- **Incremental Changes:** Make small, incremental changes to your models and run migrations frequently.
- **Review Plans:** Always review pending migrations before applying. Use `dry_run()`.
- **Version Control:** Commit your migration files to version control for reproducibility.
- **Backups:** Back up your database before applying migrations in production.
- **Check Status:** Use `status()` before and after migrations to verify the state.
- **Destructive Guard:** Never bypass the destructive guard in production without careful review.

---
For more details, see the [PormG Documentation](index.md) or the example scripts in the `test/integration/` folder.
