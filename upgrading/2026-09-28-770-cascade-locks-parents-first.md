## `delete` — a cascade locks its parents before touching their children on PostgreSQL (#770)

- **Version**: Unreleased
- **Recorded**: 2026-09-28
- **PormG ref**: #770, #771; `src/querybuilder/deletion.jl` (`lock_objects`, `lock_related_objects`, `_models_to_lock`, `run_deletions`)
- **Severity**: behavior change — on PostgreSQL a cascading `delete()` emits `SELECT … FOR UPDATE` statements before its writes (plus `SELECT … FOR SHARE` on each table a filter across a relation reads), and its `show_query` / `inspect_query` step list gains `:lock` steps; single-table deletes and SQLite are unchanged

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

The rows written are the same outside a race. Four things are observable:

- **Inspection.** A cascading delete's `show_query = :dict` / `:sql` / `:params` result, and
  `inspect_query(q, operation = :delete)`, now start with those statements, as steps with
  `:operation => :lock`. A step list you index by position, or search by `:model` alone, now finds
  the lock before the `DELETE` of a parent model.
  A root filter across a relation adds one more `:lock` step per join, right after the root's own.
  Its `:model` is the joined table's name (#771).
- **Lock duration.** A parent's row is locked from the first statement of the cascade, not only
  near its end. During a large cascade, a concurrent insert of a child row, an update of the
  parent, or a `select_for_update` on it now waits for the whole delete. With a filter across a
  relation, an update of a row that filter reads (the circuit in `"circuitid__name" => …`) waits
  too.
- **Lock order.** Parents are locked before children are written, where the deletes alone locked
  children first. A concurrent writer that locks a child and then its parent can now meet a delete in
  a deadlock. PostgreSQL detects it and aborts one of the two transactions with an error. A filter
  across a relation adds the opposite pair: its `FOR SHARE` on a joined parent table (the circuit)
  comes after the root's own lock (the race), so a joined race delete can deadlock with a circuit
  delete, or with a writer that updates a circuit and then one of its races.
- **Privilege.** `FOR UPDATE` and `FOR SHARE` need UPDATE privilege on the locked table. That now
  includes each managed table a root filter joins, where the delete used to need only `SELECT` on it.

A delete with nothing to cascade emits no lock, so its single statement is unchanged. SQLite emits
no lock at all: its writers are already serialized for the whole delete.

The lock pins the parent's **own row**. A root filter across a relation, such as
`"circuitid__name" => …`, also reads a related table, so each table it joins is locked too:

```sql
SELECT count(*) FROM (SELECT 1 FROM "circuit" AS "__pormg_locked" WHERE "__pormg_locked"."circuitid" IN (SELECT DISTINCT "Tb_1"."circuitid" FROM "race" as "Tb" INNER JOIN "circuit" AS "Tb_1" ON "Tb"."circuitid" = "Tb_1"."circuitid" WHERE "Tb"."year" = $1 AND "Tb_1"."name" = $2) FOR SHARE) AS "__pormg_lock"
```

A join into an unmanaged model (`managed = false`: a view, or a table another system owns) is not
locked, because `FOR SHARE` fails on an aggregating or materialized view and on a table the role may
only read. Still not pinned: that unmanaged hop, a filter that reads another table through a subquery
(`"x__@in" => M.Other.objects…`), a `cjoin_on` join (no key column to lock by), and a parent set that
*grows* mid-delete.
Where one of those decides which parents are deleted, keep locking that table yourself
(`select_for_update` in a transaction) or serialize the writers with an advisory lock, as before.

### How to find the calls to migrate

No call changes shape, but three things can now fail at run time, all on PostgreSQL and all only
for a delete that cascades (its model has reverse relations that `CASCADE` / `SET_NULL` /
`SET_DEFAULT`).

Tests that pin a cascading delete's step list:

```bash
grep -rnE 'operation *= *:delete|delete\(.*show_query' --include=*.jl .     # every pinned delete
grep -rnE 'findfirst\(.*\[:model\] *==' --include=*.jl .                    # step lookups by model alone
```

Deletes whose filter crosses a relation — the ones that now also lock a joined table. List every
delete, then read its filter for a `"<relation>__<field>"` key:

```bash
grep -rnE '\.delete\(|delete\(q' --include=*.jl .
```

For those, and for every cascading delete, the database role the app connects as needs **UPDATE**
privilege on each parent table and on each managed table such a filter joins (`FOR UPDATE` /
`FOR SHARE` require it). A role with only `SELECT` and `DELETE` there now gets `permission denied`.
A deadlock with a concurrent writer surfaces as an error too; retry the transaction, or take the
locks in the delete's order.

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
