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

> [!IMPORTANT]
> **Active Memory Registration**: PormG generates migrations by comparing the live database schema against the **in-memory** representations of your models. 
> Before running `makemigrations`, make sure your model definitions file has been evaluated or loaded in the current Julia session (for example, by calling `include("db/models.jl")` or using the `@import_models` macro).

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

### Interactive Review
If you prefer a terminal interface, use the [Tachikoma Dashboard](tachikoma.md):
```julia
using PormG, Tachikoma
PormG.tui("db")
```

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

---

## Automation & CI/CD
In non-interactive environments, use `interactive=false`:
```julia
# Safe migrations only
PormG.Migrations.migrate("my_db", interactive=false)

# Destructive migrations allowed
PormG.Migrations.migrate("my_db", interactive=false, destructive=true)
```
