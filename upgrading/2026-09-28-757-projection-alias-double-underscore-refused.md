## `values` / `aggregate` — a projection alias containing `__` raises `QueryBuildError` (#757)

- **Version**: Unreleased
- **Recorded**: 2026-09-28
- **PormG ref**: #757 (supersedes #723); `src/querybuilder/object_manager.jl` (`_values!`, `_refuse_path_alias`)
- **Severity**: breaking. A `values(...)` or `aggregate(...)` call that names an alias with `__` now raises where it used to build

### What changed

`__` is PormG's path separator. An alias spelled with it (`"win__total" => Sum("points")`) was
accepted, but every alias router tests "is this key a projection alias?" with a check that rejects
any key containing `__`, while the render still resolved that key through the projection memo. So
filtering or reading the alias went wrong in every direction:

- `filter("win__total__@gt" => 5)` printed `WHERE SUM(…) > ?`, an aggregate in `WHERE`, which both
  engines reject;
- a `When("win__total__@gte" => 100, …)` reading it was put in `GROUP BY`;
- a window alias `"r__k"` escaped the #685 refusal and printed `RANK() OVER` into `WHERE`;
- an alias named like a CTE column (`"ev__points"`) silently lost every filter to the CTE column (#723).

The alias is now refused where it is declared, whatever its right-hand side:

```text
QueryBuildError: Invalid projection alias "win__total": an alias cannot contain __, because PormG
reads `__` as a relation path or a CTE column ("<cte>__<col>") wherever the alias is filtered or
ordered on. Rename it, e.g. "win_total" (#757).
```

The rule covers the pair key of `values("alias" => expr)`, an explicit `SQLField(expr, "alias")`,
and the aliases passed to `aggregate(...)`. It does not cover paths. `values("driverid__surname")`
and `values("surname" => "driverid__surname")` are unchanged, and so is every filter key.

### How to find the calls to migrate

Measured before the change: 7 aliases in 4 `values(...)` calls across the consuming apps, 3 of them
built at runtime by string interpolation.

The first grep lists every `__` pair key that has no lookup suffix. Keep the ones that are the key
of a `values(...)` or `aggregate(...)` argument, or that are pushed into a vector later splatted
into one. Filter keys also match, and are fine as they are. The second lists an explicit
`SQLField(…, "a__b")`, which is refused unless the name is the wrapped path itself:

```bash
grep -rnP '"[^"@\n]*[^_@\s"]__[^@"\n][^"@\n]*"\s*=>' --include=*.jl .
grep -rnP 'SQLField\(.*,\s*"[^"\n]*__[^"\n]*"\s*\)' --include=*.jl .
```

It also finds interpolated keys such as `"flag__$(label)" =>`. An alias built at runtime only fails
when that code runs, so also search the logs and test output for the message:

```bash
grep -rn 'Invalid projection alias' <your-log-dir>
```

Every place that reads the alias back has to change with it: a `filter`/`order_by` key, a
`row[:win__total]` or `df.win__total` lookup, and a `DataFrames` rename or join key built from the
same string.

### Migrate your app

```julia
# ✗ before — raises QueryBuildError at values()
q = M.Result.objects
q.values("raceid", "win__total" => Sum("points"))
q.filter("win__total__@gt" => 5)
rows = q.list()
rows[1][:win__total]

# ✓ after — one underscore; the filter goes to HAVING as documented
q = M.Result.objects
q.values("raceid", "win_total" => Sum("points"))
q.filter("win_total__@gt" => 5)
rows = q.list()
rows[1][:win_total]
```

To keep a column named like the relation path, either project the path itself
(`values("driverid__surname")`, which keeps that output name) or rename the column after the query,
for example with `DataFrames.rename!`.
