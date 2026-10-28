## `distinct().count()` and `distinct().offset(n).exists()` across a to-many filter count each row once (#1359)

- **Version**: 0.9.0
- **PormG ref**: #1359 ; `src/querybuilder/execution_read.jl` (`_count`, `_exists_projection`), `src/querybuilder/filter_nodes.jl` (`_build_exists_query`)
- **Recorded**: 2026-10-25
- **Severity**: bug fix that changes a value. An unprojected `distinct().count()` across a to-many filter returns the number of matching rows, where it returned the number of (row, related row) pairs, and `distinct().offset(n).exists()`, or `Exists(...)` over such a query, skips `n` of those rows, where it skipped `n` pairs. Every other count and existence probe is unchanged.

### What changed

An unprojected `distinct().count()` counted the rows of `SELECT DISTINCT *`. Across a join, `*` also
takes the joined table's columns, so across a to-many filter no two rows were duplicates and the
count was one per pair. The derived table now selects the model's own columns, as Django's
`distinct()` does:

```sql
SELECT COUNT(*) FROM (SELECT DISTINCT * FROM "driver" as "Tb" INNER JOIN "result" AS "Tb_1" …)       -- before
SELECT COUNT(*) FROM (SELECT DISTINCT "Tb".* FROM "driver" as "Tb" INNER JOIN "result" AS "Tb_1" …)  -- now
```

Measured on the F1 fixture, PostgreSQL and SQLite alike:

| call | before | now |
|---|---|---|
| `M.Driver.objects.filter("result__grid" => 1).distinct().count()` | 1136 (the results with `grid = 1`) | 110 (the drivers with one) |
| `M.Driver.objects.filter("result__grid" => 1).distinct().offset(110).exists()` | `true` (a 111th pair exists) | `false` (there is no 111th driver) |

`Exists(...)` over the same query gives the same answer as `exists()`. Without an offset either only asks
whether any row matches, so it is unchanged.

A `distinct()` with a `values()` projection already counted the projected rows (#1066) and is
unchanged. So is a filter across a to-one join (`M.Result.objects.filter("driverid__surname" => "Senna")`),
which never repeated a row.

### Who this affects

Code that calls `distinct().count()`, `count(distinct = true)` or `distinct().offset(n).exists()`, or
wraps such a query in `Exists(...)`, with no `values()` projection, on a query filtered or joined
through a reverse relation or a many-to-many.

### How to find the calls to migrate

```bash
grep -rnE 'distinct\(\)\.(count|offset)\(|count\(distinct *= *true' --include=*.jl src/ test/
```

For each match without a `values(...)` on the same query, check whether a filter path goes through a
reverse relation (a related model's name, such as `result__…` on `Driver`).

### Migrate your app

```julia
# ✗ before — one per (driver, pole result) pair
n = M.Driver.objects.filter("result__grid" => 1).distinct().count()   # 1136

# ✓ after — the same call counts the drivers
n = M.Driver.objects.filter("result__grid" => 1).distinct().count()   # 110
```

Code that relied on the pair count should count the related model instead:
`M.Result.objects.filter("grid" => 1).count()`.
