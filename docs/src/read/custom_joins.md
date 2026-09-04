# Custom Join Documentation

## Overview

PormG provides a way to create custom join conditions using the chainable `.cjoin()` method on query handlers.

The `.cjoin()` method is the recommended approach as it's more flexible and allows you to specify join conditions when building queries, rather than at model definition time.

## `.cjoin()` Method 

The `.cjoin()` method allows you to add custom conditions to JOIN clauses at query time. This is particularly useful for:

1. **Legacy databases** where foreign key constraints don't exist
2. **Joining on non-ID fields** (e.g., joining on codes, names, or other unique identifiers)
3. **Adding extra conditions to the ON clause** beyond simple equality
4. **Complex multi-field joins** (e.g., multi-tenant systems where you need to match both tenant_id and another field)

## Key Features

- **Runtime flexibility** - Add join conditions when building queries
- **ON clause conditions** - Restrict the joined table during the JOIN itself
- **Full Q/Qor/operator suffix support** - Use the same filter syntax as .filter() for conditions that belong to the joined model
- **Automatic field prefixing** - Plain joined-model field names in join filters are automatically prefixed with the join path
- **F expressions** - Field-to-field comparisons in joins
- **Multi-tenant support** - Perfect for tenant isolation at join level
- **Nested joins** - Apply conditions to any level of join

## Installation

The `.cjoin()` method is built into the query builder handler, meaning no special function imports are required once you have loaded PormG:

```julia
using PormG, LibPQ   # load SQLite instead for a SQLite app
# Q, Qor, and F are automatically exported by PormG
```

## Basic Usage with `.cjoin()`

### Setup: Create Test Data

First, let's set up some test data. The `New_join_position` model has a `result` field (IntegerField) that we'll join to the `Result` model:

```julia
# Clear and populate test data
delete(M.New_join_position.objects, allow_delete_all = true)

M.New_join_position.objects.create("result" => 1, "description" => "teste 1")
M.New_join_position.objects.create("result" => 2, "description" => "teste 2")
M.New_join_position.objects.create("result" => 3, "description" => "teste 3")
```

### Simple Join

Create a custom join from an IntegerField to another model:

```julia
df = M.New_join_position.objects.
    cjoin("result" => "Result").
    values("result__statusid__status", "description", "result") |> DataFrame
```

# Output:
# 3x3 DataFrame
#  Row | result__statusid__status  description  result 
#      | String?                   String?      Int32?
# -----+------------------------------------------------
#    1 | Finished                  teste 1           1
#    2 | Finished                  teste 2           2
#    3 | Finished                  teste 3           3
```

The `.cjoin()` call creates a LEFT JOIN from `new_join_position.result` to `Result.resultid`, allowing you to traverse the relationship chain `result__statusid__status`.

### Join with Filter Conditions (LEFT JOIN)

Add conditions to the ON clause using fields from the joined model. When a row doesn't match the ON condition, the joined fields will be `missing`:

```julia
df = M.New_join_position.objects.
    cjoin("result" => "Result", filters=["resultid" => 1]).
    values("result__statusid__status", "description", "result") |> DataFrame
```

# Output:
# 3x3 DataFrame
#  Row | result__statusid__status    description  result 
#      | Union{Missing, String}      String?      Int32?
# -----+--------------------------------------------------
#    1 | Finished                    teste 1           1
#    2 | missing                     teste 2           2
#    3 | missing                     teste 3           3

Notice that only the row whose joined `Result.resultid` is `1` has the status because the filter is applied in the ON clause, not WHERE. This returns all 3 rows, but only one row matches the join condition.

### Join with Filter Conditions (INNER JOIN)

Use `join_type="INNER"` to only return rows that match the join condition:

```julia
df = M.New_join_position.objects.
    cjoin("result" => "Result", 
           filters=["resultid" => 1],
           join_type="INNER").
    values("result__statusid__status", "description", "result") |> DataFrame
