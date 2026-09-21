## `values()` refuses two projections that would render the same output name (#441)

- **Version**: 0.5.0
- **PormG ref**: #441; `src/querybuilder/object_manager.jl`, `src/querybuilder/build_query.jl`,
  `docs/src/read/values_and_joins.md`
- **Recorded**: 2026-08-26
- **Severity**: **behavior change (narrow)** — two shapes that render today stop building, and one
  of them (`Value(...)` literals sharing a name) was working correctly rather than silently wrong.
  Part of the `0.5.x` pre-publish wave.

### What changed

`get_select_query` memoises each resolved projection, keyed on `_as`. A second projection under a
name already taken was replaced by the first and never resolved at all — so the caller silently got
one column twice instead of the two they asked for. On SQLite it was worse than a lost column: the
cached field's ALREADY-RENDERED text carries its `?`, so the statement emitted one placeholder more
than the driver had values for and every parameter after it bound one slot early:

```
values("note", "h" => Exists(a), "h" => Exists(b))  +  filter("note" => "TAIL")
    SQLite      3 placeholders, parameters ["AAA", "TAIL"]
                -> "TAIL" bound to the SECOND Exists; the outer WHERE never bound at all
    PostgreSQL  $1 twice, then $2 — legal SQL, still the wrong query
```

`values()` now refuses two projections that would render the same output name. It is refused at the
call rather than repaired at render because two columns under one name are indistinguishable to
everything downstream — a DataFrame column, an `order_by` alias — so no reading of the query keeps
both.

The rule is on the **output** name, so `"*"` counts as the physical columns the database expands it
to, not the declared field names. With `note` declared `db_column = "obs"`, `values("*", "obs" => x)`
collides while `values("*", "note" => x)` does not.

**`Value(...)` duplicates are refused too**, and this is the part that removes working behavior:
`values("lbl" => Value("a"), "lbl" => Value("b"))` renders both parameters correctly today, because
literal projections bypass the memo entirely. It is refused anyway so the rule has no per-kind
exception — a rule that holds only for some projection kinds is the sort of subtlety this defect
family has repeatedly escaped through.

**Unchanged, and in fact newly fixed:** naming the same expression under two *different* names.
`values("a" => "points", "b" => "points")` used to render `as "a"` twice and drop `b`; it now returns
both columns, over a single join where a path is involved. If your code worked around that by
avoiding the shape, the workaround is no longer needed.

Also retired: the #423 ambiguity guard in `order_by()`. It refused `order_by("x")` when `values()`
projected `x` twice; `values()` now refuses that declaration, so the guard was unreachable.

### How to find the calls to migrate

Grep for `values(` calls with a repeated alias, then check `"*"` calls against the model's physical
columns:

```bash
rg -n '\.values\(' .
```

Or programmatically — **run this against your CURRENT pin, before upgrading.** After upgrading it
can never fire, because `values()` throws before you can hold an offending query. Note the `"*"`
expansion: without it the check cannot see a star collision, which is the half most likely to bite:

```julia
function duplicate_projection_names(q)
    m, names = q.object.model, String[]
    for v in q.object.values
        n = v.custom_as !== nothing ? v.custom_as : v._as
        n === nothing && continue
        n == "*" ? append!(names, unique(PormG.Models.field_db_column(m.fields[f], f)
                                         for f in m.field_names)) : push!(names, n)
    end
    [n for n in unique(names) if count(==(n), names) > 1]
end

dups = duplicate_projection_names(query)
isempty(dups) || @warn "values() projects a name twice" dups
```

### Migrate your app

Both pairs below are real F1 columns and were executed against the `db_sl` fixture — the ✗ lines
raise, the ✓ lines run.

```julia
# ✗ BEFORE — `n` twice; the Sum was silently discarded
query = M.Result.objects
query.values("driverid", "n" => Count("resultid"), "n" => Sum("points"))

# ✓ AFTER — distinct names
query = M.Result.objects
query.values("driverid", "n_results" => Count("resultid"), "total_points" => Sum("points"))
```

```julia
# ✗ BEFORE — `statusid` is already one of the columns the star emits
query = M.Result.objects
query.values("*", "statusid" => "points")

# ✓ AFTER — a name the star does not already emit
query = M.Result.objects
query.values("*", "status_points" => "points")
```

If a field carries a `db_column`, the star's contribution is the **physical** name. The F1 fixture's
`Db_column_scratch.sku` declares `db_column = "product_sku"`, so on that model it is
`values("*", "product_sku" => …)` that collides — `values("*", "sku" => …)` does not, because the
star never emits `sku`.
