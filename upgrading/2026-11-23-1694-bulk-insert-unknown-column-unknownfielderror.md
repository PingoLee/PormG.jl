## `bulk_insert` and `bulk_copy` raise `UnknownFieldError` for a `columns=` name the model has no field for (#1694)

- **Version**: Unreleased
- **PormG ref**: #1694, #1599 ; `src/querybuilder/execution_bulk.jl`
- **Recorded**: 2026-11-23
- **Severity**: behavior change, only for a `columns=` entry naming a field the model does not have. Every valid
  `columns=` writes as before.

### What changed

`bulk_insert` and `bulk_copy` raised a raw `KeyError` for a `columns=` name, bare or as a pair's target, that is a
column of the table but not a field of the model: the step that drops a blank auto-generated primary key looked the
field up before the check that names it. The check now runs, and raises the `UnknownFieldError` `bulk_update` already
raises for the same input:

| `columns=` (each name a column of the table) | before | now |
|---|---|---|
| `bulk_insert(M.Race.objects, rows; columns = ["year", "round", "nosuch"])` | `KeyError: key "nosuch" not found` | `UnknownFieldError`: `Error in bulk_insert, the field nosuch not found in race` |
| `bulk_insert(…; columns = [..., "nosuch" => "nofield"])` | `KeyError: key "nofield" not found` | `UnknownFieldError`: `Error in bulk_insert, the field nofield not found in race` |
| `bulk_copy(…; columns = [..., "nosuch"])` | `KeyError` | `UnknownFieldError` (`Error in bulk_copy, …`) |

A name that is not a column of the table either already raised this `UnknownFieldError`, and still does. When the same
call has another fault that the preparation checks before the unknown name (a required field with no column and no
default, an auto-generated primary key with blank and explicit values mixed), that fault's error is raised, as it was
for any call without the unknown name: an `InvalidValueError` or a `QueryBuildError` where the `KeyError` came first.

A `columns=` list built from a table's own column names (`names(df)`) with a column the model lacks is the usual way
to reach it.

### How to find the calls to migrate

Look for a `catch` that expects a `KeyError` around a bulk write, and for `columns=` built from a table's names:

```
grep -rn "KeyError" --include=*.jl .
grep -rn "columns = names(" --include=*.jl .
```

### Migrate your app

```julia
# ✗ before: a column the model lacks surfaced as a KeyError
# ✓ after: it is an UnknownFieldError, a UsageError naming the field
try
    PormG.bulk_insert(M.Race.objects, df; columns = names(df))
catch e
    e isa PormG.UnknownFieldError || rethrow()
    # a column of `df` is not a field of the model: drop it from `columns=`
end
```
