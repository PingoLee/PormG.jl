## CTE columns are referenced with `CTE(name, path)`, not with a `"<cte>__col"` string (#444)

> **Partially reversed by #492 — see *The `"<cte>__<col>"` string is back* in the current wave.**
> The namespace split below stands, and #431/#434 stay fixed. Only the *spelling* changed back: the
> `"<cte>__col"` string resolves again, and `CTE(name, path)` is now the disambiguator rather than
> the only form. Upgrading across both entries at once, you can skip the rewrite this one asks for —
> except where a `.with()` label collides with a model field, which #492 turns into a hard error.

- **Version**: 0.5.0
- **PormG ref**: #444 (supersedes #431, #434); `src/querybuilder/types.jl`,
  `src/querybuilder/object_manager.jl`, `src/querybuilder/build_helpers.jl`,
  `src/querybuilder/build_joins.jl`, `src/querybuilder/ctes.jl`, `src/querybuilder/functions.jl`,
  `docs/src/read/subqueries_and_ctes.md`
- **Recorded**: 2026-08-27
- **Severity**: **breaking** — every reference to a CTE column changes spelling. The old string form
  is deleted outright, not deprecated. It also FIXES two silent-wrong-result bugs (#431, #434) by
  making them unrepresentable. Part of the `0.5.x` pre-publish wave.

### What changed

A `.with()` CTE name and a model field path shared **one** `__`-separated string namespace, and join
resolution consulted the CTE registry **before** the model's own fields. So a CTE named after a model
field took that field's path over entirely:

```julia
q.with("parent" => parent_cte)   # "parent" is ALSO a ForeignKey of the model
q.values("note", "parent__sku")  # → the CTE's column. The ForeignKey's join is never emitted.
```

```sql
-- BEFORE: `cj_parent` is never joined; every base row is paired with every CTE row.
SELECT "R1"."note", "R1_1"."sku" as "parent__sku"
FROM "cj_child" as "R1"
 CROSS JOIN "parent" AS "R1_1"
```

No error. The only signal was the #44 Cartesian-product warning, which reports an uncorrelated
`CROSS JOIN` rather than a shadowed relation — it names the wrong problem (#431). The same shared
namespace made `on()`'s CTE refusal depend on declaration order: `.with()` then `.on()` was refused,
`.on()` then `.with()` was not (#434).

**CTE columns now have their own namespace.** `CTE(name, path)` is a reference object, alongside the
`F` / `OuterRef` / `Exists` / `Subquery` vocabulary PormG already uses for every other kind of
non-plain-column reference — the same choice SQLAlchemy (`cte.c.sku`), jOOQ (`t.field("a")`),
django-cte (`cte.col.field`) and peewee all make. A CTE may now legally share a name with a field,
and neither shadows the other:

```sql
-- AFTER: both joins are emitted, both references resolve, neither shadows the other.
SELECT "R1"."note", "R1_1"."product_sku" as "parent__sku", "R1_2"."sku" as "cte_sku"
FROM "cj_child" as "R1"
 LEFT JOIN "cj_parent" AS "R1_1" ON "R1"."parent" = "R1_1"."id"
 LEFT JOIN "parent"    AS "R1_2" ON "R1"."id"     = "R1_2"."id"
```

**The declaration is unchanged** — `.with("name" => subquery; join_field, join_type)` is exactly as
before, and `join_field`'s pair stays two plain strings (it is already scoped by the `.with()` it
sits in). Only the *reference* changes.

**Output column names are unchanged.** An unaliased projection joins the two halves with a DOUBLE
underscore, so `values(CTE("tb_dup","dias"))` still emits a column named `tb_dup__dias` and code that
reads results by name (`df[1, :tb_dup__dias]`) needs no edit.

Three further points, because the second argument is a **path**, not a bare column:

| shape | before | after |
|---|---|---|
| hop out of the CTE via a projected ForeignKey | `"ev__parent__sku"` | `CTE("ev", "parent__sku")` |
| operator / transform suffixes | `"ev__seen__@yyyy_mm__@lte"` | `CTE("ev", "seen__@yyyy_mm__@lte")` |
| JSON sub-path | `"ev__meta__driver"` | `CTE("ev", "meta__driver")` |

**Descending order.** A reference object cannot carry the string form's leading `-`, so ordering
direction is a keyword: `order_by(CTE("stats", "total_points"; desc = true))`. `desc = true` anywhere
other than `order_by` raises a `QueryBuildError`.

**Everything that accepted a `"<cte>__col"` string accepts the handle** — projections, filters,
ordering, scalar functions (`Lower`, `Cast`, …), aggregates (`Sum`, `Count`, …) and window
`PARTITION BY` / `ORDER BY`. The spelling changes; the surface does not shrink.

**One thing a CTE reference cannot do**, refused with a typed error rather than silently
mis-resolving: **it cannot appear in `on(...)`, `cjoin(...)` or `cjoin_on(...)`.** A JOIN's `ON`
clause targets the joined model; a CTE is joined by its own `.with()` declaration. That holds however
the reference is spelled, including as the operand of an `F` comparison
(`F("sku") == CTE("ev","sku")`). Put the predicate in `.filter(...)`. (This was already refused in
practice since #424, but as a name-collision message from a later stage.)

**No deprecated alias.** `"<cte>__col"` is gone, not kept for a train — retaining it would preserve
the ambiguous resolution branch that is the whole point of the change. A string path whose first
segment names a declared CTE now raises an `UnknownFieldError` naming the new spelling.

### How to find the calls to migrate

Grep for `.with(` to find every query that declares a CTE, then for the names it declares:

```bash
rg -n '\.with\(' .
```

Or programmatically — **run this against your CURRENT pin, before upgrading.** After upgrading it
can never fire, because every one of these references raises instead of building. It reports the
exact `CTE(...)` call to replace each string with, and flags the #431 shape (a CTE shadowing a model
field) separately, because those queries were returning **wrong rows** and their results should be
re-checked rather than merely re-spelled:

```julia
function cte_references(q)
    obj, out = q.object, String[]
    names = collect(keys(obj.ctes))
    isempty(names) && return out
    # Every place a reference path can hide: projections, filters, ordering.
    paths = String[]
    for v in obj.values
        v.field isa String && push!(paths, v.field)
    end
    for f in obj.filter
        f isa PormG.QueryBuilder.OperObject || continue
        c = f.column
        c isa PormG.QueryBuilder.SQLField && c._as isa String && push!(paths, c._as)
        f.values isa PormG.QueryBuilder.FExpression &&
            f.values.field_name isa String && push!(paths, f.values.field_name)
    end
    for o in obj.order
        o.field isa PormG.QueryBuilder.SQLField && o.field._as isa String && push!(paths, o.field._as)
    end
    for p in unique(paths), n in names
        startswith(p, n * "__") || continue
        rest = p[length(n)+3:end]
        push!(out, "\"$p\"  ->  CTE(\"$n\", \"$rest\")")
        n in obj.model.field_names &&
            push!(out, "  !! CTE \"$n\" SHADOWS the model field \"$n\" — this query returned wrong rows (#431); re-check its results, not just its spelling.")
    end
    return out
end

for line in cte_references(query); println(line); end
```

### Migrate your app

```julia
# ── projections ──────────────────────────────────────────────────────────────
# ✗ before
q.values("resultid", "tb_dup__dias")
q.values("max_points" => "high_scorers__max_points")
# ✓ after — the emitted column name is identical in both cases
q.values("resultid", CTE("tb_dup", "dias"))
q.values("max_points" => CTE("high_scorers", "max_points"))

# ── filters ──────────────────────────────────────────────────────────────────
# ✗ before
q.filter("ev__sku" => "ABC")
q.filter("ev__seen__@yyyy_mm__@lte" => "1991-10")
q.filter("ev__meta__driver" => "senna")
# ✓ after
q.filter(CTE("ev", "sku") => "ABC")
q.filter(CTE("ev", "seen__@yyyy_mm__@lte") => "1991-10")
q.filter(CTE("ev", "meta__driver") => "senna")

# ── correlating an unkeyed CTE (#44) ─────────────────────────────────────────
# ✗ before
q.filter("raceid" => F("r91__raceid"))
# ✓ after — the handle already means "a column", so F() is no longer needed
q.filter("raceid" => CTE("r91", "raceid"))

# ── ordering ─────────────────────────────────────────────────────────────────
# ✗ before
q.order_by("-monaco_stats__total_points")
# ✓ after
q.order_by(CTE("monaco_stats", "total_points"; desc = true))

# ── a CTE named after a model field: no longer a trap ────────────────────────
# ✗ before — "parent" is a ForeignKey; the CTE shadowed it and the FK's join vanished
q.with("parent" => parent_cte)
q.values("note", "parent__sku")          # meant the CTE, silently
# ✓ after — both are addressable, and the string path means the ForeignKey again
q.with("parent" => parent_cte)
q.values("note", "parent__sku",                    # the ForeignKey
                 "cte_sku" => CTE("parent", "sku"))  # the CTE
```

If you previously renamed a CTE to work around the shadowing warning, the rename is no longer
necessary — though keeping it costs nothing.
