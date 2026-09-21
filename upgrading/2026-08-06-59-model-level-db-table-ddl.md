## Model-level `db_table`, and DDL now quotes the table identifier (#59)

- **Version**: 0.4.0
- **PormG ref**: #59; `src/Kernel.jl`, `src/Models.jl`, `src/Dialect.jl`, `src/migrations/planner.jl`,
  `src/querybuilder/{execution,build_joins,deletion,execution_bulk}.jl`, `src/Configuration.jl`,
  `src/models/fields.jl`, `docs/src/schema_conventions.md`, `docs/src/fields.md`
- **Recorded**: 2026-08-06
- **Severity**: **mostly additive**, with two narrow behavior changes — a `ManyToManyField(db_table =
  …)` that was relying on being silently lowercased, and generated model files for
  **introspected mixed-case tables**. Neither requires a source edit for a schema that follows the
  documented lowercase house style.

### What changed

**The feature (additive).** A model can now pin its physical table name:

```julia
DriverProfile = Models.Model("driver_profile",
  db_table = "Driver_Profile_Legacy",   # ← the table that actually exists
  driverid = Models.IDField(),
)
```

The positional name stays the lowercase logical identifier; `db_table` carries the physical one,
**verbatim** — no case fold, no leading-underscore strip. It is authoritative in DDL, in
`SELECT`/`INSERT`/`UPDATE`/`DELETE`, in `JOIN` targets, in a `ForeignKey`'s `REFERENCES` target, and
in migration add/drop/rename detection. A model that does not set it derives its table name exactly
as before, so **no existing schema changes and nothing needs re-migrating**.

This is the escape valve #300 and #306 were built to point at: a positional name that is mixed-case
or underscore-prefixed is still rejected, and `db_table` is now where that intent goes.

**DDL quotes the table identifier.** `CREATE TABLE IF NOT EXISTS driver (…)` is now
`CREATE TABLE IF NOT EXISTS "driver" (…)`. Necessary for the feature — an unquoted mixed-case name
folds to lowercase on PostgreSQL, which would have split the DDL from every (already-quoted)
query-side site. Semantically identical for a lowercase name on both backends. Only affects code that
**string-matches generated DDL**; migrations themselves are unchanged in effect.

**`ManyToManyField(db_table = …)` now preserves case.** It previously ran the value through
`format_model_name`, silently lowercasing it (and stripping a leading underscore) — the opposite
policy from the new model-level option, for the same user intent. Both now carry the value verbatim.

```julia
Models.ManyToManyField(Driver, db_table = "Driver_Races")
# before → through table `driver_races`
# after  → through table `Driver_Races`
```

**Generated model files pin an introspected mixed-case table.** `inspectdb` on a table named
`Driver_Profile` used to generate `Models.Model("driver_profile", …)` — a declaration addressing a
*different* table than the one it was read from. It now also emits the original spelling:

```julia
Driver_profile = Models.Model("driver_profile", db_table = "Driver_Profile", …)
```

**A field named `db_table` must now be declared with `db_column`.** `db_table` is peeled off
before the `fields...` slurp (exactly like `constraints`), so it is read as the option:

```julia
# before — declared a column called `db_table`
Models.Model("thing", id = Models.IDField(), db_table = Models.CharField())
# after  → ModelDefinitionError: The 'db_table' option on model 'thing' must be a String or nothing,
#          got PormG.Models.sCharField

# migrate to db_column — still the column `db_table`:
Models.Model("thing", id = Models.IDField(), table_kind = Models.CharField(db_column = "db_table"))
```

`var"db_table" = Models.CharField()` does **not** work either: it parses to the keyword-argument
name `:db_table`, and the peel keys on that name however it was spelled. (This entry originally
prescribed the leading-underscore escape hatch, `_db_table = Models.CharField()`; that hatch was
retired later in the same pre-publish wave — see
[the #317 entry](#the-leading-underscore-field-name-escape-hatch-is-retired-317) — so `db_column`
is the spelling to migrate to.)

It fails loudly at load time, never silently. A *table* named `db_table` is unaffected —
`Models.Model("db_table", …)` needs no change.

### How to find the calls to migrate

```bash
# 1. M2M through-table overrides whose value is not already lowercase — the only ones whose
#    physical table name changes.
rg -n 'ManyToManyField\([^)]*db_table\s*=\s*"[^"]*[A-Z_]' --glob '*.jl'

# 2. Anything asserting on generated DDL text (the quoting change).
rg -n 'CREATE TABLE IF NOT EXISTS [a-z_]' --glob '*.jl'

# 3. A FIELD named db_table — now read as the model option. Matches `db_table = <something>(`,
#    i.e. a field constructor rather than a string literal, so it does not flag legitimate uses.
rg -n 'db_table\s*=\s*Models\.' --glob '*.jl'
```

An app whose M2M `db_table` values are already lowercase, and which does not string-match DDL, has
nothing to change. If hit 1 returns a match, the through table it names is being renamed — either
lowercase the value to keep the current table, or migrate the table to the new spelling.