```

# Output:
# 1x3 DataFrame
#  Row | result__statusid__status  description  result 
#      | String?                   String?      Int32?
# -----+------------------------------------------------
#    1 | Finished                  teste 1           1
```

Only the row joined to `Result.resultid = 1` is returned because the INNER JOIN excludes non-matching rows.

### Join with Q/Qor Filters (AND/OR Logic)

Use `Q()` for AND logic and `Qor()` for OR logic in join conditions. Plain field names are automatically prefixed with the join path:

```julia
# Plain fields are auto-prefixed: "statusid__status" and nested fields work too
df = M.New_join_position.objects.
    cjoin("result" => "Result", filters=[
        Q("statusid__status" => "Finished", Qor("positionorder" => 1, "positionorder" => 2))
    ]).
    values("result__statusid__status", "description") |> DataFrame
```

### Join with Driver Model (Q/Qor Example)

Here's a complete example joining Result to Driver with complex filter logic:

```julia
# Add custom join with recursive Q/Qor filters + WHERE clause filter
# Plain field names ("nationality", "forename") are automatically prefixed
df = M.Result.objects.
    cjoin("driverid" => "Driver", filters=[
        Q("nationality" => "Brazilian", Qor("forename" => "Ayrton", "forename" => "Nelson"))
    ]).
    filter("points" => 10).
    values("driverid__surname", "points") |> DataFrame
```

# Generated SQL (simplified):
# SELECT ... FROM result AS Tb
#   LEFT JOIN driver AS Tb_1 ON Tb.driverid = Tb_1.driverid 
#                           AND (Tb_1.nationality = ? AND (Tb_1.forename = ? OR Tb_1.forename = ?))
# WHERE Tb.points = ?
```

Notice that the cjoin filter parameters (`"Brazilian", "Ayrton", "Nelson"`) appear in the ON clause, while the regular filter parameter (`10` for points) appears in the WHERE clause.

## Understanding `.cjoin()` Behavior

### Contract of `.cjoin(filters=...)`

`.cjoin()` exists to modify the JOIN itself. Its `filters` are ON-clause predicates and should target fields on the joined model.

Use `.cjoin(..., filters=...)` when you want SQL like:

```sql
LEFT JOIN driver ON result.driverid = driver.driverid AND driver.nationality = ?
```

Use `.filter(...)` when you want to filter the main query rows in `WHERE`:

```sql
WHERE result.points > ?
```

This distinction matters:

- `.cjoin(filters=...)` is for joined-model predicates that belong in `ON`
- `.filter(...)` is for base-query predicates that belong in `WHERE`
- Passing base-table fields to `.cjoin(filters=...)` is not a good API contract and should be treated as unsupported usage

### Dedicated `on()` API for Existing Join Paths

When the join path already exists through the model graph, you do not need to redefine it with `.cjoin()` just to add ON-clause predicates. Use the chainable `query.on()` method instead:

```julia
df = M.Result.objects.
    on("driverid", "nationality" => "Brazilian", "code" => "SEN").
    values("resultid", "driverid__surname", "points") |> DataFrame
```

This keeps all base `Result` rows in the query tree while only attaching `Driver` rows that satisfy the ON predicates.

You can also override the join type directly from `query.on()`:

```julia
query = M.Result.objects.
    on("driverid", "nationality" => "Brazilian", join_type="INNER").
    values("resultid", "driverid__surname")
```

This changes the join keyword to `INNER JOIN` while keeping the predicate in the `ON` clause instead of moving it to `WHERE`.

### Reverse Join Example with `on()`

Reverse joins are the main use case for the dedicated API because they let you preserve base rows while limiting which related rows attach.

```julia
df = M.Result.objects.
    on("test_deletion", "name__@in" => ["reverse-join-a", "reverse-join-b"]).
    filter("resultid__@in" => [1, 2, 3]).
    values("resultid", "test_deletion__name") |> DataFrame
