## `bulk_update` refuses a call that leaves nothing to set with a `QueryBuildError`, before any SQL (#1841)

- **Version**: Unreleased
- **PormG ref**: #1841 ; `src/querybuilder/execution_bulk.jl`
- **Recorded**: 2026-11-24
- **Severity**: behavior change, only for a `bulk_update` whose every field is a key. Every call with a field to set
  renders and runs as before.

### What changed

`bulk_update` sets the fields of the table that are not keys: a `match_on=` key, the primary key it matches on when
`match_on=` is not given, and a `filters=` key are matched, never set. When every field the rows bring is a key,
nothing is left to set. PormG still sent the statement, with nothing after `SET`, and each engine rejected it as a
syntax error once it was sent; under `show_query = :sql`, `:dict` or `:params` the call returned that statement. The
call is now refused before any statement is sent or returned, with a `QueryBuildError` that names the fields and
where their keys came from:

| the call | before | now |
|---|---|---|
| `bulk_update(M.Race.objects, rows; columns = ["year"], match_on = ["raceid"], filters = ["year" => 2008])` | the statement was sent; `StatementError` (see below) | `QueryBuildError`: `bulk_update: every field in columns= (year) is a key in filters=; nothing is left to update. …` |
| `bulk_update(…; columns = ["year"], filters = ["year" => 2008])` (no `match_on=`) | as above | the same `QueryBuildError` |
| `bulk_update(…; columns = ["raceid"], match_on = ["raceid"])` | as above | `QueryBuildError`: `… every field in columns= (raceid) is a key in match_on=; …` |
| `bulk_update(…; columns = ["raceid"])` (no `match_on=`) | as above | `QueryBuildError`: `… every field in columns= (raceid) is the primary key, which bulk_update matches on when match_on= is not given; …` |
| `bulk_update(M.Status.objects, (statusid = [1],))`, rows whose every column is the primary key, `columns=` not given | as above | `QueryBuildError`: `… every column the rows bring (statusid) is the primary key, …` |
| any of the above with `show_query = :sql`, `:dict` or `:params` | returned the statement, with nothing after `SET` | the same `QueryBuildError` |

The `StatementError` each engine raised, after the statement was sent:

| engine | before |
|---|---|
| SQLite | `the SQLite statement could not be executed: near "FROM": syntax error` |
| PostgreSQL (LibPQ and Postgres.jl) | `the PostgreSQL statement could not be executed (SQLSTATE 42601): syntax error at or near "FROM"` |
| MySQL | `the MySQL statement could not be executed (SQLSTATE 42000)` (a syntax error at the statement's prepare) |

No row was ever changed by such a call, before or now. A field the model fills itself on every update
(`auto_now = true`) is set whenever the rows do not bring it, so such a call keeps a `SET` list; an `auto_now` field
that is itself a key is matched, never set, like any key. A `filters=` lookup on a field (`"year__@in" => […]`) is a
predicate, not a key, and leaves that field in `SET` as before.

The refusal comes where the `SET` list is known, after the checks that come before it (the arguments, the table, the
keys and `filters=`), which raise what they raised. A call that left `SET` empty and also had a fault checked later
(a key cell whose value the field refuses, a statement over the backend's bind-parameter limit, a joined path in
`filters=`) now raises this refusal in place of that fault's error.

### How to find the calls to migrate

Look for a `catch` that expects a `StatementError` around `bulk_update`, for `bulk_update` calls whose `columns=` are
all keys, and for a dry run (`show_query = :sql`) of such a call that reads the returned statement:

```
grep -rn "bulk_update" --include=*.jl .
grep -rn "StatementError" --include=*.jl .
```

### Migrate your app

```julia
# ✗ before: every field in columns= was a key, and the server rejected the empty SET
# ✓ after: PormG refuses it first; name in columns= the fields to update
try
    PormG.bulk_update(M.Race.objects, rows; columns = ["year"], match_on = ["raceid"], filters = ["year" => 2008])
catch e
    e isa PormG.QueryBuildError || rethrow()
    # nothing to set: add the field to update, e.g. columns = ["round"]
end
```
