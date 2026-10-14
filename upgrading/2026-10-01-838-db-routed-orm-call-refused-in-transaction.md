## `.db()` and the transaction-scope check — an ORM call is checked against the database it runs on (#838, #831)

- **Version**: 0.8.0
- **PormG ref**: #838, #831; `src/Configuration.jl` (`ensure_transaction_scope`), its call sites in
  `src/querybuilder/` (`build`, `insert`, `update`, `delete`, `get_or_create`, `update_or_create`,
  the bulk writers, `allocate_primary_keys`, `resync_sequences`)
- **Recorded**: 2026-10-01
- **Severity**: behavior change, on both engines

### What changed

While a transaction is open, PormG refuses an ORM call that would run outside it. That check used to
compare the **model's binding** (`connect_key`) with the **innermost** transaction block, while the
call itself ran on the database `.db("<key>")` routes it to. Two things followed. A `.db()` call to
a database with no open transaction passed the check and ran in autocommit there, outside the
rollback the caller relied on. And a call that really was inside an open transaction was refused.

Now the check uses the database the call **runs** on, and it looks through enclosing blocks. The
rule is: while a transaction is open, an ORM call must run on a database that has an open
transaction, in this block or an enclosing one. Otherwise it raises `TransactionError` before
anything is sent. `allocate_primary_keys` and the many-to-many manager's `add`/`remove`/`clear`/`set`,
which had no check at all, follow the same rule.

| Inside `atomic("db_a")` | before | after |
|---|---|---|
| a model bound to `db_a`, routed `.db("db_b")`, no transaction open on `db_b` | ran on `db_a`'s transaction connection — against `db_a`'s database, inside its transaction (#831 below) | `TransactionError` |
| `allocate_primary_keys` on a database with no open transaction | ran its own transaction there | `TransactionError` |
| a many-to-many manager (`add`/`remove`/`clear`/`set`) whose owner is on a database with no open transaction | ran in autocommit there | `TransactionError` |
| `show_query = :sql` / `inspect_query` of a `.db("db_b")` query, no transaction open on `db_b` | rendered | `TransactionError`, as rendering a model *bound* to `db_b` already did |
| a model bound to `db_b`, routed `.db("db_a")` | `TransactionError` | runs in `db_a`'s transaction |
| inside a nested `atomic("db_b")`, a model bound to `db_a` | `TransactionError` | runs in `db_a`'s transaction |

**Same release (#831): a statement runs on the pool it names.** The open transaction's connection
used to serve every statement sent while it was open, whatever pool the call named. Now the
transaction belongs to its own pool:

| Inside `run_in_transaction(pool_a)` / `atomic("db_a")` | before | after |
|---|---|---|
| raw `fetch(pool_b, sql)` (or `fetch_copy`) | ran on `pool_a`'s connection: `db_a`'s database, inside its transaction | runs on `pool_b`, in autocommit; not refused |
| `atomic(a) do; atomic(b) do; atomic(a) …` | PostgreSQL: the inner `atomic(a)` opened a second, independent transaction on `db_a`, committed on its own; SQLite: it waited on the outer block's write lock until `database is locked` / `PoolTimeoutError` | a `SAVEPOINT` in the outer `db_a` transaction |
| `atomic(b; durable = true)` | `TransactionError` (a transaction was open, on another pool) | allowed: only a transaction on the same pool counts |
| SQLite: `atomic(b) do; atomic(c) do; without_foreign_keys(b) …` — a block on the same pool, another pool in between | passed the check (only the innermost block was asked), then waited on the write lock until `database is locked` / `PoolTimeoutError` | `TransactionError` at once |

### How to find the calls to migrate

Only the first four rows of the first table, and the first two rows of the #831 table, can break a
working app. Look for `.db(`, `allocate_primary_keys` and
many-to-many manager calls made while a transaction block is open, including from a function that
block calls:

```bash
grep -rnE '\.db\(|allocate_primary_keys|\.(add|remove|clear|set)\(' src/
grep -rnE '\b(atomic|run_in_transaction|without_foreign_keys)\(' src/
```

In logs, the error is a `TransactionError` whose message reads `Active transaction on connection …
cannot include model … on connection …, which has no transaction open`.

### Migrate your app

```julia
# ✗ before: the db_b write ran in autocommit, silently outside db_a's transaction
atomic("db_a") do
    M.Driver.objects.filter("driverid" => 1).update("code" => "HAM")
    M.Driver.objects.db("db_b").filter("driverid" => 1).update("code" => "HAM")
end

# ✓ after: give the db_b write a transaction of its own. It still commits separately (when its
#   block ends, so a later db_a rollback does not undo it), but the code now says so
atomic("db_a") do
    M.Driver.objects.filter("driverid" => 1).update("code" => "HAM")
    atomic("db_b") do
        M.Driver.objects.db("db_b").filter("driverid" => 1).update("code" => "HAM")
    end
end

# ✓ or, if it never belonged to db_a's unit of work, move it outside the block
atomic("db_a") do
    M.Driver.objects.filter("driverid" => 1).update("code" => "HAM")
end
M.Driver.objects.db("db_b").filter("driverid" => 1).update("code" => "HAM")
```
