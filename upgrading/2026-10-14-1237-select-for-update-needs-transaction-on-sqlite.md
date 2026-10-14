## `select_for_update()` must run inside a transaction on SQLite too (#1237)

- **Version**: Unreleased
- **PormG ref**: #1237 ; `src/querybuilder/execution_read.jl` (`query`)
- **Recorded**: 2026-10-14
- **Severity**: behavior change. On SQLite, a locked read under autocommit now raises `QueryBuildError` where it ran. PostgreSQL is unchanged except for the message wording.

### What changed

A locked read outside a transaction already raised `QueryBuildError` on PostgreSQL: under autocommit
the row lock is released as soon as the read returns. On SQLite the check was skipped, because
SQLite takes no row lock, so the same call ran silently. Code developed and tested on SQLite then
raised for the first time in production on PostgreSQL. The check now runs on both engines:

| `select_for_update()` … | before | now |
|---|---|---|
| outside any transaction, SQLite | ran, with no lock clause | raises `QueryBuildError` before the query is sent |
| outside any transaction, PostgreSQL | raised `QueryBuildError` | unchanged; the message no longer names an engine |
| inside `run_in_transaction` / `atomic`, SQLite | ran, with no lock clause | unchanged |
| `explain()` of a locked read outside a transaction, SQLite | ran | raises `QueryBuildError`, as on PostgreSQL |
| `show_query` / `inspect_query` of a locked read | rendered | unchanged: only an executed read needs the transaction |

The message is now `select_for_update() must run inside a transaction (run_in_transaction/atomic):
under autocommit a locked read holds nothing once it returns.` A test that matched the old
`… on PostgreSQL; otherwise the row lock is released immediately at autocommit.` tail needs the new
wording; one that matched `must run inside a transaction` still passes.

### Who this affects

Code that calls `select_for_update` on a SQLite database without an enclosing
`run_in_transaction` or `atomic` on that database: test suites and local development setups first,
since on PostgreSQL the same call already raised.

### How to find the calls to migrate

```bash
grep -rn 'select_for_update' --include=*.jl src/ test/
```

For each one, check that the read runs inside `run_in_transaction` / `atomic` on the database the
query reads from.

### Migrate your app

```julia
# ✗ before — ran on SQLite, raised on PostgreSQL
next_stop = M.Pit_stops.objects.
  filter("raceid" => 1120).
  order_by("stop").
  select_for_update(skip_locked = true).
  list() |> first

# ✓ after — the transaction holds the lock (PostgreSQL) or the write lock (SQLite)
atomic("db_2") do
  next_stop = M.Pit_stops.objects.
    filter("raceid" => 1120).
    order_by("stop").
    select_for_update(skip_locked = true).
    list() |> first
  # … process next_stop inside the same transaction …
end
```
