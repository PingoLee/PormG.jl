## `delete` / `update` — filters are written on the target row, so PostgreSQL re-checks them (#765)

- **Version**: Unreleased
- **Recorded**: 2026-09-28
- **PormG ref**: #765; `src/querybuilder/deletion.jl` (`_collector_predicate`), `src/querybuilder/execution.jl` (`_target_predicate`, `_target_pk_selection`, `_mutation_predicate`, `update`)
- **Severity**: behavior change — the SQL text (and, for joined statements, the bound values) of every `delete()` and of a joined `update()` changes; which rows are written changes only under concurrency, and for a joined `update()` of a model without a primary key

### What changed

`delete()` scoped every statement it emitted — the root, each cascaded `DELETE`, each `SET_NULL` /
`SET_DEFAULT` `UPDATE` — as `WHERE "pk" IN (SELECT "Tb"."pk" FROM <table> AS "Tb" WHERE <filters>)`,
and a joined `update()` did the same with `SELECT DISTINCT`. Under PostgreSQL READ COMMITTED a
statement that waits on a row lock re-checks only its own `WHERE` against the row's new version; that
subquery was evaluated once, on the old snapshot. So a filter used as a guard — a compare-and-delete
such as `filter("id" => k, "status__@in" => terminal).delete()` — was ignored whenever another
transaction changed the row and committed while the statement waited: the row was deleted anyway.

Every statement now puts the filters on the row it writes:

| Statement | Before | After |
|---|---|---|
| filter with no join | `DELETE FROM "t" WHERE "id" IN (SELECT "Tb"."id" FROM "t" as "Tb" WHERE …)` | `DELETE FROM "t" AS "Tb" WHERE "Tb"."status" = $1 …` |
| cascaded child | `… WHERE "id" IN (SELECT "Tb"."id" FROM "child" as "Tb" WHERE "Tb"."fk" IN (…))` | `DELETE FROM "child" AS "Tb" WHERE "Tb"."fk" IN (…)` |
| `SET_NULL` / `SET_DEFAULT` | `UPDATE "child" SET … WHERE "id" IN (SELECT …)` | `UPDATE "child" AS "Tb" SET … WHERE "Tb"."fk" IN (…)` |
| filter across a join | `… WHERE "id" IN (SELECT … JOIN …)` | `… WHERE "Tb"."id" IN (SELECT DISTINCT … JOIN …) AND EXISTS (SELECT 1 FROM (SELECT 1) AS "__pormg_anchor" JOIN … ON "Tb"… WHERE …)` |

A joined statement keeps the old primary-key selection (so the planner can still use the index) and
adds a correlated `EXISTS` fence; the query is rendered twice, so **its values are bound twice**. A
multi-path cascade still `OR`s one predicate per path.

Outside a race, the rows written are the same, with one exception: a joined `update()` of a model
**without a primary key** used to render `UPDATE … FROM`, which turned its `LEFT JOIN`s into inner
joins, dropped `.on(...)` conditions and refused `cjoin_on`. It now takes the `EXISTS` fence, so an
`"fk__col__@isnull" => true` filter matches rows with no related row, `.on(...)` conditions apply, and
`cjoin_on` is accepted.

SQLite was never exposed to the race (its writers are serialized) but runs the same new SQL.

### How to find the calls to migrate

Nothing in application code breaks. What changes is anything that pins the rendered SQL or the
bound values of a mutation — golden or snapshot tests over `show_query = :sql` / `:dict` /
`:params` or `inspect_query(q, operation = :delete)`:

```bash
grep -rnE 'DELETE FROM \\?"[^"\\]+\\?" WHERE \\?"[^"\\]+\\?" IN \(' --include=*.jl .               # delete(), any statement
grep -rnE 'UPDATE \\?"[^"\\]+\\?" SET .* WHERE \\?"[^"\\]+\\?" IN \(' --include=*.jl .           # a cascade's SET_NULL / SET_DEFAULT
grep -rnE 'SELECT DISTINCT \\?"Tb\\?"\.' --include=*.jl .                                       # a joined update(), wrapped or not
grep -rnE 'operation *= *:delete|(delete|update)\(.*show_query' --include=*.jl .                  # every pinned mutation
```

The third pattern matches the new joined shape as well — the selection is kept — so a hit is only
still-to-migrate if the same statement has no `__pormg_anchor` fence after it.

Also look for a raw-SQL compare-and-delete written to work around this gap
(`DELETE FROM … WHERE <predicates on the row>` issued by hand): the ORM form is now safe.

### Migrate your app

Update the pinned SQL; the application calls stay as they are.

```julia
q = M.Qualifying.objects.filter("qualifyingid" => 1, "position" => 1)
norm(s) = replace(strip(s), r"\s+" => " ")

# ✗ before — golden pinned the self-subquery
@test norm(inspect_query(q, operation = :delete)[:sql_text]) == norm("""
  DELETE FROM "qualifying" WHERE "qualifyingid" IN (SELECT "Tb"."qualifyingid" as "qualifyingid"
  FROM "qualifying" as "Tb" WHERE "Tb"."qualifyingid" = \$1 AND "Tb"."position" = \$2 )""")

# ✓ after — the filters are on the row being deleted
@test norm(inspect_query(q, operation = :delete)[:sql_text]) == norm("""
  DELETE FROM "qualifying" AS "Tb" WHERE "Tb"."qualifyingid" = \$1 AND "Tb"."position" = \$2""")
```

For a joined `update()` / `delete()`, expect the selection, then the fence, and each value twice.
On PostgreSQL (`$N` numbered as the values bind — the WHERE is built before the SET):

```julia
q = M.Result.objects.filter("driverid__nationality" => "British", "resultid" => 1)

# ✗ before
@test q.update("points" => 25, show_query = :params) == ["British", 1, 25]
# ✓ after — selection values, SET value, fence values ($1 $2 | $3 | $4 $5)
@test q.update("points" => 25, show_query = :params) == ["British", 1, 25, "British", 1]
```

On SQLite (`?` bound in text order): `[25, "British", 1]` before, `[25, "British", 1, "British", 1]`
after.

And a hand-written guard can go back to the ORM:

```julia
# ✗ before — raw SQL, because delete()'s filters were not re-checked under a row lock
PormG.fetch(settings, """DELETE FROM "qualifying" WHERE "qualifyingid" = \$1 AND "position" = \$2"""; params = [1, 1])
# ✓ after
M.Qualifying.objects.filter("qualifyingid" => 1, "position" => 1).delete()
```
