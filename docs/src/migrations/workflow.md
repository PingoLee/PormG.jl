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
PormG blocks destructive SQL (DROP TABLE, DROP COLUMN) by default. To apply them, you must explicitly opt in:
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
