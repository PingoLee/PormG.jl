## Arithmetic over a `Case` whose value is a duration is an interval: refused on SQLite, typed on PostgreSQL (#1301, #1311)

- **Version**: Unreleased
- **PormG ref**: #1301, #1311 ; `src/querybuilder/expression_kind.jl` (`_render_side_kind`), `src/querybuilder/expression_render.jl` (`_render_interval_left`, `_projected_unordered_interval`), `src/querybuilder/projection_types.jl` (`_render_interval_alias_predicate`)
- **Recorded**: 2026-10-20
- **Severity**: behavior change, both engines. On SQLite the expression raises `QueryBuildError` when the query is built, where it returned a wrong number with no error, and so does ordering any interval with no millisecond form (`Case`, `Lag`, `NullIf` over a duration): against a duration inside `F` or `When`, with an ordering filter on its alias, or with `order_by` on its alias, where each compared or sorted text (#1311). On PostgreSQL a comparison of such a `Case` builds where it raised, and the SQL and its value are unchanged, but the result now has a type: a filter on its alias checks and binds a duration, and a pattern lookup or a `Concat` over it raises where it built.

### What changed

A `Case` with no `output_field` whose branches are durations, or a function over one (`Sum`, `Max`,
`Coalesce`, `Greatest`, …), used as either side of arithmetic (`* 2`, `F("lap") * …`, `/ 2`,
`+ F("time")`, `F("date") + …`), was not typed as an interval. On SQLite a
duration is stored as its `HH:MM:SS` text, so SQLite computed the arithmetic on the text:
`'00:01:30' * 2` is `0`. PormG computes an interval in milliseconds on SQLite only when it has a
millisecond form: a `DurationField` column, a timestamp difference, `Max`/`Min`/`Sum`/`Avg` and
`Greatest`/`Least`/`Coalesce` over those (#881, #894, #900). A `Case` over durations has none.

PormG now types that side as an interval. On SQLite it is refused as an interval with no millisecond
form, as a window function over a duration already was. On PostgreSQL the arithmetic is the
`interval * bigint` it always computed, and it still reads back as a `Dates.CompoundPeriod`. What
changes there is that the result is typed as an interval, so the rules for a duration apply to it, as
they apply to a `DurationField` and to other duration arithmetic (#1034):
- a filter on its alias binds the duration as its text (`"01:00:00"`, not `Hour(1)`), and a value
  that is not a duration raises `InvalidValueError`;
- a pattern lookup on its alias (`@startswith`, …) raises `FilterError` (#1183);
- `Concat` over it raises `QueryBuildError` (#1028).

A date shifted by such a `Case` is a timestamp on PostgreSQL and is refused on SQLite.

Compared inside an expression (`F`, `When`), such a `Case` was refused on both engines, since a
duration compares only against an interval. It is an interval now, so the comparison builds on
PostgreSQL. On SQLite an ORDERING comparison (`<`, `>`, `<=`, `>=`) of any interval with no
millisecond form is refused: it would compare the `HH:MM:SS` text, which is the duration's order only
below 100 hours and for non-negative values. That covers `Lag` and `NullIf` over a duration too.
They were typed as intervals already and compared their text, silently. `==` still compares the
text, as for a `DurationField` column.

The same holds for their ALIAS (#1311): with `values("d" => …)`, an ordering filter on `d`
(`d__@gt`, `@gte`, `@lt`, `@lte`, `@range`, in `filter`, `Q` or a `When` condition), an
`order_by("d")`, or a labelled order term of the expression (`order_by(SQLOrder(SQLField(dc, "d")))`)
compared or sorted the text, so the rule depended on how the query was spelled. All are refused on
SQLite now. `"d" => …` and `"d__@in" => …` still compare the text. To order or filter
such a value on SQLite, project it in a CTE and use the CTE's column, which SQLite reads in
milliseconds (#1285).

Examples on `Lap_times`, where `time` is a `DurationField` and `dc` is
`Case(When("lap" => 1, then = F("time")), default = F("time"))`:

| expression | engine | before | now |
|---|---|---|---|
| `values("d" => dc * 2)` | SQLite | built; read `0` for a `00:01:30` lap | raises `QueryBuildError` |
| `values("d" => Sum(dc) * 2)`, `Max(dc) * 2`, `Coalesce("time", dc) * 2`, `F("lap") * dc` | SQLite | built; a wrong number | raises `QueryBuildError` |
| `values("d" => F("raceid__date") + dc)` | SQLite | raised (a value PormG cannot type) | raises `QueryBuildError` (an interval with no millisecond form) |
| `filter(dc > Hour(1))`, `When(dc > Hour(1); then = 1)` | SQLite | raised (a duration compares only against an interval) | raises `QueryBuildError` (an interval with no millisecond form) |
| `filter(dc > Hour(1))`, `When(dc > Hour(1); then = 1)` | PostgreSQL | raised (a duration compares only against an interval) | builds |
| `When(Lag("time", over = …) > Hour(1); then = 1)`, `filter(NullIf("time", F("time")) > Hour(1))` | SQLite | built; compared the text | raises `QueryBuildError` |
| `values("d" => dc)`, `filter("d__@gt" => Hour(1))`; also `NullIf("time", F("time"))`, `Max(dc)` | SQLite | built; compared the text | raises `QueryBuildError` (#1311) |
| `values("d" => dc)`, `filter("d__@gt" => 5)` | SQLite | raised `InvalidValueError` (not a duration) | raises `QueryBuildError` (#1311) |
| `values("d" => dc)` or `Lag("time", over = …)` or `NullIf("time", F("time"))`, then `order_by("d")` | SQLite | built; sorted the text | raises `QueryBuildError` (#1311) |
| `values("d" => dc)`, `filter("d" => Hour(1))` or `filter("d__@in" => […])` | SQLite | built; compared the text | unchanged |
| `filter(dc == Hour(1))` | both | raised (a duration compares only against an interval) | builds; SQLite compares the stored text, as for a `DurationField` |
| `filter(dc > 5)` | both | built; PostgreSQL failed when the query ran, SQLite compared silently | raises `InvalidValueError` (not a duration) |
| `values("d" => dc * 2)` | PostgreSQL | built; a `Dates.CompoundPeriod` | unchanged |
| `values("d" => dc * 2)`, `filter("d__@gt" => 5)` | PostgreSQL | built; the query failed when it ran | raises `InvalidValueError` |
| `values("d" => dc * 2)`, `filter("d__@startswith" => "0")` | PostgreSQL | built; the query failed when it ran | raises `FilterError` |
| `values("d" => Concat(Value("-"), dc * 2))` | PostgreSQL | built; PostgreSQL's own interval text | raises `QueryBuildError` (#1028) |

Unchanged: a `Case` with arithmetic inside its branches, `Max`/`Min`/`Sum`/`Avg` of a
`DurationField`, and `Lag`/`NullIf` over a duration, which were typed already.

### Who this affects

Code that does arithmetic on a `Case` (or a function over one) whose branches are durations. On SQLite
that code returned wrong numbers. On PostgreSQL, code that filters such an alias with a value that is
not a duration or with a pattern lookup, or that puts the result in `Concat`. On SQLite, code that
orders a `Case` over durations, a `Lag` or a `NullIf` over a duration against a duration inside `F`
or `When` (`>`, `<`, `>=`, `<=`), or that projects one and then filters its alias with an ordering
lookup or passes the alias to `order_by` (#1311).

### How to find the calls to migrate

```bash
grep -rnE 'Case\(.*\)\s*[-+*/]' --include=*.jl src/ test/
grep -rnE '[-+*/]\s*Case\(' --include=*.jl src/ test/
# #1311: projections of a Case, Lag or NullIf whose alias may be ordered or filtered
grep -rnE '=>\s*([A-Za-z_.]+\.)?(Case|Lag|NullIf|Max|Min|Coalesce)\(' --include=*.jl src/ test/
```

For each projection match whose value is a `Case`, `NullIf` or `Lag` over a duration (or a function
over one, such as `Max(Case(…))`), check whether the same query passes its alias to `order_by` or
filters it with `__@gt`, `__@gte`, `__@lt`, `__@lte` or `__@range`.

For each match, check whether the `Case`'s branches are durations: a `DurationField`, interval
arithmetic or a timestamp difference.

### Migrate your app

```julia
# ✗ before — on SQLite this read 0 for every row; now it raises QueryBuildError there
q = M.Lap_times.objects
q.values("d" => Case(When("lap" => 1, then = F("time")), default = F("time")) * 2)

# ✓ after — the arithmetic inside each branch, which both engines compute
q = M.Lap_times.objects
q.values("d" => Case(When("lap" => 1, then = F("time") * 2), default = F("time") * 2))

# ✗ before (#1311) — on SQLite this sorted each driver's total by its HH:MM:SS text, so 100 h came
# before 99 h; now it raises QueryBuildError there
totals = M.Lap_times.objects
totals.values("driverid", "t" => Case(When("driverid__@gt" => 0, then = Sum("time")), default = Sum("time")))
totals.order_by("-t")

# ✓ after — the same value as a CTE column, which SQLite orders by its milliseconds
body = M.Lap_times.objects
body.values("driverid", "t" => Case(When("driverid__@gt" => 0, then = Sum("time")), default = Sum("time")))
q = M.Driver.objects
q.with("c" => body, join_field = "driverid" => "driverid", join_type = "INNER")
q.values("driverid", "c__t")
q.order_by("-c__t")
```
