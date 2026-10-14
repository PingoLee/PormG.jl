## A row lock without `of` beside an outer join is refused before the query runs, on PostgreSQL and SQLite (#1106)

- **Version**: Unreleased
- **PormG ref**: #1106 ; `src/querybuilder/execution_read.jl` (`_refuse_plain_lock_beside_outer_joins`)
- **Recorded**: 2026-10-14
- **Severity**: behavior change. On PostgreSQL most of these queries already failed at the server and now raise `QueryBuildError` before execution; the shapes its planner turned into an `INNER` join, which ran, now raise too. On SQLite a query that ran now raises.

### What changed

`select_for_update()` without `of` locks every table the query reads. PostgreSQL cannot lock the
nullable side of an outer join, and PormG joins `LEFT` for a path through a nullable foreign key,
for every hop after one, and for a `cjoin_on(…; join_type = "LEFT")`. Such a lock used to reach the
server and fail there with `FOR UPDATE cannot be applied to the nullable side of an outer join`.
PormG now refuses it while building the query, on both engines, and names the join:

| `select_for_update()` with no `of`, on a query with | before | now |
|---|---|---|
| a `LEFT` join (nullable foreign key, a hop after one, a `LEFT` `cjoin_on`) | PostgreSQL: `DatabaseError` at execution. SQLite: ran | `QueryBuildError` naming the relation path or `cjoin_on` alias, suggesting `of = ("self",)` or an `INNER` join |
| a `LEFT` join whose table a filter compares (`filter("<nullable fk>__<column>" => x)`) | PostgreSQL: ran, locking the joined rows too, because its planner turns that join into an `INNER` one. SQLite: ran | the same `QueryBuildError`: spell the `INNER` join, which returns the same rows and keeps the lock |
| a `RIGHT` or `FULL` join | PostgreSQL: `DatabaseError` at execution, unless a filter on the base table let its planner turn the join `INNER`, when it ran. SQLite: ran | `QueryBuildError`: the base table itself is on the nullable side, so no `of` helps |
| `INNER` joins only | locked every table | unchanged |
| a keyed `.with(…; join_field)` CTE, which joins `LEFT` by default | ran | unchanged: PostgreSQL does not lock a WITH query |

The refusal is raised by every terminal that renders the query, `show_query = :sql` and
`inspect_query` included, like the `of` target checks (#169).

### Who this affects

Code that calls `select_for_update` without `of` (any `nowait`, `skip_locked` or `no_key`) on a query
that joins `LEFT`, `RIGHT` or `FULL`. On PostgreSQL most of that code already failed, so only the
error type changes. The exceptions ran there and raise now: a query that filters on a `LEFT`-joined
table, and one that filters on the base table beside a `RIGHT` or `FULL` join, since PostgreSQL's
planner turns either join into an `INNER` one. Code developed on SQLite ran before in every case
and raises now.

### How to find the calls to migrate

```bash
grep -rn 'select_for_update(' --include=*.jl src/ test/ | grep -v 'of *='
```

For each one, check whether the query traverses a nullable foreign key (`null = true`) in a filter,
`values` or `order_by` path, or calls `cjoin_on`/`on` with a `join_type` other than `"INNER"`.

### Migrate your app

```julia
# ✗ before — the cjoin_on joins LEFT, so PostgreSQL cannot lock `d`
atomic("db_2") do
  query = M.Result.objects
  query.filter("raceid" => 1120)
  query.cjoin_on("Driver", alias = "d", join_type = "LEFT",
                 on = [Joined("d", "driverid") == F("driverid")])
  query.values("resultid", "surname" => Joined("d", "surname"))
  query.select_for_update().list()
end

# ✓ after — lock the result rows alone; the driver rows stay unlocked
atomic("db_2") do
  query = M.Result.objects
  query.filter("raceid" => 1120)
  query.cjoin_on("Driver", alias = "d", join_type = "LEFT",
                 on = [Joined("d", "driverid") == F("driverid")])
  query.values("resultid", "surname" => Joined("d", "surname"))
  query.select_for_update(of = ("self",)).list()
end

# ✓ after — or join INNER to lock the driver rows too (results with no driver drop out)
atomic("db_2") do
  query = M.Result.objects
  query.filter("raceid" => 1120)
  query.cjoin_on("Driver", alias = "d", join_type = "INNER",
                 on = [Joined("d", "driverid") == F("driverid")])
  query.values("resultid", "surname" => Joined("d", "surname"))
  query.select_for_update().list()
end
```

For a nullable foreign key path, the `INNER` spelling is `on("<path>", join_type = "INNER")`.

Beside a `RIGHT` or `FULL` join, change the join to `INNER`, or lock the rows with a query of their
own.
