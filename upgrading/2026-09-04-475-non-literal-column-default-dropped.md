## A non-literal column DEFAULT is now dropped on every column type, textual ones included (#475)

- **Version**: 0.6.0
- **PormG ref**: #475, #472, #455; `src/migrations/introspection.jl`, `src/migrations/runner.jl`,
  `docs/src/schema_conventions.md`
- **Recorded**: 2026-09-04
- **Severity**: **behaviour change with a data-corrupting upgrade hazard.** It bites exactly the
  apps that declared a model default matching a database expression — a shape the previous entry
  (#472) described as the way a textual column behaved. Part of the `0.5.x` pre-publish wave.

**Superseded in part by #496.** The *classification* this entry introduced stands, and so does the
hazard it warns about below — declaring a `default=` that matches a database expression is still the
one response that corrupts data, and still unprompted on PostgreSQL. What no longer holds is the
outcome: an expression default is no longer **dropped**. #496 added a `db_default` slot, so such a
column imports as `db_default=(postgres="now()",)` and round-trips. Substitute "described as a
`db_default`" for "dropped" throughout; the advice to keep it out of `default=` is unchanged.

#496 has no entry of its own, and that is the rule rather than an omission: it forces no app edit,
because a model declaring nothing on such a column still converges by design.

### What changed

Introspection used to decide whether a `DEFAULT` survived by whether the *field type* refused it. A
`DATETIME DEFAULT CURRENT_TIMESTAMP` was dropped with a warning; the **same expression on a `TEXT`
column was silently kept**, as the quoted literal `"CURRENT_TIMESTAMP"`, because `TextField` accepts
any string.

The `DEFAULT` is now classified while the schema is read — literal or expression, decided by the
DDL — and an expression is dropped and reported on **every** column type and both engines. Quoting
is what distinguishes them, so `DEFAULT 'now()'` is still a literal and is still kept; `DEFAULT 5`
and `DEFAULT true` are unaffected.

New, additive: `PormG.Migrations.check("db")` reports the affected columns directly.

### Migrate your app

**No call sites change.** The edit is in your **model definitions**, and only where you declared a
`default=` that matches a database expression. If you never did, there is nothing to do — this
release only removes churn for you.

The hazard, precisely: PormG now reads such a column as having **no** default, so a model that still
declares one is a *difference*. `makemigrations` proposes

```sql
ALTER TABLE "lap_note" ALTER COLUMN "note" SET DEFAULT 'CURRENT_TIMESTAMP';
```

— a **quoted literal** written over the database's real expression default. `SET DEFAULT` is not
classified as destructive, so on PostgreSQL `migrate()` applies it with no prompt and no
`destructive=true` gate; afterwards every new row stores those 17 characters instead of a timestamp,
and the schema *converges*, so nothing reports it again. On SQLite the same change arrives as a
table rebuild, which does trip the destructive gate.

**Before upgrading — two steps:**

```julia
# 1. List the columns. Read-only, both engines, no models file or migration history needed.
PormG.Migrations.check("db")

# 2. For every column it names, remove the matching default from your model.
#    ✗ note       = Models.TextField(default="CURRENT_TIMESTAMP")
#    ✓ note       = Models.TextField()                                 # the DB keeps its own default
#    ✓ created_at = Models.DateTimeField(auto_now_add=true)            # declare the intent instead
```

Then run `PormG.Migrations.dry_run("db")` and confirm no `SET DEFAULT` appears. Matching the
expression as a literal is never the fix: either declare `auto_now_add`, give the column a type that
expresses what the default computes, or drop the database default by hand.

Full rules: `docs/src/schema_conventions.md` → *Column defaults*.
