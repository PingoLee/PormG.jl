## `on()` / `cjoin()` on a path crossing a `ManyToManyField` raises (#977)

- **Version**: Unreleased
- **PormG ref**: #977 ; `src/querybuilder/join_conditions.jl` (`_refuse_many_to_many_join_path`)
- **Recorded**: 2026-10-06
- **Severity**: breaking (narrow). An `on()` predicate or `join_type` on a path through a ManyToMany relation was dropped from the statement with no error. It now raises `QueryBuildError` when the query is built, on both engines.

### What changed

A ManyToMany hop joins through a link table, in two joins that never read the `on()` entry for their
path. So the predicate and the join type were simply missing from the SQL, whether or not the query
projected the path. With a driver model that declares `sponsors = Models.ManyToManyField(Sponsor)`:

| query | before | after |
|---|---|---|
| `Driver.objects.on("sponsors", "name" => "X").values("driverid", "sponsors__name")` | `INNER JOIN` the link table and the sponsor table, with no `name` predicate anywhere | raises `QueryBuildError` |
| `Result.objects.on("driverid__sponsors", "name" => "X").values("resultid")` | no sponsor join and no predicate | raises `QueryBuildError` |

Paths that cross no ManyToMany relation are not affected, and neither is `cjoin_on(...)`.

### Who this affects

Apps with an `on()` on a ManyToMany path. Measured on 2026-10-06: **0** call sites in the consuming
apps, which make no `on()` or `cjoin()` calls at all.

### How to find the calls to migrate

Run the app's tests. Every remaining call raises with this message:

```
crosses the ManyToMany relation
```

### Migrate your app

Put the predicate in `.filter(...)`. That is a `WHERE` predicate, so it restricts the rows — which the
dropped `on()` never did. Where the unrestricted result was the one you relied on, delete the `on()`
call instead: it never contributed to the statement.

```julia
# Driver declares sponsors = Models.ManyToManyField(Sponsor)

# before: the predicate never reached the SQL
Driver.objects.
    on("sponsors", "name" => "X").
    values("driverid", "sponsors__name")

# after
Driver.objects.
    filter("sponsors__name" => "X").
    values("driverid", "sponsors__name")
```
