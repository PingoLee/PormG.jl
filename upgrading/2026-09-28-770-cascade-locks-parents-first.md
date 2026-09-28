## `delete` — a cascade locks its parents before touching their children on PostgreSQL (#770)

- **Version**: Unreleased
- **Recorded**: 2026-09-28
- **PormG ref**: #770; `src/querybuilder/deletion.jl` (`lock_objects`, `_models_to_lock`, `run_deletions`)
- **Severity**: behavior change — on PostgreSQL a cascading `delete()` emits `SELECT … FOR UPDATE` statements before its writes, and its `show_query` / `inspect_query` step list gains `:lock` steps; single-table deletes and SQLite are unchanged

### What changed

`delete()` removes children before their parent, and each child statement selects its parents when
*it* runs. Since #765 every statement re-checks its own filters under a row lock, so a parent that a
concurrent transaction changed to stop matching was correctly skipped, but its children had already
been deleted (or nulled). This could happen at any depth. Example: a circuit is being deleted, and
another session moves one of its races to a different circuit. The race survived, but its results
were gone.

On PostgreSQL, every collected model that is the parent of an emitted statement is now locked first,
root first, with one statement per model. Each lock uses the same predicate as that model's `DELETE`:

```sql
SELECT count(*) FROM (SELECT 1 FROM "race" AS "Tb" WHERE "Tb"."name" = $1 AND "Tb"."year" = $2 FOR UPDATE) AS "__pormg_lock"
```

The rows written are the same outside a race. Three things are observable:

- **Inspection.** A cascading delete's `show_query = :dict` / `:sql` / `:params` result, and
  `inspect_query(q, operation = :delete)`, now start with those statements, as steps with
  `:operation => :lock`. A step list you index by position, or search by `:model` alone, now finds
  the lock before the `DELETE` of a parent model.
- **Lock duration.** A parent's row is locked from the first statement of the cascade, not only
  near its end. During a large cascade, a concurrent insert of a child row, an update of the
  parent, or a `select_for_update` on it now waits for the whole delete.
- **Lock order.** Parents are locked before children are written, where the deletes alone locked
  children first. A concurrent writer that locks a child and then its parent can now meet a delete in
  a deadlock. PostgreSQL detects it and aborts one of the two transactions with an error.

A delete with nothing to cascade emits no lock, so its single statement is unchanged. SQLite emits
no lock at all: its writers are already serialized for the whole delete.

The lock pins the parent's **own row**. A root filter that reads a related table, such as
`"circuitid__name" => …`, is still re-read by every statement in the cascade. If that table changes
mid-delete, the old outcome can still happen: the parent is skipped after its children are gone.
Where such a filter decides which parents are deleted, keep locking that table yourself
(`select_for_update` in a transaction) or serialize the writers with an advisory lock, as before.

### How to find the calls to migrate

Nothing in application code breaks. Look for tests that pin a **cascading** delete's step list on
PostgreSQL:

```bash
grep -rnE 'operation *= *:delete|delete\(.*show_query' --include=*.jl .     # every pinned delete
grep -rnE 'findfirst\(.*\[:model\] *==' --include=*.jl .                    # step lookups by model alone
```

A hit only needs migrating if the delete cascades, meaning its model has reverse relations that
`CASCADE` / `SET_NULL` / `SET_DEFAULT`, and the connection is PostgreSQL.

### Migrate your app

Skip the lock steps, or assert them explicitly:

```julia
steps = M.Race.objects.filter("name" => "Monaco Grand Prix", "year" => 2009).delete(show_query = :dict)

# ✗ before — the first step was the first write, and a lookup by model found the DELETE
race = steps[findfirst(s -> s[:model] == "race", steps)]

# ✓ after — pick the write step, and pin the lock if you care about it
race = steps[findfirst(s -> s[:model] == "race" && s[:operation] == :delete, steps)]
@test steps[1][:operation] == :lock && steps[1][:model] == "race"
```
