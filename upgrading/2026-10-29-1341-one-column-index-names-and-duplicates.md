## `makemigrations`: `db_index` indexes get a derived name, and duplicate copies of one are planned away (#1341)

- **Version**: Unreleased
- **PormG ref**: #1341 ; `src/migrations/planner.jl` (`_one_column_index_name`, `_plan_index_copies!`), `src/migrations/introspection.jl` (the three readers), `src/migrations/column_spec.jl` (`LiveTable`)
- **Recorded**: 2026-10-29
- **Severity**: behavior change on PostgreSQL, SQLite and MySQL. A new `db_index` index has a different name. A plan over a column carrying the same index more than once now drops the extra copies (destructive, so `migrate` needs `destructive = true`). `LiveTable.indexes` changes type.

### What changed

- **A `db_index` index is named `<table>_<column>_idx`.** It used to end in a random suffix,
  `result_driverid_a1b2c3d4_idx`. The name is now derived from the physical table and column, the
  one-column spelling of a `Models.Index` name: `result_driverid_idx`. A name longer than the engine
  allows (63 bytes on PostgreSQL, 64 characters on MySQL) is cut and ends in 8 hex digits of its own
  hash. When another index already holds the derived name, the new index takes
  `<table>_<column>_<8 hex>_idx`. Existing indexes keep their names; nothing is renamed. Foreign-key
  constraint names are unchanged.
- **Every copy of a column's index is read.** The readers kept one index name per column, so a column
  carrying the same plain index under several names showed one, and the planner ignored the rest.
  A copy is a plain, non-unique one-column index with no `WHERE`, expression, direction, operator
  class or collation of its own.
- **The copies are planned away.** When the field declares `db_index = true`, every copy but one is
  dropped, each in its own `Remove duplicate index <index> on <column>` step. The copy kept is the one
  named `<table>_<column>_idx` if present, otherwise the first by name. When the field does not
  declare it, every copy is dropped in one plan. Before, one copy was dropped per `makemigrations`
  run, until none was left.
- **`check(…; kinds = [:schema_drift])` reports the copies.** It reports exactly the steps
  `makemigrations` would plan, so a database whose columns carry duplicate indexes now has drift
  findings until a plan drops them.
- **A pending plan for a table with copies is refused.** A plan written before the upgrade records
  each table's schema fingerprint, and `migrate` compares it. The fingerprint now lists every copy,
  so for a table that carries one, the fingerprint differs and `migrate` refuses the plan: run
  `makemigrations` again. Tables without copies keep their fingerprint.
- **A composite name a `db_index` index holds is refused at plan time.** A `Models.Index` over `b` and
  `c` derives `<table>_b_c_idx`, the same name as the `db_index` index of a column named `b_c`. When
  that index is live, `makemigrations` raises `InvalidMigrationError` asking for an explicit `name=`
  on the `Index`; the plan's `CREATE INDEX` would otherwise fail at `migrate`. When neither exists
  yet, the `Index` keeps the name and the `db_index` index takes the hashed one.
- **`LiveTable.indexes` is a `Dict{String, Vector{String}}`.** It maps each column to every index name
  over it, sorted, where it held one name or `nothing`. An empty vector stands for "indexed, name not
  known". `model.cache["index"]` on a model `inspectdb` read holds the same vectors.

| situation | before | now |
|---|---|---|
| a new `db_index = true` field `result.grid` | `CREATE INDEX IF NOT EXISTS "result_grid_k3j9x0aq_idx" …` | `CREATE INDEX IF NOT EXISTS "result_grid_idx" …` |
| `result.grid` declares `db_index = true` and carries three copies | nothing planned | two `DROP INDEX` steps |
| `result.grid` no longer declares `db_index` and carries three copies | one `DROP INDEX` per run | three `DROP INDEX` steps in one plan |
| `live.indexes["grid"]` with one index | `"result_grid_idx"` | `["result_grid_idx"]` |

### Who this affects

- Databases with a column that carries the same index more than once. On PostgreSQL, they are the
  rows of this query that share a table and a column:

  ```sql
  SELECT t.relname AS table_name, a.attname AS column_name, c.relname AS index_name
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indexrelid
    JOIN pg_class t ON t.oid = i.indrelid
    JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = i.indkey[0]
   WHERE i.indnkeyatts = 1 AND NOT i.indisunique AND i.indpred IS NULL AND i.indkey[0] <> 0
   ORDER BY 1, 2, 3;
  ```

  The next `makemigrations` plans those drops. Review them with `dry_run()`, then
  `migrate(…; destructive = true)`.
- Code that hard-codes an index name PormG created, or matches it with a pattern for a random
  suffix.
- Code that reads `LiveTable.indexes` or `model.cache["index"]`.

### How to find the calls to migrate

```
grep -rn 'Remove duplicate index' db/migrations/
grep -rnE '\.indexes\[|cache\["index"\]|_[a-z0-9]{8}_idx' --include='*.jl' .
```

### Migrate your app

```julia
# ✗ before: one name, or nothing
name = live.indexes["grid"]
name === nothing || println(name)

# ✓ after: every name over the column
for name in live.indexes["grid"]
    println(name)
end
```

A pending plan generated before this change still applies to tables without duplicate indexes:
their schema fingerprint is unchanged. For a table with copies, run `makemigrations` again.
