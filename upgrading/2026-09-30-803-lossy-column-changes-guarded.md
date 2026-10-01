## A lossy column change is refused, or needs `destructive = true` (#803)

- **Version**: Unreleased
- **Recorded**: 2026-09-30
- **PormG ref**: #803; `src/migrations/column_spec.jl` (`LossyAlter`, `LOSSY_ALTER_KINDS`), `src/migrations/runner.jl` (`migrate`, `dry_run`, `DryRunResult`, `MigrationPrecheckError`)
- **Severity**: behavior change

### What changed

The destructive guard reads a plan's SQL text, so it saw a `DROP` and nothing that only narrowed a
column. `makemigrations` now classifies every column change from what the column held before and
what it will hold, records what it finds in the plan header, and `dry_run` / `migrate` act on it.
Three plan shapes behave differently from before:

1. **A change that silently alters values now needs `destructive = true`** on PostgreSQL:
   - fewer `decimal_places` (values round);
   - `FloatField` or `DecimalField` → an integer field (values round);
   - `DateTimeField` → `DateField` or `TimeField`;
   - a `TIMESTAMPTZ` column → `TIMESTAMP`.

   These plans used to apply with no opt-in, and a lower scale logged one warning. They now raise
   `DestructiveMigrationError` non-interactively (with the change in its new `lossy_alters` field),
   and the history row records them as destructive. SQLite plans are unchanged here: every SQLite
   column change is a table rebuild, which already needed `destructive = true`.
2. **A change that would fail on existing rows is refused before anything runs**, on both engines —
   a `NULL` under a new `NOT NULL`, a value longer than a new `max_length`, an integer out of range
   for a narrower field, a negative value under a new `PositiveIntegerField`. `migrate` counts those
   rows first and raises the new `PormG.Migrations.MigrationPrecheckError`; `destructive = true`
   does not bypass it. Before, the plan ran, failed on the row inside the transaction with a
   `DatabaseError`, rolled back, and left a `failed` history row.
3. **Text → a number, boolean, date, timestamp, UUID or JSON — and boolean ↔ a number — is refused
   on PostgreSQL** with the same error: it can never run, because PostgreSQL has no automatic cast
   and the plan carries no `USING`.

`DryRunResult` also gains a fourth positional field, `lossy_alters`, and `is_destructive(r)` now also
counts the first kind.

### How to find the calls to migrate

A boot or deploy script needs attention only if it calls `migrate` without `destructive = true`, or
catches a `DatabaseError` around it, or builds a `DryRunResult` itself:

```bash
grep -rnE -B2 -A6 'migrate\(' --include=*.jl . | grep -E 'destructive|DatabaseError|IntegrityError|catch'
grep -rn 'DryRunResult(' --include=*.jl .
```

Then, before deploying the next schema change, look at what the plan does to existing rows:

```julia
PormG.Migrations.dry_run("db").lossy_alters
```

### Migrate your app

```julia
# ✗ before — a lower decimal_places on PostgreSQL rounded every value, with no opt-in
PormG.Migrations.migrate("db"; interactive = false)

# ✓ after — rounding existing values is data loss, and says so
PormG.Migrations.migrate("db"; interactive = false, destructive = true)
```

```julia
# ✗ before — a NOT NULL over NULL rows failed inside the migration, as a database error
try
    PormG.Migrations.migrate("db"; interactive = false)
catch e
    e isa PormG.DatabaseError || rethrow()
    @error "migration failed" msg = error_message(e)
end

# ✓ after — refused before any write, with the rows counted
try
    PormG.Migrations.migrate("db"; interactive = false)
catch e
    e isa PormG.Migrations.MigrationPrecheckError || rethrow()
    for f in e.findings
        @error "fix the data, then migrate again" f.table f.column f.kind f.rows
    end
end
```

```julia
# ✗ before
PormG.Migrations.DryRunResult(checksum, statements, destructive_statements)
# ✓ after
PormG.Migrations.DryRunResult(checksum, statements, destructive_statements, PormG.Migrations.LossyAlter[])
```
