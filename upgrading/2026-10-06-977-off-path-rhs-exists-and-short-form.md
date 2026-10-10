## `on()` / `cjoin(filters = …)` — an `Exists` or an FK short form naming an off-path relation raises (#977)

- **Version**: Unreleased
- **PormG ref**: #977 ; `src/querybuilder/join_conditions.jl` (`_relation_step`), `src/querybuilder/ctes.jl` (`_off_path_rhs_condition`)
- **Recorded**: 2026-10-06
- **Severity**: breaking (narrow). Two right-side shapes escaped #962's check: an `Exists(...)` whose `OuterRef` names another relation, and a right side spelled with the FK short form (`status__name` for `status_id`). They used to render, attached to whichever join came later in `FROM`. They now raise `FilterError` when the query is built, on both engines, as every other spelling has since #962.

### What changed

#962 refuses a join-condition right side that reaches a relation outside the join path, because the
predicate then lands in whichever join the renderer emits later. Two spellings were not seen by that
check:

| query | before | after |
|---|---|---|
| `on("driverid", Q(Exists(Constructor.objects.filter("name" => OuterRef("constructorid__name")))))` | adds the constructor's `LEFT JOIN`, and the `EXISTS` lands in its `ON` clause | raises `FilterError` |
| `on("driverid", "code" => F("status__name"))`, where the FK is `status_id` | adds the status `LEFT JOIN`, and the predicate lands in its `ON` clause | raises `FilterError` |

The check now resolves every relation through the renderer's own precedence, including the FK short
form and a `cjoin(field = …)` link, and walks an `Exists(...)` condition for its `OuterRef`s like a
`Subquery(...)`. An `Exists` correlated to the base row (`OuterRef("constructorid")`) or to the join's
own path still renders exactly as before. `cjoin_on(...)` is not affected.

### Who this affects

Apps with a join condition that uses `Exists(...)` or the FK short form to compare two sibling relations.

### How to find the calls to migrate

Run the app's tests. Every remaining call raises with this message:

```
a relation outside the join path
```

### Migrate your app

Move the predicate to `.filter(...)`, as for #962. That is a `WHERE` predicate, so it keeps only the
rows where it holds.

```julia
# ✗ before: the EXISTS lands in the constructor join's ON clause, not the driver's
M.Result.objects.
    on("driverid", Q(Exists(M.Driver.objects.
        filter("nationality" => OuterRef("constructorid__nationality"))))).
    values("resultid", "driverid__code")

# ✓ after: results whose constructor shares a nationality with some driver
M.Result.objects.
    filter(Exists(M.Driver.objects.
        filter("nationality" => OuterRef("constructorid__nationality")))).
    values("resultid", "driverid__code")
```

For the FK short form, write the same predicate in `.filter(...)` with the path spelled as before.
