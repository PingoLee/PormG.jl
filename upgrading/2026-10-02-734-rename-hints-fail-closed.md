## `makemigrations(interactive = false)` refuses a likely rename; `renames =` names it (#734)

- **Version**: Unreleased
- **Recorded**: 2026-10-02
- **PormG ref**: #734; `src/migrations/planner.jl` (`get_migration_plan`, `makemigrations`, `_parse_rename_hints`)
- **Severity**: behavior change. A non-interactive `makemigrations` that used to write a plan can now
  raise `InvalidMigrationError` instead. A new `renames` keyword is the fix. The plan for any other
  change is unchanged.

### What changed

`interactive = false` used to answer "new" for every unmatched model and field. A renamed table
therefore became `DROP TABLE` + `CREATE TABLE`, and a renamed column `DROP COLUMN` + `ADD COLUMN`,
losing the rows. Now a pair with the **same definition** is refused, because it is almost certainly a
rename:

- a vanished table that holds exactly the new model's columns, at least one of them besides its key;
- a removed column identical to the added one.

The error lists every such pair with the hint that decides it:

| | before | after |
|---|---|---|
| Same-definition pair, no hint | drop + add | raises `InvalidMigrationError` |
| `renames = ["old" => "new"]` | (no such keyword) | rename, no question, `interactive` either way |
| `renames = ["old" => nothing]` | (no such keyword) | drop + add, offered to no question |
| A pair whose definition differs, no hint | drop + add | drop + add (unchanged) |

`check(kinds = [:schema_drift])` is unchanged: it still reports such a pair as drift.

### How to find the calls to migrate

Every non-interactive `makemigrations` or `get_migration_plan` call, including one whose keywords
sit on a later line:

```bash
grep -rnE -A3 '(makemigrations|get_migration_plan)\(' --include=*.jl . | grep -E 'interactive *= *false'
```

### Migrate your app

Run it. If it raises, the message names each pair. Add the hint that says what you meant:

```julia
# before — the renamed column was planned as a drop and an add
PormG.Migrations.makemigrations("db"; interactive = false)

# after — a rename keeps the rows
PormG.Migrations.makemigrations("db"; interactive = false,
    renames = ["result.statusid" => "result.racestatusid"])

# after — or say it really is a new column, and the old one goes
PormG.Migrations.makemigrations("db"; interactive = false,
    renames = ["result.statusid" => nothing])
```

Names are physical (`db_table`, `db_column`), and a column is named with its table's **new** name. A
hint does nothing once the rename has run, when the old name is gone and the new one exists, so the
list can stay in the script after the migration is applied. A hint naming neither logs a warning,
because its old name is probably mistyped.
