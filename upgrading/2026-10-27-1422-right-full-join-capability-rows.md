## A `"RIGHT"` or `"FULL"` join type on SQLite older than 3.39.0 raises `BackendCapabilityError` while the query is built (#1422)

- **Version**: 0.9.0
- **PormG ref**: #1422, #1431 ; `src/capabilities.jl` (`right_joins`, `full_joins`), `src/querybuilder/build_query.jl` (`_require_outer_join`)
- **Recorded**: 2026-10-27
- **Severity**: behavior change, SQLite older than 3.39.0 only: a statement the server used to reject now raises `BackendCapabilityError` instead, before any SQL. PostgreSQL and SQLite 3.39.0 or newer are unchanged. MySQL is unreleased; there `"FULL"` is refused and `"RIGHT"` renders.

### What changed

`RIGHT JOIN` and `FULL JOIN` are two rows of the capability table, `right_joins` and `full_joins`.
PostgreSQL has both, SQLite has both from 3.39.0, and MySQL has `RIGHT JOIN` and no `FULL JOIN`.
A join type the backend lacks is refused before any SQL wherever the statement prints it, from every
place a join type is written: `on(…; join_type)`, `cjoin(…; join_type)`, `cjoin_on(…; join_type)`, a
CTE's `with(…; join_type)` and a `ForeignKey(how = …)` path join. The `BackendCapabilityError` names
the join type, the release that added it and the library at hand.

Before, the join was rendered as written, and a SQLite library older than 3.39.0 rejected it at the
server. That holds for a read, a `delete`, and an `update` whose `SET` values are constants on a model
with a primary key, because that update's key selection prints the joins as they are. Those raise
`BackendCapabilityError` now, where they raised the driver's own error.

Two `update` shapes never print the join type, and a capability does not decide them (#1431):

- an `update` with constant `SET` values on a model **without a primary key** rewrites the join for
  its row predicate (`RIGHT` to `INNER`, `FULL` to `LEFT`), which every backend runs. It runs as
  before.
- an `update` whose `SET` reads a joined column renders `UPDATE … FROM`, which joins as an inner join,
  and so does a joined `update` on a query that declares a CTE (`with(…)`), whatever it sets.
  A `RIGHT` join there updates exactly the rows it describes, so it runs as before, on every backend.
  A `FULL` join is refused on every engine with `QueryBuildError`, for its meaning rather than a
  capability: see the #1430 entry.

| a `"FULL"` join type on SQLite older than 3.39.0 | before | now |
|---|---|---|
| a read, a `delete`, or a constant-`SET` `update` on a model with a primary key and no CTE | an error from the server | `BackendCapabilityError` |
| a constant-`SET` `update` on a model without a primary key | ran as a `LEFT JOIN` | runs, unchanged |
| an `update` whose `SET` reads a joined column | ran as an inner join | `QueryBuildError` (#1430) |

### How to find the calls to migrate

Look for `join_type = "RIGHT"`, `join_type = "FULL"`, `how = "RIGHT"` or `how = "FULL"` in code
that runs on SQLite, and check which SQLite library your environment loads: 3.39.0 or newer is
unaffected, and the library SQLite.jl installs today is newer than that. Then look for code that
catches the driver's error around those queries.

### Migrate your app

Load a SQLite library of 3.39.0 or newer. On an older one, the query fails as before, with a
different exception type: catch `BackendCapabilityError` where the driver's error was caught.

```julia
# ✗ before: on SQLite < 3.39.0 the server rejected the join, raising the driver's own error
q = M.Result.objects
q.on("raceid", join_type = "FULL")
q.values("resultid", "raceid__year")
rows = try q.list() catch e; e isa SQLite.SQLiteException || rethrow(); nothing end

# ✓ now: refused before any SQL, naming the join type and the library at hand
rows = try q.list() catch e; e isa PormG.BackendCapabilityError || rethrow(); nothing end
```
