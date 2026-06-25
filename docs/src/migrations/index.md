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

PormG follows a **State-Based** migration philosophy (similar to modern tools like Flyway, Prisma, or Atlas, rather than purely change-based like standard Django). 

1. **Active Introspection**: PormG reads your `connection.yml` file, connects to the specified live database, and introspects its actual physical schema.
2. **Comparison**: It compares that live schema against your in-memory Julia `Models` loaded in the current runtime session.
3. **Diffing**: It calculates the exact "delta" required to move the database to the target state defined in your code.
4. **Generation**: It produces a standalone Julia script (`pending_migrations.jl`) containing the DDL commands.

---

## Terminology Mapping

If you are new to Django-style ORMs, the migration APIs map directly to standard universal database schema-management concepts:

| PormG Command | Django Concept | Universal DB / SQL Concept |
| :--- | :--- | :--- |
| `makemigrations("db")` | `makemigrations` | **Schema Diffing & Script Generation** (compares code to live DB and generates DDL scripts). |
| `migrate("db")` | `migrate` | **Schema Deployment / Execution** (applies the DDL scripts to the live database). |
| `init_migrations("db")` | — | **Bootstrap / Initialization** (registers/creates history tables on an existing database). |
| `dry_run("db")` | — | **Dry Run / Plan Preview** (previews the DDL statements without executing them). |
| `discard_pending_migration("db")` | — | **Discard Generated Script** (deletes the un-applied `pending_migrations.jl` draft; no DB state changes). |

---

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
- **format_version**: The frozen migration-format contract version (see [Migration Format Stability](stability.md))

Filesystem archives (`applied_migrations/`) remain useful for version control and review, but the history table is authoritative.

The exact on-disk file layout, checksum algorithm, and tracking-table columns are a stability contract — see [Migration Format Stability](stability.md).

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
