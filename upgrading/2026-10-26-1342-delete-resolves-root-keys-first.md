## `delete()` with a root filter that reads another table deletes the rows it matched (#1342)

- **Version**: Unreleased
- **PormG ref**: #1342 ; `src/querybuilder/deletion.jl` (`_root_key_plan`, `_resolve_root_keys!`, `_root_key_chunks`)
- **Recorded**: 2026-10-26
- **Severity**: bug fix that changes a value. A cascading `delete()` whose filter reads another table now deletes every row its filter matched and returns counts that say so. It used to delete some or all of the children and keep the root, with no error. Its `show_query` / `inspect_query` output gains a key read and loses the `FOR SHARE` lock steps.

### What changed

The deletion collector deletes children first and the root last, and every statement re-read the
root's filter. When that filter reads the rows the cascade deletes (a reverse relation, an `Exists`
or a subquery over a child), the statements after the first saw a different set. The root's own
`DELETE` matched nothing, and so did any cascade path that ran after the rows it read were gone. The
same happened when a `SET_NULL` / `SET_DEFAULT` child re-pointed the rows the filter read. This was the
same on every engine.

Now, when the filter reads another table and the root has something to cascade to, `delete()` reads
the root's primary keys once, before it writes anything, and scopes every statement by them. Measured
on the F1 fixture (SQLite):

| `M.Race.objects.filter("year" => 2009, "result__grid" => 1).delete()` | before | now |
|---|---|---|
| `"race"` | 0 (the 17 races stay) | 17 |
| `"driver_standings"` | 0 | 364 |
| `"result"`, `"lap_times"`, `"qualifying"` | 340, 17186, 340 | the same |
| total | 18205 | 18586 |

The inspection output of the same delete:

- **The first step is the key read**: `SELECT "Tb"."<pk>" FROM <root> AS "Tb" WHERE <filter>`. It is
  `:operation => :lock` with `FOR UPDATE` on PostgreSQL and MySQL, where it replaces the root's
  `SELECT count(*) … FOR UPDATE` lock, and `:select` on SQLite.
- **Every later statement is scoped by the keys** (`"Tb"."<pk>" = ANY($1)` on PostgreSQL, one `?` per
  key elsewhere). None of them renders the filter again.
- **The `FOR SHARE` lock on each table a joined filter reads (#771) is gone.** It pinned what every
  statement re-read, and nothing re-reads it now.
- **On SQLite and MySQL a large key set runs the cascade in chunks** (2047 keys on SQLite, 256 on
  MySQL), so the inspection shows one set of statements per chunk.

The key read is decided from the schema (the root has a `CASCADE`, `SET_NULL` or `SET_DEFAULT`
dependent), not from the rows: a joined delete of a root whose dependents have no rows, which used to
be one `DELETE`, is now the key read and the `DELETE`. Its counts do not change.

A filter on the root's own columns (`"name" => …`), and a root with no such dependent, keep the
statements and the counts they had.

### Who this affects

Code that calls `delete()` on a model with `CASCADE`, `SET_NULL` or `SET_DEFAULT` dependents, with a
filter that crosses a relation (any `__` path or `cjoin`) or holds a query (`"x__@in" => M.Other.objects…`,
`Subquery`, `Exists`). Its counts change, and so does any test that pins its `show_query` output.

### How to find the calls to migrate

```bash
grep -rnE '\.delete\(|delete\(' --include=*.jl src/ test/ | grep -vE 'delete!\('
```

For each match, check whether the query's filters include a `__` path to another model, a `cjoin`, or
a nested query, and whether the model has dependents declared `on_delete = "CASCADE"`, `"SET_NULL"` or
`"SET_DEFAULT"`.

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

A test that pins a cascading delete's `show_query = :dict` steps for such a filter should expect the
key read first, and no `FOR SHARE` lock steps.
