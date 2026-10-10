## `limit()` / `offset()` / `page()` — LIMIT and OFFSET are bound parameters, not literals (#46)

- **Version**: Unreleased
- **PormG ref**: #46 ; `src/querybuilder/execution_read.jl` (`_limit_offset_sql`, `_exists`), `src/querybuilder/parameters.jl` (`:limit` bucket), `src/Dialect.jl` (`limit_offset_clause`)
- **Recorded**: 2026-10-08
- **Severity**: behavior change. Query results are unchanged. The rendered SQL text and the parameter vector are different: `show_query`, `inspect_query` and `show_query = :dict` / `:params` output for any query with a limit or an offset.

### What changed

`LIMIT` and `OFFSET` used to be printed into the statement as integer literals. They now bind like
every other value, after all the others, LIMIT first:

| | before | after |
|---|---|---|
| PostgreSQL text | `… WHERE "Tb"."raceid" = $1 LIMIT 25 OFFSET 50` | `… WHERE "Tb"."raceid" = $1 LIMIT $2 OFFSET $3` |
| SQLite text | `… = ? LIMIT 25 OFFSET 50` | `… = ? LIMIT ? OFFSET ?` |
| `inspection[:parameters]` | `[18]` | `[18, 25, 50]` |
| `inspection[:parameter_buckets]` (SQLite) | no `:limit` key | `:limit => [25, 50]` |

This covers `first()`, `last()` and `get()` too, which apply a limit internally (`get()` probes with
`LIMIT 2`). `exists()` keeps its own literal `LIMIT 1` and binds only an offset you set. The
`EXISTS (… LIMIT 1)` predicate does not change.

`limit(0)` and `limit(Int32(0))` both bind `0` and return zero rows. The rest of that change is the
#1049 entry in this release: `0` is no longer a "no limit" value, and "no limit" is `limit(nothing)`.

Also fixed in the same change: on SQLite, an offset with no limit (`q.offset(5)`) rendered a bare
`OFFSET`, which SQLite rejects as a syntax error. It now renders `LIMIT -1 OFFSET ?`, SQLite's
no-limit spelling. PostgreSQL keeps `OFFSET $N`.

### Who this affects

Only code that asserts PormG's rendered SQL or parameter vector for a limited or offset query, such
as a golden-SQL test suite. Application code that executes queries needs no change. A golden test typically pins both the text (`LIMIT 25 OFFSET 25`) and the parameter vector.

### How to find the calls to migrate

```bash
grep -rnE 'LIMIT [0-9]|OFFSET [0-9]' --include=*.jl test/
```

Each hit inside an expected-SQL string is a pin to update. Then check the `[:parameters]` /
`:params` assertion beside it, which gains the limit and offset values at its end.

### Migrate your app

```julia
q = M.Result.objects.filter("raceid" => 18).values("resultid").page(25, 50)
insp = inspect_query(q)

# ✗ before
@test endswith(strip(insp[:sql_text]), "LIMIT 25 \nOFFSET 50")
@test insp[:parameters] == Any[18]

# ✓ after
@test endswith(strip(insp[:sql_text]), "LIMIT \$2 \nOFFSET \$3")
@test insp[:parameters] == Any[18, 25, 50]
```
