## A `Qor` arm or `__@isnull => true` across a reverse or ManyToMany relation joins `LEFT`, so it matches the parent with no child (#1367)

- **Version**: Unreleased
- **PormG ref**: #1367 ; `src/querybuilder/build_joins.jl` (`_promote_outer_joins!`), `src/querybuilder/build_filter.jl`, `src/querybuilder/filter_nodes.jl`
- **Recorded**: 2026-10-26
- **Severity**: bug fix that changes a value. Two filter shapes across a reverse relation over a `NOT NULL` foreign key, or across any ManyToMany relation, now return the parents that have no row across it, where they silently returned none. `delete()`, `update()` and `exists()` with those filters reach the same parents. A `select_for_update()` without `of` beside them now raises (see below).

### What changed

A filter path that crosses a **reverse** relation took its join type from the child's foreign key: a
`NOT NULL` key gave an `INNER JOIN`. A **ManyToMany** hop was `INNER` whatever the key. An `INNER`
join drops every parent with no row across the relation before the `WHERE` clause runs, which is wrong
for two shapes that are meant to match such a parent:

- **`__@isnull => true` through the relation** (the anti-join): it matched no parent at all;
- **a `Qor` arm across the relation**, beside an arm the parent can match on its own columns: the
  parent with no child was dropped before the OR was evaluated.

Now a reverse or ManyToMany hop that one of those two reaches is joined `LEFT`, and so is every hop
after it on the same path (a forward hop past it included). A `Qor` nested in a `Q` counts, and so does
a `Qor` inside a `When` in the filter. When the query also projects the path, the projection then
returns the parent with no child too, with a missing value in that column. Measured on the F1 fixture
(SQLite), where pit stops are recorded from 2011 on:

| `M.Race.objects.filter("year__@in" => [2010, 2011], …).values("raceid").distinct()` | before | now |
|---|---|---|
| `"pit_stops__stop__@isnull" => true` | 0 races | 19 (every 2010 race) |
| `Qor("round" => 1, "pit_stops__stop__@gte" => 4)` | 10 races | 11 (adds the 2010 opener) |

What does **not** change:

- a plain filter across the relation (`"pit_stops__stop__@gte" => 4`, `__@isnull => false`) keeps its
  `INNER JOIN`: it matches only parents that have the row, so its plan stays as it was;
- a reverse relation over a nullable foreign key was already `LEFT`;
- a join type stated with `on(path, join_type = …)` is kept as stated, on a hop after the promoted one
  too: `on("pit_stops__driverid", join_type = "INNER")` drops the race with no pit stop again;
- a `Qor` or a `When` inside `values()`, which filters no row, `having`, and joins rooted at a CTE.

A `select_for_update()` without `of` beside one of these filters now raises the `QueryBuildError` any
`LEFT JOIN` gets there (#1106), on every engine: PostgreSQL cannot lock the nullable side of an outer
join. `of = ("self",)` locks the base rows alone.

### Who this affects

Code that filters with `__@isnull => true` through a reverse relation (the accessor of a model whose
foreign key points at this one) over a `NOT NULL` key, or through a ManyToMany field; or that puts such
a path in one arm of a `Qor`. Reads return more rows. **A `delete()` or `update()` with such a filter
now reaches the parents with no child too**, so it deletes or updates rows it used to skip; review
those calls before upgrading. Tests that pin the SQL of such a query see `LEFT JOIN` where they saw
`INNER JOIN`.

### How to find the calls to migrate

```bash
grep -rnE '__@isnull"\s*=>\s*true' --include=*.jl src/ test/
grep -rnE 'Qor\(' --include=*.jl src/ test/
```

For each match, check whether the path's first segment (or any segment before the column) is a
reverse accessor (a model's lowercase name, or a `related_name`) or a `ManyToManyField`. Those
filters now match the parents with no row there.

### Migrate your app

```julia
# ✗ before: the anti-join matched nothing
M.Race.objects.filter("year__@in" => [2010, 2011], "pit_stops__stop__@isnull" => true).
    values("raceid").distinct().list()        # 0 rows

# ✓ after: the races with no recorded pit stop
M.Race.objects.filter("year__@in" => [2010, 2011], "pit_stops__stop__@isnull" => true).
    values("raceid").distinct().list()        # 19 rows
```

Code that relied on the old result (a `Qor` arm that was in effect required to match) states it
explicitly: put the arm in the `AND` part of the filter, or pass `on("pit_stops", join_type = "INNER")`.
Code that worked around the defect with an explicit subquery (`"raceid__@in" => …`) can keep it; the
two spellings now return the same rows.
