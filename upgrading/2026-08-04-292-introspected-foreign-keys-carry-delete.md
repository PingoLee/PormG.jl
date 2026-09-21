## Introspected foreign keys now carry `on_delete` (PostgreSQL) and the column default (SQLite) (#292)

- **Version**: 0.4.0
- **PormG ref**: #292; `src/migrations/introspection.jl`, `UPGRADING.md`
- **Recorded**: 2026-08-04
- **Severity**: **breaking (generated model files change; a contradictory PostgreSQL schema now
  fails at registration)** — narrow: it affects only apps that generate models by introspecting a
  database. Part of the `0.3.x` pre-publish wave.

### What changed

Introspection lost a different half of each foreign-key declaration per backend, and the two halves
were mirror images:

- **PostgreSQL never queried the referential action at all.** A table whose FK was
  `ON DELETE CASCADE` introspected to a model claiming no cascade, and a migration generated from
  that model dropped the action from the schema. Silent round-trip infidelity.
- **SQLite carried the action but dropped the column default.** Since #287 that is a hard failure:
  an `ON DELETE SET DEFAULT` FK introspected to `on_delete=SET_DEFAULT` with no `default=`, which
  `set_models` rejects — and regenerating produced the identical broken file.

Both are fixed. `OneToOneField` had the same omission as `ForeignKey` and is fixed with it.

Two consequences for existing apps:

**1. Regenerated model files change.** PostgreSQL-generated files gain `on_delete=` on every FK that
declares an action. SQLite-generated files lose a spurious `on_delete=DO_NOTHING` on FKs that never
declared one — both backends now render "no action declared" as an omitted `on_delete`, which is
what PormG already emitted as SQL (`ON DELETE NO ACTION`) for both spellings. `makemigrations` does
not diff `on_delete`, so **regenerating produces no `ALTER` and no migration**; it is a source-file
change only.

One narrow exception, on SQLite: the *field-rename* path does compare the action. So an app that
keeps an explicit `on_delete=DO_NOTHING` in its models file instead of regenerating, and then renames
that FK field, now gets a table rebuild it would not have got before. It is data- and
index-preserving, and it disappears as soon as the file is regenerated.

**2. A self-contradictory PostgreSQL schema now fails at registration.** Because the PostgreSQL path
never emitted `on_delete` before, it could not contradict anything. Now it can, and #287's guards
apply to introspected models as they already did to hand-written ones:

- `ON DELETE SET NULL` on a `NOT NULL` column → `ModelDefinitionError` at `set_models`
- `ON DELETE SET DEFAULT` on a column with no default (or a default PormG cannot represent as an
  `Int64` — a text default, a `nextval(...)` expression) → `ModelDefinitionError`

Both are legal PostgreSQL DDL that only fails at delete time, so a database can genuinely be in this
state. Introspection **warns** naming the table and column when it drops an unrepresentable default,
and never throws from inside the import itself.

### How to find the calls to migrate

```bash
# 1. Regenerate your models and diff — expect on_delete= to appear (PostgreSQL) or a spurious
#    DO_NOTHING to disappear (SQLite). No migration is generated either way.
git diff -- <your models file>
```

```sql
-- 2. Contradictory FKs, if your generated module now fails to register. Run against the DATABASE,
--    not the model file — these are schema states, not code. Reports the two columns you need to
--    judge each row: `attnotnull` and the column default.
--      * confdeltype 'n' (SET NULL)    + attnotnull = t          → contradictory
--      * confdeltype 'd' (SET DEFAULT) + col_default NULL, or a
--        default PormG cannot read as an Int64 (text, nextval)   → contradictory
--    A multi-column FK yields one row per column.
SELECT c.relname, a.attname, con.confdeltype, a.attnotnull,
       pg_get_expr(ad.adbin, ad.adrelid) AS col_default
FROM pg_constraint con
JOIN pg_class c ON c.oid = con.conrelid
JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = ANY(con.conkey)
LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
WHERE con.contype = 'f' AND con.confdeltype IN ('n', 'd');
```

### Before → after

Copy-exact `Model_to_str` output — kwarg order is struct-field order and there are no spaces around
`=`, so this is what `git diff` on a regenerated file actually shows:

```julia
# before — PostgreSQL introspection produced this for an ON DELETE CASCADE column
fk_cascade = Models.ForeignKey("Pormg_it_fk_parent", null=true, pk_field="id")

# after — the action it actually declared is carried through
fk_cascade = Models.ForeignKey("Pormg_it_fk_parent", null=true, pk_field="id", on_delete=CASCADE)
```

If a regenerated model now raises `ModelDefinitionError`, fix the **schema**, not the generated file
— the alternative is re-editing it by hand after every regeneration:

```sql
-- SET NULL needs a nullable column
ALTER TABLE results ALTER COLUMN driverid DROP NOT NULL;
-- SET DEFAULT needs something to set
ALTER TABLE results ALTER COLUMN statusid SET DEFAULT 1;
```
