## `limit(0)` returns zero rows, and a negative or `Bool` `limit` / `offset` / `page` raises `QueryBuildError` (#1049)

- **Version**: Unreleased
- **PormG ref**: #1049 ; `src/querybuilder/object_manager.jl` (`_check_slice_value`, `_limit!`, `_offset!`, `_page!`, `page`), `src/querybuilder/execution_read.jl` (`_limit_offset_sql`), `src/querybuilder/types.jl` (`SQLObjectQuery.limit`)
- **Recorded**: 2026-10-08
- **Severity**: behavior change. `limit(0)` returns no rows where it returned every row, and a negative or `Bool` value raises at the call where it used to reach the database.

### What changed

`0` used to be PormG's internal "no limit" value, so `limit(0)` returned the whole table. In SQL,
`LIMIT 0` is zero rows, and so is Django's `qs[:0]`. PormG now agrees with both. "No limit" is
spelled `limit(nothing)`, or no `limit()` call at all.

A negative value or a `Bool` is refused for `limit()`, `offset()` and `page()`. The two engines read
the bound value differently, so the same call returned different results:

| call | before, PostgreSQL | before, SQLite | after, both |
|---|---|---|---|
| `limit(0)` | every row | every row | **no rows** |
| `limit(nothing)` | `QueryBuildError` (not accepted) | `QueryBuildError` (not accepted) | every row |
| `limit(-5)` | `StatementError` (SQLSTATE 2201W) | every row | `QueryBuildError` |
| `offset(-5)` | `StatementError` (SQLSTATE 2201X) | treated as 0 | `QueryBuildError` |
| `limit(true)` | `StatementError` (SQLSTATE 22P02) | one row | `QueryBuildError` |
| `page(20, -1)` | `StatementError` | treated as 0 | `QueryBuildError` |

The "before" columns were confirmed against both live test databases. A refused call changes
nothing on the handler: `page(10, -1)` does not leave a limit of 10 behind.

`offset(0)` is unchanged and still means no offset, which is what `OFFSET 0` means in SQL too.

This also corrects one line of the #46 entry in the same release: `limit(Int32(0))` returns zero
rows, the same as `limit(0)`.

### Who this affects

- Code that passes a page size which can be `0` and expects every row back.
- Code that passes a negative offset, or a page number that can go negative, and relies on the
  database error. The error is now a `QueryBuildError`, raised before any SQL is sent.
- Code that reads `query.object.limit` and compares it to `0`. An unset limit is now `nothing`.

A page size clamped to at least 1, or a constant, never reaches `limit(0)`. An offset computed from
a page number that is not checked for a negative value already failed on PostgreSQL with a
`StatementError`, and now fails with a `QueryBuildError`; check any code that catches the old type.

### How to find the calls to migrate

```bash
grep -rnE '\.(limit|offset|page)\(|[^a-z_]page\(|\.object\.limit' --include=*.jl src/ test/
```

For each hit, check whether the size can be `0`, and whether a page number can go below its first
page.

### Migrate your app

```julia
# ✗ before: 0 meant "no limit"
n = all_rows ? 0 : page_size
rows = M.Driver.objects.order_by("surname").limit(n).list()

# ✓ after: nothing is "no limit"; 0 is zero rows
n = all_rows ? nothing : page_size
rows = M.Driver.objects.order_by("surname").limit(n).list()
```

```julia
# ✗ before: a page below 1 became a negative offset and failed in the database
q.page(page_size, (page - 1) * page_size)

# ✓ after: validate the input; a negative offset is refused before any SQL
page >= 1 || return bad_request("page must be ≥ 1")
q.page(page_size, (page - 1) * page_size)
```

```julia
# ✗ before
query.object.limit == 0        # "no limit set"

# ✓ after
query.object.limit === nothing
```
