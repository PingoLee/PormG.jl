## A subquery consumed by `@in` / `Subquery` / `Exists` may no longer declare its own CTE (#433)

- **Version**: 0.5.0
- **PormG ref**: #433; `src/querybuilder/build_helpers.jl`, `src/querybuilder/build_joins.jl`,
  `src/querybuilder/deletion.jl`, `src/querybuilder/ctes.jl`, `src/querybuilder/build_query.jl`,
  `docs/src/read/subqueries_and_ctes.md`
- **Recorded**: 2026-08-26
- **Severity**: **behavior change (narrow, but `delete()` is the wide part)** — one shape that raised
  an internal error now raises a typed one; two subquery shapes that **worked correctly on
  PostgreSQL** are refused on both backends; and **`delete()` now refuses any queryset that declares
  a CTE**, which is the change most likely to touch existing code. Part of the `0.5.x` pre-publish
  wave.

### What changed

Three consumers accept a subquery: `"col__@in"` / `"col__@nin"`, `Subquery(...)` and `Exists(...)`.
When that subquery declared a CTE of its own, they failed in two different ways:

- **`Exists(...)` never rendered it at all.** `_build_exists_query` hand-rolls its SELECT instead of
  routing through `query()`, so it emitted no `WITH` prefix and never materialized the CTE's model.
  The first path resolving `<cte>__col` raised `PormG internal error: CTE … please report it` — a
  message reserved for a broken invariant, raised for a query a user is entitled to write.
- **`Subquery(...)` and `@in` DID render it, and could misbind on SQLite.** `build_cte_clause` binds
  unconditionally into the `:cte` bucket, `:cte` is flattened ahead of `:select` and `:where`, and
  the subquery's text sits in one of those. Any value whose text precedes the nested CTE but whose
  bucket flattens later ends up bound behind it. Measured:

  ```
  filter("note" => "WHEREVAL", "parent__@in" => <sub declaring .with("gv" => …)>)
      PostgreSQL  ["WHEREVAL", "CTEVAL", "INNERVAL"]   ← matches the text
      SQLite      ["CTEVAL", "INNERVAL", "WHEREVAL"]   ← wrong rows, no error
  ```

  The misbind is **conditional, not universal**: with no earlier value to overtake, the same shapes
  bind correctly, which is why it went unnoticed. **PostgreSQL never misbinds** — `$N` numbering has
  no buckets.

All three now raise a `QueryBuildError` naming the offending CTE. Refusing on PostgreSQL too — where
nothing was actually wrong — is the *keep PostgreSQL and SQLite aligned* rule: a query that builds on
one engine and silently misbinds on the other is a worse trap than one refused on both.

Separately, referencing a CTE from `update(...)` reached the same internal error, because `update()`
emits no `WITH` clause and its own CTE guard (#394) inspects `row_join` entries that
`_build_row_join` raises while still producing. That now raises a `QueryBuildError` as well.

**`delete()` on a CTE-scoped queryset is also refused now** — this is the widest part of the change,
so it is called out separately. The deletion collector re-uses the query being deleted as a scoping
subquery (`DELETE ... WHERE pk IN (<your query>)`, plus one per cascade), which places the `WITH` in
exactly the nested position above. Before, this *rendered*: it worked on PostgreSQL, and on SQLite it
was correct only while nothing else was bound first. An exemption for PormG's own construction was
tried and measured to re-open the misbind — with one filter bound ahead of the nested CTE, SQLite
bound `["CTEVAL","INNERVAL","NOTEVAL"]` against a text order of `NOTEVAL, CTEVAL, INNERVAL`, i.e. a
silent wrong DELETE — so it is refused instead, on both the cascade and leaf paths.

Two smaller error-type changes ride along, neither of which breaks working code:

- `cjoin()` given an unknown main-model field raised a raw Julia `FieldError` (its message
  interpolated a property `Model_Type` does not have) instead of the `UnknownFieldError` it was
  building. It now raises `UnknownFieldError`.
- A previously documented misbind closes as a side effect. `build_query.jl` recorded a residual
  hole where a `cjoin_on` ON list of `["id__@gt" => 7, "parent__@in" => <sub with .with(...)>]`
  bound SQLite `["CTEVAL","SUBVAL",7]` against PostgreSQL's `[7,"CTEVAL","SUBVAL"]`. That input can
  no longer be constructed.

**Unchanged:** a CTE declared inside another **CTE's body** still renders and binds correctly on both
backends. Only subqueries used in a filter or a projection are affected.

### How to find the calls to migrate

The defect is a `.with(...)` on a query that is then handed to one of the three consumers, so list the
consumers and check each one's subquery:

```bash
rg -n '__@n?in"\s*=>|Subquery\(|Exists\(' .
```

Grep cannot decide it for you — whether the nested query carries a CTE is a property of how it was
built. This check is the same one the guard applies:

```julia
isempty(sub.object.ctes) ||
    @warn "this subquery declares a CTE and can no longer be nested" ctes = keys(sub.object.ctes)
```

### Migrate your app

**Nested subqueries — fold the CTE's predicate into the subquery's own `filter(...)`:**

```julia
# ✗ BEFORE — now refused
fast_laps = M.Lap_times.objects
fast_laps.filter("milliseconds__@lt" => 90_000)
fast_laps.values("raceid", "milliseconds")

inner = M.Result.objects
inner.with("fast" => fast_laps, join_field = "raceid" => "raceid")
inner.filter("fast__milliseconds__@lt" => 90_000)
inner.values("driverid")
query.filter("driverid__@in" => inner)

# ✓ AFTER — no nested CTE
inner = M.Lap_times.objects
inner.filter("milliseconds__@lt" => 90_000)
inner.values("driverid")
query.filter("driverid__@in" => inner)
```

**`delete()` — resolve the CTE first and filter on its result:**

```julia
# ✗ BEFORE
query = M.Result.objects
query.with("fast" => fast_laps, join_field = "raceid" => "raceid")
query.filter("fast__milliseconds__@lt" => 90_000)
query.delete()

# ✓ AFTER
fast_race_ids = M.Lap_times.objects
fast_race_ids.filter("milliseconds__@lt" => 90_000)
fast_race_ids.values("raceid")

query = M.Result.objects
query.filter("raceid__@in" => fast_race_ids)
query.delete()
```

**`update(...)` — scope the mutation with a plain filter or a subquery instead of a CTE:**

```julia
# ✗ BEFORE
query = M.Result.objects
query.with("fast" => fast_laps, join_field = "raceid" => "raceid")
query.filter("fast__milliseconds__@lt" => 90_000)
query.update("points" => 0)

# ✓ AFTER
fast_race_ids = M.Lap_times.objects
fast_race_ids.filter("milliseconds__@lt" => 90_000)
fast_race_ids.values("raceid")

query = M.Result.objects
query.filter("raceid__@in" => fast_race_ids)
query.update("points" => 0)
```
