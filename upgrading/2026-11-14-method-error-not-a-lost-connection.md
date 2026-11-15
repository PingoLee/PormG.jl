## Error classification — a `MethodError` is never a lost connection or a SQLite lock (#1599)

- **Version**: Unreleased
- **PormG ref**: #1599, #1799 ; `src/Backend.jl`, `ext/PormGSQLiteExt.jl`
- **Recorded**: 2026-11-14
- **Severity**: behavior change, only for a `MethodError` whose function or arguments print one of the
  phrases below. Every other error classifies as before.

### What changed

When a statement fails with an error that the driver does not own, PormG classifies it by its text:
whether it says the connection was lost (SQLite: `database is closed`, `database connection is closed`,
`disk i/o error`; LibPQ's own phrases), whether SQLite's database is locked (`database is locked`,
`database table is locked`), or whether no transaction is active.

For a `MethodError`, that text was `string(e)`, which prints the function and its arguments, so a
`MethodError` whose arguments held such a phrase was treated as that condition. A `MethodError` is now
classified by its type name alone, so no phrase matches it:

| a `MethodError` whose arguments print a phrase | before | now |
|---|---|---|
| SQLite, `database is locked`, raised by a statement | the statement was retried, up to the lock-retry limit | raised at once |
| SQLite or LibPQ, a lost-connection phrase, raised by a statement outside a transaction | classified as a lost connection: the connection renewed, the pool's idle connections retired, and the error raised as an `OperationalError` | raised as a `StatementError`, the connection kept |
| the same, raised inside a transaction | the abandoned statement's cleanup treated it as a lost connection | treated as any other error |
| SQLite, `no transaction is active`, raised by a ROLLBACK | taken as a benign rollback: the connection released to the pool | taken as a failed rollback: the connection renewed or discarded, and `Failed to rollback…` logged |

The change is what lets a `juliac --trim` binary report the `MethodError` itself: `string` on an untyped
value has no compiled code there, so classifying the error raised a second `MethodError` in its place.

### How to find the calls to migrate

There is no call to migrate. Code that relied on a `MethodError` being retried or treated as a lost
connection was relying on the text of the arguments that caused it. Look for a `catch` that expects an
`OperationalError` after a call that can raise `MethodError`:

```
grep -rn "OperationalError" --include=*.jl .
```

### Migrate your app

```julia
# ✗ before: a MethodError raised inside a statement, with "database is locked" among its arguments,
#   was retried as a SQLite lock and could surface as an OperationalError
# ✓ after: it reaches the caller as the MethodError (wrapped in StatementError); fix the call it names
try
    M.Result.objects.filter("driverid__surname" => "Senna").list()
catch e
    e isa PormG.StatementError && e.cause isa MethodError && rethrow()   # a bug to fix, not a condition to retry
    rethrow()   # anything else: handle it as your app already does
end
```
