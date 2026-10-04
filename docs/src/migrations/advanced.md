# Advanced Migrations

This page covers the history-table repair operations, and data migrations: changing data at a fixed point of a plan, or once per database with Julia code.

`makemigrations` plans **schema** changes only; it never writes a data change. You add one in one of two places, described in [Data Migrations](#Data-Migrations): a data step inside the plan, or a `run_once` step beside it.

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

## Data Migrations

A data change has two homes, and which one fits depends on what it needs:

| | A data step in the plan | `run_once` |
|---|---|---|
| Written in | SQL, in `pending_migrations.jl` | Julia, in your deploy or boot code |
| Runs | inside the plan's transaction, at a fixed point: before or after its schema statements | on its own, beside `migrate`: a backfill after it, an index step before it |
| Recorded | as part of the plan, in `pormg_migrations` | by name, in `pormg_migrations_data` |
| Use it for | a short `UPDATE` that goes with the plan's schema change | ORM code, large backfills, `CREATE INDEX CONCURRENTLY`, and data that must be fixed before a plan can apply |

### Data steps in a plan

Add an entry whose label starts with `Data (pre):` or `Data (post):` to any table's binding in
`pending_migrations.jl`, after `makemigrations` has written it:

```julia
# table: driver
driver = OrderedDict{String, String}(
    "Add field: code" => """ALTER TABLE "driver" ADD COLUMN "code" VARCHAR(3);""",
    "Data (post): fill code" => """UPDATE "driver" SET "code" = upper(substr("surname", 1, 3)) WHERE "code" IS NULL;""",
)
```

- **The label decides when it runs.** Every `Data (pre):` step runs before the plan's first schema
  statement, every `Data (post):` step after its last one (index creation included). Which binding
  the entry sits in does not matter. Several steps of one kind run in the plan's order: bindings
  alphabetically, then entries as written.
- **Only those two spellings.** A label that reads like one and is not — `Data (Pre):`,
  `data (post):`, `Data (post)` without its colon — raises `InvalidMigrationError` instead of running
  somewhere you did not intend.
- **A `pre` step can fix the rows a column change would fail on, if you say so.** Before it runs
  anything, `migrate` counts the rows a change would fail on (`NULL`s under a new `NOT NULL`,
  duplicates under a new `unique`, values too long for a shorter `max_length`), and refuses the
  whole plan if there are any (see [Lossy Column Changes](workflow.md#Lossy-Column-Changes)). It
  counts on the database as it is, before any `Data (pre):` step has run. To let a `pre` step fix
  those rows, mark the finding: append a tab and `handled=pre` to its `# pormg-lossy-alter:` line in
  the plan's header. Making `Driver.code` required, in one plan:

  ```julia
  # pormg-lossy-alter: kind=set_not_null<TAB>table=driver<TAB>column=code<TAB>old=…<TAB>new=…<TAB>handled=pre
  ```
  ```julia
  "Data (pre): fill code" => """UPDATE "driver" SET "code" = upper(substr("surname", 1, 3)) WHERE "code" IS NULL;""",
  ```

  (`<TAB>` is a tab character. Leave the rest of the line as `makemigrations` wrote it, and add only
  the last field.) A marked
  finding is still counted: `dry_run()` lists it under `HANDLED BY A Data (pre) STEP`, with its rows.
  But `migrate` does not refuse the plan for it, and the database enforces the change inside the
  migration, after the step. If the step leaves a row that still fails, the `ALTER` fails and the
  whole plan rolls back, the step included.
  - `handled=pre` is the only value, and only a change whose rows are counted can carry it — not
    a change that rewrites values (a lower `NUMERIC` scale), which has no count and keeps its line
    as written. A new `NOT NULL` column cannot carry it either: the step runs before the column is
    added, so it has nothing to fill. Give the column a `default`, or add it nullable first (below).
    A mark that breaks any of these rules is refused with `InvalidMigrationError`, and so is a plan
    that marks a finding and has no `Data (pre):` step.
  - Deleting the line also turns its count off, but then `dry_run` no longer shows the change.
    Mark the line rather than delete it.
- **It is part of the plan.** It runs in the plan's single transaction, it is part of the plan's
  checksum, and the [destructive guard](workflow.md#Destructive-Operations-Safety) reads it like any
  other statement: a `DELETE` with no `WHERE` needs `destructive = true`. `dry_run()` lists the data
  steps by label under *Data steps*.
- **SQL only, written as plain literals**, like the rest of the plan: the file is read as data,
  never executed (see [Format Stability](stability.md)).
- **On SQLite, foreign keys are not enforced while a plan runs**, so a `DELETE` in a data step does
  not cascade to child rows.
- **`makemigrations` keeps the plan.** A plan holding data steps is neither overwritten nor moved
  aside: `makemigrations` raises `InvalidMigrationError` naming the steps. Apply the plan with
  `migrate()` first, or move the steps out of it, then run `makemigrations` again.
  `discard_pending_migration()` still discards it, if that is what you want.

### `run_once`: a recorded Julia step

`run_once` runs a block once per database. It records the block by name in
`pormg_migrations_data`, and skips it on every later call:

```julia
using PormG, LibPQ   # load SQLite instead for a SQLite app

PormG.Migrations.migrate("db"; interactive = false)
PormG.Migrations.run_once("db", "2026-10-02_backfill_driver_code") do conn
    for d in M.Driver.objects.filter("code__@isnull" => true).list()
        M.Driver.objects.filter("driverid" => d[:driverid]).
            update("code" => uppercase(first(d[:surname], 3)))
    end
end
```

It returns `:applied` when this call ran the block, `:already_applied` when that name is recorded
already (the block is not called), and `:disabled` on a `change_db: false` connection, where it does
nothing, as `migrate` does.

- **Once, by name.** The record is the whole of "applied": a step is never run again, whatever its
  code says now. To change what a step does, give it a new name. There is no down step.
- **One transaction** (the default). The block's ORM calls and `fetch(conn, sql)` run in it, and
  the record commits with them. If the block throws, both roll back, nothing is recorded, and the
  next call runs the step again.
- **Once, even with several instances.** On PostgreSQL it takes the advisory lock `migrate` takes
  and waits up to `lock_wait` seconds (default `30`), so a data step and a schema migration never run
  at once and two instances booting together run a step once. SQLite has no such lock: there a step
  checks its record inside its `BEGIN IMMEDIATE` transaction, which no other process can share.
- **`transaction = false`** is for what cannot run in a transaction, such as PostgreSQL's
  `CREATE INDEX CONCURRENTLY`. The record is written after the block returns, so if it throws half
  way, what it did stays done and the step runs again next time. Write such a step so a second run is
  harmless:

  ```julia
  PormG.Migrations.run_once("db", "2026-10-02_results_points_index"; transaction = false) do conn
      fetch(conn, """CREATE INDEX CONCURRENTLY IF NOT EXISTS "result_points_idx" ON "result" ("points");""")
  end
  ```

  On SQLite nothing serializes a non-transactional step: two processes, or two tasks, can both run
  it, and the one that records it second returns `:already_applied`. That is one more reason to make
  it safe to run twice.

  `IF NOT EXISTS` has a trap here. If the concurrent build fails (a duplicate under `UNIQUE`, a
  deadlock, a cancel), PostgreSQL leaves an **invalid** index of that name behind. The next run then
  skips the `CREATE`, records the step, and the index is never usable.
  `check("db"; kinds = [:invalid_index])` lists such indexes (see
  [Finding invalid indexes](workflow.md#Finding-Invalid-Indexes)). Drop the invalid one **before**
  the step runs again. Once the step is recorded it never runs again, so if that has already
  happened, drop the index, remove what made the build fail (for a unique index, usually duplicate
  values), and create it by hand or under a new step name.
- **A step that creates schema has to agree with the models.** Declare the index the step creates
  (`points = Models.FloatField(db_index = true)`). Left undeclared, the next `makemigrations` plans
  to drop it; declared, it counts as already there, whatever it is named. The index is then part of
  its table's fingerprint, so a plan generated after the step ran refuses to apply on a database
  where it has not (see [Shipping a plan with a release](deploying.md#Shipping-a-plan-with-a-release)):
  at boot, run such a step **before** `migrate`, and a backfill after it.
- It raises `TransactionError` inside an open transaction on the same database, because a step has
  to commit on its own. `status("db").data_steps` lists the recorded steps.

### Expand, backfill, contract

`makemigrations` always plans the move to the schema your models declare **now**. A change that
needs data in between, such as a new column that must not be `NULL`, is therefore two plans with a
data step between them. Making `Driver.code` required on a table that already has rows:

1. **Expand.** Declare the column nullable, then plan and apply:

   ```julia
   code = Models.CharField(max_length = 3, null = true)
   ```
   ```julia
   PormG.Migrations.makemigrations("db")
   PormG.Migrations.migrate("db")
   ```

2. **Backfill** with the `run_once` step above. Ship it in the same release as the expand plan, run
   after `migrate`.
3. **Contract.** In a later release, declare `null = false`, plan, and apply. `migrate` counts the
   rows that would violate `NOT NULL` before it runs anything, and refuses the plan while any remain
   (see [Lossy Column Changes](workflow.md#Lossy-Column-Changes)), so the contract cannot run ahead
   of the backfill.

When the backfill is a single `UPDATE` that needs nothing from Julia, a `Data (post):` step in the
expand plan does the same job inside that plan. Rows that appear between the backfill and the
contract can be filled by the contract plan itself: add a `Data (pre):` fill to it and mark its
`NOT NULL` finding `handled=pre` (see [Data steps in a plan](#Data-steps-in-a-plan)). The expand step
cannot be skipped this way, because a column the plan adds does not exist yet when a `pre` step
runs.

---

## Best Practices

- **Incremental Changes:** Run migrations frequently for small updates rather than one large update.
- **Review Plans:** Use `dry_run()` before applying to catch any accidental drops.
- **Version Control:** Commit your `applied_migrations/` folder.
- **Backups:** Always back up production databases before running schema changes.
- **Destructive Guard:** Never bypass the destructive guard in CI/CD without manual approval of the migration plan. In a non-interactive context a destructive plan throws `DestructiveMigrationError` unless you pass `destructive=true`; catch it (or set the flag) deliberately rather than blanket-suppressing it.