```

The reverse join is `LEFT` here because that is what PormG derives for it, not because `on()` chose it — `on()` only adds the predicate. All three `Result` rows remain and only the matching reverse rows are attached. If you want only the matched base rows, pass `join_type="INNER"` on the same `on()` call.

!!! tip
    **Chained Reverse Paths**: You can also use `on()` through chained reverse paths. For example, `query.on("test_deletion", "just_a_nested_roll_back__description" => "nested-value")` will correctly apply the `ON`-clause predicate deep within the reversed relationship traversal chain.

### Contract of `on()`

- `query.on("path", ...)` targets an existing join path, including reverse joins such as `"test_deletion"` and nested paths such as `"raceid__circuitid"`
- multiple predicates are combined with `AND` unless you use `Qor(...)`
- repeated `on()` calls for the same path merge additional predicates into the same `ON` clause
- **`on()` does not change the join type unless you pass `join_type=`.** Without it the join keeps
  the type PormG derives from the relation itself — the field's own `how`, else `LEFT` for a
  nullable ForeignKey and `INNER` for a `NOT NULL` one. Before
  [#474](https://github.com/PingoLee/PormG.jl/issues/474) an `on()` with no `join_type` forced
  `LEFT`, so adding a predicate to a `NOT NULL` relation silently widened the result set
- an explicit `join_type` on any `on()` call for a path stays in effect for later `on()` calls on
  that same path
- `.filter(...)` keeps its existing `WHERE` semantics and is not silently rewritten into `ON`

### When `.cjoin()` is Applied

The `.cjoin()` configuration is only applied when you access fields through the join path:

```julia
# cjoin is NOT applied - no join path used in values()
df = M.New_join_position.objects.
    cjoin("result" => "Result", filters=["resultid" => 1]) |> DataFrame  # Returns all 3 rows with default columns

# cjoin IS applied - accessing result__* fields
df = M.New_join_position.objects.
    cjoin("result" => "Result", filters=["resultid" => 1]).
    values("result__statusid__status", "description", "result") |> DataFrame  # Join is created with ON conditions
```

If you need to filter the base table at the same time, do it explicitly with `.filter(...)`:

```julia
query = M.New_join_position.objects.
    cjoin("result" => "Result", filters=["resultid" => 1]).
    filter("description" => "teste 1").
    values("result__statusid__status", "description", "result")
```

### Generated SQL

You can inspect the generated SQL using `show_query`:

```julia
query = M.New_join_position.objects.
    cjoin("result" => "Result", filters=["resultid" => 1]).
    values("result__statusid__status", "description", "result")

@info query |> show_query

