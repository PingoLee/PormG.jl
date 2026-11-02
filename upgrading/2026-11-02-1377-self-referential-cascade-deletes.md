## A delete of a tree's node deletes its descendants; on MySQL, rows in a loop raise `BackendCapabilityError` (#1377)

- **Version**: Unreleased
- **PormG ref**: #1377 ; `src/querybuilder/deletion.jl`
- **Recorded**: 2026-11-02
- **Severity**: behavior. A delete that raised now deletes on every engine. One shape still raises on MySQL, with a different type: code that catches it as a `QueryBuildError` stops matching there.

### What changed

A model with a `CASCADE` foreign key to itself is a tree (a team lineage, a category and its
subcategories). Deleting a node that has children raised `QueryBuildError` ("Circular dependency
detected in model relationships") on every engine, before anything was written. Django deletes the
node and everything below it, and so does PormG now. It reads the descendants by their keys, one
level per query, and deletes the deepest level first, each level with its own dependents.

Rows whose self-references form a loop (A's predecessor is B, and B's is A) have no order of DELETEs
that a per-statement key check accepts. PostgreSQL and SQLite check the key at `COMMIT`, so they delete
them. MySQL checks it at each statement, so it refuses before any write with `BackendCapabilityError`,
naming `deferred_foreign_keys` and the looped keys.

| call | before | now |
|---|---|---|
| a filtered delete of a tree node with children, any engine | `QueryBuildError` | deletes the node, its descendants and their dependents, deepest first |
| a filter matching a node and one of its descendants, any engine | `QueryBuildError` | deletes both subtrees, each row at its own depth |
| the same over rows whose self-references form a loop, PostgreSQL / SQLite | `QueryBuildError` | deletes them all, in one statement, and counts each (a loop of up to 51 rows; a longer one is refused by the 50-level cap, `QueryBuildError` as before) |
| the same over rows whose self-references form a loop, MySQL | `QueryBuildError` | `BackendCapabilityError` (`deferred_foreign_keys`) |
| a tree reached through another model, a model with two self-referential `CASCADE` keys, or `allow_delete_all` over a tree with children | `QueryBuildError` | `QueryBuildError`, unchanged; the message now names the models on the loop |
| a leaf, or a node with no children | deletes it | deletes it, after one more key read |

`BackendCapabilityError` is a `PormGError`, not a `QueryBuildError`.

### Who this affects

- Code that relied on the refusal to stop a delete of a tree node with children: the delete now runs
  and removes the subtree.
- Code on MySQL that catches the refusal as a `QueryBuildError` for rows in a loop.

### How to find the calls to migrate

```bash
# CASCADE foreign keys, to review for the ones whose target is the model declaring them
# (a key can span several lines, so read each hit's model)
grep -rnE 'on_delete *= *"?CASCADE' --include=*.jl .
# catches of QueryBuildError around a delete
grep -rnE 'QueryBuildError' --include=*.jl . | grep -i delete
```

### Migrate your app

```julia
# ✗ before: a node with children raised, so the caller deleted the subtree by hand, deepest first
M.Team.objects.filter("id" => brawn_id).delete()
M.Team.objects.filter("id" => honda_id).delete()

# ✓ after: one delete removes the node, its descendants and their drivers
M.Team.objects.filter("id" => honda_id).delete()

# On MySQL, rows in a loop: catch the capability error, or break the loop first
M.Team.objects.filter("id" => ligier_id).update("predecessor" => nothing)
M.Team.objects.filter("id" => ligier_id).delete()
```
