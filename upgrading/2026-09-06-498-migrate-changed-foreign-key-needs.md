## `migrate()` on a changed foreign key now needs `destructive = true` (#498)

- **Version**: 0.6.0
- **PormG ref**: #498; `src/migrations/planner.jl`, `src/Models.jl`, `src/migrations/introspection.jl`
- **Recorded**: 2026-09-06
- **Severity**: **behavior change** — a migration that previously generated nothing now generates
  DDL, and that DDL is destructive-classified.

### What changed

Changing what a `ForeignKey` points at — the target model, the target column, or `on_delete` —
generated **no PostgreSQL DDL at all** and warned `The attributes [:to] are not implemented in
alter_field function` on every `makemigrations`. The live constraint kept pointing at the old parent
forever. An `on_delete` change was discarded silently on **both** backends.

It is now planned: `DROP CONSTRAINT` + `ADD CONSTRAINT` on PostgreSQL, and the existing table rebuild
on SQLite (which already did the right thing).

The consequence for an app is the `DROP CONSTRAINT`. `is_destructive` matches it, so `dry_run()`
reports the migration as destructive and `migrate()` **refuses it** unless you opt in — where the
same call previously succeeded by doing nothing at all for that key.

### How to find the calls to migrate

Any `migrate(...)` that does not pass `destructive`, in a deploy script or CI step:

```bash
grep -rn "migrate(" --include=*.jl . | grep -v "destructive"
```

Then confirm whether it matters for your app: if `makemigrations` proposes nothing, nothing changes
for you. This only bites when a model's foreign key has drifted from the live schema.

```bash
grep -rn "DROP CONSTRAINT" <your app>/db/*/migrations/pending_migrations.jl
```

### Migrate your app

```julia
# ✗ before — silently applied nothing for a re-pointed foreign key, and returned successfully
migrate("db/mydb")

# ✓ after — the re-point is real DDL, and dropping the old constraint is an opt-in
migrate("db/mydb", destructive = true)
```

Review `dry_run("db/mydb")` before opting in, as with any destructive migration. Two things worth
knowing about the generated plan:

- Only the **constraint** is dropped. No column and no row is touched.
- The new constraint is `DEFERRABLE INITIALLY DEFERRED`, so it is validated when the migration
  **commits**. If a row holds a value that does not exist in the new parent, the commit fails and the
  whole migration rolls back. Re-point the data first, or clear the column, before changing the model.

If you would rather not opt in, keep the model and the database agreed: revert the model change, or
apply the constraint swap by hand.
