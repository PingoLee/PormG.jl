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

### What this means in practice

Because every plan is a fresh diff between your models and the **live database**, PormG migrations behave differently from Django's migration graph — and the differences are deliberate:

- **`makemigrations` never reads previous migration files.** Each run compares your models against the live schema *only*; there is no dependency graph and no replay of earlier migrations to reconstruct state. Migration *order* does not accumulate — the database itself is the accumulated state.
- **Migration files are an audit trail, not the source of truth.** `pending_migrations.jl` and everything under `applied_migrations/` record *what was done*; they are never re-read to plan or apply anything. Editing an already-applied file has **no effect** on future migrations — don't do it, it only desyncs the archive from the authoritative `pormg_migrations` table.
- **You can regenerate freely.** A pending draft you dislike can be dropped with `discard_pending_migration("db")` and re-generated from scratch; there is no graph to keep consistent.
- **"Drift" means the live schema diverging from your models** — an out-of-band `ALTER`/`DROP`, say — not an edited migration file. It is surfaced the normal way: the next `makemigrations` plans to reconcile it, and [`status()`](workflow.md) reports drift signals. Verifying old migration-file checksums buys you nothing here.

!!! tip "Coming from Django?"
    There is no migration graph, no `dependencies` list, and no per-file state replay. Read each `makemigrations` as `diff(your models, the live database)` — closer to Prisma / Atlas / Flyway's declarative diffing than to Django's ordered migration chain.

---

## Terminology Mapping

If you are new to Django-style ORMs, the migration APIs map directly to standard universal database schema-management concepts:

| PormG Command | Django Concept | Universal DB / SQL Concept |
| :--- | :--- | :--- |
| `makemigrations("db")` | `makemigrations` | **Schema Diffing & Script Generation** (compares code to live DB and generates DDL scripts). |
| `migrate("db")` | `migrate` | **Schema Deployment / Execution** (applies the DDL scripts to the live database). |
| `init_migrations("db")` | — | **Bootstrap / Initialization** (registers/creates history tables on an existing database). |
| `dry_run("db")` | — | **Dry Run / Plan Preview** (previews the DDL statements without executing them). |
| `check("db")` | — | **Schema Compatibility Report** (read-only; lists live-schema facts the models cannot faithfully express). |
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

## Changing a Foreign Key

Changing what a foreign key points at is a change to the **constraint**, not to the column. PormG plans it when you change any of:

- the target model — `ForeignKey(Status)` → `ForeignKey(RaceStatus)` (a model bound `RaceStatus` maps to table `racestatus`; set `db_table` if you want another name)
- the target column — a different `pk_field`, or a parent whose key is renamed through `db_column`
- the referential action — `on_delete = CASCADE` → `on_delete = SET_NULL`

On PostgreSQL a constraint cannot be re-pointed in place, so the plan drops it and adds it back. Re-pointing `Result.statusid` from `Status` to a new `RaceStatus` model, with `on_delete = CASCADE`, generates:

```sql
ALTER TABLE "result" DROP CONSTRAINT "result_statusid_a1b2c3d4_fk";
ALTER TABLE "result" ADD CONSTRAINT "result_statusid_zmidlrtp_fk" FOREIGN KEY ("statusid") REFERENCES "racestatus" ("statusid") ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;
```

The dropped constraint is named from the live catalog; the new one gets a fresh random suffix, so the two never collide.

