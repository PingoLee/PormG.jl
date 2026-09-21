## A CTE joined in a correlated `UPDATE … FROM` is refused instead of emitting broken SQL (#394)

- **Version**: 0.5.0
- **PormG ref**: #394; `src/querybuilder/sanitization.jl`, `src/querybuilder/execution.jl`,
  `src/Dialect.jl`, `src/Generator.jl`, `src/migrations/planner.jl`,
  `docs/src/schema_conventions.md`
- **Recorded**: 2026-08-24
- **Severity**: **behavior change (very narrow)** — one shape that was already failing now fails
  earlier and with a message. Everything else in #394 is a widening and forces nothing. Part of the
  `0.5.x` pre-publish wave.

### What changed

The bulk of #394 **removes** a restriction, and nothing about that needs migrating. A physical table
or column identifier is now escaped rather than validated, so a `db_table` or `db_column` that
PormG's DDL renders is one its queries can address and its migration plan can carry. A name that
used to raise `InvalidValueError` on the first `SELECT` — a space, a leading digit, an embedded
quote, anything the importers pin from a live catalog — simply works. Two adjacent gaps closed with
it: `alter_field` on PostgreSQL emitted such a column name unescaped, and the generated
`pending_migrations.jl` wrote each table as a bare Julia binding, so `makemigrations` could produce a
plan file that `migrate` then failed to **parse**.

The one thing that can now fail differently is a **CTE joined in a correlated `UPDATE … FROM`**.

Two loops on that path wrapped their work in a `try`/`catch` that logged an `@error` and continued,
so a failure dropped a table from the `FROM` list or an `ON` condition from the statement — and then
issued it anyway. Those catches are gone: a join PormG cannot render is refused, not silently
omitted.

In practice only one shape reached them, and it was **already broken for an unrelated reason**:
`update()` emits no `WITH` prefix (`build_cte_clause` is reached only from the read paths), so a
`row_join` naming a CTE rendered `FROM "my_cte" AS "Tb_1"` against a relation the statement never
declared. PostgreSQL and SQLite both rejected it. So this is not a case of apps having silently
corrupted data — it is a backend error becoming a clear PormG one, raised before any SQL is built:

> `A CTE cannot be joined in a correlated UPDATE ... FROM: the statement emits no WITH clause, so the
> CTE it references is never declared. Scope the mutation with a filter or a subquery instead.`

Both CTE shapes are covered — the CROSS-joined one (`.with(name, query)` with no `join_field`,
correlated by an `F()` filter) and the keyed one. The sibling guard for an anchor-less `cjoin_on` has
raised on this path since #45 and is unchanged.

### How to find the calls to migrate

There is nothing to grep for statically: the affected call is an `.update(...)` on a query that also
declares a CTE **and** references it from a filter. It is easier to find in your logs — the old
behavior always announced itself before failing:

```bash
# Anything matching either of these was a query that could not be built and was issued regardless.
rg -n 'Error building FROM tables for join|Error building join condition for join' /path/to/logs
```

Expect no hits. If your app had one, it was raising a database error at that call already.

### Migrate your app

Scope the mutation with a filter or a subquery instead of correlating it against a CTE:

```julia
# ✗ BEFORE — the CTE is referenced from the filter, so it reaches the UPDATE's FROM list; the
#            statement emits no WITH clause, so the database rejected the whole UPDATE.
q = M.Result.objects
q.with("fast_laps" => M.Lap_time.objects.filter("milliseconds__lt" => 90000).values("raceid"))
q.filter("raceid" => F("fast_laps__raceid"))
q.update("points" => 25)

# ✓ AFTER — resolve the set first, then mutate against it.
fast = M.Lap_time.objects.filter("milliseconds__lt" => 90000).values("raceid").list()
M.Result.objects.
    filter("raceid__@in" => unique(fast.raceid)).
    update("points" => 25)
```
