## `makemigrations` — composite indexes and uniqueness are diffed on existing tables, and undeclared ones are dropped (#161)

- **Version**: Unreleased
- **Recorded**: 2026-09-24
- **PormG ref**: #161, #19; `src/migrations/planner.jl` (`_plan_composite_actions!`, `_check_composite_names`), `src/migrations/introspection.jl` (`_pg_composite_indexes`, `_sqlite_composite_indexes`), `src/migrations/column_spec.jl` (`LiveComposite`, `declared_composites`)
- **Severity**: behavior change — the first `makemigrations` after upgrading can plan statements for tables whose models did not change

### What changed

`Models.UniqueConstraint` and `Models.Index` used to be created **only with their table**. On a table
that already existed, adding, removing or changing one planned nothing, and no introspection read
composite *uniqueness* back at all — not PormG's own `CREATE UNIQUE INDEX`, and not the
`UNIQUE (a, b)` constraint Django's `unique_together` creates.

Now `makemigrations` diffs them like columns, on every table:

1. **A declared composite missing from the database is created.** A `UniqueConstraint` or `Index`
   added to an existing model — or declared long ago and never created, because the table already
   existed — now gets its `CREATE [UNIQUE] INDEX`. A unique one fails the migration if the table
   already holds duplicate rows.
2. **A composite in the database that no model declares is dropped.** That covers composite
   indexes and uniqueness constraints a DBA added by hand, and one-column `CREATE UNIQUE INDEX`es.
   The drop is destructive: `dry_run()` lists it and `migrate()` refuses it without
   `destructive = true`. Indexes PormG cannot reproduce are never read and never dropped: partial,
   functional, non-b-tree, `DESC`, an explicit opclass or collation, `INCLUDE`, `NULLS NOT DISTINCT`,
   `DEFERRABLE`, invalid.
3. **An explicit `name =` the live index does not carry is renamed to it.** PostgreSQL uses
   `ALTER INDEX … RENAME TO` or `ALTER TABLE … RENAME CONSTRAINT`. SQLite drops and re-creates the
   index, which counts as destructive. A declaration with no `name` matches whatever the live index
   is called.
4. **Composite creates no longer say `IF NOT EXISTS`**, the ManyToManyField join table's index
   included. A name some other object already holds used to be a silent no-op, leaving the table
   without its index. Now it fails the migration. `makemigrations` also refuses a plan that would
   create (or rename to) one name twice on *any* tables, or a name another table's index still
   holds — move a name between tables in two migrations; and on SQLite an explicit name starting
   with `sqlite_`.
5. **`inspectdb` / `convert_schema_to_models` now emit `constraints = [UniqueConstraint(…)]`** for
   the composite uniqueness they find. A regenerated models file therefore contains lines it did
   not contain before.

Matching is by kind and columns, so a Django `unique_together` already in the database satisfies the
`UniqueConstraint` the Django importer generated for it. Nothing is planned for it.

### How to find the calls to migrate

There is no call pattern to grep for. The change is in what the next plan contains. Run the normal
operator flow against each app's database and read the plan before migrating:

```julia
PormG.Migrations.makemigrations("db")
PormG.Migrations.dry_run("db")      # look for DROP INDEX / DROP CONSTRAINT / RENAME on index names
```

Any `DROP INDEX` or `DROP CONSTRAINT` on an index you want to keep means the model does not declare
it.

### Migrate your app

```julia
# Before: the live table carried UNIQUE (constructorid, year), declared nowhere; nothing noticed.
Constructor_engine = Models.Model("constructor_engines",
  id = Models.IDField(),
  constructorid = Models.ForeignKey(Constructor, pk_field = "constructorid", on_delete = "CASCADE"),
  year = Models.IntegerField())

# After: declare it, and makemigrations matches the existing constraint by its columns — no plan.
Constructor_engine = Models.Model("constructor_engines",
  id = Models.IDField(),
  constructorid = Models.ForeignKey(Constructor, pk_field = "constructorid", on_delete = "CASCADE"),
  year = Models.IntegerField(),
  constraints = [Models.UniqueConstraint(fields = ("constructorid", "year"))])
```

To declare everything a live database already has, regenerate the models with `inspectdb` and copy
the `constraints = […]` / `indexes = […]` lines across. To drop an index on purpose, leave it
undeclared and migrate with `destructive = true`.
