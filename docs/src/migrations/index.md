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
- **Both sides are compared as columns, not as field types.** Each declared field compiles to a canonical description of the column it renders — type, nullability, key, uniqueness, default, foreign key, CHECKs, identity — and the live schema is read straight into the same description from the catalog. Two fields that render the same column (`CharField`, `URLField` and `SlugField` with the same length; a `ForeignKey(unique = true)` and a `OneToOneField`) are therefore one column to the diff, and nothing about a live column is inferred from which field type it "looks like".

!!! note "Adopting a schema PormG did not create"
    Because the live side is read as facts, a column that no declaration could produce shows up as a **one-time plan** rather than being silently equated with the nearest field type — after it is applied, the schema converges:

    - a `SMALLINT` / `INTEGER UNSIGNED` column without its `>= 0` CHECK plans `ADD CHECK` once against a `PositiveSmallIntegerField` / `PositiveIntegerField`;
    - a foreign-key column with no index plans `CREATE INDEX` once against a `ForeignKey` (which declares `db_index = true` by default) — declare `db_index = false` if you do not want one;
    - a lengthless `varchar` or an unparameterised `numeric` plans the declared width once;
    - a column type PormG has no field for (`inet`, `citext`, an array, `character(n)`) never matches a declared `TextField` or `CharField`: `generate_models_from_db` emits `TextField` for it **with a warning**, and `makemigrations` plans a retype unless you exclude the table or declare the column by hand.

    Tables PormG created itself always carry these facts, so nothing changes for them.

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

### Renaming a field

**A rename plans the rename.** Both backends carry a column's own baggage across
`ALTER TABLE ... RENAME COLUMN` — its indexes, its `UNIQUE` constraint, its `PRIMARY KEY`, and its
`FOREIGN KEY` — so when nothing else about the field changed, that one statement is the whole plan.
Renaming `Result.statusid` to `Result.racestatusid`, with everything else about the key unchanged:

```sql
ALTER TABLE "result" RENAME COLUMN "statusid" TO "racestatusid";
```

That is all, on both engines, and it holds for a plain field, an indexed field
(`ForeignKey` sets `db_index = true` by default), a `unique = true` field, and one that is both.

The **index keeps its old name**. PormG names indexes with a random suffix it cannot re-derive, so an
index created for `statusid` stays `result_statusid_a1b2c3d4_idx` while covering `racestatusid`. That
is cosmetic: nothing reads the name — PormG matches an index by its real column membership — and
`makemigrations` sees the column as indexed on both sides afterwards, so it plans nothing further.
The alternative would be dropping and re-creating the index on every rename, which rebuilds it from
scratch on a large table to change a string nobody reads.

The **foreign key** likewise keeps its pre-rename name, and that too is harmless: PormG looks a key
up by its table and column, never by a name convention, so a later drop or re-point finds it.

#### When a rename carries more than a rename

A rename is the same column change with a new name, so if the field *also* changed, the plan carries
that change too — the `RENAME COLUMN` first, then exactly what an ordinary alteration of that column
would have emitted. Rename `Result.statusid` to `Result.racestatusid` **and** change the key — a
different parent, a different target column, or a different `ON DELETE`; any of the three re-issues
the constraint — and you get the drop, the rename, and the new constraint, in that order:

```sql
ALTER TABLE "result" DROP CONSTRAINT "result_statusid_a1b2c3d4_fk";

ALTER TABLE "result" RENAME COLUMN "statusid" TO "racestatusid";

ALTER TABLE "result" ADD CONSTRAINT "result_racestatusid_wpkbcx73_fk"
  FOREIGN KEY ("racestatusid") REFERENCES "status" ("statusid") ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;
```

The drop comes first and names the **pre-rename** column, because that is what the live catalog knows
when the plan is built; the add names the new one, because by then the rename has run. On SQLite the
same change is one table rebuild, emitted after the `RENAME COLUMN`.

