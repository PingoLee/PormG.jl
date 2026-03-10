# Database Migrations in PormG

PormG provides a simple way to manage database schema changes through migrations, inspired by Django but tailored for Julia and PostgreSQL workflows.

## What Are Migrations?
Migrations are version-controlled scripts that describe changes to your database schema. They allow you to:
- Create new tables and fields
- Alter or remove existing fields
- Apply incremental changes
- Keep your database schema in sync with your Julia models

## How it Works: State-Based Reconciliation
PormG follows a **State-Based** migration philosophy (similar to tools like Flyway or Atlas, rather than purely change-based like Django). 
1. **Introspection**: PormG inspects your live database schema.
2. **Comparison**: It compares the live schema against your in-memory Julia `Models`.
3. **Diffing**: It calculates the "delta" required to move the database to the state defined in your code.
4. **Generation**: It produces a standalone Julia script (`pending_migrations.jl`) containing the DDL commands.

## Database-Specific Behavior

### SQLite: Table Recreation
SQLite has limited `ALTER TABLE` support (it cannot drop columns, change types, or modify nullability/unique constraints directly on existing tables). 

To handle these types of changes, PormG automatically:
- Creates a new temporary table with the desired schema.
- Migrates existing data from the old table to the new one.
- Re-creates indexes and foreign keys.
- Drops the old table and renames the new one.

This process is transparent to the user but may take longer on very large tables.

## Automation & CI/CD

In automated environments where user input is not possible, use the `interactive = false` flag:

```julia
# Bypasses rename confirmations and confirms migration application automatically
makemigrations("my_db", interactive=false)
migrate("my_db", interactive=false)
```

## Migration Workflow

1. **Define Your Connection**
  - By default, PormG uses the `db` as folder to store connection.yml, migration files, and models, but you can specify a different folder by different data base, for example `db_2`.
  - For more information on configuring your connection, see the [Configuration Documentation](index.md).

2. **Define Your Models**
  - If you add the information about your database in folder `db_2`, in file `db_2/connection.yml`, you should also edit your models in `db_2/models.jl` (or your chosen models file).

3. **Generate Migrations**
  - Run the migration generator to detect changes and create migration scripts:
    ```julia
    PormG.Migrations.makemigrations("db_2")
    ```
  - This will generate migration files in `db_2/migrations/pending_migrations.jl`.

4. **Review Pending Migrations**
  - Always review the generated migration plan before applying it, especially in production environments.
  - Remember, PormG.jl is in initial stages, so some features may not be fully implemented or tested.

5. **Apply Migrations**
   - Apply the migrations to your database:
     ```julia
     PormG.Migrations.migrate("db_2")
     ```
   - Applied migrations are moved to `db_2/migrations/applied_migrations/`.

## Example: Full Migration Script

Below is an example script to create and migrate your database:

```julia
using Pkg
Pkg.activate(".")
using PormG
PormG.Configuration.load("db_2")
PormG.Migrations.makemigrations("db_2")
PormG.Migrations.migrate("db_2")
```

## Advanced Usage

### Manual SQL Actions
If you need to perform custom SQL actions (e.g., data migrations, creating views), you can add them to your `pending_migrations.jl` file using the `Migrations.MigrationAction` structure:

```julia
# Inside pending_migrations.jl
push!(actions, Migrations.MigrationAction(
    "Data Migration",
    "UPDATE drivers SET nationality = 'Unknown' WHERE nationality IS NULL;"
))
```

### Data Migrations
For more complex logic, you can use the `with_transaction` block within a migration action or context:

```julia
# This is usually done manually after generating a plan
PormG.with_transaction(PormG.Configuration.get_pool("db_2")) do conn
    # Custom Julia logic or raw SQL
    PormG.DB.execute(conn, "UPDATE ...")
end
```

## Best Practices
- **Incremental Changes:** Make small, incremental changes to your models and run migrations frequently.
- **Review Plans:** Always review pending migrations before applying.
- **Version Control:** Commit your migration files to version control for reproducibility.
- **Backups:** Back up your database before applying migrations in production.

---
For more details, see the [PormG Documentation](index.md) or the example scripts in the `test/integration/` folder.
