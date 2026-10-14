## A task that outlives its `run_in_transaction` / `atomic` block no longer uses the block's connection (#839)

- **Version**: 0.8.0
- **PormG ref**: #839 ; `src/Configuration.jl` (`with_tx_context`, `_open_tx_context`, `get_tx_connection`, `in_transaction_context`)
- **Recorded**: 2026-10-11
- **Severity**: behavior change. A query issued by a task spawned inside a transaction block, and
  still running after the block ended, runs on a different connection, in autocommit. Transaction
  helpers return different values in that task.

### What changed

The transaction context is a `ScopedValue`, so a task spawned inside `run_in_transaction` / `atomic`
inherits it. A task that was never awaited kept that context after the block had committed and
handed its connection back to the pool. Its queries then reused the **released** connection, with
`in_transaction_context()` still `true` — while another borrower could lease the same connection.
A block that task opened itself became a `SAVEPOINT` on that released connection.

The context is now closed when the block ends (on a return and on a throw), and every reader skips
a closed one:

| In a task still running after its block ended | before | after |
|---|---|---|
| `fetch` / any ORM query | the block's released connection | an ordinary connection from the pool, autocommit |
| `in_transaction_context()` | `true` | `false` |
| `current_transaction_depth()` | the block's depth | `0` (or the depth of an enclosing block that is still running) |
| `run_in_transaction` opened inside it | a `SAVEPOINT` on the released connection | its own transaction |

PormG logs one warning per process the first time a task reads a closed context. A statement the
task sends just before the block ends may still run on the block's connection, before or after the
`COMMIT`; await the task inside the block to make it part of the transaction.

### Who this affects

Code that starts a task (`@async`, `Threads.@spawn`, `@spawn`-based helpers) inside a transaction
block and does not wait for it before the block returns.

### How to find the calls to migrate

```bash
grep -rnE -A15 'run_in_transaction|atomic\(' --include=*.jl . | grep -E '@async|@spawn|Threads\.@spawn|schedule\('
```

### Migrate your app

```julia
# ✗ before — if the block returned first, the task's write ran on the block's released connection,
#   which another borrower could hold. Now it runs on its own connection, in autocommit, with a warning
PormG.run_in_transaction("db") do
    M.Driver.objects.filter("driverid" => 1).update("code" => "HAM")
    @async M.Result.objects.filter("driverid" => 1).update("points" => 0)
end

# ✓ after — await it inside the block if it belongs to the transaction
PormG.run_in_transaction("db") do
    M.Driver.objects.filter("driverid" => 1).update("code" => "HAM")
    wait(@async M.Result.objects.filter("driverid" => 1).update("points" => 0))
end
```
