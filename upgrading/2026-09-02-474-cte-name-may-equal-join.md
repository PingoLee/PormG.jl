## A CTE name may equal a join key, `on()` no longer forces `LEFT`, and `join_type` is validated (#474)

- **Version**: 0.5.0
- **PormG ref**: #474 (withdraws the #447 half of the entry below; supersedes the #424 collision
  route); `src/querybuilder/build_joins.jl`, `src/querybuilder/build_helpers.jl`,
  `src/querybuilder/build_query.jl`, `src/querybuilder/ctes.jl`, `src/querybuilder/types.jl`,
  `docs/src/read/custom_joins.md`, `docs/src/read/subqueries_and_ctes.md`
- **Recorded**: 2026-09-02
- **Severity**: **behavior change** - two shapes that raised now build, one query shape changes its
  join type, and three that built now raise. Every one of the last three produced invalid SQL or
  silently wrong rows. Part of the `0.5.x` pre-publish wave.

**Measured before adopting these**: `cjoin_on`, `.cjoin(`, `.on(` and `.with(` have **zero** call
sites across `esus_back`, `PortalsusBack`, `LinkS`, `LinkSUS` and `work_server`.

### What changed

**1. A CTE name may equal a join key.** `_build_row_join` set its `join_path` to the first path
segment, which for a `CTE("b2", "sku")` reference *is* the CTE name - and then looked that name up
in the base model's join-config map and claimed it in the resolved-path set. So a `.with()` label
equal to a `cjoin` path, a `cjoin_on` alias or an `on()` path handed the CTE's join that entry's
join type and predicates, and suppressed your own join entirely. #447 refused the collision; #474
removes the lookup, which makes it unrepresentable:

```julia
q.with("b2" => grand_codes, join_field = "parent" => "id", join_type = "INNER")
q.cjoin_on("Parent", alias = "b2", on = [F("b2.sku") == F("note")])
q.values("note", "cte_code" => CTE("b2", "code"))
```

```sql
-- BEFORE #447: "parent" is never joined and "b2" names a relation the statement never declares.
-- WITH #447:   QueryBuildError, "rename one of the two".
-- AFTER #474:  both emitted. The CTE's alias is GENERATED, so only ONE relation is named "b2".
WITH "b2" AS (SELECT "Tb"."id", "Tb"."code" FROM "grand" AS "Tb")
SELECT "R1"."note", "R1_1"."code" AS "cte_code" FROM "child" AS "R1"
 INNER JOIN "b2" AS "R1_1" ON "R1"."parent" = "R1_1"."id"
 INNER JOIN "parent" AS "b2" ON ("b2"."sku" = "R1"."note")
```

The same split closes a **second** collision that #447's guard never covered, because it needed no
join at all. `instruct.cache` is keyed by a projection's output name, and #444 fixed a CTE
reference's at `"<cte>__<path>"` on purpose - byte-identical to the field path `"<fk>__<col>"`.
Whichever rendered first claimed the entry:

```julia
q.with("parent" => parent_cte, join_field = "parent" => "id")   # "parent" is also a ForeignKey
q.values("note", "c" => CTE("parent", "sku"))
q.filter("parent__sku" => "S")                                  # meant the ForeignKey
```

```sql
-- BEFORE: filters the CTE's column; the ForeignKey's join is emitted and never used.
... LEFT JOIN "parent" AS "R1_1" ... LEFT JOIN "cj_parent" AS "R1_2" ... WHERE "R1_1"."sku" = $1
-- AFTER:  filters the ForeignKey's column, matching the same query with no CTE declared.
...                                                              WHERE "R1_2"."product_sku" = $1
```

**2. `on()` no longer forces `LEFT` (#474).** With no `join_type` of its own, `on()` wrote
`"LEFT"`, and that value is read as an *override* - so adding a predicate to a `NOT NULL`
ForeignKey's join silently widened the result set:

```sql
-- BEFORE: q.values("note", "owner__sku")                     -> INNER JOIN "parent" ...
--         q.on("owner", "sku" => "S"); q.values(...)         -> LEFT  JOIN "parent" ... AND ...
-- AFTER:  both INNER. on() adds predicates; it does not retype the join.
```

The join now keeps what PormG derives for it - the field's own `how`, else `LEFT` for a nullable
ForeignKey and `INNER` for a `NOT NULL` one, including the LEFT-propagation a deep path needs. An
explicit `join_type` still wins and still persists for later `on()` calls on the same path.

**3. `join_type` is validated on every writer, and `"CROSS"` is refused (#474).** Every join renders
`<join_type> JOIN <table> AS <alias> ON <clause>`, so `"CROSS"` could only ever build
`CROSS JOIN ... ON ...`, which PostgreSQL and SQLite both reject. It was accepted by `cjoin`,
`cjoin_on` and `on()`, and never documented. Worse, `.with(..., join_type = ...)` was validated
**nowhere** - the string went verbatim into the JOIN keyword slot:

```julia
# BEFORE: rendered `LEFT OUTER JOIN grand AS injected ON 1=1 -- JOIN "gg" AS "R1_1" ON ...`
q.with("gg" => sub, join_field = "parent" => "id",
       join_type = "LEFT OUTER JOIN grand AS injected ON 1=1 --")
```

All four writers now raise `QueryBuildError` at the call for anything outside `"INNER"`, `"LEFT"`,
`"RIGHT"` and `"FULL"`.

### How to find the calls to migrate

Items 1 and 3 raise where they used to build (or vice versa), so a run of your test suite finds
them. Item 2 is the silent one - it changes rows, not shapes:

```bash
rg -n '\.on\(' .        # then check each call for an explicit join_type=
```

Any `on()` **without** `join_type` on a `NOT NULL` ForeignKey path was rendering `LEFT JOIN` and
will now render `INNER JOIN`. That is the join type the same path already had without the `on()`,
so the fix is almost always nothing; if you were relying on the wider result set, say so:

```julia
# Keep the old rows explicitly.
q.on("owner", "sku" => "S", join_type = "LEFT")
```

### Migrate your app

```julia
# CROSS: there is one supported cross product, and it is a CTE you REFERENCE.
# (Declaring it alone emits no join at all since #444 - you would get N rows, not N x M.
#  Since #492 either spelling references it: "all_drivers__surname" or CTE("all_drivers","surname").)
q.with("all_drivers" => M.Driver.objects.values("driverid", "surname"))   # unkeyed
q.values("points", "who" => CTE("all_drivers", "surname"))                # this is what joins it

# A CTE name colliding with a join key needed a rename under #447. It does not any more; if you
# renamed one to get past that error, the rename is no longer necessary (keeping it costs nothing).
```
