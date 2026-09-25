## `values` — a condition naming both a model field and another projection's alias raises `AmbiguousFieldError` (#706)

- **Version**: Unreleased
- **Recorded**: 2026-09-24
- **PormG ref**: #706; `src/querybuilder/build_query.jl` (`_guard_select_condition_collision`)
- **Severity**: behavior change. A projection list that used to render, with a meaning that
  depended on declaration order, now raises when the query is built.

### What changed

A condition inside a projection, such as a `When` in a `Case` or a `Q` inside one, can name a key
that is both a model column and another projection's alias. It had the same two meanings a
`filter(...)` on that key has (#703), and PormG picked one by **declaration order**:

- **condition first** → the condition read the column, and the colliding projection **silently
  vanished**. `values("f" => Case([When("points" => 4, then = 1)], default = 0), "points" => Sum("points"))`
  rendered `"Tb"."points" as "points"`: the `SUM` you asked for was replaced by the raw column, with
  no error;
- **alias first** → the condition compared the projection, `CASE WHEN SUM("Tb"."points") = ? …`,
  and that `CASE` was also put in `GROUP BY`. Both engines reject an aggregate there, so this order
  failed at the driver. Only the condition-first order ever executed, and that is the silent one.

Both orders now raise `AmbiguousFieldError`, whether the condition is a `When` pair, a `Q`/`Qor`
inside a `Case`, a `Case` in a window's `partition_by` or `order_by`, or carries a lookup suffix
(`"points__@gt"`). The message names the projection
holding the condition, both readings and the rename that resolves it. This is #703's rule, applied to
the SELECT side.

**Not refused:**

- a projection whose **own** condition names it: `"points" => Case([When("points" => 4, then = 1)], default = 0)`.
  Inside the expression that defines it, the name can only mean the column;
- a colliding projection that **is** the column: `values("points")`, `"points" => "points"`,
  `"points" => F("points")`;
- a condition on a key that names **no** field, such as `When("doubled" => 4)` over
  `"doubled" => F("points") * 2`. That is a plain alias read, and it still reads the projection.

Measured before the change, across the three consuming apps that use PormG: 0 of 241 `values(...)`
calls have a condition on another projection's field-named alias. The six `When` calls there
either condition on their own projection's column or sit beside aliases spelled with `__`, which
cannot equal a plain column key.

### How to find the calls to migrate

The error names the key and the projection, so the quickest check is to run the app's queries. To
find candidates statically, list the `values(...)` calls that contain a `When(` or a `Q(`:

```bash
grep -rnP 'values\(.*\b(When|Q|Qor)\(' --include=*.jl .
```

A multi-line `values(...)` defeats that line-oriented grep, so also list every `When(` and read the
projection list around each one:

```bash
grep -rn 'When(' --include=*.jl .
```

A hit needs migrating when its condition key (without a `__@` suffix) is also the alias of **another**
projection in the same call, and that projection is not the column itself.

### Migrate your app

```julia
# Before: the SUM projection silently rendered as the raw column
query = M.Result.objects
query.values("raceid",
             "podium_finish" => Case([When("points__@gte" => 15, then = 1)], default = 0),
             "points" => Sum("points"))

# After: rename the alias; the condition then reads the column
query = M.Result.objects
query.values("raceid",
             "podium_finish" => Case([When("points__@gte" => 15, then = 1)], default = 0),
             "total_points" => Sum("points"))
```