# Output:
# SELECT
#    "Tb_2"."status" as result__statusid__status,
#    "Tb"."description" as description,
#    "Tb"."result" as result
# FROM "new_join_position" as "Tb"
#  LEFT JOIN "result" AS "Tb_1" ON "Tb"."result" = "Tb_1"."resultid" 
#                                  AND "Tb_1"."resultid" = \$1
#  LEFT JOIN "status" AS "Tb_2" ON "Tb_1"."statusid" = "Tb_2"."statusid"
```

## Full-Control ON Clauses with `.cjoin_on()` (#45)

`.cjoin()` and `.on()` always emit a base equi-anchor (`main.field = target.pk`) and AND-append
filters that must target the **single joined model**. When you need the *entire* ON clause to be
your own — an arbitrary boolean (top-level `OR`), field-to-field comparisons across **both** sides
(a self-join), or SQL functions in the ON — use **`.cjoin_on()`**.

```julia
query.cjoin_on("Model"; alias="b2", on=[ ... ], join_type="INNER")
```

- **`"Model"`** — the model to join (may be the query's **own** model, for a self-join).
- **`alias`** — the SQL alias for the joined copy. Reference its columns as `Joined(alias, "column")`.
- **`on`** — the expressions that form the **entire** ON clause. No equi-anchor is added.
- **`join_type`** — defaults to `"INNER"`.

### Reference convention

Inside `on`, the two sides of the join are named by how you write the reference:

| You write | Resolves to |
|-----------|-------------|
| `F("col")` (bare) | the **base/main** table (the query's own alias) |
| `Joined("b2", "col")` | the **joined copy** declared by this `cjoin_on` (its `alias`) |

This is unambiguous even in a self-join, where both sides share every column name.

[`Joined(alias, path)`](@ref Joined) is a reference **object**, not a string, and it works in every
clause rather than only inside `on`: project it in `values(...)`, compare it in `filter(...)`, sort
by it in `order_by(...)`, and name **another** `cjoin_on`'s alias from inside one `on` list.

!!! warning "The dotted-string spelling was removed"
    `F("alias.col")` is gone (#481). It could not carry an operator suffix, the bare string form
    could not be projected (`values("b2.sku")` raised), and a typo in the alias reported an unknown
    *field* called `"typo.col"` instead of an unknown alias. Rewrite `F("b2.sku")` as
    `Joined("b2", "sku")`; see [Upgrading](../upgrading.md).

### Self-join example

Find, for each lap, other laps in the same race — or the same driver+lap — or the same calendar
year of the timestamp:

```julia
query = M.Lap.objects
query.cjoin_on("Lap"; alias="b2", join_type="INNER", on=[
  Qor(
    Joined("b2", "raceid") == F("raceid"),
    Q(Joined("b2", "driverid") == F("driverid"), Joined("b2", "lap") == F("lap")),
    Joined("b2", "dt__@year") == F("dt__@year"),  # year() on both sides — dialect-aware
  ),
])
query.values("id")
```

**Generated SQL (SQLite** — PostgreSQL renders `$n` placeholders and `EXTRACT(YEAR FROM …)`**):**

```sql
SELECT "Tb"."id" as "id"
FROM "laps" as "Tb"
 INNER JOIN "laps" AS "b2" ON (
       ("b2"."raceid" = "Tb"."raceid")
    OR (("b2"."driverid" = "Tb"."driverid") AND ("b2"."lap" = "Tb"."lap"))
    OR (CAST(strftime('%Y', "b2"."dt") AS INTEGER) = CAST(strftime('%Y', "Tb"."dt") AS INTEGER))
 )
