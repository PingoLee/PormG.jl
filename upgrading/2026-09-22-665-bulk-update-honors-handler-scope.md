## `bulk_update` keeps the handler's filters and no longer modifies the handler (#665)

- **Version**: Unreleased
- **Recorded**: 2026-09-22
- **PormG ref**: #665; `src/querybuilder/execution_bulk.jl` (`_bulk_update`), `src/querybuilder/execution.jl` (`_reject_unsafe_mutation_shape`)
- **Severity**: breaking — a filtered handler now narrows the update, and some handler shapes now raise

### What changed

`bulk_update(q, df; …)` used to clear every filter attached to `q` and build its `WHERE` from
`match_on=` and `filters=` alone. It did that **in place**, so afterwards `q` carried the call's
`filters=` instead of its own scope. Three things change:

1. **The handler's filters are kept.** They are AND'd with the `match_on=` merge condition and the
   `filters=` predicates — the Django shape (`queryset.filter(pk__in=…).update(…)`), and what
   `update()` and `delete()` already did. A handler scoped to one season now updates only that
   season's rows; before, it updated matching rows of every season. A `DataFrame` row whose key
   falls outside the scope now matches nothing.
2. **The handler is never modified.** The statement is built from a private copy. A later
   `q.list()`, `q.count()` or `q.update()` sees the scope you built, not the call's `filters=`.
3. **Handler state an `UPDATE` cannot express raises `UnsafeMutationError`** instead of being
   ignored: `limit()`, `offset()`, `order_by()`, `distinct()`, an aggregate annotation, a CTE
   (`.with`), or a `cjoin` / `on` / `cjoin_on` join. The first three sets are `update()`'s guards,
   now shared. A plain `values()` projection is ignored. A handler filter
   that traverses a relation raises `QueryBuildError`, like a joined column.

Measured before the change: 3 of the 101 `bulk_update(` calls in the consuming apps passed a
filtered handler, and one of those relied on the handler filter for its scope — which was being
dropped. No production call passed a handler carrying the shapes in (3); one scratch script passed
a paged (`page()`) handler, which now raises.

### How to find the calls to migrate

List every call, then check where its first argument was built:

```bash
grep -rn 'bulk_update(' --include=*.jl .
```

A call needs attention when that handler had `.filter(…)`, `.limit(…)`, `.offset(…)`, `.page(…)`,
`.order_by(…)`, `.distinct()`, `.with(…)` or a `cjoin` applied before the call — or when the same
variable is read again after the call and the code expected it to carry `filters=`.

At runtime the new refusal reads:

```
Cannot call bulk_update() on a query that has limit(), offset(), or order_by() set. …
```

### Migrate your app

```julia
# Before: the season filter on `q` was silently discarded; every matching id was updated
season_1988 = M.Race.objects.filter("year" => 1988).values("raceid")
q = M.Result.objects.filter("raceid__@in" => season_1988)
bulk_update(q, df, columns = ["points"], match_on = ["resultid"])

# After: the same call now updates 1988 rows only. If you relied on the old
# every-row behavior, pass a fresh handler:
bulk_update(M.Result.objects, df, columns = ["points"], match_on = ["resultid"])
```

```julia
# Before: a paged/ordered handler was accepted and its limit/order silently dropped
q = M.Result.objects.filter("raceid" => 1034).order_by("resultid")
bulk_update(q, df, columns = ["points"], match_on = ["resultid"])

# After: raises UnsafeMutationError. The DataFrame already names the rows, so drop
# the ordering/paging from the handler you pass:
bulk_update(M.Result.objects.filter("raceid" => 1034), df,
    columns = ["points"], match_on = ["resultid"])
```

```julia
# Before: code that read the handler after the call saw bulk_update's filters= on it
bulk_update(q, df, match_on = ["resultid"], filters = ["raceid" => 1034])
q.count()     # counted raceid = 1034, whatever q was scoped to

# After: q is untouched; apply the filter yourself if that was the intent
q.filter("raceid" => 1034).count()
```
