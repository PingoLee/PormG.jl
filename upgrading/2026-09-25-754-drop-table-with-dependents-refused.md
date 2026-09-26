## `makemigrations` — refuses to drop a table that a view or a trigger still reads (#754)

- **Version**: Unreleased
- **Recorded**: 2026-09-25
- **PormG ref**: #754; `src/migrations/planner.jl` (`_refuse_dropped_table_dependents`), `src/migrations/introspection.jl` (`_pg_drop_table_dependents`, `_sqlite_drop_table_dependents`)
- **Severity**: behavior change. Deleting a model that a view reads used to plan the drop; it now raises `InvalidMigrationError`

### What changed

Deleting a model plans a `DROP TABLE` for its table. Before this change the planner looked at
nothing else, and each engine lost the objects that read the table in its own way:

- **PostgreSQL** drops with `DROP TABLE … CASCADE`, which silently removed every view on the table
  (views built on those views too) along with it. The plan showed only the table drop.
- **SQLite** left those views, and any trigger on another table that named the table, in place and
  dangling. The next `ALTER TABLE … RENAME` anywhere in the database, which is the last step of
  every table rebuild, then failed with `error in view …: no such table: main.<table>`. From then on
  no table rebuild, column rename or column drop could be migrated until the object was fixed by
  hand.

`makemigrations` now refuses the drop. It raises `InvalidMigrationError` at plan time, lists every
object that still reads the table, and writes no plan. What it checks:

- **PostgreSQL**: everything `CASCADE` would remove besides the foreign keys pointing at the table.
  That covers views, materialized views, rules on other tables, policies, functions with a
  SQL-standard body, another table's column of the table's row type (or an array of it), and
  another table's default on the table's sequence. `CASCADE` stays, for those foreign keys.
- **SQLite**: views, views on those views, `INSTEAD OF` triggers on them, and triggers on other
  tables that name any of them.

Triggers **on** the dropped table go with it and never block the drop. A function whose body is a
string (PL/pgSQL, or `LANGUAGE sql AS '…'`) and names the table is not detected: PostgreSQL records
no dependency for such a body.

### How to find the calls to migrate

There is no call to change. What matters is whether a table you are about to stop declaring still
has views or triggers reading it. The error names them:

```
Cannot drop table "driver": this migration drops it because no model declares it any more, but other objects still read it:
  - view "result_driver" reads "driver"
```

To look before running `makemigrations`, list the views and triggers in the database:

```bash
# PostgreSQL
psql "$DATABASE_URL" -c "SELECT schemaname, viewname FROM pg_views WHERE schemaname = 'public'"
psql "$DATABASE_URL" -c "SELECT schemaname, matviewname FROM pg_matviews WHERE schemaname = 'public'"
# SQLite
sqlite3 db/f1.sqlite "SELECT type, name, tbl_name FROM sqlite_master WHERE type IN ('view', 'trigger')"
```

### Migrate your app

```julia
# ✗ before: the Driver model is deleted while the hand-made view result_driver reads its table
PormG.Migrations.makemigrations("db")     # planned DROP TABLE "driver" (CASCADE on PostgreSQL)
PormG.Migrations.migrate("db", destructive = true)
# PostgreSQL: result_driver was gone. SQLite: result_driver dangled, and the next table rebuild failed.

# ✓ after: makemigrations raises InvalidMigrationError naming result_driver, and writes no plan.
# Drop the view yourself (and re-create it against the new schema later if you still need it):
#   DROP VIEW result_driver;
PormG.Migrations.makemigrations("db")     # now plans DROP TABLE "driver"
PormG.Migrations.migrate("db", destructive = true)
```

If the model was renamed rather than deleted, run `makemigrations` interactively and answer its
rename question instead. A rename on its own keeps the views and triggers on both engines. On
SQLite, a rename in the same migration as a table rebuild is refused when a view or trigger that
rebuild carries names the renamed table; apply the rename as a migration of its own first.
`interactive = false` never renames and so plans the drop.