```

No `main.field = target.pk` anchor is emitted — the `on` expression **is** the ON clause. Bound
parameters from `on` route to the JOIN clause (ahead of any WHERE parameters).

!!! note "What a `Joined(...)` reference can do"
    Since #481 the joined copy is referenced by a typed handle, and three limitations this note used
    to list are gone:

    - **Alias-qualified operator pairs work.** `filter(Joined("b2", "col__@gte") => 3)` compares the
      joined side against a literal; every operator the ordinary pair path accepts works here, since
      it *is* that path.
    - **A third table can be referenced.** One `cjoin_on`'s `on` may name another's alias —
      `Joined("d2", "surname") == Joined("d1", "surname")`. Emission order still decides where a
      predicate lands; see the warning below.
    - **A joined column projects in every form.** `values("who" => Joined("d", "surname"))` and the
      bare `values(Joined("d", "surname"))` both work; the bare dotted string never did.

    Still true: a predicate that all relocates onto a later join leaves this one with no `ON` clause
    of its own, which raises `QueryBuildError` (#435).

    **A CTE cannot be referenced from an `ON` clause at all.** A `CTE(name, path)` inside `on`
    raises `FilterError`: an `ON` clause targets the joined *model*, and a CTE is joined by its own
    `.with(...)` declaration. Put the predicate in `.filter(...)` instead (#444).

    **A join key may share a name with a CTE the query joins.** A `cjoin_on` **alias**, a `cjoin`
    **path** and an `on()` **path** live in a different namespace from a `.with()` label, so a
    query may use the same word for both and each stays addressable — the same coexistence
    [#444](https://github.com/PingoLee/PormG.jl/issues/444) established for a CTE name and a model
    field:

    ```julia
    # "best" names both the CTE and the cjoin_on alias here.
    best = M.Result.objects.values("driverid", "best" => Min("positionorder"))

    df = M.Result.objects.
        with("best" => best, join_field = "driverid" => "driverid", join_type = "INNER").
        cjoin_on("Driver", alias = "best", on = [Joined("best", "driverid") == F("driverid")]).
        values("points", "career_best" => CTE("best", "best")).
        filter("raceid" => 18).
        order_by("-points").
        limit(5) |> DataFrame
    ```

    ```sql
    -- Both are emitted. The CTE is joined under a GENERATED alias, so only one relation in the
    -- statement is actually named "best".
    WITH "best" AS (
      SELECT "Tb"."driverid" as "driverid", MIN("Tb"."positionorder") as "best"
      FROM "result" as "Tb" GROUP BY 1
    )
    SELECT "R1"."points" as "points", "R1_1"."best" as "career_best"
    FROM "result" as "R1"
     INNER JOIN "best" AS "R1_1" ON "R1"."driverid" = "R1_1"."driverid"
     INNER JOIN "driver" AS "best" ON ("best"."driverid" = "R1"."driverid")
    WHERE "R1"."raceid" = ?
    ORDER BY "points" DESC NULLS FIRST
    LIMIT 5
    ```

    Until [#474](https://github.com/PingoLee/PormG.jl/issues/474) this was refused, because join
    resolution looked a CTE hop up in the join-config map under the CTE's own name — so a collision
    handed the CTE the other entry's join type and predicates and dropped your join. That lookup is
    gone, so a join KEY no longer collides.

    **A `cjoin_on` alias may also equal a relation name on the base model**, or an `on()` / `cjoin()`
    join path. Both joins are emitted — the relation's under a generated alias, the joined copy's
    under the alias you declared — and each stays addressable: `Joined(alias, column)` reaches the
    copy, `"relation__column"` reaches the relation. `on(...)` and `cjoin(...)` decorate the
    *relation's* join, never the copy's, in either declaration order.

    ```julia
    # "driverid" names both the ForeignKey on Result and the cjoin_on alias.
    df = M.Result.objects.
        cjoin_on("Driver", alias = "driverid", join_type = "LEFT",
                 on = [Joined("driverid", "driverid") == F("driverid")]).
        filter("raceid" => 841).
        values("points", "fk" => "driverid__surname",
               "copy" => Joined("driverid", "surname")) |> DataFrame
    ```

    ```sql
    -- Two joins, each with its own alias, its own ON clause and its own join type: the ForeignKey's
    -- keeps what PormG derives from the relation (INNER — `driverid` is NOT NULL), the joined copy
    -- keeps the LEFT it declared. Neither adopts the other's.
    SELECT "Tb"."points" as "points", "Tb_1"."surname" as "fk", "driverid"."surname" as "copy"
    FROM "result" as "Tb"
     INNER JOIN "driver" AS "Tb_1" ON "Tb"."driverid" = "Tb_1"."driverid"
     LEFT JOIN "driver" AS "driverid" ON ("driverid"."driverid" = "Tb"."driverid")
    WHERE "Tb"."raceid" = ?
    ```

    Before [#484](https://github.com/PingoLee/PormG.jl/issues/484) this shape was silently wrong
    whenever the relation was *also* traversed: the alias's predicates were AND-appended to the
    ForeignKey's `ON`, its join type adopted, its own join never emitted — leaving the statement
    referencing a range variable it never declared (PostgreSQL: *missing FROM-clause entry*). A
    `cjoin_on` alias and a join path are now two namespaces, so the overlap is simply two relations
    that happen to share a name.

    One name a CTE may never take is a **physical table name**: `.with("driver" => ...)` raises
    `QueryBuildError` at the call when `driver` is the `db_table` of any registered model, or a
    many-to-many join table. SQL resolves an unqualified table reference to a same-named CTE for the whole statement,
    so the `driver` join PormG generates for `driverid__surname` would silently read the CTE
    ([#479](https://github.com/PingoLee/PormG.jl/issues/479)). Pick a name that is not a table.

    `cjoin_on` works in reads and in the common `update()`/`delete()` (which scope rows via a
    subquery); only a **correlated** UPDATE-FROM/DELETE-USING (setting a column *from* a joined
    table) is unsupported and raises. Finally, a `cjoin_on` join is not tracked by the #74
    aggregate fan-out guard — if the join is to-many, aggregate the base table with `distinct=true`
    (or over the joined table's own column) to avoid silent row multiplication.

!!! warning "Give the join a predicate that names its own alias"
    Every predicate in `on` that references a join emitted *after* this one is moved onto that
    join — it has to be, because a join cannot reference an alias that has not appeared yet. If
    **all** of them move, your join is left with no `ON` clause and PormG raises, naming the alias
    they went to (#435):

    ```julia
    query = M.Result.objects
    query.values("points")
    query.cjoin_on("Driver", alias = "d", on = ["raceid__circuitid__country" => "Italy"])
    # ERROR: Every ON predicate given for d resolved onto Tb_2 instead, …
    ```

    **The fix depends on whether your predicates name the alias at all**, and the two cases pull
    in opposite directions. The error message tells you which one you are in.

    *Nothing names it* — as above. The join has nothing correlating it. Add a predicate that does
    (`Joined("d", "driverid") == F("driverid")`), or move the conditions to `.filter(...)` and drop the
    `cjoin_on` entirely — it needs at least one `on` predicate, so moving them all out without
    removing the call raises too.

    Here, **do not** "fix" it by projecting the path in `values(...)` first. That builds those
    joins ahead of the `cjoin_on`, so nothing needs to move — and you get
    `INNER JOIN "driver" AS "d" ON "Tb_2"."country" = ?`, an `ON` clause that never mentions `d`.
    That is an unconstrained join: every `driver` row against every qualifying base row. PormG
    refuses it too (#448), so projecting trades one error for another rather than fixing anything.

    *It names the alias and a deeper path* — `on = [Joined("d", "nationality") == F("raceid__circuitid__country")]`,
    drivers racing in their home country — is a real correlation that moved only because the join
    on its other side is built later. Projecting **is** the fix here: add
    `raceid__circuitid__country` to `values(...)` and the clause renders exactly as written.

    *It names the alias and another `cjoin_on` alias* — there is no path to project, so declare
    the predicate on whichever of the two PormG emits **later**; the reference then points
    backwards and nothing moves. The error message names that join for you. Give the first join an
    `ON` predicate of its own as well — it is still joined, and `cjoin_on` requires at least one:

    ```julia
    # ✗ before — d1's only predicate names d2, which is emitted after it
    query.cjoin_on("Driver", alias = "d1", on = [Joined("d1", "surname") == Joined("d2", "surname")])
    query.cjoin_on("Driver", alias = "d2", on = [Joined("d2", "driverid") == F("driverid")])

    # ✓ after — the shared predicate moves to d2, and d1 gets one of its own
    query.cjoin_on("Driver", alias = "d1", on = [Joined("d1", "driverid") == F("driverid")])
    query.cjoin_on("Driver", alias = "d2", on = [Joined("d2", "surname") == Joined("d1", "surname")])
    ```

    **Two `cjoin_on` joins are emitted in the order you declare them**, so "whichever PormG emits
    later" is the one you wrote second — a rule you can apply without running the query. (Until
    [#449](https://github.com/PingoLee/PormG.jl/issues/449) that order came from hashing the alias
    *strings*, so renaming an alias could flip a working query into an error and reversing your
    declarations changed nothing.)

    More generally, an `ON` clause that never names its own alias is **refused**
    ([#448](https://github.com/PingoLee/PormG.jl/issues/448)): `on = ["points__@gt" => 10]` puts no
    condition on the join at all, so every joined row would pair with every matched base row. Give
    every `cjoin_on` at least one predicate naming its own alias.

    If you genuinely want a cross product, declare the table as an **unkeyed** CTE and **reference
    it** — declaring it alone emits no join at all:

    ```julia
    q.with("all_drivers" => M.Driver.objects.values("driverid", "surname"))  # no join_field
    q.values("points", "who" => CTE("all_drivers", "surname"))               # the reference is
                                                                             # what joins it
    q.limit(100)   # illustrative: this is drivers × results, so bound it
    ```

    That renders a real `CROSS JOIN` and warns that it is Cartesian (#44), so the intent is visible
    in the query and in the log rather than hidden in an `ON` clause.

    **`join_type = "CROSS"` is not the way to ask for this.** It raises `QueryBuildError` on
    `cjoin`, `cjoin_on`, `on()` and `.with()` alike. Every one of those renders
    `<join_type> JOIN <table> AS <alias> ON <clause>`, so a `CROSS` there could only ever build
    `CROSS JOIN … ON …`, which PostgreSQL and SQLite both reject — and on `cjoin_on`, where at
    least one `ON` predicate is required (#448), the alternative would have been to discard the
    predicates you wrote. The unkeyed-and-referenced `.with(...)` above is the supported spelling
    ([#474](https://github.com/PingoLee/PormG.jl/issues/474)).

## Use Cases

### 1. Legacy Databases Without Foreign Keys

When your database doesn't have proper foreign key constraints:

```julia
# Join on a code field instead of ID
query = M.Order.objects.
    cjoin("product_code" => "Product").  # Joins on product_code = Product.code
    values("product_code__name", "quantity")
