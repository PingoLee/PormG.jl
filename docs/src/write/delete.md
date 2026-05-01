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

**Return Value:**
The function returns a tuple containing the total count of deleted rows and a dictionary of counts per table (useful when cascades are involved):
```julia
(1, Dict{String, Integer}("just_a_test_deletion" => 1))
```

### Deletion with Conditions

```julia
# Delete with multiple conditions
query = M.Just_a_test_deletion.objects;
query.filter("test_result__@in" => [11, 12], "test_result2__@isnull" => true)
delete(query)
```

Using `show_query=:sql` reveals the underlying deletion logic without executing it (returns a String or Vector of Strings):
```julia
sql = delete(query, show_query=:sql)
# Returns: "DELETE FROM just_a_test_deletion WHERE \"id\" IN (
#    SELECT \"Tb\".\"id\" FROM \"just_a_test_deletion\" as \"Tb\" ...
# )"
```

### `change_data` Guard

If the connection is configured with `change_data: false`, any call to `delete()` raises an `ArgumentError` at the ORM layer before generating SQL.

```julia
# connection.yml: change_data: false
query = M.Just_a_test_deletion.objects.filter("id" => 1)
delete(query)
# ERROR: Not allowed to delete ...
```

See [Connection YML](../configuration/connection_yml.md) for the `change_data` configuration option.

---

## Bulk Deletion

By default, calling `delete()` on a query without filters will raise an error to prevent accidental data loss. You must explicitly set `allow_delete_all=true`.

```julia
# Delete all records (requires explicit permission)
query = M.Just_a_test_deletion.objects
delete(query, allow_delete_all=true)

# Selective bulk deletion
query = M.Result.objects
query.filter("raceid__year__@lt" => 1960)
delete(query)
```

## Cascade Deletion

If your models are configured with `on_delete="CASCADE"` (the default for `ForeignKey` fields), PormG or the database (depending on the adapter) will automatically remove related records to maintain integrity.

```julia
# This will also delete related Result records if they reference this Race
query = M.Race.objects
query.filter("name" => "Cancelled Grand Prix")
delete(query)
```

See [Models and Fields](../fields.md) for more details on configuring deletion behavior (CASCADE, PROTECT, SET_NULL, etc.).
