# Migration Workflow

The standard lifecycle for managing migrations in PormG involves five key phases: Bootstrapping, Generation, Review, Status Check, and Application.

## Step 0: Bootstrapping

Before you can run migrations, you need a database configuration folder and a `connection.yml` file.

### For New Projects
If you are starting a new project, use the interactive setup tool (it defaults to `db` if no folder path is provided):
```julia
using PormG

# Default
PormG.setup()

# Custom folder
PormG.setup("db_bs")
```
This will guide you through creating the `db/` folder and configuring your connection.

### For Existing Projects (Manual)
If you already have a `db/` folder but need to initialize the migration history table:
```julia
PormG.Migrations.init_migrations("db")
```
This is safe to run on existing databases and will create the `pormg_migrations` table if it doesn't already exist.

---

## Step 1: Define Your Models

Edit your models in `db/models.jl` (or your chosen models file). PormG uses these definitions as the "target state" for your database.

!!! info "Important"
    **Active Memory Registration**: PormG generates migrations by comparing the live database schema against the **in-memory** representations of your models. 
    Before running `makemigrations`, make sure your model definitions file has been evaluated or loaded in the current Julia session (for example, by calling `include("db/models.jl")` or using the `@import_models` macro).

---

## Step 2: Generate Migrations

Once your models are defined and evaluated in the Julia runtime, generate a DDL migration plan (Schema Diff):
```julia
PormG.Migrations.makemigrations("db")
```
This connects to the physical database, compares the live table schema against the registered in-memory `PormGModel` subclasses, and generates the transition plan in `db/migrations/pending_migrations.jl`.

### Answering the rename questions

A model whose table does not exist, next to a table no model claims any more, may be the same table under a new name, and only you know which. `makemigrations` asks:

```text
The table race_result has no match in the database. Is it a new table? Answer yes, or no / the number of the table it was renamed from: 1 - result:
```

Answer `yes` to create `race_result` and drop `result`, or `1` to plan `ALTER TABLE "result" RENAME TO "race_result"` and keep every row. `no` asks for the number on its own. A field with no matching column is asked the same way: its old column's number, or `no` for a new column.