```

### 2. Multi-Tenant Systems

Add tenant isolation at the join level:

```julia
query = M.Invoice.objects.
    cjoin("customer_id" => "Customer", 
            filters=["tenant_id" => current_tenant_id]).
    values("customer_id__name", "amount")
```

### 3. Conditional Joins with Complex Logic

Join only when certain conditions are met using Q/Qor:

```julia
query = M.Result.objects.
    cjoin("driverid" => "Driver",
            filters=[Q("nationality" => "British", Qor("code" => "HAM", "code" => "BUT"))],
            join_type="INNER").
    values("driverid__forename", "driverid__surname", "points")
```

This creates: `ON ... AND (driver.nationality = ? AND (driver.code = ? OR driver.code = ?))`

### 4. Driver Filtering (Real-World Example)

Find results for drivers of a specific nationality with specific names:

```julia
# Add both a custom join condition and a regular filter
query = M.Result.objects.
    cjoin("driverid" => "Driver", filters=[
        Q("nationality" => "Brazilian", Qor("forename" => "Ayrton", "forename" => "Nelson"))
    ]).
    filter("points__@gt" => 0).  # Regular WHERE clause filter
    values("driverid__forename", "driverid__surname", "points")

df = query |> DataFrame

# Result: Only Brazilian drivers named Ayrton or Nelson with points > 0
```

## API Reference

```julia
query.cjoin(main_join; filters=[], field=nothing, join_type="LEFT")
```

### Arguments

| Argument | Type | Description |
|----------|------|-------------|
| `main_join` | `Pair{String, String}` | Field name => Target model name (e.g., `"result" => "Result"`) |
| `filters` | `Vector` | Optional conditions for the ON clause. Supports `Pair`, `Q()`, `Qor()`, operator suffixes, or F expressions. Plain field names in filters are automatically prefixed with the join path. |
| `field` | `PormGField` | Optional custom field definition |
| `join_type` | `String` | Join type: `"LEFT"`, `"INNER"`, `"RIGHT"`, `"FULL"` (default: `"LEFT"`). `"CROSS"` raises `QueryBuildError`; see the cross-product note in the `cjoin_on` section above |

### Filter Types in `.cjoin()`

- **Pair filters**: `"field" => value` - Plain field names are automatically prefixed (e.g., `"nationality"` → `"driverid__nationality"`)
- **Q filters**: `Q("field1" => val1, "field2" => val2)` - AND logic; plain field names are prefixed recursively
- **Qor filters**: `Qor("field1" => val1, "field2" => val2)` - OR logic; plain field names are prefixed recursively
- **Operator suffix filters**: Complex operator-based filters using the suffix operator system (e.g., `"nationality__@ne" => "British"`)
- **F expressions**: Field-to-field comparisons (e.g., `F("field1") == F("field2")`)

## Important Notes

### Parameter Placement

When using `.cjoin()` with filters:
- **Join filter parameters** (from `filters=`) are placed in the **ON clause** of the JOIN and should reference joined-model fields
- **Regular filter parameters** (from `.filter()`) are placed in the **WHERE clause**

This is important for query efficiency and correctness:

```julia
# This parameter goes to WHERE clause, cjoin filters go to ON clause
query = M.Result.objects.
    filter("points" => 10).
    cjoin("driverid" => "Driver", filters=["nationality" => "Brazilian"])

