## SQLite before 3.30: an alias a column also names places its NULLs by the projection (#1130)

- **Version**: 0.9.0
- **PormG ref**: #1130 ; `src/querybuilder/build_select.jl` (`get_order_query`), `src/querybuilder/select_nodes.jl` (`_projection_null_key`)
- **Recorded**: 2026-10-23
- **Severity**: behavior change, SQLite before 3.30.0 only. An `order_by` on a projected name that is also a column of a table the query reads returns its NULLs where the placement says (last ascending, first descending), where it placed them by that column, with no error. One such ordering now raises `QueryBuildError` instead (below). PostgreSQL and SQLite 3.30.0 or later are unchanged.

### What changed

SQLite before 3.30.0 has no `NULLS FIRST`/`NULLS LAST`, so PormG places NULLs with an
`(expr IS NULL)` sort key ahead of the term (#75). A term that orders by a projection printed the
projection's name in that key: `ORDER BY ("laps" IS NULL) DESC, "laps" DESC`. Inside an expression
SQLite reads a name as a column of a table in `FROM` before a result alias, so when a table has a
column of that name the key tested the column, and the NULLs landed where that column's NULLs are.

The key is now the projection's own SQL wherever a table the query reads has a column of the name
(`("Tb"."position" IS NULL)`), with any value the projection binds bound again for it. The term itself
still orders by the name. A name no column has keeps it in the key, as before.

PormG decides the key while it renders `ORDER BY`, and a few joins are added after that. When the
table with the column is joined only by a later term through a nested query, such as an
`Exists(...)` or a `Subquery(...)` whose `OuterRef("driverid__surname")` joins the driver, the query
raises `QueryBuildError` naming the projection, where it returned the NULLs in the wrong place. Name
the projection after no column, or order by that term first.

| call on SQLite < 3.30 | before | now |
|---|---|---|
| `M.Result.objects.values("laps" => "position").order_by("-laps")` | the NULL positions last: the key tested `laps`, never NULL | the NULL positions first |
| `M.Result.objects.values("year" => "position", "raceid__name").order_by("year")` | the key tested the race's `year` | the NULL positions last |
| `M.Result.objects.values("surname" => "position").order_by("-surname", SQLOrder(SQLField(Exists(…OuterRef("driverid__surname")…), "ex")))` | the key tested the driver's `surname` | `QueryBuildError`: rename the projection, or order by the `Exists` term first |

### Who this affects

Code on SQLite before 3.30.0 that orders by a name given in `values(...)` when that name is also a
column of the model or of a model the query joins, and whose projection can be NULL.

### How to find the calls to migrate

```bash
grep -rlE 'order_by\(' --include=*.jl src/ | xargs grep -nE 'values\(.*"[A-Za-z_]+" *=>'
```

For each projection named this way in a file that orders, check whether a query orders by its name
and whether that name is also a column of a table the query reads.

### Migrate your app

```julia
# ✗ before — on SQLite < 3.30 the NULL positions sorted last
M.Result.objects.values("laps" => "position").order_by("-laps").list()

# ✓ after — the same call puts them first, as PostgreSQL and newer SQLite do; nothing to change
```
