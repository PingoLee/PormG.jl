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

If your models are configured with `on_delete="CASCADE"` (the default for `ForeignKey` fields), PormG or the database (depending on the adapter) will automatically remove related records to maintain integrity.

```julia
# This will also delete related Result records if they reference this Race
query = M.Race.objects
query.filter("name" => "Cancelled Grand Prix")
delete(query)
```

**Generated SQL (PostgreSQL):**
```sql
DELETE FROM "race" AS "Tb" 
WHERE "Tb"."name" = $1
-- Note: Dependent rows in "result" are removed by DB FOREIGN KEY CASCADE or ORM cascade
-- Parameters: ["Cancelled Grand Prix"]
```

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

!!! note "Limitation: `SET_NULL` requires a nullable FK"
    Declaring `on_delete = SET_NULL` on a field that is also `null = false` is a contradiction the
    schema cannot satisfy. The delete raises `ModelDefinitionError` — declare the FK with
    `null = true`, or choose a different `on_delete`.

See [Models and Fields](../fields.md) for more details on configuring deletion behavior (CASCADE, PROTECT, SET_NULL, etc.).