# Result SQL:
# ... ON driver.driverid = result.driverid AND driver.nationality = ?
# WHERE result.points = ?
```

### Field Name Normalization

When you provide plain field names in `.cjoin()` filters, they are automatically prefixed with the join field to resolve them against the joined model:

```julia
# "nationality" is automatically prefixed to "driverid__nationality"
query = M.Result.objects.cjoin("driverid" => "Driver", filters=["nationality" => "Brazilian"])

# This works with Q and Qor too:
query = M.Result.objects.cjoin("driverid" => "Driver", filters=[
  Q("nationality" => "Brazilian", Qor("forename" => "Ayrton", "forename" => "Nelson"))
])

# All three fields (nationality, forename, forename) are auto-prefixed
```

If a field belongs to the base model instead, keep it in `.filter(...)` rather than `.cjoin(...)`:

```julia
query = M.New_join_position.objects.
    cjoin("result" => "Result", filters=["resultid" => 1]).
    filter("description" => "teste 1")
```

### ForeignKey Target Validation

When a join field already has a defined `ForeignKey` on the model, `.cjoin()` validates that the target model matches:

```julia
# This works: Result.driverid FK points to Driver
query = M.Result.objects.
    cjoin("driverid" => "Driver", filters=["nationality" => "Brazilian"]).
    values("driverid__surname")

