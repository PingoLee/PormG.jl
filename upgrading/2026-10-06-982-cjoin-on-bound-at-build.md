## `cjoin_on()` — a predicate naming a path stays in its own `ON` clause, and aliases are emitted in dependency order (#982)

- **Version**: Unreleased
- **PormG ref**: #982 ; `src/querybuilder/join_conditions.jl` (`_bind_cjoin_on_conditions!`), `src/querybuilder/build_query.jl` (`build_row_join_sql_text`)
- **Recorded**: 2026-10-06
- **Severity**: behavior change. A `cjoin_on` predicate that names a relation path (`"raceid__circuitid__country" => "Italy"`, `F("driverid__code")`) used to be moved into that path's join. It now stays in the `cjoin_on`'s own `ON` clause, and the path is joined before it. Under `join_type = "LEFT"` the result changes: the predicate now restricts the joined copy instead of dropping base rows. (The path's own join is unchanged: a reverse relation is still an `INNER JOIN` that multiplies and drops base rows, as it did before.) Shapes that raised #435 now render.

### What changed

A `cjoin_on` condition that named a path joined that path *while* the `ON` clause rendered, which
put the path's join after the `cjoin_on` in `FROM`. To make the reference valid, PormG then moved the
predicate onto that later join by scanning the rendered SQL text. The predicate left the `ON` clause it
was written in, and landed in a join of whatever type the relation derived. When every predicate moved,
the `cjoin_on` was left with no `ON` clause and PormG raised (#435).

Binding now resolves every `cjoin_on` condition before anything renders. It joins each path the
conditions name first, and emits the aliases so that each comes after the aliases its `ON` clause
names.

| query | before | after |
|---|---|---|
| `cjoin_on("Driver", alias = "d", join_type = "LEFT", on = [Joined("d", "driverid") == F("driverid"), "raceid__circuitid__country" => "Italy"])` | the predicate lands in the circuit's **INNER** join: a race outside Italy returns **no rows** | the predicate stays in `d`'s `LEFT` join: every result row returns, with `d` null outside Italy |
| the same, with `join_type = "INNER"` | predicate in the circuit's join | predicate in `d`'s join. Same rows |
| `on = [Joined("d", "code") == F("driverid__code")]` (the path is not projected) | `QueryBuildError` (#435): "Every ON predicate given for d resolved onto …" | renders `ON ("d"."code" = "Tb_1"."code")` |
| `d1`'s `on` names `Joined("d2", …)`, with `d2` declared after `d1` | `QueryBuildError` (#435) | renders, `d2` emitted before `d1` |
| `d1` and `d2` each name the other | `QueryBuildError` (#435) | `QueryBuildError`: "… name each other …" |

Two things are unchanged:

- An `ON` clause that never names its own alias is still refused (#448). It is now decided from the
  conditions, before the query renders, so a projected path no longer changes the outcome.
- Aliases that name no other alias are still emitted in declaration order (#449).

### Who this affects

Apps with a `cjoin_on(...)` whose `on` list names a `__` path, or names another alias declared after
it. Measured on 2026-10-06 (for #977, PR #981): **0** `cjoin_on()` call sites in the consuming apps.

### How to find the calls to migrate

```bash
grep -rn 'cjoin_on(' src/ --include=*.jl
```

Look at each `on` list for a `__` path (as a key, inside `F(...)` or in an `OuterRef`) under
`join_type = "LEFT"`. INNER joins return the same rows as before.

### Migrate your app

If you relied on the old placement — a path predicate under a `LEFT` `cjoin_on` that filtered
**base rows** — say so explicitly with `.filter(...)`:

```julia
# ✗ before: the country predicate silently filtered results (it sat in an INNER join)
M.Result.objects.
    cjoin_on("Driver", alias = "d", join_type = "LEFT",
             on = [Joined("d", "driverid") == F("driverid"), "raceid__circuitid__country" => "Italy"]).
    values("resultid", "who" => Joined("d", "surname"))

# ✓ after: filter the base rows in WHERE, and keep d's ON clause about d
M.Result.objects.
    cjoin_on("Driver", alias = "d", join_type = "LEFT",
             on = [Joined("d", "driverid") == F("driverid")]).
    filter("raceid__circuitid__country" => "Italy").
    values("resultid", "who" => Joined("d", "surname"))
```

A query that worked around #435 by projecting the path in `values(...)`, or by reordering its
`cjoin_on` calls, needs no change. It renders the same SQL.
