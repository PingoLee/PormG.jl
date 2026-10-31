## The bulk writers take any Tables.jl table, and `allocate_primary_keys` loses `clone` (#1344)

- **Version**: Unreleased
- **PormG ref**: #1344 (phase 3, decision 3) ; `src/querybuilder/execution_bulk.jl` (`_bulk_frame`, `allocate_primary_keys`)
- **Recorded**: 2026-10-31
- **Severity**: breaking for `allocate_primary_keys(…; clone = …)`, which now raises. With a `DataFrame`, `bulk_insert`, `bulk_update` and `bulk_copy` write and return what they did before; the table lists the error types and message texts that changed, and the three ways `allocate_primary_keys`' result differs (the key column's element type on LibPQ, a refusal where PostgreSQL has no sequence, the frame's metadata).

### What changed

`bulk_insert`, `bulk_update`, `bulk_copy` and `allocate_primary_keys` used to accept only a
`DataFrames.DataFrame`. They now take any Tables.jl table: a `DataFrame`, a `Vector` of
`NamedTuple`s, a `NamedTuple` of vectors, a `CSV.File`, or anything else with
`Tables.istable(x) == true`. PormG converts it once into its own columns; a `DataFrame`'s columns are
read in place, never copied, as before. This is part of moving `DataFrames` out of PormG's
dependencies.

`allocate_primary_keys` now returns a **new table of the kind you passed**, built by the table's own
`Tables.materializer`, so a `DataFrame` still gives a `DataFrame`. A generic table cannot be written
in place, so the in-place mode is gone.

| Call | before | now |
|---|---|---|
| `allocate_primary_keys(q, df; clone = false)` | wrote the key column into `df` and returned it | `MethodError` (unsupported keyword argument `clone`): write `df = allocate_primary_keys(q, df)` |
| `allocate_primary_keys(q, df; clone = true)` | a copy of `df` with the key filled | `MethodError`: drop the keyword, the default already returns a copy |
| `allocate_primary_keys(q, df)` with a `DataFrame` | a new `DataFrame` with the key filled | the same |
| `allocate_primary_keys(q, rows)` with a `Vector` of `NamedTuple`s, a `NamedTuple` of vectors, a `CSV.File` | `MethodError` | a new table: a `Vector` of `NamedTuple`s for the first, a `NamedTuple` of vectors for the others |
| the key column `allocate_primary_keys` fills, PostgreSQL through LibPQ | a `Vector{Union{Missing, Int64}}` | a `Vector{Int64}`, as the docstring always said and as SQLite and Postgres.jl already returned |
| `allocate_primary_keys` on PostgreSQL for a key with no sequence or identity behind it (an `IDField()` over a plain integer column) | the key column came back holding `missing` | `QueryBuildError`, naming the key: declare it `IDField(generated = false)` and supply it |
| `bulk_insert(…; returning = …)` on PostgreSQL in that same case, when it pre-allocates the key | an error from inside the id copy, outside PormG's error types | the same `QueryBuildError` |
| table- and column-level metadata (`metadata!`, `colmetadata!`) on the `DataFrame` you pass to `allocate_primary_keys` | kept on the returned copy | not carried: the result is rebuilt from the columns. Set it again on the result if you use it |
| `bulk_insert(q, x)`, `bulk_update(q, x)`, `bulk_copy(q, x)`, `allocate_primary_keys(q, x)` where `x` is not a table | `MethodError` | `QueryBuildError` ("expected a Tables.jl table"). Checks that do not need the table still come first and raise as they do for a `DataFrame`: writes disabled, an invalid `returning=`, `match_on=` or `filters=`, a handler `bulk_update` cannot express, `bulk_copy` off PostgreSQL, an `IDField(generated = false)` key for `allocate_primary_keys`. Before, a non-`DataFrame` failed at dispatch, ahead of all of them |
| the same calls where `x` is a PormG query (`M.Driver.objects…`), which is a Tables.jl source since #1344 phase 1 | `MethodError` | `QueryBuildError` ("a query is not a table to write"): read its rows first, e.g. `Tables.columntable(query)` |
| a `Vector` of `NamedTuple`s whose rows name different columns | `MethodError` | `QueryBuildError` naming the row and the columns that differ; nothing is written |
| `bulk_insert(x)` / `bulk_update(x)` (the curried forms) where `x` is not a table | `MethodError`, or a closure for a `DataFrame` | `QueryBuildError` at once; a table still gives the closure |
| any `bulk_*` call with a non-`DataFrame` table | `MethodError` | runs, writing exactly what the same rows as a `DataFrame` write |

Messages that used to say "the DataFrame" (an unmapped column, a missing key, the empty-input
warning, "the DataFrame is empty" → "the table is empty") now say "the table".

`bulk_insert(…; returning = …)` still returns its `rows` as a `DataFrame` for now, whatever you
passed; the next phase of #1344 changes it to the kind of table you passed.

### Who this affects

Code that passes `clone =` to `allocate_primary_keys`, or that relied on `clone = false` filling the
caller's frame in place. Code that matches the text of a bulk error message or warning containing
"DataFrame".

### How to find the calls to migrate

```bash
grep -rnE -A3 'allocate_primary_keys\s*\(' --include=*.jl . | grep -E 'clone\s*='   # -A3: a keyword on a later line
grep -rnE 'DataFrame' --include=*.jl . | grep -E 'test_logs|occursin|contains|r"'   # code matching a bulk message's text
```

### Migrate your app

```julia
# ✗ before: filled drivers_df in place
allocate_primary_keys(M.Driver.objects, drivers_df; clone = false)

# ✓ after: assign the result
drivers_df = allocate_primary_keys(M.Driver.objects, drivers_df)

# ✓ also possible now: no DataFrame at all
rows = [(forename = "Ayrton", surname = "Senna"), (forename = "Alain", surname = "Prost")]
rows = allocate_primary_keys(M.Driver.objects, rows)     # a Vector of NamedTuples, driverid filled
bulk_insert(M.Driver.objects, rows)
```
