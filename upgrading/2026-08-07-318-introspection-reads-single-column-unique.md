## Introspection now reads single-column `UNIQUE` back (#318)

- **Version**: 0.4.0
- **PormG ref**: #318; `src/migrations/introspection.jl`, `src/migrations/planner.jl`
- **Recorded**: 2026-08-07
- **Severity**: **behavior-visible (one-time migration plan against existing databases)** — no source
  edit is required. Part of the `0.4.x` wave.

### What changed

Neither backend read a column's `UNIQUE` constraint back, so a model declaring `unique=true` never
compared equal to its own live table. `makemigrations` proposed the same alteration **on every run**
— on SQLite that alteration is the full `CREATE new → INSERT SELECT → DROP old → RENAME` table
rebuild. It also masked genuine drift: with a permanently-dirty baseline, a real schema change was
indistinguishable from the standing false positive.

Two independent root causes, both fixed:

- **SQLite** — `PRAGMA table_info` has no uniqueness column, so `unique` was never populated at all.
  Introspection now reads it from `PRAGMA index_list`/`index_info`.
- **PostgreSQL** — the `unique_constraints` CTE grouped by *table*, merging every unique constraint's
  columns into one array; the consumer then required that array to have length 1. So a table with
  **two separate single-column `UNIQUE`s** reported **neither** as unique. The single-column test now
  applies per *constraint*.

Composite uniqueness is deliberately **not** read as a per-field `unique`: PormG models it as a
model-level `UniqueConstraint` (#19), and marking a member column would churn in the other direction.
For the same reason a bare `CREATE UNIQUE INDEX` (including a single-field `UniqueConstraint`) is not
read back — that keeps both backends symmetric, since PostgreSQL reads `pg_constraint`, which cannot
see an index either.

### What you may see once

Nothing to edit — but the **first** `makemigrations` after upgrading can propose a one-time plan:

- A live single-column `UNIQUE` your model does **not** declare is now visible as drift, so PormG will
  propose removing it (on SQLite, via the table rebuild). Previously it was silently ignored. Review
  that plan before applying it: if the constraint should stay, add `unique=true` to the field.
- On PostgreSQL this newly affects every table carrying **two or more** unique constraints — those
  columns previously introspected as `unique=false` regardless of what the model said.

After that one plan, re-running `makemigrations` is clean, which is the point of the fix.

### How to find the calls to migrate

```bash
# Models declaring column-level uniqueness — the ones whose diff behavior changes.
rg -n 'unique\s*=\s*true' --glob '*.jl'
```

Then run `makemigrations` and **read the plan** before `migrate`.
