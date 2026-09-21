## An ON predicate that lands on a CROSS-joined CTE is refused instead of being dropped (#424)

- **Version**: 0.5.0
- **PormG ref**: #424 (landed with #421); `src/querybuilder/build_query.jl`,
  `docs/src/read/custom_joins.md`
- **Recorded**: 2026-08-25
- **Severity**: **behavior change (very narrow)** — two shapes that silently returned row-multiplied
  results now raise at query-build time. Part of the `0.5.x` pre-publish wave.

### What changed

A CTE declared **without** `join_field` is `CROSS JOIN`ed (#44), and a `CROSS JOIN` has no `ON`
clause. If an `ON` predicate resolved onto such a CTE, PormG dropped it — not reported, not logged,
dropped — and the join then matched every row:

```sql
-- BEFORE: the predicate against the CTE is simply gone.
INNER JOIN "cj_parent" AS "b2" ON ("b2"."sku" = "R1"."note")
CROSS JOIN "ev" AS "R1_1"
```

An unconstrained `CROSS JOIN` multiplies the base rows, so the query returned *more* rows than it
should have, each of them wrong. On SQLite the dropped predicate's bound value was left orphaned in
the parameter bucket, which sometimes surfaced as a placeholder-count error — but that was luck, not
a guard, and #421 (which makes a predicate's values travel with its text) removes even that accident.

**When does a CROSS-joined CTE acquire an ON predicate at all?** Exactly two ways, and it is worth
stating as a rule rather than a list of call shapes — an earlier draft of this entry listed the
shapes and missed half of them:

1. **Its NAME collides with a join key.** Joins are registered under a key, and three unrelated
   methods write one: `cjoin` uses its join **path**, `cjoin_on` uses its **alias**, and `on()` uses
   its **path**. If any of those equals an unkeyed CTE's name, the CTE's CROSS entry inherits that
   join's predicates. The collision does *not* have to involve a model field, and nothing has to be
   relocated.
2. **A predicate that names its alias is relocated onto it** — a `cjoin_on` whose `on` carries a
   bare `"ev__col" => v` path. Unlike a keyed `cjoin`, whose `filters` are path-prefixed onto the
   joined model and reject anything else, `cjoin_on`'s `on` expression is the entire `ON` clause, so
   it accepts such a path. This was always the documented boundary (*"Referencing a third table
   (another join's alias) inside one `cjoin_on` is also out of scope for now"*) — it simply was not
   enforced.

The most common way to hit (1) by accident *was* naming a CTE after a **model field**: join
resolution consulted the CTE registry *before* the model's fields, so `.with("parent" => …)` on a
model that has a `parent` foreign key shadowed that field's join entirely.

!!! note "Superseded within this same release train by #444"
    **Read the `CTE(name, path)` entry above before acting on this one.** #444 gave CTE columns
    their own namespace, and it lands in the same untagged train as this guard — so if you are
    upgrading across the whole train, three of the four routes into this error never existed as far
    as you are concerned:

    - the **model-field** collision is gone: a CTE and a field may share a name, and a `__` string
      path now always means the field (#431);
    - a `cjoin` path or an `on()` path colliding with a CTE name now simply resolves to the
      ForeignKey, which is what it always should have done;
    - a `cjoin_on` `on` list can no longer name a CTE at all — the string does not resolve to one,
      and a `CTE(...)` handle is refused with a `FilterError`.

    What still reaches this guard is the **`cjoin_on` alias** collision: `.with("d" => …)` unkeyed
    plus `cjoin_on(…, alias = "d", …)`. The message's mention of a shadowed field is history; the
    remedy for the surviving case is to rename the alias or key the CTE.

PormG now refuses both before building any SQL, naming the CTE and both remedies:

> `An ON predicate resolved onto R1_1, a CROSS-joined CTE (a .with(...) declared without
> join_field). A CROSS JOIN has no ON clause to carry that predicate, so it would be dropped and the
> join would match every row.`
> `  Two shapes reach this: a cjoin_on whose ON expression names a path through another join, and a
> .with("parent" => ...) whose name matches a model FIELD, which shadows that field's own join.`
> `  Fix whichever applies: rename the CTE so it does not shadow a field, give it a join_field so it
> emits a real ON clause, or move the predicate to .filter(...) (#44).`

### How to find the calls to migrate

Every affected query needs a `.with(...)` with **no** `join_field` — a keyed CTE emits a real `ON`
clause and carries its predicates correctly, then and now. So start by listing CTE declarations:

```bash
rg -n '\.with\(' .          # then check which of these do NOT pass `join_field` in the same call
```

Grep cannot take you further, because the defect is a **name collision**, not a syntax. Run this over
each query instead — it is the same rule the guard uses, and it catches the collision whether the
other side is a `cjoin` path, a `cjoin_on` alias, or an `on()` path:

```julia
# Any unkeyed CTE whose name collides with a model field or a registered join key.
for (name, cte) in q.object.ctes
    cte["join_field"] === nothing || continue          # keyed CTEs are unaffected
    # The field-shadowing arm is #444 history: from that change on, a CTE name may collide with a
    # model field harmlessly. Kept so this snippet still tells the truth when run against a PIN
    # PREDATING #444 — which is the only pin where it can report anything.
    if name in q.object.model.field_names
        @warn "CTE name shadows a model field (pre-#444 pins only)" cte = name
    elseif haskey(q.object.custom_join, name)
        @warn "CTE name collides with a cjoin/cjoin_on/on() key" cte = name
    end
    # NOTE (#474): the `cte["join_field"] === nothing || continue` above is correct again, and now
    # for good. #447 briefly refused this collision for BOTH CTE kinds; #474 withdrew that and
    # removed the cause, so on any post-#474 pin neither arm can report anything and this whole
    # snippet is pre-#444 archaeology.
end
```

The relocation route (2) is narrower and *is* greppable — a `cjoin_on` whose `on` list carries a
`__` path:

```bash
rg -n --multiline 'cjoin_on\([^)]*on\s*=\s*\[[^\]]*"\w+__\w+"\s*=>' .
```

### Migrate your app

**Shape B — rename the CTE (or key it).** The name collision is almost never intentional; the join it
shadows is usually the one you wanted:

```julia
# ✗ BEFORE — "parent" is both a CTE and a ForeignKey field. The CTE won, silently.
q.with("parent" => M.Cj_parent.objects.values("id", "sku"))
q.cjoin("parent" => "Cj_parent", filters = ["sku" => "S"], warn = false)

# ✓ AFTER — a name that shadows nothing; the FK path resolves as a normal join again.
q.with("parent_stats" => M.Cj_parent.objects.values("id", "sku"))
q.cjoin("parent" => "Cj_parent", filters = ["sku" => "S"], warn = false)
```

**Shape A — key the CTE, or move the predicate to `.filter(...)`.** Keying it is usually what you
want, because it is the only one of the two that actually *relates* the CTE to the base rows:

```julia
# ✗ BEFORE — "ev__year" resolves onto the CROSS-joined CTE, which cannot carry it. The predicate was
#            dropped and the join matched every row.
q = M.Result.objects
q.with("ev" => M.Race.objects.values("raceid", "year"))        # no join_field => CROSS JOIN
q.values("resultid")
q.cjoin_on("Driver", alias = "d",
           on = [F("d.driverid") == F("driverid"), "ev__year" => 2009])

# ✓ AFTER (preferred) — give the CTE a join_field. It emits a real ON clause, carries the predicate,
#   and relates each base row to its own CTE row instead of to all of them.
q = M.Result.objects
q.with("ev" => M.Race.objects.values("raceid", "year"), join_field = "raceid" => "raceid")
q.values("resultid")
q.cjoin_on("Driver", alias = "d", on = [F("d.driverid") == F("driverid")])
q.filter("ev__year" => 2009)
```

> ⚠️ Moving the predicate to `.filter(...)` **without** adding a `join_field` builds and runs, but it
> is a plain filter over a Cartesian product, not a correlation — every base row is still paired with
> every matching CTE row. A `CROSS JOIN`ed CTE is correlated by an `F()` comparison
> (`filter("raceid" => F("ev__raceid"))`, #44), never by a literal predicate. If you are not writing
> that comparison, you want `join_field`.
