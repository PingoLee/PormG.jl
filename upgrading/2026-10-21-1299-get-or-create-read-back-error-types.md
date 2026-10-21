## `get_or_create` raises `OperationalError` or `StatementError` when its row cannot be read back (#1299)

- **Version**: Unreleased
- **PormG ref**: #1299 ; `src/querybuilder/execution_write.jl` (`get_or_create`, the two read-back checks after the insert)
- **Recorded**: 2026-10-21
- **Severity**: behavior. The two read-back failures of `get_or_create` raised `QueryBuildError`, a `UsageError`. They now raise a `DatabaseError` subtype: `OperationalError` on PostgreSQL and `StatementError` on SQLite. A `catch QueryBuildError` or `catch UsageError` around `get_or_create` no longer matches them.

### What changed

`get_or_create` runs `INSERT … ON CONFLICT (lookup) DO NOTHING` on a miss and then reads the row. When
that read finds nothing, the caller's call was not at fault, and `UsageError` promises that it was
(#1238: "the remedy is to change the call"). An app that maps `UsageError` to a bad request
answered 400 to a server-side condition.

| Engine | When | before | after |
|---|---|---|---|
| PostgreSQL | the insert returned no row, and the read finds none: usually the conflicting row was deleted before the read | `QueryBuildError` | `OperationalError`: usually a race, so the call retried can succeed (a trigger or rule that skips the insert fails every retry) |
| SQLite | the insert reported success, but the read finds no row (a trigger dropped it, or a PormG fault) | `QueryBuildError` | `StatementError`: the call runs under the write lock, so no race is possible and a retry fails the same way |

Unchanged: `get_or_create`'s refusals of the call itself (an unknown field, a lookup with no UNIQUE
constraint, a value the field refuses) are still `UsageError` members.

### Who this affects

Code that catches `QueryBuildError` or `UsageError` around `get_or_create` and relies on it for these
two failures. Both are rare: one needs a concurrent delete on PostgreSQL, the other a trigger or a
fault on SQLite.

### How to find the calls to migrate

```bash
grep -rnE 'get_or_create\(' --include=*.jl src/ test/
```

Keep each hit inside a `try` whose `catch` tests `QueryBuildError` or `UsageError`.

### Migrate your app

```julia
# ✗ before — a lost race answered as the caller's mistake
try
    M.Status.objects.get_or_create("statusid" => 200; defaults = ["status" => "Finished"])
catch e
    e isa PormG.UsageError && return bad_request(PormG.error_message(e))
    rethrow()
end

# ✓ after — the race is a retry signal, as any other transient database failure
try
    M.Status.objects.get_or_create("statusid" => 200; defaults = ["status" => "Finished"])
catch e
    e isa PormG.UsageError && return bad_request(PormG.error_message(e))
    e isa PormG.OperationalError && return service_unavailable(PormG.error_message(e))
    rethrow()
end
```
