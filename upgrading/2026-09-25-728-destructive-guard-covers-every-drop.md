## `migrate` — the destructive guard covers every `DROP`, a `TRUNCATE`, and a `DELETE` with no `WHERE` (#728)

- **Version**: Unreleased
- **Recorded**: 2026-09-25
- **PormG ref**: #728; `src/migrations/runner.jl` (`_DESTRUCTIVE_PATTERNS`, `_PROPERTY_DROP_CLAUSE`, `is_destructive`)
- **Severity**: behavior change — a hand-edited plan that used to apply without `destructive = true` can now be refused

### What changed

`Migrations.is_destructive` used to match five spellings: `DROP TABLE`, `DROP COLUMN`, `DROP INDEX`,
`DROP CONSTRAINT` and `TRUNCATE TABLE`. Anything else a plan held was treated as additive, so
`migrate()` applied it without asking. `makemigrations` never writes anything else. But a plan
edited by hand, as *Manual SQL in Pending Migrations* describes, could carry a `DROP VIEW … CASCADE`,
a `TRUNCATE drivers`, or an `ALTER TABLE drivers DROP nationality` (the `COLUMN` keyword is optional
on both engines), and none of those needed `destructive = true`.

A statement is now destructive when it is:

1. **any `DROP`**: every object kind, including views, schemas, functions, types, sequences,
   triggers and extensions, plus `ALTER TABLE … DROP [COLUMN] x`. The exceptions are the
   `ALTER COLUMN … DROP NOT NULL / DEFAULT / IDENTITY / EXPRESSION` sub-clauses, which remove a
   property rather than data;
2. **`TRUNCATE`**, with or without `TABLE`;
3. **`DELETE FROM` with no `WHERE`**, which empties the table like `TRUNCATE` does and is the only
   way to write that on SQLite.

`UPDATE` without `WHERE` is still not flagged.

The guard reads SQL text, so a **generated** plan changes class in one case only: a literal it
carries reads like one of the statements above. For example, `default = "Drop zone"` renders as
`SET DEFAULT 'Drop zone'`, and that plan now needs `destructive = true`. The rule is deliberately
fail-closed: stripping literals first would hide an `EXECUTE 'DROP TABLE ' || t` inside a `DO`
block. Apart from that, every statement in the golden plan corpus classifies as before, and a unit
sweep pins it.

It can still miss a few hand-written spellings: any `WHERE` excuses a `DELETE`, even `WHERE true`,
and a keyword glued to a quoted name or a comment (`DROP"col"`) is not seen. The old guard caught
none of those either.

The history table's `is_destructive` column follows the same rule, including for `mark_applied`
called with `sql_content`.

### How to find the calls to migrate

There is no call pattern to grep for. The change is in how a plan's statements are classified. Look
for hand-added SQL in any plan you apply non-interactively:

```bash
grep -nEi 'DROP|TRUNCATE|DELETE[[:space:]]+FROM' db/migrations/pending_migrations.jl
```

For generated plans, look for a field `default =` string or a `db_default` expression that
contains `drop `, `truncate ` or `delete from`.

Then run `PormG.Migrations.dry_run("db")`. It lists the destructive statements before anything runs.

### Migrate your app

```julia
# ✗ before — a deploy script applying a plan that holds a hand-added
#   "Rebuild standings view" => """DROP VIEW driver_standings_v;"""
PormG.Migrations.migrate("db")          # applied the DROP VIEW without asking

# ✓ after — the same plan now throws DestructiveMigrationError until you opt in
PormG.Migrations.migrate("db", destructive = true)
```
