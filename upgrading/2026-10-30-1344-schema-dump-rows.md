## `PormG.Migrations.get_database_schema(conn)` on PostgreSQL returns rows, not a `DataFrame` (#1344)

- **Version**: Unreleased
- **PormG ref**: #1344 (phase 2) ; `src/migrations/introspection.jl` (`get_database_schema(::PormGPostgres)`, `convertSQLToModel(row)`)
- **Recorded**: 2026-10-30
- **Severity**: breaking, for one qualified call. `get_database_schema` is not exported, but the #274 entry names it as still reachable as `PormG.Migrations.get_database_schema(conn)`. `inspectdb`, `makemigrations`, `check()` and `convert_schema_to_models` read the same schema and return what they returned before.

### What changed

PormG's migration and introspection code used to turn every catalog read into a `DataFrame`, only to
index it. Since #1344 phase 2 it reads `fetch(...) |> Tables.rowtable`, one `NamedTuple` per row,
which is what lets `DataFrames` leave PormG's dependencies in a later phase. The PostgreSQL schema
dump is one of those reads, and it is also what `get_database_schema` returns.

| Call | before | now |
|---|---|---|
| `PormG.Migrations.get_database_schema(conn)` on PostgreSQL (and `get_database_schema(; pickup = conn)`) | a `DataFrame`, one row per table | a `Vector` of `NamedTuple`s with the same columns and values, one per table |
| `schema[1, :table_name]` | the first table's name | `ArgumentError: invalid index`: write `schema[1].table_name` |
| `schema.table_name` | the column of names | `FieldError`: write `[r.table_name for r in schema]` |
| `for r in eachrow(schema)` … `r.table_name` | each table's row | `FieldError` (`eachrow` of a `Vector` yields views, not rows): write `for r in schema` |
| `nrow(schema)` (after `using DataFrames`) | the table count | the same count; `length(schema)` needs no DataFrames |
| `DataFrame(schema)` (after `using DataFrames`) | a copy of the frame | the same frame as before |
| `convertSQLToModel(row)` | took only a `DataFrameRow` | takes any Tables.jl row: one of these `NamedTuple`s, or a `DataFrameRow` as before |

`get_database_schema` on SQLite returns the same `Dict` as before.

### Who this affects

Only code that calls `PormG.Migrations.get_database_schema` on a PostgreSQL connection and treats the
result as a `DataFrame`.

### How to find the calls to migrate

```bash
grep -rnE 'get_database_schema\s*\(' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before
schema = PormG.Migrations.get_database_schema(conn)
tables = schema.table_name

# ✓ after: read the rows
schema = PormG.Migrations.get_database_schema(conn)
tables = [r.table_name for r in schema]

# ✓ or keep a frame
using DataFrames
schema = DataFrame(PormG.Migrations.get_database_schema(conn))
```
