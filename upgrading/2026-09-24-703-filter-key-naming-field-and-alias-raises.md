## `filter` — a key that names both a model field and a projection alias raises `AmbiguousFieldError` (#703)

- **Version**: Unreleased
- **Recorded**: 2026-09-24
- **PormG ref**: #703; `src/querybuilder/build_query.jl` (`_guard_field_alias_collision`)
- **Severity**: behavior change. A filter that used to resolve silently, to one meaning or the other
  depending on the shape, now raises when the query is built.

### What changed

`values(...)` can project something under a name that is also a column of the model, for example
`"points" => Sum("points")`. A later `filter("points" => …)` then has two meanings, the column and the
projected value. PormG resolved it with no rule:

- over an aggregate it rendered `WHERE SUM("Tb"."points") = ?`, which both engines reject;
- over a row expression that **binds a value** (`F("points") * 2`) it filtered the expression on
  PostgreSQL and misbound it on SQLite.

**Every other shape executed on both engines, and now raises.** Which meaning it got depended on the
shape:

- **the alias**, for a row expression that binds nothing:
  `values("surname" => Upper("surname")); filter("surname" => "SENNA")` filtered
  `UPPER("Tb"."surname")`, and the `__` path form
  `values("driverid__surname" => Upper("driverid__forename")); filter("driverid__surname" => …)`
  filtered the forename;
- **the column**, for another column under the field's name
  (`values("points" => "grid"); filter("points" => 1)` filtered `points`), and for a window next to
  `values("r" => "points")`, where the column won only because that projection claimed the name
  first.

Such a filter now raises `AmbiguousFieldError` on every spelling: top-level, inside `Q`/`Qor`, and
with a lookup suffix (`"points__@gt"`). The same applies to a relation path used as an alias,
`values("driverid__surname" => Upper("driverid__forename"))` followed by
`filter("driverid__surname" => …)`, which used to filter the alias. The message names both readings
and the rename that resolves it. This follows #492, which refuses a `__` path whose first segment
names both a CTE and a field.

**The declaration stays legal.** `values("raceid", "points" => Sum("points"))` with no filter on
`"points"` renders exactly as before. So does a projection that *is* the column:
`values("points")`, `values("points" => "points")`, `values("points" => F("points"))`.

Measured before the change, in the three consuming apps that use PormG: 0 queries both project and
filter a colliding name. They do declare 270 aliases that are not the column itself, including
`"casos" => Sum("casos")` and `"nu_competencia" => Max("nu_competencia")`. All of them stay legal. The
one query that projects `"matricula" => "mat"` and filters `"matricula"` already fails, because `mat`
is not a field.

### How to find the calls to migrate

The error names the key, so the quickest check is to run the app's queries. To find candidates
statically, list every `values(...)` alias that is not the column itself, then check whether the
same query also filters on that name (top-level, in `Q`/`Qor`, or with a `__@` suffix):

```bash
grep -rnP '"(\w+(?:__\w+)*)"\s*=>(?!\s*"\1")' --include=*.jl .
```

That lists every string-keyed pair, filter pairs included, so read each hit as a candidate rather
than a match.

### Migrate your app

```julia
# Before: two meanings for "points". It rendered WHERE SUM(...) > ? and failed at the driver.
query = M.Result.objects
query.values("driverid__surname", "points" => Sum("points"))
query.filter("points__@gt" => 100)

# After: rename the alias; filter it for HAVING, or the field name for WHERE
query = M.Result.objects
query.values("driverid__surname", "total_points" => Sum("points"))
query.filter("total_points__@gt" => 100)   # HAVING SUM("Tb"."points") > $1
```

```julia
# Before: the field "points" won, although the result column "points" holds grid
query = M.Result.objects
query.values("resultid", "points" => "grid")
query.filter("points" => 10)

# After: name the projection after what it holds
query = M.Result.objects
query.values("resultid", "grid_position" => "grid")
query.filter("points" => 10)                # WHERE "Tb"."points" = $1
```