Any other answer — an empty line, a typo, a number that is not listed — raises `InvalidMigrationError` and writes nothing, so run `makemigrations` again. So does running out of input: see [Automation & CI/CD](#Automation-and-CI/CD) for running without a terminal.

---

## Step 3: Review Pending Migrations
**Always** review the generated migration plan before applying it.

### Plain Text Review
Use `dry_run()` for a detailed report:
```julia
result = PormG.Migrations.dry_run("db")
println(result)
```
This shows the SQL statements that will be executed and detects any destructive operations.

`dry_run()` only **reads** the plan file: it parses it and never executes it, even though it is
written in Julia syntax. A table or index name from the database that happens to contain `$(…)`
therefore stays text. A hand-edited plan that contains anything other than plain string literals
raises `InvalidMigrationError`. See
[Format Stability → A plan file is read as data](stability.md).

### Checking What the Models Cannot Express

`dry_run()` reports what PormG *will do*. `check()` reports what PormG *cannot describe* — facts
about the live schema that no model can faithfully carry, so they never appear in a plan at all:

```julia
result = PormG.Migrations.check("db")
println(result)
```

It is read-only, works on both engines, and needs no migration history — so it is also useful before
you have run `makemigrations` even once. Today it reports columns whose `DEFAULT` is a SQL
expression (`now()`, `CURRENT_TIMESTAMP`, `gen_random_uuid()`). Those columns import as
`db_default=` carrying exactly the text it prints, so its output is what you paste into the model —
and declaring one as `default=` instead would propose overwriting the database's expression with a
quoted literal. Full rules: [Column defaults](../schema_conventions.md#Column-defaults).


### Discarding a Pending Migration

Reviewed the generated plan and decided you don't want it? Discard the draft before applying:

```julia
PormG.Migrations.discard_pending_migration("db")
```

This is the one inherently safe, reversible migration op: a pending migration is **only** the
`db/migrations/pending_migrations.jl` file, with no database state behind it. Discarding it is
**filesystem-only** — it never touches the `pormg_migrations` history table or the live schema
(unlike `migrate` or `remove_migration_record`, which mutate applied state).

By default the draft is **renamed** to `pending_migrations.jl.discarded` so it can be recovered.
Pass `backup=false` to delete it outright:

```julia
# Keep a recoverable copy (default) → pending_migrations.jl.discarded
PormG.Migrations.discard_pending_migration("db")

# Delete the draft with no backup
PormG.Migrations.discard_pending_migration("db", backup=false)
```

It returns a summary of what was thrown away — `(discarded=true, path, backup, tables, statements)` —
or `nothing` when there was no pending migration. A later `makemigrations` overwrites the pending
file anyway, so regenerating the plan afterwards is unaffected.

`makemigrations` does this discard itself when it finds **no changes**: if you revert the model change
behind a pending plan and run it again, it logs that nothing is pending and moves the old plan to
`pending_migrations.jl.discarded`, so a later `migrate()` cannot apply a change your models no longer
declare. Either way the pending file describes the current diff and nothing else. The backup keeps
only the most recent discard; an earlier `.discarded` file is overwritten.

One pending plan is kept even then: a plan a previous `migrate()` applied but failed to move to
`applied_migrations/`. Your models already match it, which is why nothing changed. `makemigrations`
recognises it by checksum and warns instead of discarding it; run `migrate()` to archive it, which
it does without applying the plan a second time. If that plan is destructive, pass
`destructive=true`: the destructive guard runs before `migrate()` recognises the plan as applied.

---

## Step 4: Check Status
Before applying, verify the current migration state:
```julia
s = PormG.Migrations.status("db")
println(s)
```
This reports applied migrations, failed migrations, and any "drift" between files and the database.

---

## Step 5: Apply Migrations
Apply the pending migrations to your database:
```julia
PormG.Migrations.migrate("db")
```
Applied migrations are recorded in the history table and archived to `db/migrations/applied_migrations/`.

### Destructive Operations Safety
PormG blocks destructive SQL by default. A statement is destructive when it is:

- **any `DROP`**: a table, column, constraint or index, and also a view, schema, function, type,
  sequence, trigger or extension. The exceptions are `ALTER COLUMN … DROP NOT NULL`, `DROP DEFAULT`,
  `DROP IDENTITY` and `DROP EXPRESSION`, which remove a property of the column, not its data.
- **a `TRUNCATE`**, with or without the `TABLE` keyword.
- **a `DELETE` with no `WHERE`.** That empties the table the way `TRUNCATE` does, and on SQLite, which
  has no `TRUNCATE`, it is the only way to write one. A `DELETE … WHERE` and any `UPDATE` are not
  flagged, because a targeted data step or a backfill is not a table wipe.

`makemigrations` writes only the first kind, but a [hand-edited plan](advanced.md#Manual-SQL-in-Pending-Migrations)
can carry any of them. The guard reads the SQL text and does not parse it, so it errs toward flagging. A
string literal that reads like one of these also flags the plan: `default = "Drop zone"` renders as
`SET DEFAULT 'Drop zone'`. It can also miss a few hand-written spellings: any `WHERE` excuses a
`DELETE`, even `WHERE true`, and a keyword glued to a quoted name or a comment (`DROP"col"`) is not
seen. To apply a destructive plan you must explicitly opt in:
```julia
PormG.Migrations.migrate("db", destructive=true)
```

At an interactive terminal, a destructive plan without `destructive=true` prints a warning and aborts so you
can re-run with the opt-in. In a **non-interactive** context (CI, `Pkg.test`, a deploy script, or piped
stdin) the same plan throws a `DestructiveMigrationError` instead — automation fails loudly rather than
hanging on a prompt or silently skipping the migration.

---

## Automation & CI/CD
`migrate()` detects a non-interactive process automatically: when stdin is not a terminal it shows no
confirmation prompt and never blocks on `readline()`. You do not need `interactive=false` for that (it is
auto-detected), though passing it is still allowed and harmless.
```julia
# Non-destructive plans apply directly — no prompt, no hang:
PormG.Migrations.migrate("my_db")

# A destructive plan must opt in explicitly, or it throws DestructiveMigrationError:
PormG.Migrations.migrate("my_db", destructive=true)
```

To tolerate "a destructive plan is present — skip it rather than fail", catch the error:
```julia
try
    PormG.Migrations.migrate("my_db")
catch e
    e isa PormG.Migrations.DestructiveMigrationError || rethrow()
    @warn "Destructive migration skipped; apply manually with destructive=true" exception=e
end
```

`makemigrations()` is different: it does **not** detect a missing terminal. Its
[rename questions](#Answering-the-rename-questions) read stdin whenever `interactive=true` (the default),
so answers can be piped in. A script or CI job with nothing on stdin runs normally until a question comes
up, then reaches end of input and raises `InvalidMigrationError` rather than guessing. Pass
`interactive=false` there. It plans
every unmatched model and field as new, so it **never renames**: a renamed table is planned as a drop and a
create, which the destructive guard above then stops.
```julia
PormG.Migrations.makemigrations("my_db", interactive=false)
```
