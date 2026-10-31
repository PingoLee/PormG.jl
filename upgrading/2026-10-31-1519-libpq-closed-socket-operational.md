## LibPQ: a socket closed under a statement raises `OperationalError`, not `StatementError` (#1519)

- **Version**: Unreleased
- **PormG ref**: #1519 ; `ext/PormGLibPQExt.jl` (`backend_is_connection_error`)
- **Recorded**: 2026-10-31
- **Severity**: behavior change. The exception type changes for one failure, under the LibPQ driver only.

### What changed

When the socket under a running statement closed (a server restart, a proxy or load balancer
cutting the connection), LibPQ.jl raised `LibPQ.Errors.JLConnectionError("PostgreSQL connection
socket was unexpectedly closed")`, and PormG did not recognize it as a lost connection. The caller
got a `StatementError`, the type that means the database refused the SQL, and the dead connection
stayed in its pool slot until the checkout probe retired it. PormG now classifies that exception as
a lost connection. The caller gets `OperationalError`, the slot is renewed, and the pool's other idle
connections are swept, as for every other lost connection. The statement is still not re-run: the
socket can close after the server received it.

| Call | before | now |
|---|---|---|
| A query whose socket closes mid-statement, `postgres_driver: LibPQ` (the default) | `StatementError` (`cause` a `LibPQ.Errors.JLConnectionError`) | `OperationalError` (same `cause`) |
| The pool slot that held the connection | kept the dead handle until the next checkout probe | renewed at once; idle slots swept |
| Re-run of the statement by `fetch` | no | no (unchanged) |
| `postgres_driver: Postgres` | `OperationalError` | unchanged |

### How to find the calls to migrate

Code that catches `StatementError` around queries, or that retries on `OperationalError`:

```bash
grep -rnE 'StatementError|OperationalError|with_read_retry' --include=*.jl .
```

### Migrate your app

Retry logic keyed on `OperationalError`, including `with_read_retry`, now covers this failure.
Nothing to change there. A `catch e isa StatementError` that was handling a dropped connection as a
side effect stops seeing it. Handle it as a lost connection instead:

```julia
# before
try
    M.Result.objects.filter("raceid" => 18).list()
catch e
    e isa StatementError || rethrow()
    # also reached when the socket closed under the query
end

# after
try
    M.Result.objects.filter("raceid" => 18).list()
catch e
    if e isa OperationalError
        # the connection was lost: retry, or report the database as unavailable
    elseif !(e isa StatementError)
        rethrow()
    end
end
```
