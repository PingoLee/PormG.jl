## A CTE may not be named after a physical table, and a `cjoin_on` alias cannot take a generated alias (#479, #480)

- **Version**: 0.5.0
- **PormG ref**: #479, #480; `src/querybuilder/ctes.jl`, `src/querybuilder/build_helpers.jl`,
  `src/querybuilder/build_joins.jl`, `docs/src/read/custom_joins.md`,
  `docs/src/read/subqueries_and_ctes.md`
- **Recorded**: 2026-09-03
- **Severity**: **behavior change** - one shape that built now raises at the `.with()` call; one
  shape that built invalid SQL now renders, and one that built invalid SQL now raises. Part of the
  `0.5.x` pre-publish wave.

**Measured before adopting these**: `cjoin_on`, `.cjoin(`, `.on(` and `CTE(` have **zero** call
sites across `esus_back`, `PortalsusBack`, `LinkS`, `LinkSUS` and `work_server` (re-measured on
the current remotes). The one `.with(` in `esus_back` names its CTE `tab_ind`, which is not a table.

### What changed

**1. A CTE name may not be the `db_table` of any registered model, or a many-to-many join table (#479).** SQL keeps a
statement's CTE names and its table names in one namespace and the CTE wins - PostgreSQL's SELECT
reference: *"the WITH query hides any real table of the same name for the purposes of the primary
query"* - and PormG generates its joins unqualified from `db_table`. So a CTE named after a table
turned every generated join to that table into a read of the CTE. Before this change the two join
rows also collided in join de-duplication, so only **one** join was emitted, under the
ForeignKey's join type, and `CTE(name, col)` read the physical column:

```julia
best = M.Result.objects.values("driverid", "best" => Min("positionorder"))
q.with("driver" => best, join_field = "driverid" => "driverid", join_type = "INNER")   # "driver" is M.Driver's table
q.values("points", "who" => "driverid__surname", "career_best" => CTE("driver", "best"))
```

```sql
-- BEFORE (rendered on the F1 models): ONE join, the ForeignKey's, and SQL resolves it to the CTE
--         anyway - so "who" fails at execution (the CTE projects no surname) or, with other
--         columns, silently reads CTE rows. The CTE's own INNER was declared for nothing.
WITH "driver" AS (
  SELECT "Tb"."driverid" as "driverid", MIN("Tb"."positionorder") as "best"
  FROM "result" as "Tb" GROUP BY 1)
SELECT "R1"."points" as "points", "R1_1"."surname" as "who", "R1_1"."best" as "career_best"
FROM "result" as "R1"
 INNER JOIN "driver" AS "R1_1" ON "R1"."driverid" = "R1_1"."driverid"
-- AFTER:  QueryBuildError at the .with() call:
--         CTE name "driver" is the physical table of model driver (db_table "driver") ...
```

Emitting both joins was not an option: both `JOIN "driver"` would read the CTE, and the only
correct render would schema-qualify the physical table, which PormG cannot do (`db_table` is
unqualified on purpose, #59, and resolves through the search path). The check covers every
physical table PormG can render from the models it knows - every model in every module
`set_models` registered, and their many-to-many join tables - not only the ones the statement
joins: the joined set is only known at render, and a statement that never joins the table loses
nothing by picking another name.

**2. A `cjoin_on` alias no longer collides with a generated alias (#480).** The generated alias
`<base>_<n>` was chosen from the joins materialized so far, and a `cjoin_on` row is materialized
last, so `cjoin_on(alias = "R1_1")` next to a CTE or ForeignKey join produced two range variables
named `R1_1` - invalid on both engines. The generator now steps around every declared `cjoin_on`
alias, and an alias equal to the base relation's own (`"Tb"`, or `"R1"` once a CTE is declared)
raises `QueryBuildError` at render:

```sql
-- BEFORE: CROSS JOIN "evs" AS "R1_1"  INNER JOIN "driver" AS "R1_1" ON ("R1_1"."driverid" = ...)
-- AFTER:  CROSS JOIN "evs" AS "R1_2"  INNER JOIN "driver" AS "R1_1" ON ("R1_1"."driverid" = ...)
```

### How to find the calls to migrate

Item 1 raises where it used to build, so a run of your test suite finds it; to grep instead,
compare every CTE name against your models' `db_table` values:

```bash
rg -n '\.with\("' .
rg -n 'cjoin_on\(.*alias *= *"(Tb|R[0-9]+)(_[0-9]+)?"' .    # item 2: renders now, or raises for the base alias
```

### Migrate your app

```julia
# ✗ before - "driver" is the db_table of M.Driver
q.with("driver" => best, join_field = "driverid" => "driverid")
q.values("points", "career_best" => CTE("driver", "best"))

# ✓ after - any name that is not a table
q.with("best_by_driver" => best, join_field = "driverid" => "driverid")
q.values("points", "career_best" => CTE("best_by_driver", "best"))
```
