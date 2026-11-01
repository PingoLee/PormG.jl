## `query |> DataFrame`: a query is a Tables.jl source, and `PormG.QueryBuilder.DataFrame` is gone (#1344)

- **Version**: Unreleased
- **PormG ref**: #1344 (phase 1) ; `src/querybuilder/execution_read.jl` (`Tables.columns(::SQLObjectHandler)`), `src/QueryBuilder.jl`
- **Recorded**: 2026-10-30
- **Severity**: breaking, for one name only. `query |> DataFrame` returns the same frame it returned before, on every engine. What is gone is the public binding `PormG.QueryBuilder.DataFrame`, and with it PormG's own `DataFrame` method and docstring.

### What changed

`query |> DataFrame` used to run through a method PormG defined on `DataFrames.DataFrame`, and
`PormG.QueryBuilder` re-exposed DataFrames' `DataFrame` as a `public` name so that method could carry
a docstring. A query is now a [Tables.jl](https://github.com/JuliaData/Tables.jl) table: it implements
`Tables.istable` and `Tables.columns`, and DataFrames' own `DataFrame(table)` constructor reads it.
The frame is the same: the same column names, element types and values, with temporal columns typed
(`Date`, `Time`, `ZonedDateTime`, `CompoundPeriod`) on every engine, as `list()` types them (#582).
A recording of the frames before the change, on PostgreSQL under both drivers, SQLite and MySQL, is
what `test/integration/test_tables_source.jl` compares against.

| Call | before | now |
|---|---|---|
| `query \|> DataFrame` (after `using DataFrames`) | a `DataFrame` | the same `DataFrame` |
| `PormG.QueryBuilder.DataFrame` | DataFrames' `DataFrame` | ``UndefVarError: `DataFrame` not defined in `PormG.QueryBuilder` `` |
| `using PormG.QueryBuilder: DataFrame` | imports DataFrames' `DataFrame` | a `WARNING: Imported binding QueryBuilder.DataFrame was undeclared at import time`, then the same `UndefVarError` on first use |
| `DataFrame(query; copycols = false)` | `MethodError` | a `DataFrame` that shares the driver's columns, as `DataFrame(result; copycols = false)` does: on PostgreSQL through LibPQ a column the query reads unparsed is LibPQ's own read-only view, so writing to it raises `CanonicalIndexError`. Leave `copycols` at its default for a frame you modify |
| `CSV.write(io, query)`, `Tables.rowtable(query)`, any Tables.jl sink | `ArgumentError` (not a table) | reads the query |
| `?DataFrame` | showed PormG's docstring among DataFrames' | DataFrames' only; the contract is on `?PormG.SQLObjectHandler` |

This is phase 1 of #1344, which takes `DataFrames` and `CSV` out of PormG's `[deps]`. In this release
neither is a dependency of PormG any more (see the entry *`using PormG` no longer loads `DataFrames` or
`CSV`*). Write `using DataFrames` wherever you build a `DataFrame`, with `DataFrames` in your app's
own `Project.toml`.

### Who this affects

Only code that names `DataFrame` through PormG's `QueryBuilder` module rather than through DataFrames.

### How to find the calls to migrate

```bash
grep -rnE 'QueryBuilder\.DataFrame\b|QueryBuilder:.*\bDataFrame\b' --include=*.jl .
# and every alias of the module, whose `<alias>.DataFrame` the line above does not see:
grep -rnE '=\s*PormG\.QueryBuilder\b|QueryBuilder as' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before
df = PormG.QueryBuilder.DataFrame(M.Driver.objects.filter("nationality" => "Brazilian"))

# ✓ after
using DataFrames
df = M.Driver.objects.filter("nationality" => "Brazilian") |> DataFrame
```
