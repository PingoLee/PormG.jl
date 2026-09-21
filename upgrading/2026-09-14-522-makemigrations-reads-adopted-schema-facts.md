## `makemigrations` reads an adopted schema as facts, so the first run after upgrading may plan one-time changes (#522)

- **Version**: 0.6.0
- **PormG ref**: #522 ; `src/migrations/introspection.jl`, `src/migrations/column_spec.jl`, `src/migrations/planner.jl`
- **Recorded**: 2026-09-14
- **Severity**: behavior change

### What changed

The introspection readers no longer rebuild a field struct from the live catalog and infer facts
from which struct it "looked like"; they read the catalog into the same column description the
declared side compiles to. For a table PormG created through its own migrations **nothing changes**.
For a table PormG **adopted** — created by Django, by hand, or by an older tool — the first
`makemigrations` after upgrading can plan, once, what the old reader silently equated:

| before | after |
|---|---|
| a `SMALLINT` / `INTEGER UNSIGNED` column without its `>= 0` CHECK converged against a `PositiveSmallIntegerField` / `PositiveIntegerField` | plans `ADD CHECK` once |
| a foreign-key column with no single-column index converged against a `ForeignKey` / `OneToOneField` (both declare `db_index = true` by default) | plans `CREATE INDEX` once — Django-created `OneToOneField` columns are the common case, since Django creates no plain index beside the unique one |
| a lengthless `varchar` / a bare `numeric` converged against `CharField(250)` / `DecimalField(10, 2)` | plans that width once |
| a column type PormG has no field for (`inet`, `citext`, an array, `character(n)`) converged against a declared `TextField` / `CharField` | plans a retype, and keeps planning it until the column is excluded or declared by hand; `generate_models_from_db` now warns for such a column |

Two plans also **disappear** on SQLite, for tables PormG did write: a `UUIDField(primary_key = true)`
key, and any key declared `(primary_key = true, unique = true)`, used to re-plan a table rebuild on
every run because the reader flattened every non-integer key to an `IDField`; they now converge.

Also gone: the `PormG.sqlite_type_map` / `PormG.postgres_type_map` constants (never on `names(PormG)`;
0 call sites in the consuming apps) and the `type_map` keyword of `convertSQLToModel`. Internal
signatures that moved, in case an app reached into them: `Dialect.alter_field` lost its `old_field`
positional, and `convertSQLToModel(::DataFrameRow)` gained a `conn` keyword.

### Who this affects

Apps whose database was not created by PormG's own migrations, on either engine. An app whose every
table came from `makemigrations` sees no plan.

### How to find the calls to migrate

There are no calls to migrate. After upgrading, run `makemigrations` and read `dry_run("db")` once per
connection; each row of the table above is recognisable by its statement.

### Migrate your app

Apply the one-time plan, or change the declaration to match the column: `db_index = false` on a
`OneToOneField` you do not want indexed, the real `max_length` / `max_digits`, or
`PormG.register_ignore_tables!([...])` for a table carrying a type PormG cannot declare. A retype is
only ever proposed; nothing runs without `migrate`.
