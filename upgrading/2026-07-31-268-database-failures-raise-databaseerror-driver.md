## Database failures now raise `DatabaseError`, not the driver's exception type (#268)

- **Version**: 0.4.0
- **PormG ref**: #268; `src/exceptions.jl`, `src/Backend.jl`, `src/ConnectionPool.jl`,
  `src/AdvisoryLock.jl`, `src/Configuration.jl`, `ext/PormGLibPQExt.jl`, `ext/PormGSQLiteExt.jl`,
  `docs/src/api.md`
- **Recorded**: 2026-07-31
- **Severity**: **breaking (error contract)** — closes the last hole in `catch PormGError`. Part of
  the `0.3.x` pre-publish wave.

### What changed

Once a statement reached the database, failures used to propagate as the **driver's own exception
type**. Handling a UNIQUE violation therefore meant `catch SQLite.SQLiteException` /
`catch LibPQ.Errors.*` — a hard dependency on the driver package purely to *name* the type, which
fights the `[weakdeps]` design that keeps LibPQ/SQLite optional. `docs/src/api.md` meanwhile
promised "`catch PormGError` catches them all", which was simply false for this class.

Those failures are now wrapped at the pool's own seams:

| New type | Covers |
|---|---|
| `DatabaseError` *(abstract)* | umbrella for all three below |
| `IntegrityError` | `UNIQUE` / `FOREIGN KEY` / `NOT NULL` / `CHECK` / exclusion violations |
| `OperationalError` | connection dropped mid-query, deadlock, serialization failure, lock timeout (incl. `with_advisory_lock`) |
| `StatementError` | invalid SQL, unknown table/column, rejected type, insufficient privilege — and the unclassified fallback |
| `TransactionError` | transaction-**API** misuse; not a database error |

The driver's exception is preserved on `.cause`, so nothing is lost. Classification is exact on
PostgreSQL (LibPQ parameterizes its exception type on the SQLSTATE) and message-based on SQLite
(`SQLiteException` carries only a message).

**User code is untouched.** `run_in_transaction` / `atomic` / `with_savepoint` run your closure
inside their `try`; an exception *you* raise still propagates as itself. Only driver failures wrap.

### How to find the calls to migrate

```bash
grep -rn "SQLiteException\|LibPQ.Errors\|PQResultError" --include=*.jl .
grep -rn "duplicate key\|UNIQUE constraint\|violates foreign key" --include=*.jl .
```

Also check any `catch` that matched a database failure by message substring — a type now exists.

### Before → after

```julia
# before — needs `using SQLite` (or LibPQ) purely to name the type, and is backend-specific
try
    M.Driver.objects.create("driverref" => "senna", "code" => "SEN")
catch e
    if e isa SQLite.SQLiteException && occursin("UNIQUE constraint failed", e.msg)
        return conflict()
    end
    rethrow()
end

# after — backend-agnostic, no driver dependency
try
    M.Driver.objects.create("driverref" => "senna", "code" => "SEN")
catch e
    e isa IntegrityError   && return conflict(error_message(e))
    e isa OperationalError && return retry_later()
    rethrow()
end
```

Two further retypings in the same pass, both previously uncatchable via `PormGError`:

```julia
# before                                        # after
catch e; e isa ErrorException && …              catch e; e isa OperationalError && …
#   with_advisory_lock acquisition timeout

catch e; e isa QueryBuildError && …             catch e; e isa TransactionError && …
#   atomic(durable=true) nested in a transaction
catch e; e isa InvalidConfigurationError && …   catch e; e isa TransactionError && …
#   model bound to another connection during an open transaction
```

Read any of these with `error_message(e)`, **not** `e.msg` — like `PoolConnectError`, the three
`DatabaseError` subtypes are built from structured fields and have no `msg`.
