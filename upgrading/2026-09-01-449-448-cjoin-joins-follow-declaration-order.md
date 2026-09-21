## `cjoin_on` joins follow declaration order, and two silent-wrong-result shapes are refused (#449, #448)

- **Version**: 0.5.0
- **PormG ref**: #449, #448 (#447 withdrawn by #474); `src/querybuilder/types.jl`, `src/querybuilder/build_query.jl`,
  `docs/src/read/custom_joins.md`, `docs/src/read/subqueries_and_ctes.md`
- **Recorded**: 2026-09-01
- **Severity**: **behavior change** — one ordering semantic changes, and three shapes that
  previously built a query now raise at query-build time. Every one of them produced wrong results or invalid
  SQL, so nothing that was working stops working. Part of the `0.5.x` pre-publish wave.

**Measured before adopting these**: `cjoin_on`, `.cjoin(`, `.on(` and `.with(` have **zero** call
sites across `esus_back`, `PortalsusBack`, `LinkS`, `LinkSUS` and `work_server`. The whole
custom-join / CTE surface has no consumer yet, which is why refusing these shapes outright was
preferred over warning about them.

### What changed

**1. Emission order is declaration order (#449).** `custom_join` was an unordered `Dict`, and
`build()` materializes joins by iterating it — so which of two `cjoin_on` joins was emitted first
came from hashing the alias *strings*. A predicate is relocated onto the **last** join it names, so
that hash decided which join kept its `ON` clause and which was left bare:

```julia
# BEFORE: both declaration orders produced [b3, b2]. Reversing the declarations changed nothing;
#         renaming b2/b3 to aa/zz changed everything.
q.cjoin_on("Parent", alias = "b3", on = [F("b2.sku") == F("note")])
q.cjoin_on("Parent", alias = "b2", on = [F("b2.sku") == F("note")])
```

It is now an `OrderedDict`, matching `insert` on the same struct (ordered since #97). Joins are
emitted in the order you declare them, so *"declare the predicate on whichever join PormG emits
later"* is now a rule you can apply by reading your own code.

**2. An `ON` clause that never names its own alias is refused (#448).** PormG checked that the join
*had* an `ON` clause, never that the clause **constrained** it:

```sql
-- BEFORE: renders, and every "driver" row pairs with every matched base row. No error, no warning.
INNER JOIN "driver" AS "d" ON "Tb"."points" > ?
```

Two routes reached it: a predicate list naming the alias nowhere, and — worse — a predicate naming a
deep path that `values(...)` had already built, so nothing relocated and #435 never fired. That made
the *loud* outcome depend on projection order rather than on whether the join was constrained.

> This is stricter than SQLAlchemy, Ecto and jOOQ, which all emit an unconstrained join without
> complaint; Django sidesteps the question by not exposing an arbitrary `ON` clause at all. The
> departure is deliberate — a silently row-multiplied result set is the worst failure mode in the
> package, and a genuine cross product is still expressible (below).

**3. ~~A join key colliding with a CTE name is refused, for both CTE kinds (#447).~~ Withdrawn
before release - see *A CTE name may equal a join key* below.** This train briefly refused a
`.with()` label that equalled a `cjoin` path, a `cjoin_on` alias or an `on()` path. #474 removed the
cause rather than the shape: join resolution no longer looks a CTE hop up in the join-config map
under the CTE's own name, so the two names never meet and both relations are emitted. Nothing was
released under the refusal, so there is no migration for it - the shape simply works.

> **`join_field` was never a remedy for a name collision.** #424's message and the CTE docs used to
> suggest keying the CTE so it "emits a real `ON` clause"; that only moved the collision from
> #424's case to #447's. Since #474 there is no collision to remedy.

### How to find the calls to migrate

#449 and #448 both need a `cjoin_on`, so that is the only writer to grep for:

```bash
rg -n 'cjoin_on\(' .
```

For **#448**, check each `cjoin_on` for at least one predicate naming its own alias — `F("<alias>.…")`
on either side of a comparison:

```bash
rg -n --multiline 'cjoin_on\([^)]*alias\s*=\s*"(\w+)"' .   # then read each `on = [...]` for "\1."
```

For **#449**, nothing to grep: re-read any query declaring **two or more** `cjoin_on` joins and
confirm the intended emission order is the order they are written.

### Migrate your app

**#448 — give the join a predicate that names it, or declare the cross product explicitly:**

```julia
# ✗ BEFORE — renders an unconstrained join; every driver against every matched result
q.cjoin_on("Driver", alias = "d", on = ["points__@gt" => 10])

# ✓ AFTER — correlate the join, and put the base-side condition where it belongs
q.cjoin_on("Driver", alias = "d", on = [F("d.driverid") == F("driverid")])
q.filter("points__@gt" => 10)

# ✓ AFTER — if the cross product was genuinely intended, say so. NOTE the reference: since #444 a
#   CTE is joined only when one of its COLUMNS is referenced, so `.with(...)` on its own emits no
#   join at all and you would get N rows instead of N×M. Since #492 the reference may be written
#   either way — `"all_drivers__surname"` or the handle below.
q.with("all_drivers" => M.Driver.objects.values("driverid", "surname"))   # unkeyed => CROSS JOIN
q.values("points", "who" => CTE("all_drivers", "surname"))                # <- this is what joins it
q.filter("points__@gt" => 10)
```

That renders a real `CROSS JOIN` and emits the #44 Cartesian warning on every execution — the intent
is then visible both in the SQL and in the log.

**#449 — no code change is required**, but if you relied on the previous order, declare the joins in
the order you want them emitted:

```julia
# ✓ the predicate references d1, which is declared FIRST, so it points backwards and nothing moves
q.cjoin_on("Driver", alias = "d1", on = [F("d1.driverid") == F("driverid")])
q.cjoin_on("Driver", alias = "d2", on = [F("d2.surname") == F("d1.surname")])
```
