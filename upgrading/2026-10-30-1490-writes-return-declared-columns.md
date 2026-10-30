## `create` / `get_or_create` / `update_or_create`: the row a write returns carries the model's fields only (#1490)

- **Version**: Unreleased
- **PormG ref**: #1490 ; `src/querybuilder/execution_write.jl` (`_returned_columns`), `src/querybuilder/engine_facts.jl` (`_inserted_row_query`)
- **Recorded**: 2026-10-30
- **Severity**: behavior change. The SQL a write sends, and so what `show_query` shows, names the model's columns instead of `*`. The row it returns no longer carries a column the table has and the model does not declare: reading one raises `UnknownFieldError` where it returned the value.

### What changed

A write used to read back the row it wrote with `*`: PostgreSQL's `INSERT … RETURNING *`, and on
SQLite and MySQL a `SELECT *` after the `INSERT`. Its result therefore followed the **table**. Under
the Postgres.jl statement cache (#1479) that made a cached `create()` fail with SQLSTATE `0A000`
(*cached plan must not change result type*) inside a transaction, on every pooled connection, after
a deploy's `migrate` added a column. Each write now names every column the model declares, in
declaration order, by its physical (`db_column`) name: the same list on every engine. A type change
to a declared column (`varchar(50)` to `varchar(100)`) still changes a cached statement's result
type, and still raises inside a transaction under Postgres.jl; only an added column no longer does.

| Call | before | now |
|---|---|---|
| `M.Driver.objects.create(…; show_query = :sql)` on PostgreSQL | `… RETURNING *;` | `… RETURNING "driverid", "driverref", …, "url";` |
| `update_or_create(…; show_query = :sql)` on PostgreSQL | `… RETURNING *, (xmax = 0) AS "__pormg_created";` | `… RETURNING "statusid", "status", (xmax = 0) AS "__pormg_created";` |
| `get_or_create(…; show_query = :sql)` on PostgreSQL | `… DO NOTHING RETURNING *;` | `… DO NOTHING RETURNING "statusid", "status";` |
| The row `create()` returns, for a table with a column `team` the model does not declare | `row.team` and `keys(row)` include it, and so does `JSON.json(row)` | absent: `row.team` raises `UnknownFieldError`; `keys(row)` holds the model's fields |
| The same row from `update_or_create()`, or from a `get_or_create()` that inserted | includes `team` | absent, on every engine (SQLite and MySQL read the row back by the same column list) |
| Under `postgres_driver: Postgres`, a cached `create()` inside a transaction after another process added a column to its table | `StatementError` (`0A000`), the transaction aborted | runs |
| A write on a model that declares a field its table does not have yet (code deployed before `migrate`), or still declares one a migration dropped (an old instance in a rolling deploy) | ran: the `INSERT` left the unset field out and `*` read back what the table had | `StatementError` (*column does not exist*, or SQLite's *no such column*), on every engine. On SQLite and MySQL it is the read-back that raises, after the `INSERT`: outside a transaction PormG rolls the `INSERT` back, but inside one of yours the row is in your transaction, and committing after catching the error stores it |

Unchanged: reads that select no fields (`get()`, `first()`, `list()` without `values()`) still send
`SELECT *` and return every column the table has, and so does `get_or_create()` when it **finds** the
row. So while a table has a column its model does not declare (during a deploy, or on a table the
model maps only in part), the row `create()` returns has fewer keys than the same row read back with
`get()`.

### Who this affects

Code that reads a column off the row a write returned where the model does not declare that column,
and offline golden-SQL suites that pin a write's SQL text (`docs/src/testing.md`), which now see the
column list where they pinned `RETURNING *`. And deploys that run code against a table its
migration has not reached yet: a write names every declared column, so the table must have them.
Run `migrate` before the code that declares a new field serves writes, and remove a field from the
model one deploy before the migration that drops its column (Django asks the same).

### How to find the calls to migrate

```bash
grep -rn 'RETURNING \*' --include=*.jl --include=*.sql --include=*.txt .
grep -rnE '\.(create|get_or_create|update_or_create)\(' --include=*.jl .
```

### Migrate your app

A pinned write statement takes the model's column list:

```julia
# ✗ before
@test sql == """INSERT INTO "status" ("status") VALUES (\$1) RETURNING *;"""

# ✓ after
@test sql == """INSERT INTO "status" ("status") VALUES (\$1) RETURNING "statusid", "status";"""
```

A column the code reads off a written row belongs on the model. Declare it, or read it with a query:

```julia
# ✗ before: `team` is a column of the table, not a field of M.Driver
row = M.Driver.objects.create("driverref" => "senna", …)
row.team

# ✓ after: declare the field on M.Driver, or read the row back
row = M.Driver.objects.create("driverref" => "senna", …)
M.Driver.objects.get("driverid" => row.driverid).team
```
