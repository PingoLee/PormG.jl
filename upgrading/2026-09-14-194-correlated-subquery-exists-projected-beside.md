## A correlated `Subquery`/`Exists` projected beside an aggregate now raises unless its correlation column is grouped (#194)

- **Version**: 0.6.0
- **PormG ref**: #194 ; `src/querybuilder/build_query.jl`, `src/querybuilder/build_helpers.jl`, `src/querybuilder/types.jl`
- **Recorded**: 2026-09-14
- **Severity**: behavior change (narrow) — a shape that was already wrong on SQLite and already refused by PostgreSQL now raises at build time on both. Part of the `0.6.x` pre-publish wave.

### What changed

Projecting a correlated `Subquery`/`Exists` in a query that **aggregates** now raises
`QueryBuildError` unless every outer column the inner `OuterRef`s reference is in the `GROUP BY`.
The error names the ungrouped column and the projection at fault.

This was never well-defined, and the two backends did different things with it:

| before | after |
|---|---|
| PostgreSQL raised the driver's own `GroupingError: subquery uses ungrouped column "Tb.driverid" from outer query`, at execution | PormG raises `QueryBuildError` naming the column, before any SQL is sent |
| SQLite **ran it**, evaluating the subquery against an arbitrary row of each group, and returned a plausible-looking wrong number | the same `QueryBuildError` — the engines now agree |
| a whole-table aggregate (`values("n" => Count(...), "s" => Subquery(...))`, no `GROUP BY` at all) got no warning at all, and the same divergence | refused too: it is the same shape with an empty group set |

The `@warn` that shipped with #92 — *"Subquery/Exists projected alongside a grouped aggregate…"* —
is **gone**. It fired on the legitimate grouped-correlation case as well, and said so; that false
positive is what this replaces.

Three shapes are deliberately left alone: a correlation column that reaches the `GROUP BY` only
through `order_by` (it is genuinely grouped), an `Exists` used in `filter(...)` rather than projected
(a `WHERE` predicate is evaluated before grouping), and any query with no outer aggregate at all.

One shape is newly refused that you may not expect: a **wildcard projection** —
`values("*", "n" => Count(...), "s" => Subquery(...))`. PormG sees `"Tb".*` as one opaque group
expression and cannot tell whether the expansion covers the correlated column, so it refuses rather
than guess. Measured on PostgreSQL 16, this one *did* work there: `GROUP BY 1` lands on the model's
primary key, and the functional dependency below then covers both the expansion and the correlation.
So this is the same deliberate strictness as the primary-key case, not a separate rule — name the
columns you want instead of `*`, and the query builds.

One case is stricter than both engines: PostgreSQL accepts correlating on *any* column of a table
whose **primary key** is grouped, since every column is then functionally dependent on it. PormG does
not infer that dependency and refuses the shape on both backends rather than let the rule differ per
engine. Adding the column to `values(...)` is the fix, and relaxing this later would only widen what
is accepted.

### Who this affects

Apps on **SQLite** that project a correlated `Subquery`/`Exists` alongside an aggregate. On
PostgreSQL the same queries already failed, so nothing that worked stops working — only the error
type and its timing change. An app that was relying on the SQLite result was reading a number taken
from one arbitrary row of each group.

### How to find the calls to migrate

PormG has been naming these since #92: grep your logs for the retired warning text.

```bash
grep -rn "Subquery/Exists projected alongside a grouped aggregate" <your-log-dir>
grep -rnE "values\(.*(Subquery|Exists)\(" <your-app>/src   # then check each for an aggregate beside it
```

### Migrate your app

Add the correlated column to `values(...)` so it joins the group set — note this changes the
grouping granularity, which is the point: the old query had no single correct answer.

```julia
standings = M.Driver_standings.objects
standings.filter("driverid" => OuterRef("driverid"))
standings.values("t" => Count("driverstandingsid"))

# ✗ before — groups by nationality, correlates on the ungrouped driverid
M.Driver.objects.values("nationality",
                        "n_drivers"   => Count("driverid"),
                        "n_standings" => Subquery(standings))

# ✓ after — group by what you correlate on
M.Driver.objects.values("driverid",
                        "n_drivers"   => Count("driverid"),
                        "n_standings" => Subquery(standings))

# ✓ or drop the outer aggregate: a scalar Subquery already returns one value per outer row
M.Driver.objects.values("nationality", "n_standings" => Subquery(standings))
```
