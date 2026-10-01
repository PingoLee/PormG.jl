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

The models file is the connection's own `model_file` under its folder. `models_file = "path/to/models.jl"` names another one; that is how you [revert](#Reverting-by-declaring-the-old-state).

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
This shows the SQL statements that will be executed and detects any destructive operations, and
any [lossy column change](#Lossy-Column-Changes) — with, for a change that would fail on existing
rows, how many rows it would fail on.

`dry_run()` only **reads**: it parses the plan file and never executes it, even though it is
written in Julia syntax, and all it asks the database is about a lossy column change the plan
records: whether the column still exists, and how many rows would fail. A table or index name from the database that happens to contain `$(…)`
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
you have run `makemigrations` even once. By default it reports columns whose `DEFAULT` is a SQL
expression (`now()`, `CURRENT_TIMESTAMP`, `gen_random_uuid()`). Those columns import as
`db_default=` carrying exactly the text it prints, so its output is what you paste into the model —
and declaring one as `default=` instead would propose overwriting the database's expression with a
quoted literal. Full rules: [Column defaults](../schema_conventions.md#Column-defaults).

### Checking the Database Against the Models

`check()` also answers "does this database match the declared models?", when asked for the
`:schema_drift` class:

```julia
r = PormG.Migrations.check("db"; kinds = [:schema_drift])
println(r)
exit(isempty(r) ? 0 : 1)   # as a CI or release gate
```

It reports one finding per step the next `makemigrations` would plan. The finding's `detail` is the
step's label (`"New model"`, `"Drop table"`, `"Add field: country"`, …), and its `message` says which
side has what the other lacks. It uses the same live reader, the same models loader and the same
planner as `makemigrations`, so the two cannot disagree about whether there is a change. Unlike
`makemigrations`, it is a gate you can point at production:

- **It writes nothing**: no `pending_migrations.jl`, no history row, no archive.
- **It runs under `change_db: false`**, the setting a production connection usually carries, where
  `makemigrations` refuses to run.
- **A failed read raises.** `makemigrations` logs a failed live-schema read and stops; a gate must
  never report "clean" because it could not look.
- **It never prompts.** A renamed column is therefore reported as an add plus a remove, and a
  renamed table as a new model plus a drop, because that is what a plan without answers does. Each
  of the two findings names the other in its `message`, so you can tell a rename from two changes.

The models file is the one `makemigrations` reads, `model_file` under the connection's folder;
`models_file = "path/to/models.jl"` names another. `include_table = ["driver", "result"]` reports only
those tables. Every declared model is still planned, so a `ManyToManyField`'s through table is
reported only when you list it too. `ignore_table` skips live tables only, as the default skip list
does for `makemigrations`. It replaces that default list, but the connection's own
[`ignore_tables:`](../configuration/connection_yml.md#Tables-PormG-leaves-alone) still applies on top
of it, and so does `register_ignore_tables!`. Replacing the default list does not make a managed
model on a default-ignored table legal: that model is still refused with `InvalidConfigurationError`,
as it is in `makemigrations` (see
[Tables PormG leaves alone](../configuration/connection_yml.md#Tables-PormG-leaves-alone)).

A column whose definition changes reads differently per engine. PostgreSQL reports
`"Alter field: <column>"`. SQLite rebuilds the table, so its finding is `"Alter table: <table>"` and
names no column. Added and removed columns keep their `"Add field: …"` and `"Remove field: …"`
labels on both engines.


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

### Reverting by declaring the old state

PormG has no `rollback`, no `down` migration, and no `migrate_to(version)`. It does not need them.
A plan is `diff(live database, declared models)`, so planning against an **older** models file
produces the way back. Going forward and going back are the same operation, and the same review
applies to both.

Say release 1.5 added a `nickname` column to `Driver`, and you want the database back at 1.4's
models. Check out the old models file:

```bash
git show v1.4:db/models.jl > db/models_v1_4.jl
```

That restores one file. If your models file `include`s others, their paths resolve next to the
copy, so the copy would load today's versions of them. The plan would then target a mix of 1.4
and 1.5. Check out the whole revision instead, for example with `git worktree add ../app-v1.4 v1.4`,
and pass `models_file = "../app-v1.4/db/models.jl"`.

Then plan against it, review it, and apply it:

```julia
PormG.Migrations.makemigrations("db"; models_file = "db/models_v1_4.jl")
PormG.Migrations.dry_run("db")                      # review: the plan drops "nickname"
PormG.Migrations.migrate("db"; destructive = true)
```

`models_file` resolves relative to the working directory, like any path you type. The plan records
which file it was generated from, and `migrate` snapshots **that** file as the applied migration's
`_old_models.jl`.

Finish by making the old file the declared state: `mv db/models_v1_4.jl db/models.jl` (or copy
the old folder's files over the current ones), and commit.
Until you do, `models.jl` still declares 1.5, so the next plain `makemigrations("db")` plans the
column back, and `check("db"; kinds = [:schema_drift])` reports it.

What a revert does not do:

- **Dropped data does not come back.** Reverting a column's *addition* drops the column and
  everything written to it since. Reverting its *removal* re-creates it empty. Only a backup
  restores data.
- **The destructive guard applies unchanged.** A revert that drops anything needs
  `destructive = true`, like any other plan.
- **It is recorded as a new migration, not an undo.** The history table only grows: the revert is
  one more `applied` row.
- **A rename reverts as a drop and an add** unless you answer the rename question `makemigrations`
  asks (see [Answering the rename questions](#Answering-the-rename-questions)).

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
result = PormG.Migrations.migrate("db")
```
Applied migrations are recorded in the history table and archived to `db/migrations/applied_migrations/`.

`migrate()` returns a `MigrationResult` whose `outcome` is `:applied`, `:already_applied`,
`:nothing_pending`, `:disabled` (the connection is `change_db: false`) or `:declined` (you answered
"no" at the prompt, a destructive plan was refused at the terminal for lack of `destructive=true`, or
a [lossy column change](#Lossy-Column-Changes) would fail on existing rows). Having nothing to apply is `:nothing_pending`, not an error. What each outcome
means, and how to run `migrate()` at application boot: [Deploying](deploying.md).

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

### Lossy Column Changes
The guard above reads the SQL text, so it sees a `DROP` — but not an `ALTER` that narrows a column.
`makemigrations` therefore also classifies each column change from what the column held before and
what it will hold, and writes what it finds into the plan's header (a `# pormg-lossy-alter:` comment
line per column or constraint). `dry_run()` lists them, and `migrate()` acts on them. There are three kinds:

| Kind | Examples | What `migrate()` does |
| :--- | :--- | :--- |
| **Fails on existing rows** | `null = true` → `false` over rows holding `NULL`; a shorter `max_length`; `BigIntegerField` → `IntegerField`; fewer `max_digits`; `IntegerField` → `PositiveIntegerField` over negative values; a **new** column that is `NOT NULL` with no `default`, added to a table that has rows; `unique = true` over duplicate values; `primary_key = true` moved to a column with duplicates (or `NULL`s, on PostgreSQL); a new `UniqueConstraint` over duplicate tuples; a new `CheckConstraint` some rows fail; a new or re-pointed foreign key over rows with no parent; on PostgreSQL, text → a number, boolean, date, timestamp, UUID or JSON over values that do not parse as the new type | Counts the offending rows first. Any row that would fail means the plan is refused before anything is written; none means it applies with no opt-in. |
| **Changes existing values** | fewer `decimal_places` (values round); `FloatField` or `DecimalField` → `IntegerField` (values round); `DateTimeField` → `DateField` (the time is dropped); a `TIMESTAMPTZ` → `TIMESTAMP` (the offset is dropped); on PostgreSQL, a number → `BooleanField` (every non-zero value becomes `true`); on PostgreSQL, one of the text or boolean conversions above on a column with a database default the model does not declare as a `db_default` — the conversion has to drop it | Needs `destructive = true`, exactly like a `DROP`. |
| **Cannot run as planned** | a plan written by an older PormG that changes text → a number, boolean, date, timestamp, UUID or JSON, or boolean ↔ a number, on PostgreSQL | Refused: PostgreSQL has no automatic cast between these, and that plan carries no `USING` clause. Run `makemigrations()` again; current plans write the `USING`. |

For the first kind, `destructive = true` does **not** get the plan through — no opt-in can make a
`NULL` fit a `NOT NULL` column. Fix the data, then run `migrate()` again (the same plan counts again),
or change the models file and run `makemigrations()`:
```julia
r = PormG.Migrations.dry_run("db")
r.lossy_alters     # one entry per column: table, column, kind, and `rows` for the failing kind
```
A new `NOT NULL` column has nothing to put in the rows already there, so for it there is no data to
fix: declare a `default` (or `db_default`), which fills them, or add the column with `null = true`,
fill it, and make it `NOT NULL` in a later migration — that second step is the ordinary
`null = true` → `false` change above, counted the same way. An empty table takes the column as
declared, on both engines.
In a non-interactive context a refused plan throws `PormG.Migrations.MigrationPrecheckError`, which
carries the same findings; at a terminal the findings are logged and `migrate()` returns `:declined`.

A few things to know:

- **The row count reads the database.** It is one `SELECT COUNT(*)` per such column, run before
  `migrate()` takes its lock. It is advisory: rows written between the count and the `ALTER` can
  still make the `ALTER` fail, and then the whole migration rolls back as it always did.
- **PostgreSQL and SQLite differ.** SQLite enforces no `VARCHAR` length, no integer width and no
  decimal scale, so a narrowing there changes nothing and is not reported. What SQLite does enforce
  is `NOT NULL`, a `CHECK`, `UNIQUE` and a foreign key, and what it does change is text moved into a numeric column: `'0042'`
  is stored as `42`. That last case needs `destructive = true` — which every SQLite column change
  already does, because SQLite rebuilds the table to apply it.
- **Text into another type is parsed by the server.** On PostgreSQL the plan converts with
  `USING CAST(col AS <type>)`, and the count asks the server's own parser (`pg_input_is_valid`)
  which values would not convert, so a value too large for the new type counts too. That function
  is PostgreSQL 16+. An older server checks numbers, booleans and UUIDs by their input grammar, and
  cannot check dates, timestamps or JSON at all: there every non-`NULL` value counts as failing, so
  such a change over a populated table needs PostgreSQL 16, or a hand-written step. A boolean
  becomes a number as `1` / `0`, which loses nothing and is not reported.
- **Constraints are counted the way the database enforces them.** A `NULL` is never a duplicate, and
  a `CheckConstraint` whose condition is `NULL` passes, so neither is counted.
- **What is not checked.** A constraint the count cannot evaluate before the plan runs is left to the
  database, which refuses it inside the migration and rolls back: a `CheckConstraint` over a column
  the same plan adds, renames or retypes; a `UniqueConstraint` over a column it adds; and a foreign
  key whose parent table (or key column) the same plan creates or renames, or whose column it retypes. Likewise the
  `>= 0` `CHECK` of a `PositiveIntegerField` converted from text or a boolean, since the column still
  holds the old type when the count runs. A change that loses
  precision rather than digits (a `DecimalField` or `BigIntegerField` → `FloatField`) is not reported
  either.
- **Hand-editing the plan.** The header describes the plan `makemigrations` wrote. If you add a
  backfill or a `USING` clause by hand to get past a finding, delete that finding's
  `# pormg-lossy-alter:` line too, or regenerate the plan. A line naming a column the database no
  longer has is ignored with a warning. A `CheckConstraint`'s line carries its condition, but the
  plan is data, so that text is never what the count runs: the condition is counted only when the
  models file declares the same `CheckConstraint` (same table, name and condition), and otherwise the
  database checks it during the migration. That is the connection's own models file: a plan made with
  `makemigrations(…; models_file = "other.jl")` gets no `CheckConstraint` count. A line whose condition no statement in the plan adds is
  refused as damaged.

---

## Automation & CI/CD
`migrate()` detects a non-interactive process automatically: when stdin is not a terminal it shows no
confirmation prompt and never blocks on `readline()`. You do not need `interactive=false` for that (it is
auto-detected), though passing it is still allowed and harmless.
```julia
# Non-destructive plans apply directly — no prompt, no hang:
result = PormG.Migrations.migrate("my_db")
result.outcome   # :applied, :already_applied or :nothing_pending — none of them an error

# A destructive plan must opt in explicitly, or it throws DestructiveMigrationError:
PormG.Migrations.migrate("my_db", destructive=true)
```

Several instances calling `migrate()` at once queue on its lock; `lock_wait`, `lock_timeout` and
`statement_timeout` bound how long they wait and what they block. See [Deploying](deploying.md).

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
