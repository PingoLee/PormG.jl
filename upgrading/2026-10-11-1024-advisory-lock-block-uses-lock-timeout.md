## `with_advisory_lock(…; strategy = :block)` bounds its wait with `lock_timeout`, not `statement_timeout` (#1024, #1010)

- **Version**: Unreleased
- **PormG ref**: #1024, #1010 ; `src/AdvisoryLock.jl` (`with_advisory_lock`)
- **Recorded**: 2026-10-11
- **Severity**: behavior change, PostgreSQL only. The statements sent around the lock change, a
  session `statement_timeout` now applies to the wait, and a timeout on a server whose messages are
  not in English raises the lock-holder error instead of the raw cancel.

### What changed

`:block` waits in the server, in `pg_advisory_lock`. It used to bound that wait by setting
`statement_timeout` to `timeout_ms` for the call, and to recognize the expiry by its English message
text. It now sets `lock_timeout` instead, and recognizes the expiry by its own SQLSTATE, `55P03`.

| | before | after |
|---|---|---|
| Statements around the lock | `SHOW` / `SET statement_timeout = <timeout_ms>`, restored after | `SHOW` / `SET lock_timeout = <timeout_ms>`, restored after |
| A session or role `statement_timeout` shorter than `timeout_ms` | overridden for the wait | applies: it ends the wait first, raising the query-canceled `OperationalError` (SQLSTATE `57014`) |
| The wait times out, server `lc_messages` in English | `OperationalError` "Failed to acquire advisory lock …" | the same |
| The wait times out, server messages localized (e.g. `pt_BR`) | the raw driver cancel (`57014`) propagated | `OperationalError` "Failed to acquire advisory lock …" |
| Any other `57014` (an external `pg_cancel_backend`) | propagated | propagated |

`strategy = :poll` (the default) and SQLite are unchanged.

### Who this affects

Code that calls `with_advisory_lock` with `wait = true, strategy = :block` on PostgreSQL, and
either sets a session or role `statement_timeout` shorter than its `timeout_ms`, catches the cancel
error on a localized server, or asserts the statements sent.

### How to find the calls to migrate

```bash
grep -rnE 'with_advisory_lock' --include=*.jl . | grep -E ':block'
```

### Migrate your app

```julia
# ✗ before — a role statement_timeout of 2 s was overridden by timeout_ms for the wait
PormG.with_advisory_lock("db", "nightly-import"; wait = true, strategy = :block, timeout_ms = 30_000) do
    import_results()
end

# ✓ after — the 2 s statement_timeout ends the wait first. Keep timeout_ms below it, or raise the
#   session's statement_timeout around the call
PormG.with_advisory_lock("db", "nightly-import"; wait = true, strategy = :block, timeout_ms = 1_500) do
    import_results()
end
```
