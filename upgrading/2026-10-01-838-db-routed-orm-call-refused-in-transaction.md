## `.db()` and the transaction-scope check — an ORM call is checked against the database it runs on (#838)

- **Version**: Unreleased
- **PormG ref**: #838; `src/Configuration.jl` (`ensure_transaction_scope`), its call sites in
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
| a model bound to `db_a`, routed `.db("db_b")`, no transaction open on `db_b` | ran in autocommit on `db_b` | `TransactionError` |
| `allocate_primary_keys` on a database with no open transaction | ran its own transaction there | `TransactionError` |
| a many-to-many manager (`add`/`remove`/`clear`/`set`) whose owner is on a database with no open transaction | ran in autocommit there | `TransactionError` |
| `show_query = :sql` / `inspect_query` of a `.db("db_b")` query, no transaction open on `db_b` | rendered | `TransactionError`, as rendering a model *bound* to `db_b` already did |
| a model bound to `db_b`, routed `.db("db_a")` | `TransactionError` | runs in `db_a`'s transaction |
| inside a nested `atomic("db_b")`, a model bound to `db_a` | `TransactionError` | runs in `db_a`'s transaction |

Raw `fetch(pool, sql)` is unchanged: on a database with no open transaction it still runs in
autocommit, as it has since #831.

### How to find the calls to migrate

Only the first four rows can break a working app. Look for `.db(`, `allocate_primary_keys` and
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
