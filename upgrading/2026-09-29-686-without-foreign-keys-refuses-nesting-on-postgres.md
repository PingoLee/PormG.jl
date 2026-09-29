## `without_foreign_keys` — refuses to nest inside a transaction on PostgreSQL too (#686)

- **Version**: Unreleased
- **Recorded**: 2026-09-29
- **PormG ref**: #686; `src/ConnectionPool.jl` (`without_foreign_keys`, `_refuse_nested_without_foreign_keys`)
- **Severity**: behavior change — a `without_foreign_keys` block opened inside `atomic` /
  `run_in_transaction` on the same database now raises `TransactionError` on PostgreSQL, as it
  already did on SQLite

### What changed

The docstring always said the block must be the outermost transaction on its pool, but only the
SQLite method enforced it. On PostgreSQL a nested block became a `SAVEPOINT` and ran. That meant
code that passed on PostgreSQL threw on SQLite, so only a SQLite test run could catch it.

The PostgreSQL method now refuses too, before it touches the database. For the foreign keys PormG
creates, nesting bought nothing: inside a transaction they are already deferred to `COMMIT`. And
the `SET CONSTRAINTS ALL DEFERRED` it issued was not limited to the block. It persisted after the
savepoint was released, for the rest of the enclosing transaction.

A top-level `without_foreign_keys` is unchanged on both engines. So is a nested one on a
*different* database than the enclosing transaction.

### How to find the calls to migrate

A nested call fails loudly with this message, so a PostgreSQL test run finds every one:

```
without_foreign_keys must be the outermost transaction on this pool
```

To find them before running anything, list every call and check whether an `atomic` /
`run_in_transaction` on the same database encloses it, directly or further up the call stack:

```bash
grep -rn 'without_foreign_keys' --include=*.jl .
```

### Migrate your app

Usually the inner block is not needed at all. Inside `atomic`, children written before their
parents already commit, because the check on a foreign key PormG created waits for `COMMIT`:

```julia
# ✗ before — ran on PostgreSQL, TransactionError on SQLite
atomic("db") do
    without_foreign_keys("db") do
        bulk_insert(M.Result, results_df)   # children
        bulk_insert(M.Race,   races_df)     # parents
    end
end

# ✓ after — the enclosing transaction already defers the check
atomic("db") do
    bulk_insert(M.Result, results_df)
    bulk_insert(M.Race,   races_df)
end
```

If the block really needs enforcement suspended (a SQLite repair or a planted violation), make it
the outermost block: `without_foreign_keys("db") do … end` with no `atomic` around it. Do the same
on PostgreSQL if the tables carry foreign keys PormG did not create (an introspected legacy schema)
declared `DEFERRABLE INITIALLY IMMEDIATE`. Those are checked per statement even inside `atomic`, and a
top-level `without_foreign_keys` still defers them.