# This raises an error: driverid points to Driver, not Constructor
query = M.Result.objects.
    cjoin("driverid" => "Constructor", filters=["name" => "Ferrari"])  
# QueryBuildError: Field 'driverid' is already a ForeignKey pointing to 'Driver', 
# but `.cjoin()` attempted to join with 'Constructor'...
# Use query.cjoin("driverid" => "Driver", filters=[...]) instead.
```

**Why this validation exists:** If a ForeignKey target is mismatched, field prefixing would resolve against the wrong model, silently breaking your filters. By enforcing target model matching, `.cjoin()` ensures ON-condition filters always apply to the correct joined model.

### Auto-Discovery Warning (No Explicit FK Link)

If the source field in `main_join` is **not** a ForeignKey field and you do not pass `field=...`, `.cjoin()` auto-discovers the target model primary key and logs a **warning by default** to ensure you are joining intentionally.

Example:

```julia
# "result" is an IntegerField, not a ForeignKey
query = M.New_join_position.objects.cjoin("result" => "Result")

# cjoin warns and auto-links:
# main.result -> Result.resultid   (or the model PK)
```

#### If your intended link is not the target model PK

Pass an explicit field mapping:

```julia
query = M.New_join_position.objects.cjoin("result" => "Result",
      field=Models.ForeignKey("Result", pk_field="your_target_field"))
```

This keeps behavior explicit and avoids accidental joins to the wrong target column.

#### If you intentionally want auto-discovery without the warning

You can suppress the warning using the `warn` parameter:

```julia
# Suppress the auto-discovery warning
query = M.New_join_position.objects.cjoin("result" => "Result", warn=false)
```

This is useful when you're confident about the join link and don't want the informational message in production logs.

### Other features are in development and will be documented soon.
