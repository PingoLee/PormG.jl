## An ordering term is no longer a field expression (#533)

- **Version**: 0.6.0
- **PormG ref**: #533 ; `src/Kernel.jl`, `src/querybuilder/types.jl`, `src/querybuilder/object_manager.jl`, `src/querybuilder/functions.jl`, `src/querybuilder/execution.jl`
- **Recorded**: 2026-09-10
- **Severity**: breaking

### What changed

`SQLTypeOrder` was declared `<: SQLTypeField`. Because around 26 signatures across the query builder
spell `Union{String, SQLTypeField, …}`, that one subtype relation silently admitted an `SQLOrder` into
every one of them — `partition_by`, `Lower(...)`, `Cast(...)`, `values(...)`, `OperObject.column` and
the rest. None of those has a consumer for an ordering term, so each accepted it at construction and
then died at render with a raw `MethodError` outside the #231 taxonomy. It is now
`SQLTypeOrder <: SQLType`.

Three consequences a consuming app can see:

| spelling | before | after |
|---|---|---|
| `x isa PormG.SQLTypeField` for an `SQLOrder` | `true` | `false` — test `SQLTypeOrder` |
| `partition_by = SQLOrder(...)`, `Lower(SQLOrder(...))`, … | constructed, then a raw `MethodError` | refused at declaration with a `QueryBuildError` naming the supported spellings |
| `SQLOrder("surname")` | constructed, then a raw `FieldError` naming the internal `._as` slot | normalizes to the `SQLField` every consumer requires, and renders |

`SQLOrder.field` is narrowed to `SQLTypeField`, and every construction path runs through one funnel —
so a value the constructor accepts is a value the renderer handles. `SQLOrder("-surname")` is refused
rather than resolving a column literally named `-surname`; the direction belongs in `orientation`.

`ORDER BY` itself is untouched: `SQLTypeOrder` is still a member of `WindowOrderPart`, and
`order_by(SQLOrder(...))` — including the `CTE` and `Joined` handle spellings #509 added — behaves as
before.

**One rendering did move**, in a shape that combines three things: a CTE, a projection *aliased* with
a CTE path, and a window that orders by the same path as a `SQLOrder(String)`. That projection's memo
namespace was `:cte` and is now `:base`, so a later `filter` on the alias resolves the CTE column
instead of reusing the projection:

```julia
q.with("ev" => cte, join_field = "parent" => "id")
q.values("note", "ev__seen" => Rank(over = WindowOver(order_by = [SQLOrder("ev__seen")])))
q.filter("ev__seen" => "2020-01-01")
```

```sql
-- before
WHERE RANK() OVER (ORDER BY "R1_1"."seen" ASC) = ?
-- after
WHERE "R1_1"."seen" = ?
```

No app should need an edit: the previous SQL put a window function in `WHERE`, which neither
PostgreSQL nor SQLite accepts, so that query could not have been running successfully. The new
rendering matches what `SQLOrder(CTE("ev","seen"))` has always produced.

### How to find the calls to migrate

```bash
grep -rn 'SQLOrder(' --include='*.jl' .
grep -rn 'SQLTypeField' --include='*.jl' .
```

Measured across both consuming apps when this landed: **zero** hits for either.

### Migrate your app

```julia
# ✗ before — an SQLOrder satisfied ::SQLTypeField, so these constructed and died at render
Rank(over = WindowOver(partition_by = SQLOrder(SQLField("x", "x"))))
Lower(SQLOrder(SQLField("note", "note")))

# ✓ after — name the column; only ORDER BY has a direction to carry
Rank(over = WindowOver(partition_by = "x"))
Lower("note")

# ✗ before — a type test that silently included ordering terms
x isa PormG.SQLTypeField
# ✓ after — say which you meant
x isa PormG.SQLTypeOrder                                    # ordering terms
x isa PormG.SQLTypeField || x isa PormG.SQLTypeOrder        # genuinely both

# ✗ before — accepted, then a raw FieldError naming an internal slot
query.order_by(SQLOrder("-surname"))
# ✓ after — the direction goes in its own slot
query.order_by(SQLOrder("surname"; orientation = "DESC"))
```
