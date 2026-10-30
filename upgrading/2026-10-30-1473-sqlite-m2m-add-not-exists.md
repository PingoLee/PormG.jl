## Many-to-many `add` on SQLite links a target once without a unique key on the through table (#1473)

- **Version**: Unreleased
- **PormG ref**: #1473 ; `src/querybuilder/many_to_many.jl` (`_m2m_add!(::PormGSQLite, …)`)
- **Recorded**: 2026-10-30
- **Severity**: behavior change, SQLite only. On an explicit through model with no unique key over its two keys, a target linked already or given twice is now linked once, where it got a second row. A pair the through table rejects (a target with no key, a `CHECK`, two spellings of one key in one call on a table with a unique key) now raises `IntegrityError` and links none of the call's targets, where the pair was skipped without a word and the rest were linked.

### What changed

On SQLite, `add(manager, targets...)` was `INSERT OR IGNORE INTO <through> (o, r) VALUES (?, ?), …`.
`OR IGNORE` skips a row only when it breaks a constraint, so it linked once on the through table PormG
generates, which has a unique key over the two columns, but not on an explicit through model without
one. There, `add(team)` twice, or `add(team, team)`, wrote two rows.

It is now the statement PostgreSQL and MySQL already send: a pair already linked is skipped by
`NOT EXISTS`, and a target given twice in one call is bound once (#1413), with or without a unique key:

```sql
WITH "v"("o", "r") AS (VALUES (?, ?), …)
INSERT INTO <through> (o, r) SELECT "v"."o", "v"."r" FROM "v"
WHERE NOT EXISTS (SELECT 1 FROM <through> AS "e" WHERE "e".o = "v"."o" AND "e".r = "v"."r");
```

`OR IGNORE` also skipped a pair that failed a `NOT NULL`, `CHECK` or `UNIQUE` constraint of the
through table, on every through table, and linked the call's other targets. (A foreign key is not one
it skips: a target with no row raised before, and still does, #1399.) Without it the statement fails,
so the call raises `IntegrityError` and links none of its targets. A split `add` whose error you catch
inside your own `atomic` keeps the groups written before the failing one (#1413). The pairs a through
table rejects:

- a target without a key (`nothing`), which binds NULL into the `NOT NULL` foreign key; PostgreSQL
  raises `IntegrityError` here too;
- a pair a `CheckConstraint` of an explicit through model rejects, as on PostgreSQL;
- two spellings of one integer key in one call that PormG does not bind as one target, such as `5` and
  `"5.0"`. Integer text (`"5"`) is bound as its integer and is one target with `5` (#1413); `"5.0"`
  stays text. The column stores both as `5`, so on a through table with a unique key the second fails
  it, and on an explicit through model without one both are linked, as two rows. A `"5.0"` given after
  `5` was linked by an earlier call compares equal to it and is skipped. PostgreSQL refuses `"5.0"` as
  text that is not a `bigint`, with a different error.

| on SQLite | before | now |
|---|---|---|
| `driver.teams.add(ferrari)` twice, explicit through model without a unique key | two link rows | one link row |
| `driver.teams.add(ferrari, ferrari)`, explicit through model without a unique key | two link rows | one link row |
| `driver.sponsors.add(petrolux, nothing)` | `petrolux` linked, no error | `IntegrityError`, nothing linked |
| `add(valid, rejected)` where a `CheckConstraint` of the through model rejects `rejected` | `valid` linked, no error | `IntegrityError`, nothing linked |

Rows a repeated `add` wrote before this change stay in the through table. The manager's `all()` never
showed them twice (it is a semi-join), and `remove` and `clear` delete every row of a pair; a query on
the through model itself still counts them.

### Who this affects

- SQLite apps whose `ManyToManyField` names an explicit `through=` model without a `UniqueConstraint`
  over its two keys, and which count or read the through model's own rows.
- Any SQLite app whose `add` passes a target the through table rejects — `nothing`, a pair a
  `CheckConstraint` rejects, or `"5.0"` beside `5` in one call — and relied on the rest being linked without an
  error.

### How to find the calls to migrate

```bash
grep -rnE 'ManyToManyField\([^)]*through *=' --include='*.jl' .   # then check each through model's constraints
```

### Migrate your app

Nothing to change for the repeated `add`: it now gives the rows you meant. Where some targets may be
rejected, leave them out before the `add`:

```julia
# ✗ before: relied on SQLite skipping a missing sponsor and a pair the CHECK rejects
driver.teammates.add(teammates...)

# ✓ after: leave out the targets the through table rejects
driver.teammates.add(filter(t -> t !== nothing && t[:driverid] != driver[:driverid], teammates)...)
```
