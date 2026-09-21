## `bulk_copy` — field formatters now applied; `""` and `missing` no longer collapse to NULL

- **PormG ref**: issue #86 / PR #115 ; `src/querybuilder/execution_bulk.jl`
- **Recorded**: 2026-07-12
- **Severity**: behavior change (persisted values can differ)

### What changed

`bulk_copy` wrote **raw** DataFrame values (each field's formatter result was validated, then
discarded), so datetime/bool/float values could silently diverge from what `bulk_insert` /
`create()` store; and the COPY payload carried no NULL marker, collapsing `""` and `missing`
into the same NULL. It now formats every cell exactly like `bulk_insert` and serializes with a
`\N` NULL sentinel: `missing` → SQL `NULL`, `""` → empty string, and the two round-trip
distinctly.

### How to find the calls to migrate

No API change. Review `bulk_copy` call sites that (a) pre-formatted datetimes/bools/floats to
compensate for the old raw write — the workaround is now redundant (but harmless), or
(b) relied on empty strings being stored as NULL.

### Migrate your app

```julia
# The old behavior stored NULL for BOTH of these; they now persist differently:
df = DataFrames.DataFrame(surname = ["Senna", "Prost"], code = ["", missing])
bulk_copy(M.Driver.objects, df)   # row 1 code → '' (empty string), row 2 code → NULL

# Keep the NULL semantics only where you actually want it — coerce before the call:
df[!, :code] = map(x -> !ismissing(x) && x == "" ? missing : x, df[!, :code])
```
