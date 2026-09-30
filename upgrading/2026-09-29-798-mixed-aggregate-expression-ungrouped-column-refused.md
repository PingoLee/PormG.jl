## An expression mixing a column with an aggregate now raises unless that column is grouped (#798)

- **Version**: Unreleased
- **PormG ref**: #798 ; `src/querybuilder/build_query.jl`, `src/querybuilder/types.jl`
- **Recorded**: 2026-09-29
- **Severity**: behavior change (narrow). The shape was wrong on SQLite and, but for one case, refused by PostgreSQL; it now raises at build time on both.

### What changed

An expression that mixes a plain column with an aggregate — `F("grid") - Avg("positionorder")`,
`Coalesce("grid", Max("points"))`, a `Case` whose condition reads a column while a branch aggregates,
or a window term such as `partition_by = [F("raceid__year") + Sum("points")]` — now raises
`QueryBuildError` unless the query already groups that column. The error names the projection, the
column, and where the column sits.

Such an expression is computed once per group, and nothing grouped the column inside it: the
expression was left out of `GROUP BY` whole, like a bare aggregate. The two backends then did
different things:

| before | after |
|---|---|
| PostgreSQL raised the driver's `GroupingError: column "Tb.grid" must appear in the GROUP BY clause or be used in an aggregate function`, at execution | PormG raises `QueryBuildError` naming the column, before any SQL is sent |
| SQLite **ran it**, taking the column from an arbitrary row of each group, and returned plausible-looking wrong numbers | the same `QueryBuildError`: the engines now agree |
| `.aggregate("x" => Coalesce("grid", Max("points")))`, with no `GROUP BY` at all, took one arbitrary row's `grid` for the whole table | refused too: it is the same shape with an empty group set |

A column grouped by any route satisfies the check: projected in `values(...)`, named in `order_by`,
or read by a window's plain `partition_by` / `order_by` term. A transform is grouped by its own path
or by its column (`F("dob__@year")` or `Concat("dob__@year", …)` is covered by `"dob__@year"` or
`"dob"`; `Joined("d", "dob__@year")` by the same handle or by `Joined("d", "dob")`), except inside a
filter condition, where only the column counts: the sargable rewrite renders `"dob__@year__@gt"` as
a comparison on `dob` itself.

One case is stricter than PostgreSQL, deliberately and as for #194: grouping by the table's
**primary key** alone does not cover another of its columns. PostgreSQL accepts it (functional
dependency), but PormG does not infer the dependency and refuses on both backends rather than let the
rule differ per engine. Relaxing that later would only widen what is accepted.

### Who this affects

- Apps on **SQLite** that project, or partition a window by, an expression mixing a column with an
  aggregate beside a `GROUP BY` that does not include that column. They were reading an arbitrary
  row's value per group.
- Apps on **PostgreSQL** only in the primary-key case above:
  `values("resultid", "x" => F("raceid") + Sum("points"))` ran there and now raises. Every other
  refused shape already failed on PostgreSQL, so for those only the error type and its timing change.

### How to find the calls to migrate

```bash
grep -rnE 'F\("[^"]+"\) *[-+*/] *(Sum|Count|Avg|Max|Min)\(|(Sum|Count|Avg|Max|Min)\([^)]*\) *[-+*/] *F\(' --include='*.jl' <your-app>/src
```

That finds the common arithmetic spelling; it misses an aggregate with a nested call in it
(`Sum(F("points") * 2) + F("raceid")`) and a bare string operand (`Sum("points") + "raceid"`). Also
check every `Coalesce`, `Greatest`, `Least` or `Case` in a
`values(...)` that holds an aggregate beside a plain column, and every window `partition_by` /
`order_by` term that holds an aggregate. The error message names each one at build time, so a test
run surfaces the rest.

### Migrate your app

Either aggregate the column, or project it so the query groups by it. The two answer different
questions: the second changes the grouping granularity.

```julia
# ✗ before — `grid` is one start's slot, but the query groups by driver
M.Result.objects.values("driverid__surname", "places_gained" => F("grid") - Avg("positionorder"))

# ✓ after — aggregate it: each driver's average grid slot minus their average finish
M.Result.objects.values("driverid__surname", "places_gained" => Avg("grid") - Avg("positionorder"))

# ✓ or project it: one row per driver and grid slot
M.Result.objects.values("driverid__surname", "grid", "places_gained" => F("grid") - Avg("positionorder"))
```
