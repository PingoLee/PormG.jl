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
- [Nested Transactions and Savepoints](#Nested-Transactions-and-Savepoints)
- [Row-Level Locking](#Row-Level-Locking)
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

Note that inherited context means every child task shares the transaction's **single pinned connection**, so their statements serialize — this propagation is about *correctness* (all work joins the same transaction), not throughput. For concurrent throughput, fan out whole transactions instead; see [Async & Concurrency — Transactions and concurrency](../async.md#Transactions-and-concurrency).

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

    # A constraint violation on the next write aborts the whole block
    (M.Result.objects).create("raceid" => 999_999, "driverid" => 1, "constructorid" => 1)
  end
catch e
  e isa PormGError || rethrow()
  @error "Transaction failed, rolled back" msg=error_message(e) type=typeof(e)
  # Perform cleanup (e.g., release temporary resources)
end
```

Two things worth separating here:

- **PormG's own failures are typed.** The example above raises [`IntegrityError`](../errors.md)
  (the FK does not exist); a filterless `update` would raise `UnsafeMutationError`, and a
  connection with `change_data: false` raises `WritesDisabledError`. Catch `PormGError` to handle
  any of them, or a specific subtype to react to one.
- **Your own exceptions propagate as themselves.** Raising `ErrorException("Driver not found")`
  inside the block still rolls the transaction back — PormG rolls back on *any* throw — but it
  reaches your `catch` as an `ErrorException`, not wrapped. Only driver failures are wrapped into
  the taxonomy.

**Generated SQL (PostgreSQL):**
```sql
BEGIN;

-- First insert succeeds
INSERT INTO "result" ("raceid", "driverid", "constructorid", "points") 
VALUES (\$1, \$2, \$3, \$4) 
RETURNING *
-- Parameters: [1, 1, 1, 25]

-- Second insert violates the raceid foreign key -> IntegrityError
-- Exception raised -> PormG intercepts and executes rollback
ROLLBACK;
```

```julia
# Neither record was inserted because the transaction rolled back
q = M.Result.objects
q.filter("raceid" => 1)
@test q.count() == 0
```

### Nested Exception Handling

!!! warning "Catching an exception inside the block cancels the rollback"
    PormG rolls back when an exception **escapes** the `run_in_transaction` block — the rollback
    lives in that function's `catch`. If an inner `try`/`catch` swallows the error, the block
    returns normally and the transaction **commits**, including the writes that came before the
    failure. To log an inner failure *and* still abort, `rethrow()` after logging, or use a
    savepoint (see [Nested Transactions and Savepoints](#Nested-Transactions-and-Savepoints)) to
    roll back just the inner step.

```julia
PormG.run_in_transaction("db_2") do
  (M.Result.objects).create("raceid" => 1, "driverid" => 1, ...)

  try
    (M.Result.objects).create("raceid" => 999_999, "driverid" => 1, ...)
  catch e
    e isa PormGError || rethrow()
    @warn "Inner write failed, aborting the transaction" msg=error_message(e)
    rethrow()          # ← without this, the outer block COMMITS the first insert
  end
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

The connection failure reaches your `catch` as an [`OperationalError`](../errors.md) — a
`DatabaseError` for a condition that is transient rather than a defect in the statement. Retry the
**whole transaction**, never the individual statement:

```julia
try
    PormG.run_in_transaction("db_2") do
        (M.Result.objects).filter("resultid" => 1).update("points" => 25)
    end
catch e
    e isa OperationalError || rethrow()
    @warn "Connection lost mid-transaction; the whole block must be retried" msg=error_message(e)
end
```

Outside transactions, plain queries still recover transparently: the pooled connection is
renewed and the statement retried once.

### Misusing the transaction API

[`TransactionError`](../errors.md) is raised *before* anything is sent, for two call patterns that
cannot work:

- `atomic(durable = true)` nested inside an already-open transaction — it must be outermost.
- Touching a model bound to one connection while a transaction is open on another. Open the
  transaction on that model's own connection instead: `run_in_transaction("<its connect_key>")`.

It is deliberately **not** a `DatabaseError` — the database was never involved.

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

## Nested Transactions and Savepoints

`run_in_transaction` and its friendly alias **`atomic`** are **reentrant**. Calling `atomic` again
*inside* an already-open transaction on the **same** database does not open a second, independent
transaction — it creates a **savepoint** on the same connection. If the nested block throws, only its
savepoint is rolled back; the outer transaction stays alive and usable (catch the error *outside* the
nested block to keep going). This mirrors Django's `atomic()`. `atomic(db)` and `run_in_transaction(db)`
are interchangeable — `atomic` just reads better when you nest.

```julia
# Import a batch of race results; one malformed result must not abort the whole import.
atomic("db_2") do
  for row in incoming_results
    try
      atomic("db_2") do                          # nested → SAVEPOINT
        M.Result.objects.create(
          "raceid"        => row.raceid,
          "driverid"      => row.driverid,
          "positionorder" => row.position,
          "points"        => row.points,
        )
      end
    catch e
      # Only this result rolled back to its savepoint; the outer import transaction continues.
      @warn "Skipping malformed result" raceid = row.raceid exception = e
    end
  end
end   # every result that didn't roll back commits together
```

Semantics:

- The **outermost** `atomic` opens the real transaction (`BEGIN`); each **nested** `atomic` on the same
  database opens a savepoint (`SAVEPOINT pormg_sp_<depth>`).
- A nested block that returns normally **releases** its savepoint — its work stays part of the outer
  transaction and is undone only if the **outer** transaction later rolls back.
- A nested block that throws **rolls back to** its savepoint and re-raises, leaving the outer
  transaction unaffected until the exception reaches it.
- A nested `atomic` targeting a **different** database opens its own independent transaction.

Savepoints behave **identically on PostgreSQL and SQLite** — both support `SAVEPOINT` /
`RELEASE SAVEPOINT` / `ROLLBACK TO SAVEPOINT` natively.

Pass `durable = true` to assert a block is the outermost transaction; it raises if one is already active:

```julia
atomic("db_2"; durable = true) do
  # guaranteed to be a real, top-level transaction — never a nested savepoint
end
```

---

## Row-Level Locking

`select_for_update()` appends a `FOR UPDATE` clause so a read **locks** the selected rows until the
surrounding transaction commits or rolls back — the standard guard for a safe read-modify-write.

```julia
# Read-modify-write a constructor's running points total without a lost update.
atomic("db_2") do
  standing = M.Constructor_standings.objects.
    filter("constructorid" => 131, "raceid" => 1120).
    select_for_update().                       # locks the matched rows until COMMIT
    list() |> first

  M.Constructor_standings.objects.
    filter("constructorstandingsid" => standing[:constructorstandingsid]).
    update("points" => standing[:points] + 25)
end
```

Options (PostgreSQL):

| Call | SQL | Meaning |
|------|-----|---------|
| `select_for_update()` | `FOR UPDATE` | Wait for conflicting locks to clear, then lock. |
| `select_for_update(skip_locked = true)` | `FOR UPDATE SKIP LOCKED` | Skip rows another transaction already holds (claim-next-available pattern). |
| `select_for_update(nowait = true)` | `FOR UPDATE NOWAIT` | Raise immediately if a matched row is already locked. |
| `select_for_update(no_key = true)` | `FOR NO KEY UPDATE` | Weaker lock that still allows FK-referencing inserts. |

`nowait` and `skip_locked` are mutually exclusive. On PostgreSQL a locked read **must run inside a
transaction** — calling it under autocommit raises, because the lock would be released immediately.

```julia
# Process pit stops for a race, one worker at a time, skipping rows another worker already holds.
atomic("db_2") do
  next_stop = M.Pit_stops.objects.
    filter("raceid" => 1120).
    order_by("stop").
    select_for_update(skip_locked = true).
    list() |> first
  # … process next_stop …
end
```

!!! warning "Row locking on SQLite"
    SQLite has no `SELECT ... FOR UPDATE`. On SQLite, `select_for_update()` is a **silent no-op** — no
    lock clause is emitted and no error is raised, so identical query code runs on both backends (this
    matches Django, SQLAlchemy, and Rails). SQLite already serializes writers per database file via
    `BEGIN IMMEDIATE` (see [Multithreaded Work](#Multithreaded-Work)); if you need explicit
    write-serialization there, rely on the transaction itself rather than a row lock. An `OF <table>`
    target is not yet supported on either backend (a planned follow-up).

---

## Lower-Level Helpers

If you need finer control (e.g., manual `SAVEPOINT` or multi-statement blocks), PormG exposes:

- **`with_tx_context(conn_pool, conn::LibPQ.Connection, block)`**: Install a connection in thread-local storage so child tasks inherit it.
- **`with_transaction(settings, sql, conn=nothing, release_conn=false)`**: Execute raw SQL inside a transaction context.
- **`get_tx_connection()`**: Check if a transaction context is active and return the connection.
- **`finalize_transaction_connection!(settings, conn; rollback_error=nothing)`**: Return `conn` to the pool exactly once from a terminal `finally`. Pass `rollback_error=nothing` when the COMMIT succeeded or the cleanup ROLLBACK ran cleanly; pass the caught error when the cleanup ROLLBACK itself threw, and a non-benign one causes the connection to be renewed or discarded instead of released.
- **`acquire_connection(pool; timeout_seconds=nothing)`** / **`release_connection(pool, conn)`**: Lease a connection and give it back. Every acquire must be paired with a release, from a `finally`. `with_transaction` does this for you when you pass `conn=nothing`. Neither is exported — call them qualified, as below.

!!! warning "SQLite: acquire writes with `mode = :write`"
    SQLite allows only one writer, so a PormG SQLite pool splits its slots into readers plus a
    single **writer slot**. The SQLite method of `acquire_connection` therefore takes an extra
    `mode` keyword — `:read`, `:write`, or `:any` (the default). Acquire with `:read` or `:any`
    and you can be handed a read-only connection on which a write fails.

    ```julia
    import PormG.ConnectionPool: acquire_connection, release_connection

    settings = PormG.Configuration.get_settings("db_sl")
    pool = settings.connections

    conn = acquire_connection(pool; mode = :write)   # SQLite: required before writing
    try
        # … use conn …
    finally
        release_connection(pool, conn)               # exactly once, from a finally
    end
    ```

    **`mode` is SQLite-only — it is not a keyword the PostgreSQL method accepts**, so passing it
    to a PostgreSQL pool is a `MethodError`, not a no-op. Backend-portable code must branch on
    the pool type, which is what PormG's own internals do:

    ```julia
    conn = pool isa PormG.PormGSQLite ? acquire_connection(pool; mode = :write) :
                                        acquire_connection(pool)
    ```

    This applies **only** to manual checkout — `run_in_transaction`, `atomic` and
    `with_transaction(conn = nothing)` already request the writer slot on your behalf.

    If you are driving a `BEGIN`/`COMMIT`/`ROLLBACK` lifecycle rather than a single statement,
    do **not** end it with `release_connection`: a failed cleanup `ROLLBACK` can leave the
    connection holding an open transaction. Terminate with `finalize_transaction_connection!`
    instead, exactly as the example below does.

### Example: Manual Savepoint

!!! tip "Prefer nested `atomic` for savepoints"
    For savepoints, reach for nested [`atomic`](#Nested-Transactions-and-Savepoints) — it manages the
    `SAVEPOINT` / `RELEASE` / `ROLLBACK TO` lifecycle and naming for you, on both backends. The
    hand-rolled version below is shown only to illustrate the underlying mechanics.

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
| `run_in_transaction(settings) do ... end` / `atomic(settings) do ... end` | Most common; automatic commit/rollback |
| Nested `atomic` on the same database | Automatic savepoint; roll back part of the work without aborting the whole transaction |
| `select_for_update()` | Lock rows for a safe read-modify-write (PostgreSQL; no-op on SQLite) |
| Async tasks inside transaction | Spawn concurrent workers that share the connection |
| Bulk operations inside transaction | Ensure all-or-nothing for large batch inserts/updates |
| Manual `with_tx_context` + `with_transaction` | Fine-grained control; hand-rolled multi-statement workflows |

Start with `run_in_transaction`/`atomic` for all your database work. Nest `atomic` for savepoints. Drop to the lower-level helpers only for hand-rolled multi-statement workflows or multi-database coordination.

