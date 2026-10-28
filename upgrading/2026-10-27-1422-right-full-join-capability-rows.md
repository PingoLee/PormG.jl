## A `"RIGHT"` or `"FULL"` join type on SQLite older than 3.39.0 raises `BackendCapabilityError` while the query is built (#1422)

- **Version**: Unreleased
- **PormG ref**: #1422 ; `src/capabilities.jl` (`right_joins`, `full_joins`), `src/querybuilder/build_query.jl` (`_require_outer_join`)
- **Recorded**: 2026-10-27
- **Severity**: behavior change, SQLite older than 3.39.0 only. PostgreSQL and SQLite 3.39.0 or newer are unchanged. MySQL is unreleased; there `"FULL"` is refused and `"RIGHT"` renders.

### What changed

`RIGHT JOIN` and `FULL JOIN` are two rows of the capability table, `right_joins` and `full_joins`.
PostgreSQL has both, SQLite has both from 3.39.0, and MySQL has `RIGHT JOIN` and no `FULL JOIN`.
A join type the backend lacks is refused before any SQL, from every place a join type is written:
`on(…; join_type)`, `cjoin(…; join_type)`, `cjoin_on(…; join_type)`, a CTE's
`with(…; join_type)` and a `ForeignKey(how = …)` path join. The `BackendCapabilityError` names the
join type, the release that added it and the library at hand.

Before, the join was rendered as written, and a SQLite library older than 3.39.0 refused it at the
server. That held for a read, a `delete`, and an `update` whose `SET` values are constants on a model
with a primary key, because that update's key selection prints the joins as they are. Two `update`
shapes did not print the join type, so they ran there:

- an `update` whose `SET` reads a joined column (`update("points" => F("raceid__year"))`), on any
  model, renders `UPDATE … FROM`, which joins as an inner join;
- an `update` with constant `SET` values on a model **without a primary key** rewrote the join for
  its row predicate (`RIGHT` to `INNER`, `FULL` to `LEFT`).

Those two are now refused like the rest.

| a `"FULL"` join type | before | now |
|---|---|---|
| PostgreSQL, SQLite 3.39.0 or newer | unchanged | unchanged |
| SQLite older than 3.39.0: a read, a `delete`, or a constant-`SET` `update` on a model with a primary key | an error from the server | `BackendCapabilityError` |
| SQLite older than 3.39.0: an `update` whose `SET` reads a joined column | ran as an inner join | `BackendCapabilityError` |
| SQLite older than 3.39.0: a constant-`SET` `update` on a model without a primary key | ran as a `LEFT JOIN` | `BackendCapabilityError` |

### How to find the calls to migrate

Look for `join_type = "RIGHT"`, `join_type = "FULL"`, `how = "RIGHT"` or `how = "FULL"` in code
that runs on SQLite, and check which SQLite library your environment loads: 3.39.0 or newer is
unaffected, and the library SQLite.jl installs today is newer than that.

### Migrate your app

Load a SQLite library of 3.39.0 or newer. On an older one, write the join type the statement ran as:
`"INNER"` for an `update` whose `SET` reads a joined column, and, for a constant-`SET` `update` on a
model without a primary key, `"LEFT"` for `"FULL"` and `"INNER"` for `"RIGHT"`:

```julia
# ✗ before: on SQLite < 3.39.0, a keyless model's update ran this join as a LEFT JOIN
q = M.Pit_stops.objects
q.on("raceid", join_type = "FULL")
q.filter("raceid__year" => 1990)
q.update("milliseconds" => 0)

# ✓ now: the same statement, spelled the way it ran
q = M.Pit_stops.objects
q.on("raceid", join_type = "LEFT")
q.filter("raceid__year" => 1990)
q.update("milliseconds" => 0)
```
