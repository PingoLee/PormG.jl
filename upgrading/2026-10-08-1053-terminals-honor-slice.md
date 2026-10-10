## Read terminals honor a `limit()`/`offset()` slice, or refuse it (#1053)

- **Version**: Unreleased
- **PormG ref**: #1053 ; `src/querybuilder/execution_read.jl` (`_is_sliced`, `_probe_limit`, `_refuse_sliced`, `_count`, `_aggregate`, `_exists`, `first`, `last`, `_extreme`, `get`), `src/querybuilder/filter_nodes.jl` (`_build_exists_query`)
- **Recorded**: 2026-10-08
- **Severity**: behavior change. Five terminals return a different answer on a sliced query, and five more raise where they used to answer.

### What changed

A read terminal runs on a copy of the query, and each one used to replace the copy's limit with its
own, or clear it. After #1049 made `limit(0)` zero rows, `q.limit(0).list()` returned nothing while
`q.limit(0).exists()` said rows existed. The terminals now work inside the slice, the way Django's
do on `qs[:n]`: a terminal that needs `k` rows takes the smaller of `k` and the caller's limit, and
keeps the caller's offset. A terminal that cannot work inside a slice raises `QueryBuildError`
instead of ignoring it. For `last()`, `earliest()` and `latest()` that matches Django, which refuses
to reorder a slice. For `count("col")` and `aggregate()` it is a deliberate divergence (#1066): Django's
`aggregate()` computes over the slice through a derived table, and PormG refuses instead — aggregate
the query before slicing it.

| call | before | after |
|---|---|---|
| `q.limit(0).exists()` | `true` when any row matches | `false` |
| `q.limit(0).first()` | the first matching row | `nothing` |
| `q.limit(0).get()` | the matching row | `DoesNotExist` |
| `q.limit(5).count()` | every matching row | at most 5 (`COUNT(*)` over the sliced rows) |
| `q.offset(10).count()` | every matching row | the rows after the first 10 |
| `filter(Exists(sub.limit(0)))` | `sub`'s limit and offset reset | kept: always false |
| `q.limit(5).last()`, `.earliest(…)`, `.latest(…)` | a row, from a reordered slice | `QueryBuildError` |
| `q.limit(5).count("col")`, `.aggregate(…)` | computed over every matching row | `QueryBuildError` |

`first()` and `get()` already kept the caller's offset; only the limit changed. `get()` still
accepts inline filters on a sliced query, as `filter()` after `limit()` does.

### Who this affects

Code that calls one of the terminals above on a handler that already has `limit()`, `offset()` or
`page()` set. The usual case is a pagination handler that slices a query and then counts the same
handler for its total — that count is now the page size.

A total counted on a fresh query, or before the slice is applied, is unaffected.

### How to find the calls to migrate

```bash
grep -rnE '\.(limit|offset|page)\(|[^a-z_.]page\(' --include=*.jl src/ test/
```

For each hit, check whether the same handler later reaches `count`, `exists`, `first`, `last`,
`get`, `earliest`, `latest` or `aggregate`, or is passed to `Exists(...)`.

### Migrate your app

```julia
# ✗ before: count() ignored the slice, so it returned the total
q = M.Driver.objects.filter("nationality" => "British")
q.page(20, 40)
rows  = q.list()
total = q.count()

# ✓ after: count before slicing, or on a fresh query
q = M.Driver.objects.filter("nationality" => "British")
total = q.count()
q.page(20, 40)
rows  = q.list()
```

```julia
# ✗ before: last() ran on a reordered slice
newest = M.Race.objects.order_by("date").limit(10).last()

# ✓ after: take the row you mean without a slice, or read the slice and pick from it
newest = M.Race.objects.order_by("date").last()
rows   = M.Race.objects.order_by("date").limit(10).list()
tenth  = isempty(rows) ? nothing : rows[end]
```