Two renames on the same table in one migration are fine, and so is a rename alongside a new column:
SQLite collapses them into a single rebuild placed after every rename and every `ADD COLUMN`.

!!! note "On SQLite, a rename combined with another change may leave its index for the next run"
    The rebuild re-creates the renamed column's secondary indexes when the rename is what registered
    it. But a rename that co-occurs with an ordinary column alteration, or with a new column, on the
    *same* table produces one rebuild for all of them — and that one may not carry the rename, in
    which case the renamed column's index is not re-created. No column and no data are affected, and
    the next `makemigrations` sees the column as unindexed and plans the `CREATE INDEX`. Renaming on
    its own, or renaming two columns together, always keeps the indexes.

!!! warning "A rename that DROPS a constraint needs `destructive = true`"
    Renaming a field is not destructive. But if the same change also removes a `UNIQUE` constraint or
    a `PRIMARY KEY`, the plan contains `DROP CONSTRAINT` (PostgreSQL) or a table rebuild whose
    `DROP TABLE` is part of the recreation (SQLite) — and `dry_run()` classifies either as
    destructive, so `migrate()` refuses it until you opt in with `migrate(path, destructive = true)`.

    On **SQLite** the opt-in is needed for *any* rename that also changes the column — a retype, a
    nullability change, a re-pointed key — because SQLite alters a column by recreating the table.
    The recreation copies every row; no column and no data are lost, but `DROP TABLE` is what the
    classifier sees. On **PostgreSQL** the same changes are in-place
    `ALTER COLUMN` statements and need no opt-in unless a constraint is genuinely being dropped.

    Measured per shape (`dry_run().statements` through `Migrations.is_destructive`):

    | the rename also… | PostgreSQL | SQLite |
    |---|---|---|
    | …changes nothing else | not destructive | not destructive |
    | …retypes the column, or changes `null` | not destructive | **destructive** |
    | …drops a `UNIQUE` or `PRIMARY KEY` | **destructive** | **destructive** |

!!! warning "Repairing a `UNIQUE` constraint dropped by an older PormG"
    Before this behavior was fixed, renaming a `unique = true` field **destroyed the constraint on PostgreSQL** and **aborted the migration on SQLite**. The plan dropped the index backing the constraint, and on PostgreSQL that meant dropping the constraint first — successfully, and with nothing to put it back.

    PostgreSQL is the case worth checking, because it is silent: the migration reported success, and introspection reads `unique` back correctly afterwards, so the model compares converged and `makemigrations` will never propose restoring it. SQLite failed loudly and rolled back, so a SQLite database was never left in this state.

    Check any table where you renamed a `unique` field, then re-add what is missing:

    ```sql
    -- What UNIQUE constraints does the table actually have?
    SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
    WHERE conrelid = 'driver'::regclass AND contype = 'u';

    -- Look for duplicates FIRST — re-adding the constraint fails on dirty data,
    -- and the window in which it was missing is when duplicates could arrive.
    SELECT "driverslug", count(*) FROM "driver"
    GROUP BY "driverslug" HAVING count(*) > 1;

    ALTER TABLE "driver" ADD CONSTRAINT "driver_driverslug_key" UNIQUE ("driverslug");
    ```

    On SQLite there is no `ALTER TABLE ... ADD CONSTRAINT`; if you need to add one by hand, `CREATE UNIQUE INDEX "driver_driverslug_key" ON "driver" ("driverslug");` enforces the same rule.

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

## Statement Ordering

A migration's statements are applied in a fixed sequence of buckets, not in the order the plan file lists them:

1. `CREATE TABLE` (new models)
2. `DROP TABLE`
3. `RENAME TABLE`
4. `RENAME COLUMN`
5. Everything else — column alterations, `ADD CONSTRAINT`, `DROP CONSTRAINT`, `DROP INDEX`
6. Field `CREATE INDEX`

