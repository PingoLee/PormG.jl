## A delete whose `SET_NULL` / `SET_DEFAULT` keys form a cycle runs; deleting a `SET_DEFAULT` key's own default row raises `IntegrityError` (#1374)

- **Version**: Unreleased
- **PormG ref**: #1374 ; `src/querybuilder/deletion.jl`
- **Recorded**: 2026-11-02
- **Severity**: behavior. Deletes that raised now run on every engine. One shape still raises, with a different type: code that catches it as a `QueryBuildError` stops matching.

### What changed

The deletion collector counted every reverse relation with rows as ordering the deletes, so a
`SET_NULL` or `SET_DEFAULT` relation could close a "cycle" and the delete raised `QueryBuildError`
("Circular dependency detected in model relationships") before any write. That covered a
self-referential `SET_NULL` / `SET_DEFAULT` key with dependent rows, and a team whose favourite driver
(`SET_NULL`) races for a team the delete `CASCADE`s to. Those relations' `UPDATE`s run before every
`DELETE`, so they order nothing now, and the deletes run as in Django.

One of those shapes is an error in Django too: a `SET_DEFAULT` key whose default is a row the same
delete removes (a self-referential lineage deleting its default row, or a team's `favourite_driver`
whose default driver races for the deleted team). The `UPDATE` re-points the rows at the default,
which the `DELETE` then removes, so the database refuses it with `IntegrityError`.

- **When:** at the `DELETE` on MySQL (InnoDB enforces `SET DEFAULT` as `RESTRICT`) and on PostgreSQL
  (the key's `SET DEFAULT` action re-checks at once). At `COMMIT` on SQLite, and on a deferrable
  `NO ACTION` key PormG did not create.
- **Inside your own `run_in_transaction` / `atomic`, on a key checked at `COMMIT`:** `delete()`
  returns normally, and the `IntegrityError` comes from the transaction's `COMMIT`, not from
  `delete()`.
- Nothing is written either way: the transaction rolls back.

| call | before | now |
|---|---|---|
| a lineage with `predecessor = ForeignKey("Team", on_delete = SET_NULL)`: `filter("predecessor__@isnull" => true).delete()` | `QueryBuildError` | deletes the root, nulls its successors |
| the same with `SET_DEFAULT` (default 1): `filter("predecessor" => 1).delete()` | `QueryBuildError` | deletes the matched rows, re-points their successors to 1 |
| the `SET_DEFAULT` lineage: `filter("id" => 1).delete()`, deleting the default row itself while rows point at it | `QueryBuildError` | `IntegrityError`, nothing written |
| any `SET_DEFAULT` key whose default row the same delete removes, where the relation closed a cycle | `QueryBuildError` | `IntegrityError`, nothing written |
| a team whose favourite driver (`SET_NULL`) races for a deleted team | `QueryBuildError` | deletes the team and its drivers, nulls the favourite |
| a self-referential `CASCADE` with dependent rows | `QueryBuildError` | `QueryBuildError`, unchanged |

`IntegrityError` is a `DatabaseError`, not a `QueryBuildError`.

### Who this affects

- Code that relied on the refusal to stop such a delete: it now runs.
- Code that catches the `SET_DEFAULT` shape above as a `QueryBuildError`. Inside a transaction of
  its own on SQLite, catch it around the transaction, not around `delete()`.

### How to find the calls to migrate

```bash
# self-referential SET_NULL / SET_DEFAULT keys
grep -rnE 'on_delete *= *"?(SET_NULL|SET_DEFAULT)' --include=*.jl .
# catches of QueryBuildError around a delete
grep -rnE 'QueryBuildError' --include=*.jl . | grep -i delete
```

### Migrate your app

```julia
# ✗ before: the refusal was caught as a QueryBuildError
try
  M.Team.objects.filter("id" => 1).delete()
catch e
  e isa PormG.QueryBuildError || rethrow()
end

# ✓ after: re-point the successors first, or catch the database's refusal
M.Team.objects.filter("predecessor" => 1).update("predecessor" => nothing)
M.Team.objects.filter("id" => 1).delete()
```
