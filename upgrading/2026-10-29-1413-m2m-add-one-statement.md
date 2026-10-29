## Many-to-many `add`: one statement per add on PostgreSQL, per group of 2048 targets on MySQL (#1413)

- **Version**: Unreleased
- **PormG ref**: #1413 ; `src/querybuilder/many_to_many.jl` (`_m2m_add!`, `_m2m_distinct_ids`)
- **Recorded**: 2026-10-29
- **Severity**: behavior change, narrow. On MySQL, an `add` whose error you catch inside your own transaction keeps fewer targets. On PostgreSQL, the targets are bound as an array of the related key's declared type. On MySQL, two targets that only a case-insensitive collation equates (a text key on a table PormG did not create) are now both inserted. Otherwise the same rows are linked and the same errors are raised.

### What changed

`add(manager, targets...)` sent one `INSERT … SELECT … WHERE NOT EXISTS (…)` per target on PostgreSQL
and MySQL, all in one transaction (#1399). It now sends:

- **On PostgreSQL**, one statement for every target. The targets are bound as one array, typed like the
  related primary key: `INSERT … SELECT $1, "u"."x" FROM unnest($2::bigint[]) AS "u"("x") WHERE NOT EXISTS (…)`.
- **On MySQL**, one `INSERT … SELECT … FROM (VALUES ROW(?, ?), …) … WHERE NOT EXISTS (…)` per group of
  2048 targets, which fills MySQL.jl's 4096-parameter limit. The groups run in one transaction.

A target given twice in one call is linked once, as before, both with and without a unique key on
the through table. Two targets are the same when PormG binds the same value for them: an integer key's
integer text is bound as its integer, so `5` and `"5"` are one target, and a UUID is compared
lower-cased. A text key that only the database's collation equates (a case-insensitive MySQL collation
on a table PormG did not create) is two targets, and one statement inserts both: link those in separate
calls.

**On PostgreSQL** the targets are bound as an array of the related key's declared type, where each
used to take the through column's type. A declaration whose type does not compare with the column
(a `uuid` column declared as a `CharField`) now fails with PostgreSQL's "operator does not exist"
error, as `bulk_insert` does for that model. Declare the key with the column's type.

**What a caller can see** is on MySQL, inside a transaction you opened, when you catch the `add`'s
error and keep going. Before, the targets ahead of the failing one stayed written. Now nothing from
the failing statement is written: no target at all, unless the `add` was split into groups, in which
case the earlier groups stay. On PostgreSQL the foreign keys PormG creates are checked at `COMMIT`, so
nothing changes there.

| on MySQL, inside `atomic`, error caught | before | now |
|---|---|---|
| `add(a, b, ghost)` where `ghost` has no row | `a` and `b` linked | nothing linked |
| `add(<2048 ids>..., ghost)` | the 2048 linked | the 2048 linked (first group) |

### Who this affects

- MySQL code that calls `add` inside `atomic`, catches its error inside the block, and then relies on
  the targets before the failing one being linked.
- PostgreSQL models whose related key is declared with a type the through table's column does not
  compare with.

### How to find the calls to migrate

```
grep -rnE '\.add\(|\badd\(' --include='*.jl' .   # then look for a `catch` around each call inside `atomic`
```

### Migrate your app

Add the targets you want kept in their own call, before the one that may fail:

```julia
# ✗ before: relied on a and b staying linked when ghost fails
PormG.atomic("db") do
    try
        driver.sponsors.add(a, b, ghost)
    catch e
        e isa PormG.IntegrityError || rethrow()
    end
end

# ✓ after: link what must stay first
PormG.atomic("db") do
    driver.sponsors.add(a, b)
    try
        driver.sponsors.add(ghost)
    catch e
        e isa PormG.IntegrityError || rethrow()
    end
end
```
