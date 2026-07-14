# Transactions and `run_in_transaction`

PormG transactions are **async-aware** and **connection-aware**, designed to integrate seamlessly with multithreaded Julia code and web frameworks like Genie.jl. The primary entry point is `run_in_transaction`, which borrows a connection from the pool, executes your block inside a PostgreSQL transaction, and either commits or rolls back automatically.

Because every operation runs through the async core, even synchronous-looking code never blocks the scheduler. This means you can safely wrap database work inside `@async` tasks, web request handlers, or multithreaded `@sync` loops without deadlocking.

## Table of Contents

- [Basic Usage](#Basic-Usage)
- [Why Use Transactions](#Why-Use-Transactions)
- [Async Context Propagation](#Async-Context-Propagation)
- [Bulk Operations in Transactions](#Bulk-Operations-in-Transactions)
- [Multithreaded Work](#Multithreaded-Work)
- [Error Handling and Rollback](#Error-Handling-and-Rollback)
- [Lower-Level Helpers](#Lower-Level-Helpers)

---

## Basic Usage

The simplest pattern: pass your `"db_2"` database key to `run_in_transaction`, then execute your query block inside the callback.

```julia
using PormG, LibPQ   # "db_2" is a PostgreSQL connection
using DataFrames

# Load configuration
PormG.Configuration.load("db_2")

# Load models
include("db_2/models.jl")
import .models as M

# Run a transaction
PormG.run_in_transaction("db_2") do
  # All queries inside this block share the same connection
  query = M.Result.objects
  query.filter(
    "raceid__year" => 2025,
    "positionorder" => 1,
  )
  
  query.values(
    "driverid__forename",
    "driverid__surname",
    "constructorid__name",
    "points",
  )
  
  df = query |> DataFrame
  @info "2025 Champion" df=df
end
```

**Generated SQL (PostgreSQL):**
```sql
-- PormG transaction boundary control
BEGIN;

-- SELECT query executing inside the transaction connection
SELECT 
  "T1"."forename" AS "driverid__forename", 
  "T1"."surname" AS "driverid__surname", 
  "T2"."name" AS "constructorid__name", 
  "Tb"."points" AS "points"
FROM "result" AS "Tb"
INNER JOIN "races" AS "Tb_1" ON "Tb"."raceid" = "Tb_1"."raceid"
INNER JOIN "driver" AS "T1" ON "Tb"."driverid" = "T1"."driverid"
INNER JOIN "constructor" AS "T2" ON "Tb"."constructorid" = "T2"."constructorid"
WHERE "Tb_1"."year" = \$1 AND "Tb"."positionorder" = \$2
-- Parameters: [2025, 1]

-- Auto-committed when the block completes successfully
COMMIT;
```

The connection is automatically returned to the pool when the block exits. If any exception is raised inside the block, the transaction is rolled back and the exception rethrows.


---

## Why Use Transactions

### Atomicity with Multiple Writes

When you update multiple tables and need them to succeed or fail together:

```julia
# Real-world scenario: a stewards' decision moves 2 championship points from one
# driver to another — the deduction and the award must commit together
PormG.run_in_transaction("db_2") do
  # Deduct from the penalized driver
  penalized = M.Driver_standings.objects
  penalized.filter("raceid" => 841, "driverid" => 20)
  penalized.update("points" => F("points") - 2)
  
  # Award to the promoted driver
  promoted = M.Driver_standings.objects
  promoted.filter("raceid" => 841, "driverid" => 1)
  promoted.update("points" => F("points") + 2)
  
  # Both changes succeed together, or both roll back
end
```

**Generated SQL (PostgreSQL):**
```sql
BEGIN;

-- Deduction using an F() expression
UPDATE "driver_standings" AS "Tb"
SET "points" = ("Tb"."points" - \$1)
WHERE "Tb"."raceid" = \$2 AND "Tb"."driverid" = \$3
-- Parameters: [2, 841, 20]

-- Award using an F() expression
UPDATE "driver_standings" AS "Tb"
SET "points" = ("Tb"."points" + \$1)
WHERE "Tb"."raceid" = \$2 AND "Tb"."driverid" = \$3
-- Parameters: [2, 841, 1]

COMMIT;
```

If the award fails, the deduction is never applied — the standings never lose points into thin air. This keeps championship data consistent.

### Avoiding Partial States

Bulk operations (inserts, updates, deletes) already use transactions internally, but wrapping them in an explicit transaction ensures all-or-nothing behavior across multiple bulk calls:

```julia
# Scenario: Load a season's constructor standings
bulk_data = [
  Dict("year" => 2025, "constructorid" => 1, "points" => 250, "position" => 1),
  Dict("year" => 2025, "constructorid" => 2, "points" => 240, "position" => 2),
  # ... 8 more constructors
]
df = DataFrame(bulk_data)

query = M.Constructor_standing.objects

# If any row fails, all 10 are rolled back
PormG.bulk_insert(query, df, chunk_size=5)

```

---

## Async Context Propagation

One of PormG's key strengths is that spawned `@async` tasks automatically inherit the transaction context. This lets you write elegant concurrent code without worrying about connection pools.

### Single Async Task

```julia
child_saw_context = Atomic{Bool}(false)

PormG.run_in_transaction("db_2") do
  (M.Result.objects).create(
    "raceid" => 900,
    "driverid" => 11,
    "constructorid" => 6,
    "points" => 26,
  )
  
  t = @async begin
    # The async task can detect the transaction context
    child_saw_context[] = PormG.Configuration.get_tx_connection() !== nothing
    
    # Use the same transaction without requesting a new connection
    query = M.Driver.objects
    query.filter("driverid" => 11)
    query.update("code" => "WIN")
  end
  
  wait(t)
end

@test child_saw_context[]  # true: async inherited the context
```

### Tasks created outside a transaction

Creating a `Task` with `Task(...)` (or the `@task` macro) *outside* a transaction captures the current task-local state. Scheduling that pre-created task later *inside* a `run_in_transaction` block does **not** retroactively install the transaction context into the Task — it keeps the context it captured at creation time.

```julia
# Create a task outside any transaction
child_saw_tx = Atomic{Bool}(false)

t = Task(() -> begin
  child_saw_tx[] = PormG.Configuration.get_tx_connection() !== nothing
end)

# Scheduling it inside a transaction does NOT make it transactional
PormG.run_in_transaction(settings) do
  schedule(t)
  wait(t)
end

@info "Task saw tx?" saw_tx=child_saw_tx[]  # expected: false
```

If you need a task to participate in a transaction, create and start it from inside `run_in_transaction` (e.g., with `@async`) or explicitly acquire and install the transaction connection with `with_tx_context` before running the work.

### Multiple Concurrent Tasks

You can spawn many tasks and let Julia's scheduler coordinate them:

```julia
PormG.run_in_transaction(settings) do
  # Create base records
  for i in 1:3
    (M.Race.objects).create(
      "year" => 2025,
      "round" => i,
      "name" => "Race $i",
      "circuitid" => i,
      "date" => Date(2025, i, 1),
    )
  end
  
  # Spawn workers that all share the transaction
  worker_count = 5
  @sync for worker in 1:worker_count
    @async begin
      for race_round in 1:3
        # All inserts use the same connection
        (M.Result.objects).create(
          "raceid" => 900 + race_round,
          "driverid" => worker,
          "constructorid" => 1,
          "points" => 25 - worker,
        )
      end
    end
  end
end
```

When the `@sync` block finishes, all tasks have completed and the transaction commits.

---

## Bulk Operations in Transactions

PormG provides `bulk_insert` and `bulk_update` for efficient batch operations. Always wrap them in a transaction to ensure all-or-nothing semantics.

### Transaction with deletion and bulk operations (example)

This example demonstrates a common pattern: delete matching rows, perform a bulk insert, and then run a bulk update — all inside a single transaction so either all changes persist or none do.

```julia
# Example: Delete matching rows, then perform bulk insert and bulk update inside a single transaction
# Setup: remove previous data and create seed records
delete(M.Just_a_test_deletion.objects, allow_delete_all = true)

# Pre-insert some records
q = M.Just_a_test_deletion.objects
for i in 1:10
  q.create("name" => "to-be-deleted-$(i)", "test_result" => 800 + i)
end

(M.Just_a_test_deletion.objects).create("name" => "test_update", "test_result" => 456)

q = M.Just_a_test_deletion.objects
q.filter("name" => "test_update")
df_u = q |> DataFrame
# Prepare the DataFrame used for bulk_update
df_u[1, :test_result2] = 457

# Perform delete + bulk-insert + bulk-update inside a single transaction
PormG.run_in_transaction(settings) do
  q = M.Just_a_test_deletion.objects
  q.filter("name__@icontains" => "to-be-deleted")
  df = q |> DataFrame
  delete(q)

  # Bulk insert
  bulk_data = [Dict("name" => "bulk-$(i)", "test_result" => 900 + i) for i in 1:5]
  df_bulk = DataFrame(bulk_data)
  q = M.Just_a_test_deletion.objects
  PormG.bulk_insert(q, df_bulk)

  # Bulk update (apply the single-row update prepared above)
  PormG.bulk_update(q, df_u)
end

# Inspect results (non-test checks)
q = M.Just_a_test_deletion.objects
println("Total rows after transaction: ", q.count())
println("Names: ", sort(q.list() .|> x -> x[:name]))
```

Note: This mirrors `test_transactions.jl` coverage — it demonstrates delete + bulk insert + bulk update inside one transaction and shows how a later rollback would revert all operations.

---

## Multithreaded Work

When mixing transactions with Julia's thread pool, `run_in_transaction` ensures all workers see the same connection, avoiding race conditions on the pool.

```julia
using Base.Threads: Atomic, atomic_add!

inserted_count = Atomic{Int}(0)

PormG.run_in_transaction("db_2") do
  @sync for i in 1:Threads.nthreads()
    @async begin
      for j in 1:100
        (M.Result.objects).create(
          "raceid" => 1000 + i,
          "driverid" => j,
          "constructorid" => 1,
          "points" => 10,
        )
        atomic_add!(inserted_count, 1)
      end
    end
  end
end

@test inserted_count[] == Threads.nthreads() * 100
```

All inserts happen on the same connection, and they either all commit or all roll back.

---

## Error Handling and Rollback

If any exception is raised inside the block, PormG automatically rolls back the transaction and rethrows. Use `try`/`catch` for cleanup:

```julia
using Logging

try
  PormG.run_in_transaction("db_2") do
    (M.Result.objects).create(
      "raceid" => 1,
      "driverid" => 1,
      "constructorid" => 1,
      "points" => 25,
    )
    
    # Simulate a validation error
    throw(ErrorException("Driver not found"))
  end
catch e
  @error "Transaction failed, rolling back" exception=e
  # Perform cleanup (e.g., release temporary resources)
end
```
**Generated SQL (PostgreSQL):**
```sql
BEGIN;

-- Insert attempted
INSERT INTO "result" ("raceid", "driverid", "constructorid", "points") 
VALUES (\$1, \$2, \$3, \$4) 
RETURNING *
-- Parameters: [1, 1, 1, 25]

-- Exception raised -> PormG intercepts and executes rollback
ROLLBACK;
```

```julia
# The record was never inserted because the transaction rolled back
q = M.Result.objects
q.filter("raceid" => 1)
@test q.count() == 0
```

### Nested Exception Handling

You can nest `try`/`catch` blocks and still maintain transaction semantics:

```julia
PormG.run_in_transaction("db_2") do
  (M.Result.objects).create("raceid" => 1, "driverid" => 1, ...)
  
  try
    (M.Result.objects).create("raceid" => 999, "driverid" => 999, ...)
    throw(ErrorException("Simulated error"))
  catch e
    @warn "Inner block failed, outer transaction will roll back" exception=e
  end
  
  # Even though we caught the error, it was already logged
  # The outer transaction will still roll back when this block exits
end
```

### Connection Loss During a Transaction

If the database connection drops mid-transaction (server restart, network failure, terminated
backend), PormG **never reconnects or re-runs statements within the transaction** — a retried
statement would execute on a fresh autocommit session, silently committing work that should have
died with the transaction. Instead, the connection error propagates out of the block like any
other exception: the transaction rolls back (or is already gone with the dead session) and the
pooled connection is renewed or discarded before returning to the pool, so the next borrower
always gets a clean connection.

Outside transactions, plain queries still recover transparently: the pooled connection is
renewed and the statement retried once.

If the work must survive connection loss, retry the **whole transaction** at the application
level — the standard contract across ORMs:

```julia
# Retry the whole unit of work, never a single statement
for attempt in 1:3
  try
    PormG.run_in_transaction("db_2") do
      (M.Pit_stops.objects).create(
        "raceid" => 841,
        "driverid" => 153,
        "stop" => 3,
        "lap" => 42,
        "time" => "17:05:23",
        "duration" => "22.500",
        "milliseconds" => 22500,
      )
      # ... more work sharing the same transaction
    end
    break   # committed
  catch e
    attempt == 3 && rethrow()
    @warn "Transaction failed; retrying" attempt exception=e
  end
end
```

---

## Lower-Level Helpers

If you need finer control (e.g., manual `SAVEPOINT` or multi-statement blocks), PormG exposes:

- **`with_tx_context(conn_pool, conn::LibPQ.Connection, block)`**: Install a connection in thread-local storage so child tasks inherit it.
- **`with_transaction(settings, sql, conn=nothing, release_conn=false)`**: Execute raw SQL inside a transaction context.
- **`get_tx_connection()`**: Check if a transaction context is active and return the connection.
- **`finalize_transaction_connection!(settings, conn; rollback_error=nothing)`**: Return `conn` to the pool exactly once from a terminal `finally`. Pass `rollback_error=nothing` when the COMMIT succeeded or the cleanup ROLLBACK ran cleanly; pass the caught error when the cleanup ROLLBACK itself threw, and a non-benign one causes the connection to be renewed or discarded instead of released.

### Example: Manual Savepoint

```julia
import PormG.Configuration: with_tx_context, get_tx_connection
import PormG.ConnectionPool: with_transaction, finalize_transaction_connection!

settings = PormG.Configuration.get_settings("db_2")
result, conn = with_transaction(settings, "BEGIN;")
# Return the connection to the pool exactly once, in a single terminal `finally`, so a failed
# COMMIT never hands it back before your cleanup ROLLBACK runs on it (#139).
rollback_error = nothing
try
  with_tx_context(settings.connections, conn) do
    # Insert first batch
    for i in 1:5
      (M.Result.objects).create("raceid" => i, "driverid" => 1, ...)
    end
    
    # Create savepoint
    with_transaction(settings, "SAVEPOINT sp1;", conn=conn)
    
    # Insert second batch
    for i in 6:10
      (M.Result.objects).create("raceid" => i, "driverid" => 2, ...)
    end
    
    # If this fails, we can roll back just the second batch
    if some_validation_error
      with_transaction(settings, "ROLLBACK TO sp1;", conn=conn)
    end
  end
  
  # Commit — release_conn=false: the finally owns the single release.
  with_transaction(settings, "COMMIT;", conn=conn, release_conn=false)
catch e
  # Roll back on the still-leased connection; capture a rollback failure so the finally
  # renews/discards the connection instead of releasing it, then rethrow the original error.
  try
    with_transaction(settings, "ROLLBACK;", conn=conn, release_conn=false)
  catch rollback_err
    rollback_error = rollback_err
  end
  rethrow(e)
finally
  finalize_transaction_connection!(settings, conn; rollback_error=rollback_error)
end
```

**Important:** When you hand-roll a `BEGIN`/`COMMIT`/`ROLLBACK` lifecycle, do the cleanup ROLLBACK on the *still-leased* connection and return it to the pool exactly once from a single `finally` via `finalize_transaction_connection!`, as above. Running `COMMIT`/`ROLLBACK` with `release_conn=true` releases the connection *even when the statement fails*, which can hand it back to the pool before your ROLLBACK runs on it — a use-after-release race (#139). Prefer `run_in_transaction`, which does all of this for you.

---

## Summary

| Pattern | Use Case |
|---------|----------|
| `run_in_transaction(settings) do ... end` | Most common; automatic commit/rollback |
| Async tasks inside transaction | Spawn concurrent workers that share the connection |
| Bulk operations inside transaction | Ensure all-or-nothing for large batch inserts/updates |
| Manual `with_tx_context` + `with_transaction` | Fine-grained control; savepoints; multi-statement workflows |

Start with `run_in_transaction` for all your database work. Drop to the lower-level helpers only when you need explicit savepoints or multi-database coordination.