Within a bucket the order is stable but arbitrary — effectively alphabetical by table, because the plan is read back out of `pending_migrations.jl` by module binding name. **It is not a dependency order, and PormG does not compute one.**

That is safe rather than lucky, and it rests on three properties the test suite pins:

- **PostgreSQL never inlines a foreign key in `CREATE TABLE`.** Every key is a separate `ALTER TABLE … ADD CONSTRAINT` in bucket 5, so it runs after *every* `CREATE TABLE`. Two new tables that reference each other therefore apply in either order — which no dependency sort could achieve, because that is a cycle.
- **`DROP TABLE` is `DROP TABLE … CASCADE` on PostgreSQL**, so a parent can be dropped before its children are cleaned up. Because `CASCADE` also removes the children's constraints, PormG emits `DROP CONSTRAINT IF EXISTS` — otherwise removing a child's foreign-key field in the same migration that drops its parent would abort on a constraint the `CASCADE` had already taken.
- **SQLite suspends foreign-key enforcement for the whole migration** (`PRAGMA foreign_keys = OFF`, restored by renewing the connection afterwards). Its inline `REFERENCES` clauses therefore constrain nothing while DDL is running, and SQLite resolves an FK's parent table lazily in any case.

!!! note "Why there is no topological sort"
    This is the same design position as the rest of the engine: no dependency graph, no replay (see [What this means in practice](#What-this-means-in-practice)). The plan file is a flat, frozen v1 artifact whose statements are opaque SQL by the time they are executed, so ordering by dependency would mean changing the format rather than adding a sort. Keeping constraints out of the ordering problem is cheaper and handles cycles, which a sort cannot.

## Database-Specific Behavior

### SQLite: Table Recreation
SQLite has limited `ALTER TABLE` support. It can rename tables/columns and add or drop plain columns, but it **cannot** change a column's type, modify nullability/`UNIQUE`/`CHECK` constraints in place, remove a foreign key (there is no `ALTER TABLE ... DROP CONSTRAINT`), or `DROP COLUMN` on a column that participates in a `FOREIGN KEY`, a `UNIQUE` constraint, the `PRIMARY KEY`, or **any index**.

To handle any of those changes, PormG automatically rebuilds the table from your model:
- Creates a new table with the desired schema.
- Copies existing data from the old table into it (surviving columns only).
- Re-creates the surviving indexes and foreign keys — an index referencing a *dropped* column is **not** re-created (see the expression-index note below).
- Drops the old table, renames the new one, and runs `PRAGMA foreign_key_check` to catch orphaned rows.

The rebuild is emitted as plain DDL that composes with the migration's transaction, so no data is lost and the remaining indexes and constraints are preserved. This is what makes **removing a foreign-key field or constraint, a `UNIQUE` column, a `PRIMARY KEY` column, or an indexed column** work on SQLite even though `DROP COLUMN`/`DROP CONSTRAINT` alone cannot express it. Changes SQLite *can* do in place — adding a column, or dropping an *ordinary* column (not part of a `FOREIGN KEY`, `UNIQUE`, or `PRIMARY KEY`, and not referenced by an index) — use `ALTER TABLE` directly, without a rebuild.

This process is transparent to the user but may take longer on very large tables.

**Adding a foreign key to an existing table.** When the column already exists — a `db_constraint = false` key flipped back on, say — the rebuild renders the `FOREIGN KEY` clause from your model, so the constraint really is created, and PormG logs an `@info` noting that the table is being rebuilt, because that cost is worth knowing about on a large table. Re-pointing a key that already exists takes the same rebuild but logs nothing.

**A foreign key arriving as a *new* column** is created too, and usually without a rebuild. SQLite accepts an inline `REFERENCES` clause on `ALTER TABLE ... ADD COLUMN` provided the column is nullable and has no default, which is the ordinary shape of a new `ForeignKey`:

```sql
ALTER TABLE "result" ADD COLUMN "circuitid" INTEGER NULL REFERENCES "circuit"("circuitid") ON DELETE CASCADE;
```

Give the column a `default` and SQLite will not take the clause inline — PormG then adds the column and rebuilds the table from your model, which renders the `FOREIGN KEY` clause the same way `CREATE TABLE` does. PostgreSQL is unaffected either way: it adds a separate named constraint with `ADD CONSTRAINT`, as it always has.

!!! warning "Two column shapes SQLite refuses outright"
    Independently of foreign keys, SQLite will not `ADD COLUMN` a `UNIQUE` column at all, nor a `NOT NULL` column without a default — the refusal is about the column. So adding a **new** `OneToOneField` (which is `unique = true`), or a **new** `null = false` field that ends up with no `DEFAULT`, fails on SQLite when the table already exists. It fails on the `ADD COLUMN` itself, before any rebuild PormG queued behind it, and the migration rolls back rather than doing anything silently.

    `DateTimeField` and `DateField` are the exception to the second half: PormG synthesizes a temporary default for those two, adds the column with it, and then rebuilds the table to drop it — so a new required timestamp needs none of the below. That temporary default exists **only** for a `null = false` column with no `default` of its own. A `null = true` `DateTimeField` / `DateField` is added as a plain nullable column and every existing row stays `NULL` — no temporary value, no rebuild — and a column with a declared `default` backfills through that default and keeps it.

    PostgreSQL accepts the `UNIQUE` column, but shares the `NOT NULL` restriction: `ADD COLUMN … NOT NULL` with no default is rejected on a table that already has rows, because the existing rows would violate it.

    For every other required column, add it in two steps on either backend: declare it nullable with no default, migrate, backfill the values, then tighten it — the tightening is an alteration of an existing column, which takes the table rebuild on SQLite and an `ALTER COLUMN` on PostgreSQL.

!!! warning "Deleting an indexed column, and the two index shapes PormG cannot re-create"
    SQLite refuses `ALTER TABLE ... DROP COLUMN` for a column **any** index references, so deleting an indexed column takes the table rebuild rather than a plain `DROP COLUMN`. The rebuild drops every index with the old table and re-creates the ones the rebuilt table can still support, so the end state is the same — it just costs a data copy on a large table.

    PormG writes exactly two index shapes — a plain `CREATE INDEX` (from `db_index` and `Models.Index`) and a plain `CREATE UNIQUE INDEX` (from `Meta.unique_together` and many-to-many join tables). Both are a bare list of column names. An index carrying anything more cannot be re-created from a model, because **no model declaration expresses it**:

    - an **expression index** — `CREATE INDEX ... ON t(lower(a))`
    - a **partial index** — `CREATE INDEX ... ON t(a) WHERE b > 0`
    - an explicit **`COLLATE`** — `CREATE INDEX ... ON t(a COLLATE NOCASE)`
    - a sort **direction** — `CREATE INDEX ... ON t(a DESC)`; Django's `Index(fields=['-name'])` produces exactly this

    PormG never creates any of them, but a database it adopted through `generate_models_from_db` or the Django importer can arrive carrying them, and so can one indexed by hand.

    When a rebuild drops one of those four, PormG logs a warning naming the index and its definition, so **an index PormG cannot model is never dropped silently**. Nothing puts it back, though: re-create it by hand after the migration if you still need it.

    ```
    ┌ Warning: SQLite table rebuild will DROP an index PormG cannot re-create: it uses an
    │ expression, a WHERE clause, an explicit COLLATE or a sort direction, none of which a
    │ model declaration expresses. Re-create it by hand after the migration if you still
    │ need it.
    │   table = "driver"
    │   index = "driver_surname_lower_idx"
    │   dropped_columns = 1-element Vector{String}: …
    │   definition = "CREATE INDEX \"driver_surname_lower_idx\" ON \"driver\" (lower(\"surname\"))"
    ```

    A plain index — the two shapes PormG *does* write — is dropped without a warning, because the column it covered is the one you removed: a `db_index` you still declare comes back with the rebuild, and a `unique_together` group you still declare cannot name a column that no longer exists.

    Such an index on a column that **survives** the rebuild is preserved, name and all — across a `RENAME COLUMN` too: the renamed column is rewritten inside the preserved index's DDL wherever it appears, however the index spells it (`lower(surname)`, `lower("surname")`, `[surname]`), so a hand-written expression or partial index follows the rename.

!!! warning "Dropping a primary key: PostgreSQL vs SQLite"
    Removing a column that is the table's **only** primary key diverges by backend. PostgreSQL's `DROP COLUMN` drops the column and its `PRIMARY KEY` constraint natively, leaving a table with no primary key. SQLite cannot express that without silently degrading the table to a rowid table, so PormG **fails `makemigrations` loudly** instead — declare a replacement primary key, or make the change manually. Dropping a primary-key column while the model still declares a primary key (the key moved to another column) rebuilds normally on both backends.

!!! note "SQLite Limitation"
    Advisory locking is not available for SQLite. Migration safety is single-instance only.
    Do not run concurrent migrations against the same SQLite database.

### PostgreSQL: Advisory Locking
`migrate()` acquires a PostgreSQL session-level advisory lock before it executes anything, so a second migrator against the same database **queues** instead of interleaving its DDL. It waits up to 30 seconds and then fails rather than proceeding unserialized.

The key is the constant `pormg::migrations`, with **no database or folder qualifier** — deliberately. A PostgreSQL advisory lock is tagged with the *database OID* alongside the key, so the database is already the lock's namespace:

- Every configuration pointing at one database contends on one lock, **including two different `db/` config folders that resolve to the same server and database**. Before #90 the key embedded the config folder name, so those two folders took two different locks and migrated one database concurrently.
- Two databases cannot collide on it, however identical the key, because their locks carry different database OIDs.

This is a guarantee about *one database*, not one server: `migrate()` against `analytics` does not block `migrate()` against `billing` on the same cluster, which is what you want.

!!! warning "A transaction-pooling proxy defeats it"
    The lock is **session-level** — it lives on the connection that took it. Behind PgBouncer in `transaction` mode (or any pooler that reassigns server connections per transaction) the lock can be released or observed on the wrong backend. Point `migrate()` at a direct connection, or use `session` pooling.

### PostgreSQL: Identity Columns
`IDField()` renders a PostgreSQL identity column, and `generated_always = true` makes it the stricter `GENERATED ALWAYS AS IDENTITY` — a column application code cannot supply a value for. Changing that declaration is a migration like any other, and PostgreSQL spells the three transitions differently:

| Change | Statement PormG emits | Order |
|---|---|---|
| A non-identity column becomes one | `ALTER COLUMN "id" ADD GENERATED { ALWAYS \| BY DEFAULT } AS IDENTITY` | **after** the type change — a column can only become an identity once it is already an integer type |
| The flavour moves, `BY DEFAULT` ⇄ `ALWAYS` | `ALTER COLUMN "id" SET GENERATED { ALWAYS \| BY DEFAULT }` | unordered — it does not touch the column type |
| An identity column stops being one | `ALTER COLUMN "id" DROP IDENTITY` | **before** the type change — PostgreSQL enforces the integer restriction *during* `ALTER COLUMN ... TYPE`, so a later `DROP IDENTITY` would never run |

The distinction between the first two matters because PostgreSQL rejects the wrong one: `ADD GENERATED` on a column that already is an identity fails with `column "id" is already an identity column`. Tightening a live key is therefore `SET GENERATED ALWAYS`, and it changes only the flavour — the sequence keeps its current value and no data is rewritten.

SQLite has no equivalent. Its identity is `INTEGER PRIMARY KEY AUTOINCREMENT`, which has no `ALWAYS`/`BY DEFAULT` distinction and which no `ALTER` can change, so `generated_always` is a no-op there and a change to it correctly plans nothing.
