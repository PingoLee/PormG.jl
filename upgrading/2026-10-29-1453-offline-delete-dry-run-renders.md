## A dry-run `delete()` on a `register_offline` key renders its cascade; past a `PROTECT` relation it raises `ProtectedError` (#1453)

- **Version**: Unreleased
- **PormG ref**: #1453 ; `src/querybuilder/deletion.jl` (`_is_live_pool`), `src/Configuration.jl` (`_is_offline_pool`)
- **Recorded**: 2026-10-29
- **Severity**: behavior change, every engine, offline keys only. `delete(show_query = …)` of a model that others reference raised `InvalidConfigurationError` on an offline key. Through `CASCADE`, `SET_NULL` or `SET_DEFAULT` relations it now returns the plan; past a `PROTECT` or `RESTRICT` relation it raises `ProtectedError` instead.

### What changed

A live database is read to plan a cascading `delete()`: the root's primary keys, and which related
tables hold rows. The planner decided whether it could read by the pool's type. An offline entry
holds a real `PostgresConnectionPool` or `SQLiteConnectionPool`, so the planner read, and the first
read hit the offline refusal, even under `show_query`.

An offline pool now reads nothing, the same way a mock backend never has. `delete(show_query = :dict)`
returns the root-key read as written, then each related table's statement, scoped by an empty key
list (`= ANY($1)` bound to `[]` on PostgreSQL, `(1 = 0)` on SQLite).

With no rows to read, the plan assumes related rows exist. A `PROTECT` or `RESTRICT` relation then
refuses the dry run with `ProtectedError`, the error a live delete raises when such a row exists.
That is the one call whose error type changes. `delete()` without `show_query` still raises the
offline `InvalidConfigurationError`.

| on an offline key | before | now |
|---|---|---|
| `delete(show_query = :dict)`, related through `CASCADE` / `SET_NULL` / `SET_DEFAULT` | `InvalidConfigurationError` | the plan (#1453) |
| `delete(show_query = :dict)`, related through `PROTECT` / `RESTRICT` | `InvalidConfigurationError` | `ProtectedError` (#1453) |
| `delete()` | `InvalidConfigurationError` | `InvalidConfigurationError`, unchanged |

### Who this affects

A golden-SQL suite that asserts the old refusal of a dry-run `delete()` on an offline key.

### How to find the calls to migrate

```bash
grep -rn 'delete(.*show_query' --include=*.jl test/
```

For each match in a file that calls `register_offline`, check whether it expects
`InvalidConfigurationError`.

### Migrate your app

```julia
# ✗ before — the dry run of a race with results raised; now it returns the plan (#1453)
@test_throws InvalidConfigurationError M.Race.objects.filter("year" => 1991).delete(show_query = :dict)

# ✓ pin the plan: which statements run, in which order (PostgreSQL; on SQLite the first step is
#   `(:select, "race")`, a key read without `FOR UPDATE`)
steps = M.Race.objects.filter("year" => 1991).delete(show_query = :dict)
@test [(s[:operation], s[:model]) for s in steps] == [(:lock, "race"), (:delete, "result"), (:delete, "race")]

# ✓ past a PROTECT relation, pin the refusal by its type
@test_throws ProtectedError M.Race.objects.filter("year" => 1991).delete(show_query = :dict)
```
