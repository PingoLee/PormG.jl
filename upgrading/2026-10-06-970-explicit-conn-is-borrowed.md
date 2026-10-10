## `fetch(…; conn = c)` — a connection you pass is borrowed, never released for you (#970)

- **Version**: Unreleased
- **PormG ref**: #970 ; `src/ConnectionPool.jl` (`fetch_async`, `await_result`, `FetchTask`, `with_transaction_async`)
- **Recorded**: 2026-10-06
- **Severity**: breaking (narrow). `fetch` and `fetch_async` used to release a connection passed as `conn = c` when the statement ended. They now leave it leased, and the caller releases it.

### What changed

Four funnels accept a connection as `conn = c`, and each one used to decide for itself whether to
release it. There is now one rule: **a connection you pass is borrowed**. No funnel releases it, on
any outcome. The one exception is the explicit hand-over, `with_transaction(…; release_conn = true)`.

| Funnel, with `conn = c` | success, before → after | refused before it is sent (#951 NUL) | driver throws |
|---|---|---|---|
| `fetch`, `fetch_async` + `await_result` | released → **kept** | released → **kept** | released → **kept** |
| `with_transaction_async` | kept | kept | released → **kept** |
| `with_transaction(…; release_conn = false)` | kept | kept | kept |
| `with_transaction(…; release_conn = true)` | released | released | released |

`with_transaction_async`'s change is a fix. Its docstring always said it never released the
connection, but a driver throw at dispatch handed a caller's connection back to the pool, possibly
with the caller's `BEGIN` still open on it. Another borrower could then be given it.

A connection the funnel acquires itself (`conn = nothing`) is unaffected: `fetch` still releases
it, and `with_transaction*` still returns it to you in the result tuple.

### Who this affects

Only code that passes `conn =` to `fetch` or `fetch_async`. Nothing inside PormG does: the sites that could have
done so avoided it because `fetch` released the connection.

### How to find the calls to migrate

```bash
grep -rnP -A4 '\bfetch(_async)?\(' --include=*.jl . | grep -P '\bconn\s*='
```

The `-A4` catches a `conn =` keyword written on a continuation line of a multi-line call; read each
hit in context.

A call that relied on the release now holds a lease the pool never gets back. With
`leak_detection_threshold` set, that shows up as *"Pool connection held past
leak_detection_threshold"*, and eventually as `PoolTimeoutError`.

### Migrate your app

```julia
# ✗ before — fetch released c for you
c = acquire_connection(pool)
rows = fetch(pool, "SELECT count(*) FROM driver"; conn = c)

# ✓ after — c is yours; release it once, from a finally
c = acquire_connection(pool)
try
    rows = fetch(pool, "SELECT count(*) FROM driver"; conn = c)
finally
    release_connection(pool, c)
end
```

Code that worked around the old release — routing statements through `with_tx_context` instead of
passing `conn`, or releasing after `with_transaction` rather than `fetch` — keeps working.
