## `delete()` that cascades reads the root's keys first, so it deletes the rows its filter matched (#1342, #1370)

- **Version**: Unreleased
- **PormG ref**: #1342, #1370 ; `src/querybuilder/deletion.jl` (`_root_key_plan`, `_resolve_root_keys!`, `_root_key_chunks`)
- **Recorded**: 2026-10-26 (amended for #1370 the same day)
- **Severity**: bug fix that changes a value. A cascading `delete()` now deletes exactly the rows its filter matched and returns counts that say so. With a filter that reads another table it used to delete some or all of the children and keep the root (#1342); with a filter on the root's own columns, when a `SET_NULL` / `SET_DEFAULT` statement wrote the root's table, it deleted rows it should only have updated (#1370). No error either way. The `show_query` / `inspect_query` output of every filtered cascading delete gains a key read, and loses the `FOR SHARE` lock steps.

### What changed

The deletion collector deletes children first and the root last, and every statement re-read the
root's filter. Two shapes made the statements after the first see a different set, on every engine:

- **A filter that reads another table** (a reverse relation, an `Exists` or a subquery over a child).
  The root's own `DELETE` matched nothing once the rows it read were gone, and so did any cascade
  path that ran after them. The same happened when a `SET_NULL` / `SET_DEFAULT` child re-pointed the
  rows the filter read (#1342).
- **A filter on the root's own columns, when a `SET_NULL` / `SET_DEFAULT` statement writes the
  root's table.** Every such update runs before any `DELETE`, so the root's `DELETE` matched the rows
  the update had just re-pointed (#1370). The collector refuses the statement as a dependency cycle
  when it targets the root's own model (a self-referencing key), so the shape that reached it is a
  second model mapped to the same table that declares the foreign key the root model does not.

Now, whenever the root has something to cascade to, `delete()` reads the root's primary keys once,
before it writes anything, and scopes every statement by them. Measured on the F1 fixture (SQLite):

| `M.Race.objects.filter("year" => 2009, "result__grid" => 1).delete()` | before | now |
|---|---|---|
| `"race"` | 0 (the 17 races stay) | 17 |
| `"driver_standings"` | 0 | 364 |
| `"result"`, `"lap_times"`, `"qualifying"` | 340, 17186, 340 | the same |
| total | 18205 | 18586 |

And on the #1370 shape: teams whose favourite driver is an integer on the team model, declared as a
`SET_NULL` foreign key on an unmanaged second model over the same table, with drivers that `CASCADE`
from their team. Tyrrell has no favourite driver, and McLaren's is Stewart, a Tyrrell driver:

| `filter("favourite_driver__@isnull" => true).delete()` | before | now |
|---|---|---|
| teams deleted | 2 (Tyrrell and McLaren) | 1 (Tyrrell; McLaren's favourite is nulled) |
| drivers deleted | 2 (Stewart and Senna) | 1 (Stewart) |

The inspection output of every filtered delete whose root has a `CASCADE`, `SET_NULL` or
`SET_DEFAULT` dependent:

- **The first step is the key read**: `SELECT "Tb"."<pk>" FROM <root> AS "Tb" WHERE <filter>`. It is
  `:operation => :lock` with `FOR UPDATE` on PostgreSQL and MySQL, where it replaces the root's
  `SELECT count(*) … FOR UPDATE` lock, and `:select` on SQLite.
- **Every later statement is scoped by the keys** (`"Tb"."<pk>" = ANY($1)` on PostgreSQL, one `?` per
  key elsewhere). None of them renders the filter again, the root's own `DELETE` included.
- **The `FOR SHARE` lock on each table a joined filter reads (#771) is gone.** It pinned what every
  statement re-read, and nothing re-reads it now.
- **On SQLite and MySQL a large key set runs the cascade in chunks** (2047 keys on SQLite, 256 on
  MySQL), so the inspection shows one set of statements per chunk.
- **On a mock pool** (no database), the key read returns no keys, so the statements after it render
  over the empty set (`(1 = 0)` on SQLite, an empty array on PostgreSQL).

The key read is decided from the schema (the root has a `CASCADE`, `SET_NULL` or `SET_DEFAULT`
dependent), not from the rows: a delete of a root whose dependents have no rows, which used to be one
`DELETE`, is now the key read and the `DELETE`. Its counts do not change. Measured on the F1 fixture,
rolled back, median of seven: on PostgreSQL the statement count is the same where the cascade has rows
(the key read replaces the root's lock) and the time is within noise; on SQLite it is one more
`SELECT`, 15 ms on a 612 ms delete of 430 races.

A root with no such dependent, and an unfiltered delete (`allow_delete_all = true`), keep the
statements and the counts they had.

### Who this affects

Code that calls `delete()` with a filter on a model with `CASCADE`, `SET_NULL` or `SET_DEFAULT`
dependents. Its counts change when the filter crosses a relation (any `__` path or `cjoin`) or holds a
query (`"x__@in" => M.Other.objects…`, `Subquery`, `Exists`), or when a `SET_NULL` / `SET_DEFAULT`
foreign key declared on another model points into the root's table from a model the cascade reaches.
Any test that pins such a delete's `show_query` output changes, whatever its filter reads.

### How to find the calls to migrate

```bash
grep -rnE '\.delete\(|delete\(' --include=*.jl src/ test/ | grep -vE 'delete!\('
```

For each match, check whether the model has dependents declared `on_delete = "CASCADE"`, `"SET_NULL"`
or `"SET_DEFAULT"`. Those deletes now start with the key read. Their counts change if the query's
filters include a `__` path to another model, a `cjoin` or a nested query, or if two models share the
root's table (`db_table = …`) and one of them declares a `SET_NULL` / `SET_DEFAULT` key the other does
not.

### Migrate your app

```julia
# ✗ before: the results, laps and qualifying went; the 17 races stayed
total, counts = M.Race.objects.filter("year" => 2009, "result__grid" => 1).delete()
counts["race"]   # 0

# ✓ after: the same call deletes the races it matched
total, counts = M.Race.objects.filter("year" => 2009, "result__grid" => 1).delete()
counts["race"]   # 17
```

Code that worked around the defect by resolving the keys itself can keep doing so; the two spellings
now delete the same rows:

```julia
ids = unique([r[:raceid] for r in M.Result.objects.filter("grid" => 1, "raceid__year" => 2009).values("raceid").list()])
M.Race.objects.filter("raceid__@in" => ids).delete()
```

A test that pins a cascading delete's `show_query = :dict` steps should expect the key read first,
the root's `DELETE` over the keys (`WHERE "Tb"."<pk>" = ANY($1)`, or `IN (?, …)`), and no `FOR SHARE`
lock steps.
