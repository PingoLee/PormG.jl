## `migrate()` returns a `MigrationResult`, and nothing pending is no longer an error (#737)

- **Version**: Unreleased
- **Recorded**: 2026-09-26
- **PormG ref**: #737; `src/migrations/runner.jl` (`migrate`, `MigrationResult`)
- **Severity**: behavior change

### What changed

`migrate()` used to return `nothing` whatever it did. When there was no `pending_migrations.jl` it
threw `InvalidMigrationError("No pending migrations found at: …")`. That is the same type a plan
that does not parse raises, so a caller could not tell "up to date" from "broken".

It now returns a `PormG.Migrations.MigrationResult(outcome, version, n_statements)` on every path
that does not throw. `outcome` is one of:

- `:applied`
- `:already_applied`
- `:nothing_pending`
- `:disabled` (the connection is `change_db: false`)
- `:declined` (the interactive prompt was not confirmed, or a destructive plan was refused at the
  terminal for lack of `destructive = true`)

**No pending plan now returns `:nothing_pending` instead of throwing.** A plan that does not parse
still raises `InvalidMigrationError`, and it now does so before anything is written to the
database.

The other changes in #737 add behavior rather than change it:

- On PostgreSQL the history-table DDL and the extension install now run inside the migration lock.
- `lock_wait`, `lock_timeout` and `statement_timeout` keywords were added.
- On SQLite the already-applied check now runs inside `BEGIN IMMEDIATE`.

None of these needs a code change.

### How to find the calls to migrate

A call site needs attention only if it catches `InvalidMigrationError` around `migrate` to mean
"nothing to do", or relies on the return value being `nothing`:

```bash
grep -rnE -B2 -A6 'migrate\(' --include=*.jl . | grep -E 'InvalidMigrationError|MigrationError|isnothing|=== nothing'
```

`-B2 -A6` catches a `try`/`catch` written around the call.

### Migrate your app

```julia
# ✗ before — "nothing pending" arrived as an exception, indistinguishable from a corrupt plan
try
    PormG.Migrations.migrate("db"; interactive = false)
catch e
    e isa PormG.InvalidMigrationError || rethrow()
    @info "No pending migrations"
end

# ✓ after — it is an outcome; a corrupt plan still throws
result = PormG.Migrations.migrate("db"; interactive = false)
result.outcome === :nothing_pending && @info "No pending migrations"
```