On SQLite the same change goes through the [table rebuild](#SQLite:-Table-Recreation) described below, which re-renders the whole `FOREIGN KEY ... REFERENCES ... ON DELETE` clause from your model. The two backends therefore agree on the outcome; only the DDL differs.

!!! warning "Re-pointing a foreign key needs `destructive = true`"
    The PostgreSQL plan contains `DROP CONSTRAINT`, so `dry_run()` classifies the migration as destructive and `migrate()` refuses it until you opt in with `migrate(path, destructive = true)`. Nothing is dropped except the constraint itself — no column, no data.

    The new constraint is `DEFERRABLE INITIALLY DEFERRED`, so it is validated when the migration **commits**. If any existing row holds a value that does not exist in the new parent, the commit fails and the whole migration rolls back. Re-point the data first, or make the column nullable and clear it, before changing the model.

### Renaming a foreign-key field

Renaming the field is **not** a change to the constraint. On PostgreSQL `ALTER TABLE ... RENAME COLUMN` carries the existing `FOREIGN KEY` along with the column, and on SQLite the stored `FOREIGN KEY ... REFERENCES` clause is rewritten as part of the rename — so PormG renames the column and re-creates its index, and never re-issues the key. Renaming `Result.statusid` to `Result.racestatusid`, with everything else about the key unchanged, generates this on PostgreSQL, in execution order:

```sql
ALTER TABLE "result" RENAME COLUMN "statusid" TO "racestatusid";

ALTER TABLE "result" DROP CONSTRAINT IF EXISTS "result_statusid_a1b2c3d4_idx";
DROP INDEX IF EXISTS "result_statusid_a1b2c3d4_idx";

CREATE INDEX IF NOT EXISTS "result_racestatusid_wpkbcx73_idx" ON "result" ("racestatusid");
```

The **index** is re-created rather than carried over — `ForeignKey` sets `db_index = true` by default, and PormG names indexes with a random suffix it cannot re-derive, so it drops the old one and creates a fresh one against the new column. The `DROP CONSTRAINT IF EXISTS` names that **index**, not the foreign key: it is there because a `UNIQUE` constraint is *implemented by* an index of the same name, and PostgreSQL refuses to drop that index while the constraint owns it — so the constraint goes first. For an ordinary indexed column it is a no-op — a `NOTICE`, nothing more. SQLite emits the bare `DROP INDEX IF EXISTS` and no `ALTER TABLE` for that step.

What the plan does **not** contain is any `DROP CONSTRAINT`/`ADD CONSTRAINT` for the *foreign key*: it is untouched, and keeps its **pre-rename** name. That is harmless — PormG looks a foreign key up by its table and column, never by a name convention, so a later drop or re-point finds it normally. Rename the field *and* change what the key points at in the same migration and you get both: the rename runs first, then the drop, then the add.

!!! warning "Renaming an indexed field needs `destructive = true`"
    The plan contains `DROP INDEX`, which `dry_run()` classifies as destructive — so `migrate()` refuses it until you opt in with `migrate(path, destructive = true)`. Only the field's index is dropped, and the same migration re-creates it against the new column name; no column and no data are removed.

!!! warning "Repairing a duplicate left by an older PormG"
    Before this behavior was fixed, a rename that left the foreign key unchanged **added a second, identical constraint** beside the one the rename carried along. Both point at the same parent with the same action, so inserts and deletes behave identically and nothing surfaces the problem — the model compares converged, so `makemigrations` will never propose removing it.

    It is worth cleaning up rather than ignoring, because the *next* change to that key only removes one of the two. A re-point would drop one constraint and add the new one, leaving a stale constraint still pointing at the **old** parent, permanently and invisibly.

    List the foreign keys on the table and drop the extras by name:

    ```sql
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'result'::regclass AND contype = 'f';

    ALTER TABLE "result" DROP CONSTRAINT "result_statusid_a1b2c3d4_fk";
    ```

    SQLite is unaffected — it has no `ALTER TABLE ADD CONSTRAINT`, so the duplicate was never possible there.

## Database-Specific Behavior

### SQLite: Table Recreation
SQLite has limited `ALTER TABLE` support. It can rename tables/columns and add or drop plain columns, but it **cannot** change a column's type, modify nullability/`UNIQUE`/`CHECK` constraints in place, remove a foreign key (there is no `ALTER TABLE ... DROP CONSTRAINT`), or `DROP COLUMN` on a column that participates in a `FOREIGN KEY`, a `UNIQUE` constraint, or the `PRIMARY KEY`.

To handle any of those changes, PormG automatically rebuilds the table from your model:
- Creates a new table with the desired schema.
- Copies existing data from the old table into it (surviving columns only).
- Re-creates the surviving indexes and foreign keys — an index on a *dropped* column is **not** re-created.
- Drops the old table, renames the new one, and runs `PRAGMA foreign_key_check` to catch orphaned rows.

The rebuild is emitted as plain DDL that composes with the migration's transaction, so no data is lost and the remaining indexes and constraints are preserved. This is what makes **removing a foreign-key field or constraint, a `UNIQUE` column, or a `PRIMARY KEY` column** work on SQLite even though `DROP COLUMN`/`DROP CONSTRAINT` alone cannot express it. Changes SQLite *can* do in place — adding a column, or dropping an *ordinary* column (not part of a `FOREIGN KEY`, `UNIQUE`, or `PRIMARY KEY`) — use `ALTER TABLE` directly, without a rebuild.

This process is transparent to the user but may take longer on very large tables.

**Adding a foreign key to an existing table.** When the column already exists — a `db_constraint = false` key flipped back on, say — the rebuild renders the `FOREIGN KEY` clause from your model, so the constraint really is created, and PormG logs an `@info` noting that the table is being rebuilt, because that cost is worth knowing about on a large table. Re-pointing a key that already exists takes the same rebuild but logs nothing.

!!! warning "A foreign key arriving as a *new* column is not created on SQLite"
    Adding a **new** `ForeignKey` field to an existing table is a plain `ALTER TABLE ... ADD COLUMN`, and SQLite can only declare a foreign key inside `CREATE TABLE`. PormG emits the column without the constraint and does not rebuild the table, so the key exists in your models and not in the database. PostgreSQL adds it normally with `ADD CONSTRAINT`, so this is a backend divergence, not a shared limitation.

    Until this is automated, create the table with the key (a fresh database), or make the change by hand on SQLite.

!!! warning "Dropping a primary key: PostgreSQL vs SQLite"
    Removing a column that is the table's **only** primary key diverges by backend. PostgreSQL's `DROP COLUMN` drops the column and its `PRIMARY KEY` constraint natively, leaving a table with no primary key. SQLite cannot express that without silently degrading the table to a rowid table, so PormG **fails `makemigrations` loudly** instead — declare a replacement primary key, or make the change manually. Dropping a primary-key column while the model still declares a primary key (the key moved to another column) rebuilds normally on both backends.

!!! note "SQLite Limitation"
    Advisory locking is not available for SQLite. Migration safety is single-instance only.
    Do not run concurrent migrations against the same SQLite database.

### PostgreSQL: Advisory Locking
PostgreSQL migrations automatically acquire an advisory lock (`pormg_migrations_{db_name}`) to prevent concurrent migration execution. This ensures safe deployment in multi-instance environments.
