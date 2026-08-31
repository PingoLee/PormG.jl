# Deleting Records

PormG provides methods for removing data while ensuring referential integrity through cascade support and safety flags for bulk operations.

## Single Record Deletion

To delete records, apply filters to the objects manager and call `delete()`.

```julia
# Delete specific records
query = M.Just_a_test_deletion.objects;
query.filter("test_result" => 10)
delete(query)
```

**Generated SQL (PostgreSQL):**
```sql
DELETE FROM "just_a_test_deletion" AS "Tb" 
WHERE "Tb"."test_result" = $1
-- Parameters: [10]
```

**Return Value:**
The function returns a tuple containing the total count of deleted rows and a dictionary of counts per table (useful when cascades are involved):
```julia
(1, Dict{String, Integer}("just_a_test_deletion" => 1))
```

### Deleting a Fetched Row

A `PormGRow` you already have in hand — from `get()`, `first()`, `last()`, or `list()` — can delete itself with `row.delete()`. It is located by its primary key and routed through the **same** deletion collector as `query.delete()`, so cascade / `on_delete` handling is identical. It returns the same `(total, per-table counts)` tuple.

```julia
status = M.Status.objects.get("statusid" => 200)
total, counts = status.delete()
# (1, Dict{String, Integer}("status" => 1))
```

The row must have had its primary key projected (rows from `get()`/`first()`/`last()`/`list()` always do). The in-memory `row` is not mutated — its field data is stale after the delete.

### Deletion with Conditions

```julia
# Delete with multiple conditions
query = M.Just_a_test_deletion.objects;
query.filter("test_result__@in" => [11, 12], "test_result2__@isnull" => true)
delete(query)
```

**Generated SQL (PostgreSQL):**
```sql
DELETE FROM "just_a_test_deletion" AS "Tb" 
WHERE "Tb"."test_result" IN ($1, $2) AND "Tb"."test_result2" IS NULL
-- Parameters: [11, 12]
```

Using `show_query=:sql` reveals the underlying deletion logic without executing it (returns a String or Vector of Strings):
```julia
sql = delete(query, show_query=:sql)
# Returns: "DELETE FROM just_a_test_deletion WHERE \"id\" IN (
#    SELECT \"Tb\".\"id\" FROM \"just_a_test_deletion\" as \"Tb\" ...
# )"
```

### `change_data` Guard

If the connection is configured with `change_data: false`, any call to `delete()` raises a `WritesDisabledError` at the ORM layer before generating SQL.

```julia
# connection.yml: change_data: false
query = M.Just_a_test_deletion.objects.filter("id" => 1)
delete(query)
# ERROR: WritesDisabledError: Error in delete: the connection db is not allowed to write.
# Writes are disabled by default — set change_data: true under the `config:` block of the
# active environment in connection.yml to enable creates, updates, and deletes.
```

See [Connection YML](../configuration/connection_yml.md) for the `change_data` configuration option.

### Query shapes `delete()` refuses

!!! warning "`delete()` rejects `limit`, `offset`, `order_by`, `distinct` and aggregates"
    The deletion collector walks the *complete* filtered set so that row counts, cascades and
    constraint handling stay deterministic. Any query shape that collapses or truncates that set
    is refused with `UnsafeMutationError` **before** SQL is generated:

    ```julia
    # ✗ all four raise UnsafeMutationError
    M.Result.objects.filter("points" => 0).limit(10).delete()
    M.Result.objects.filter("points" => 0).offset(5).delete()
    M.Result.objects.filter("points" => 0).order_by("-points").delete()
    M.Result.objects.filter("points" => 0).distinct().delete()

    # ✓ bound the set with the filter instead
    ids = M.Result.objects.filter("points" => 0).limit(10).values("resultid") |> DataFrame
    M.Result.objects.filter("resultid__@in" => ids.resultid).delete()
    ```

    A query carrying `group_by`/aggregate annotations is refused for the same reason. There is no
    "delete the first N rows" form — filter by primary key.

---

## Bulk Deletion

By default, calling `delete()` on a query without filters raises `UnsafeMutationError` to prevent accidental data loss. You must explicitly set `allow_delete_all=true`.

```julia
# Delete all records (requires explicit permission)
query = M.Just_a_test_deletion.objects
delete(query, allow_delete_all=true)
```

