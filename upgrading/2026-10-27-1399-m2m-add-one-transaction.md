## A many-to-many `add` that fails links none of its targets on PostgreSQL and MySQL (#1399)

- **Version**: Unreleased
- **PormG ref**: #1399 ; `src/querybuilder/many_to_many.jl` (`_m2m_add!`, `_m2m_in_one_transaction`)
- **Recorded**: 2026-10-27
- **Severity**: behavior change. On PostgreSQL and MySQL, an `add` of several targets outside a transaction used to write each link in its own statement, committed on its own, so a target that failed raised and left the links before it written. It now raises and leaves none of them.

### What changed

The statements of an `add` of several targets run in one transaction, or in the caller's when one is
open, as SQLite's `add` and every engine's `remove` and `set` already did (#1355). An `add` of one
target is one statement, as before. Django's `ManyRelatedManager.add` runs in one transaction too.

| call, outside a transaction | before | now |
|---|---|---|
| `driver.sponsors.add(sponsor_a, sponsor_b, 99_999_999)` (no sponsor has that id), PostgreSQL or MySQL | raises; `sponsor_a` and `sponsor_b` linked | raises; nothing linked |
| the same, SQLite | raises; nothing linked | unchanged |
| the same inside `atomic(...)`, every engine | the block rolls back | unchanged |
| `driver.sponsors.add(sponsor_a, sponsor_b)` | both linked | unchanged |

On PostgreSQL, where the foreign keys PormG creates are checked at `COMMIT`, the failure is now
reported when the `add`'s transaction commits rather than at the failing target's statement; it is an
`IntegrityError` before and after. The links an `add` writes, and on MySQL the ranges its
`NOT EXISTS` reads, stay locked until it finishes, so two `add`s at once on the same owner can wait on
each other, or deadlock, where each statement used to release its locks when it committed.

Inside your own `atomic` block nothing changes: the `add` opens no savepoint there, so an error you
catch inside the block (on MySQL, which checks each statement) keeps the targets written before the
failing one, as before.

### Who this affects

Code that catches an error from a many-to-many manager's `add` of several targets and relies on the
targets before the failing one being linked.

### How to find the calls to migrate

```bash
grep -rnE '\badd\(' --include=*.jl src/ test/
```

For each match on a many-to-many manager (`driver.sponsors.add(…)`, or `add(manager, …)`) inside a
`try`, check whether the `catch` reads the links.

### Migrate your app

```julia
# ✗ before — the sponsors before the failing one stayed linked
try
    driver.sponsors.add(sponsor_ids...)
catch e
    e isa PormGError || rethrow()
end

# ✓ after — add the targets one at a time to keep each one that succeeds
for sponsor_id in sponsor_ids
    try
        driver.sponsors.add(sponsor_id)
    catch e
        e isa PormGError || rethrow()
    end
end
```
