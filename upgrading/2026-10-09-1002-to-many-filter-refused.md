## `filter()` / `order_by()` across a to-many relation — refused unless the query asks for those rows (#1002)

- **Version**: Unreleased
- **PormG ref**: #1002 ; `src/querybuilder/build_query.jl` (`_check_join_cardinality`), `src/querybuilder/build_joins.jl` (`_record_join_reach!`), `src/querybuilder/execution_write.jl` (`_get_join_condition_list`)
- **Recorded**: 2026-10-09
- **Severity**: behavior change. A query whose filter or ordering crosses a reverse relation or a `ManyToManyField` used to return each base row once per related row, silently, and `count()` counted the repeats. It now raises at build time, unless the query projects that join, is `distinct()`, or only asks whether a row matches.

### What changed

A join PormG adds to *evaluate* something (a filter, an ordering, an `OuterRef` path, a `cjoin_on`
condition) must not repeat a base row. A to-many join is allowed where the caller asked for its rows:
a projection (`values`) or an `on()` / `cjoin` path that reaches the **same** join.

| query | before | after |
|---|---|---|
| `M.Constructor.objects.filter("result__positionorder" => 1).values("name")` | each constructor once per win | raises `FilterError` |
| the same, `.count()` | the number of wins | raises `FilterError` |
| `M.Driver.objects.order_by("-result__points").values("surname")` | each driver once per result | raises `QueryBuildError` |
| the filter above plus `.distinct()` | each constructor once | unchanged |
| the filter above with `values("name", "result__points")` | one row per win | unchanged: the projection asks for those rows |
| the filter inside `Exists(...)`, an `__@in` subquery, `exists()`, `update(...)` with literal values, or `delete()` | correct | unchanged |
| the same inside `exists()` / `Exists(...)` with an `offset()`, or an `__@in` subquery with a `limit()` | the repeats counted toward the slice | raises `FilterError` |
| a grouping or aggregating query (`values("nationality", "n" => Max("number"))`) | unchanged | unchanged: `Count`/`Sum`/`Avg` still meet the #74 fan-out guard |
| `update("x" => F("rel__col"))` whose `UPDATE … FROM` carries a to-many join | set from an arbitrary related row | raises `QueryBuildError` |
| a reverse `OneToOneField` (or a reverse `ForeignKey` declared `unique = true`) | counted as to-many by the fan-out guard | to-one: nothing repeats, so the guard no longer fires |

A `cjoin_on` condition crossing a reverse or many-to-many path was already refused (#992), and still
is; a reverse `OneToOneField` there is still refused, because its `INNER JOIN` can drop the base row. A
`cjoin(field = …)` link, or a `ForeignKey` `pk_field`, naming a column the target does not declare
unique now counts as to-many: an aggregate over it meets the fan-out guard, and a `cjoin_on`
condition through it is refused.

### Who this affects

A `filter()`, `Q(...)`, `Qor(...)` or `order_by()` key whose path crosses a reverse accessor or a
`ManyToManyField`, on a query that does not project that same path, is not `distinct()`, and does not
aggregate. Also an `update()` that sets a column from a joined table while a filter crosses a to-many
relation.

### How to find the calls to migrate

The error is raised when the query is built, so `show_query = :sql` or `inspect_query` finds it
without a database. Each call raises with a message containing:

```
PormG cardinality check (#1002)
```

To find them in source, list your models' reverse accessors (each `related_name`, or the lowercase
child model name) and `ManyToManyField` names, and search filter and ordering keys for them, e.g.
`grep -rnE '(filter|order_by|Q|Qor)\(.*"(result|sponsors)__' --include=*.jl .`.

### Migrate your app

Say what the filter means:

```julia
# ✗ before: each constructor once per winning result
query = M.Constructor.objects
query.filter("result__positionorder" => 1)
query.values("constructorid", "name")

# ✓ after: each constructor once, when it has a win — a correlated EXISTS, no join
query = M.Constructor.objects
query.filter(Exists(M.Result.objects.filter("constructorid" => OuterRef("constructorid"), "positionorder" => 1)))
query.values("constructorid", "name")

# ✓ or: keep the join and collapse the repeats
query.distinct()

# ✓ or, if one row per win is what you want: project the path
query.values("constructorid", "name", "result__points")
```

For an ordering, order by one value per base row computed in a correlated `Subquery(...)` over the
related rows (for example their `Max`).
