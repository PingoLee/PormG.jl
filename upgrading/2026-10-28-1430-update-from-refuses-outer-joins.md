## An `update()` that sets a column from a joined table refuses a `LEFT` or `FULL` join (#1430)

- **Version**: Unreleased
- **PormG ref**: #1430 ; `src/querybuilder/execution_write.jl` (`_get_join_condition_list`)
- **Recorded**: 2026-10-28
- **Severity**: behavior change, every engine. An `update()` whose `SET` reads a joined column, in a statement with a `LEFT` or `FULL` path join, used to run as if that join were `INNER`, which skipped the rows it had no match for. It now raises `QueryBuildError` when the query is built.

### What changed

An `update()` whose `SET` reads a joined column renders `UPDATE … FROM` (MySQL: the multi-table
`UPDATE`). That statement joins in its `WHERE` clause, so every join in it acts as an `INNER` join. A
row with no match was not updated, where a `LEFT` or `FULL` join keeps it and reads the joined column
as NULL. Nothing reported the difference: the update matched fewer rows than the filter selected.

The `LEFT` is usually not written by the caller. A path through a nullable `ForeignKey` is joined
`LEFT`, so `update("x" => F("<nullable_fk>__col"))` skipped every row whose key is NULL. A filter's join
is flattened the same way: `filter("<nullable_fk>__col__@isnull" => true)` beside a joined `SET` matched
no row at all.

Such an `update()` is now refused on every engine, whether `SET` reads the `LEFT` or `FULL` join or a
filter added it. #174 already refused it beside a `cjoin_on`; the rule now holds without one. The
`QueryBuildError` names the join and the two ways to say which rows are meant.

The rule covers every such join in the statement, so it also refuses calls that were already correct:
a filter that compares a value through a nullable path (`filter("<nullable_fk>__col" => "x")`) drops
the NULL rows itself, so the inner join changed nothing there. Those calls migrate to the `INNER`
spelling below, which updates the same rows.

A `RIGHT` join is not refused, and runs as before. The chain of joins starts at the target table, so a
`RIGHT` join adds only rows where the target is NULL, which no `UPDATE` writes. Run as an inner join, it
updates exactly the rows it describes.

| an `update()` that sets a column from a joined table, with … | before | now |
|---|---|---|
| a path through a nullable `ForeignKey`, in `SET` or in a filter | ran as an inner join | `QueryBuildError` (#1430) |
| `on(…; join_type = "LEFT" / "FULL")`, `ForeignKey(how = "LEFT" / "FULL")` | ran as an inner join | `QueryBuildError` (#1430) |
| only `INNER` and `RIGHT` joins (non-null keys, or `on(…; join_type = "INNER")`) | ran | runs, unchanged |

A joined `update()` on a query that declares a CTE (`with(…)`) renders `UPDATE … FROM` whatever its
`SET` holds, so the rule applies to it too. Any other `update()` that sets literal values, or reads only the
target's own columns, is not affected: it selects its rows through the primary key, with the joins as
written.

### Who this affects

Code that sets a column from a related table through a nullable foreign key, or through a join
declared `LEFT` or `FULL`, and an `update()` beside a `with(…)` whose filters cross a nullable key.

### How to find the calls to migrate

```bash
grep -rn -E 'update\(.*(F\("[a-z_]+__|Joined\()' --include=*.jl src/ test/
```

For each match, check whether any path in the statement (in `SET` or in a filter) crosses a nullable
`ForeignKey`, or a join declared `LEFT` or `FULL`. A multi-line `update(` needs its body read too.

### Migrate your app

Say which rows you mean. Here a driver's `teamid` is a nullable key:

```julia
# ✗ before — skipped the results whose driver has no team; now raises QueryBuildError (#1430)
M.Result.objects.filter("raceid" => 18).update("code" => F("driverid__teamid__name"))

# ✓ the same rows as before: declare the path INNER
q = M.Result.objects
q.on("driverid__teamid", join_type = "INNER")
q.filter("raceid" => 18)
q.update("code" => F("driverid__teamid__name"))

# ✓ every row, NULL where the driver has no team: set it from a correlated Subquery
team_name = Subquery(M.Driver.objects.filter("driverid" => OuterRef("driverid")).values("teamid__name"))
M.Result.objects.filter("raceid" => 18).update("code" => team_name)
```

The `INNER` spelling updates exactly the rows the old statement updated. The `Subquery` spelling is
the one the `LEFT` join meant.