**Generated SQL (PostgreSQL):**
```sql
DELETE FROM "just_a_test_deletion" AS "Tb"
```

```julia
# Selective bulk deletion
query = M.Result.objects
query.filter("raceid__year__@lt" => 1960)
delete(query)
```

**Generated SQL (PostgreSQL):**
```sql
DELETE FROM "result" AS "Tb" 
WHERE "Tb"."raceid" IN (
  SELECT "Tb_1"."raceid" 
  FROM "race" AS "Tb_1" 
  WHERE "Tb_1"."year" < $1
)
-- Parameters: [1960]
```

## Cascade Deletion

A `ForeignKey` declared `on_delete="CASCADE"` makes PormG's deletion collector remove the related
records too, in dependency order and inside the same transaction.

```julia
# This will also delete related Result records if they reference this Race
query = M.Race.objects
query.filter("name" => "Cancelled Grand Prix")
delete(query)
```

!!! warning "`CASCADE` is **not** the default — an unset `on_delete` cascades nothing"
    Omitting `on_delete` leaves it unset, which is a distinct state from `CASCADE`. PormG emits no
    statement for that relation, and the column renders `ON DELETE NO ACTION` in DDL. What happens
    when you delete the parent then depends entirely on the backend:

    | Backend | Deleting a parent whose child FK has an unset `on_delete` |
    |---|---|
    | PostgreSQL | `NO ACTION` is enforced — the delete fails with a foreign-key violation |
    | SQLite | `NO ACTION` is enforced — the delete fails the same way (#276) |

    Declare the behaviour you want explicitly on every `ForeignKey`.

!!! note "Both backends enforce foreign keys"
    PormG issues `PRAGMA foreign_keys = ON` on every SQLite connection (#276), so a delete the
    database should refuse is refused on both. Before that, SQLite defaulted the pragma to **off**
    and enforced nothing: an `on_delete` PormG's own collector did not handle (unset, or
    `DO_NOTHING`) silently orphaned the child there while raising on PostgreSQL, so the same schema
    and the same `delete()` could pass a SQLite test run and fail in production.

    PormG's deletion collector still applies `on_delete` itself — that is what makes `CASCADE` and
    `SET_NULL` behave identically across backends — but the database is now a real backstop rather
    than a formality.

**Generated SQL (PostgreSQL):**
```sql
DELETE FROM "race" AS "Tb" 
WHERE "Tb"."name" = $1
-- Note: dependent rows in "result" are removed by PormG's deletion collector, which emits their
-- DELETE separately in the same transaction (see the counts in the returned per-table Dict)
-- Parameters: ["Cancelled Grand Prix"]
```

!!! warning "A cascade descends at most 50 levels"
    Each level of the cascade nests one more subquery inside the statement below it, so the collector
    refuses to descend past 50 with a `QueryBuildError` naming the models it walked. Almost always
    that means a **foreign-key cycle** — two models declaring `on_delete = CASCADE` at each other, or
    self-referencing rows that form a loop — which would otherwise make the walk run until the stack
    ran out. Break the cycle, or give one side a different `on_delete` and clear its rows first.

    A genuinely acyclic hierarchy more than 50 levels deep hits the same ceiling; there is no way to
    raise it, so delete such a graph in stages, from the far end inward.

### Concurrency: a cascade path can be pruned out from under you on PostgreSQL

`delete()` plans the cascade by probing each declared path — "are there any `result` rows for these
races?" — and **dropping** the paths that come back empty, so a delete only emits statements for
relations that actually have rows. Planning and the statements it produces run inside the same
transaction. What that is worth differs by backend:

| Backend | Mechanism | A row inserted on a pruned path mid-delete |
|---|---|---|
| SQLite | `BEGIN IMMEDIATE` plus PormG's process-wide write lock | Impossible — no other writer can commit while planning runs |
| PostgreSQL | `BEGIN` at READ COMMITTED | Possible — every statement takes a fresh snapshot, even inside a transaction |

So on PostgreSQL two sessions can interleave like this:

1. Session A calls `delete()` on a `race`. Planning probes `lap_times`, finds nothing, drops the path.
2. Session B inserts a `lap_times` row for that race and commits.
3. Session A's deletes run. The race goes; the new lap time was never in PormG's plan.

**On a schema PormG's migrations built, the database is the backstop.** Migrations emit each
`ForeignKey`'s own `on_delete` into the DDL — `ON DELETE CASCADE`, `SET NULL`, `SET DEFAULT`,
`RESTRICT` — so whatever the collector skipped, the database still knows about. What that means
depends on the action:

- **`CASCADE` / `SET_NULL` / `SET_DEFAULT`** — the three that emit statements. PostgreSQL performs
  the skipped action itself at `COMMIT` (these constraints are `DEFERRABLE INITIALLY DEFERRED`), so
  the row is removed, nulled or defaulted anyway and the delete succeeds. What you lose is the
  **accounting**, not the rows: the per-table counts in the returned `(total, Dict)` tally only
  statements PormG issued, so work the database did on a pruned path is not counted. Treat those
  counts as a report of what the ORM did, not an audit of the transaction.
- **`PROTECT` / `RESTRICT`** — pruning applies here too, because the probe runs for *every* reverse
  relation before PormG looks at the action at all; that is what makes `PROTECT` existence-driven.
  So a row inserted after the probe means [`ProtectedError`](../errors.md) is *not* raised, and the
  `DELETE` instead hits the DDL's `ON DELETE RESTRICT`, which PostgreSQL cannot defer. The delete
  still fails — same refusal, but reported as the driver's foreign-key error rather than PormG's.

An unset `on_delete` is unaffected either way: it builds no cascade path, so there is nothing to
prune.

Two shapes are genuinely exposed, because there is no database action to fall back on:

- a `ForeignKey` declared `db_constraint = false`, which suppresses the constraint;
- a hand-written model over a table PormG did not create — a legacy or unmanaged schema — whose
  actual `ON DELETE` clause is absent or disagrees with what the model declares.

In both, a row inserted on a pruned path simply survives with a dangling reference. If that is your
situation, serialize the delete against the writer yourself — an
[advisory lock](../advisory_lock.md) around both is the usual answer.

PormG deliberately does **not** raise the isolation level or lock the probed rows on your behalf:
either would change the failure modes of *every* delete — serialization failures the caller must
retry, or blocking on rows another transaction holds — to close a window that the database already
covers wherever the constraint is real.

!!! warning "`PROTECT` and `RESTRICT` refuse the delete with `ProtectedError`"
    A `ForeignKey` declared `on_delete = PROTECT` (or `RESTRICT`) makes the referenced row
    undeletable while referencing rows exist. PormG checks this at the ORM layer and raises
    [`ProtectedError`](../errors.md), naming the referencing model and field:

    ```julia
    try
        M.Driver.objects.filter("driverid" => 1).delete()
    catch e
        e isa ProtectedError || rethrow()
        @warn "Reassign or delete the referencing rows first" msg=error_message(e)
    end
    ```

    Nothing about the call is malformed — the *data* forbids it, so the remedy is to delete or
    reassign the dependents. The check is existence-driven: it only fires when referencing rows
    are actually present.

!!! note "`SET_NULL` requires a nullable FK, `SET_DEFAULT` requires a default"
    Both are contradictions the schema cannot satisfy, and both raise `ModelDefinitionError`:

    - `on_delete = SET_NULL` on a field that is also `null = false` — declare the FK `null = true`,
      or choose a different `on_delete`.
    - `on_delete = SET_DEFAULT` on a field with no `default` — give the FK a `default =`, or choose
      a different `on_delete`. Before this was enforced the delete emitted `SET <column> = NULL`,
      so `SET_DEFAULT` silently behaved as `SET_NULL` and then violated the column's constraint.

    The error is raised at model registration (`set_models` / `@import_models`), so a contradictory
    schema fails as soon as the models load rather than at the first delete. `delete()` keeps its own
    copy of both checks as a backstop for models built without going through registration.

    Every contradiction *of these two kinds* in the module is collected and reported in a single
    `ModelDefinitionError` naming each offending model, field and fix, so a legacy schema carrying
    several of them is diagnosed in one pass rather than one registration per field. Only these two
    are aggregated: every *other* registration error — an unresolvable foreign-key or many-to-many
    target, a duplicate `related_name`, a model without exactly one primary key, an unusable
    explicit `through` model — still raises on the first occurrence and preempts that report.

See [Models and Fields](../fields.md) for more details on configuring deletion behavior (CASCADE, PROTECT, SET_NULL, etc.).
