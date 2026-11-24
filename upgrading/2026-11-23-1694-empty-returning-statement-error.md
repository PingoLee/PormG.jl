## `create` and `update_or_create` on PostgreSQL raise `StatementError` when the insert returns no row (#1694)

- **Version**: Unreleased
- **PormG ref**: #1694, #1599 ; `src/querybuilder/execution_write.jl`, `src/querybuilder/error_funnels.jl`
- **Recorded**: 2026-11-23
- **Severity**: behavior change, only when an `INSERT … RETURNING` returns no row: a trigger or rule skipped the row.
  Every other `create` and `update_or_create` returns as before.

### What changed

On PostgreSQL (LibPQ and Postgres.jl), `create` and `update_or_create` read the new row from the statement's
`RETURNING`. When a `BEFORE INSERT` trigger returns `NULL`, or a rule replaces the insert, the statement succeeds and
returns no row. PormG then indexed the empty rows and raised a raw `BoundsError`. It now raises the
`StatementError` that `update_or_create` on MySQL already raises when its row cannot be read back for the same cause:

| `INSERT … RETURNING` returns no row | before | now |
|---|---|---|
| `create` (PostgreSQL) | `BoundsError` | `StatementError`: `create: the statement returned no race row: a trigger or rule may have skipped it.` |
| `update_or_create` (PostgreSQL) | `BoundsError` | `StatementError`: `update_or_create: the statement returned no race row: a trigger or rule may have skipped it.` |

Not a `UsageError` (the call was valid) and not an `OperationalError` (nothing transient: the same call fails the same
way again). `get_or_create` keeps its `OperationalError` (#1299), whose usual cause is a race.

### How to find the calls to migrate

Only a table with a trigger or rule that skips inserts can reach this. Look for a `catch` that expects a
`BoundsError` around a `create` or `update_or_create`:

```
grep -rn "BoundsError" --include=*.jl .
```

### Migrate your app

```julia
# ✗ before: a trigger that skipped the insert surfaced as a BoundsError
# ✓ after: it is a StatementError, a DatabaseError like any refused statement
try
    M.Race.objects.create("year" => 2009, "round" => 6, "circuitid" => 1, "name" => "Monaco Grand Prix",
                          "date" => Date(2009, 5, 24))
catch e
    e isa PormG.StatementError || rethrow()
    # the row was not written: report it as your app reports a refused statement
end
```
