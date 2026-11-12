## Postgres.jl statements bind up to 65535 parameters (#1662)

- **Version**: Unreleased
- **PormG ref**: #1662, #1447 ; `ext/PormGPostgresExt.jl`, `src/Backend.jl`
- **Recorded**: 2026-11-12
- **Severity**: behavior change, for code that counts the statements a Postgres.jl dry run returns.
  The rows written and the values returned by an executed write are unchanged.

### What changed

PormG held a Postgres.jl pool to 32767 bind parameters per statement, a ceiling left from driver
releases below the 2.6 floor, which wrote the Bind message's parameter count as an `Int16`. Every
Postgres.jl that PormG's `[compat]` admits writes it as a `UInt16`, so a Postgres.jl pool now binds the
protocol's 65535, as a LibPQ pool always did. A statement PormG splits under the limit splits half as
often:

| under Postgres.jl | before | now |
|---|---|---|
| a many-to-many `remove` of 32767–65534 ids | two DELETE statements, in one transaction | one DELETE |
| `bulk_insert` / `bulk_update(…; chunk_size = 0)` (or any non-positive `chunk_size`) of more than `fld(32767, ncols)` and at most `fld(65535, ncols)` rows | two statements, so a dry run (`show_query = :sql`, `:params`, `:dict`, `:inspection`, `:none`) returned a 2-element `Vector` | one statement, so the dry run returns one result |
| `bulk_update(…; chunk_size = 0)` whose `filters=` alone bind more than `32767 − ncols` parameters | raised `QueryBuildError` | runs |

A positive `chunk_size` (the default is 1000) is unaffected: on PostgreSQL it binds one array per
column and was never capped by this limit. LibPQ pools are unaffected.

### How to find the calls to migrate

Only code that runs a Postgres.jl pool and inspects how many statements a dry run returned, or how
many statements a `remove` sent:

```
grep -rnE 'chunk_size *= *(0|-)' --include=*.jl .
```

Then look for a `show_query = …` on the same call whose result is indexed or counted.

### Migrate your app

```julia
# `df`: 20000 rows of `statusid` and `status` (40000 parameters)
# ✗ before: under Postgres.jl this split at 16383 rows, so it returned a 2-element Vector
stmts = bulk_insert(M.Status.objects, df; chunk_size = 0, show_query = :sql)
first_chunk = stmts[1]

# ✓ after: one statement under either PostgreSQL driver; normalize when the count can vary
stmts = bulk_insert(M.Status.objects, df; chunk_size = 0, show_query = :sql)
chunks = stmts isa Vector ? stmts : [stmts]
first_chunk = chunks[1]
```
