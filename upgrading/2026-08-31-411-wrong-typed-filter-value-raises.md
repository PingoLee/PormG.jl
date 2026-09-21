## A wrong-typed filter value raises `FilterError`, not `InvalidValueError` (#411)

- **Version**: 0.5.0
- **PormG ref**: #411, #446; `src/querybuilder/build_helpers.jl`, `src/querybuilder/build_query.jl`,
  `src/querybuilder/types.jl`, `src/querybuilder/build_joins.jl`
- **Recorded**: 2026-08-31
- **Severity**: **behavior change** — only for code that catches a *specific* `PormGError` subtype.
  Everything else in this wave is a fix to something already broken. Part of the `0.5.x` pre-publish
  wave.

### What changed

The filter path used to decide its error type by **matching the text** of the message a formatter
threw — `"The date"` and `"is invalid"`. That matched exactly one formatter method,
`format_date_sql(::AbstractString)`, so a wrong-typed value on a Date field became a `FilterError`
while the same mistake on any other field type escaped as `InvalidValueError` — a type whose own
docstring scopes it to the insert/update coercion helpers, not to a read.

It is now a type check, so the filter path reports its own error type consistently.

```julia
M.Result.objects.filter("points" => "abc")     # IntegerField, wrong-typed value
# before → InvalidValueError
# after  → FilterError
```

Both are `PormGError`, so `catch e; e isa PormGError` is unaffected. Only a `catch` naming
`InvalidValueError` specifically, around a **read**, needs to change.

**One arm is deliberately unchanged:** `@range` / `@nrange` still raise `InvalidValueError`, because
`BETWEEN` formats its two operands outside the guard. That inconsistency is pinned by a test rather
than left to chance.

### Also in this change, and needing no source edit

- **`__@in` now works on every field type** (`BinaryField` since #466, see below). It was an error on
  `DateField`, `DateTimeField`, `BooleanField`, `DurationField` and `UUIDField`, and silently
  **wrong** on `JSONField`, where
  `[1, 2]` was bound as the single JSON document `"[1,2]"` and matched nothing. If you worked around
  any of those, the workaround is now unnecessary — but nothing forces you to remove it.
- **`BinaryField` `__@in` was refused with a clear `FilterError`** by this change, instead of a
  `MethodError` naming an internal function — binary values bind through a wrapper the list
  parameter path could not unwrap, which would have matched nothing rather than fail. #466 taught
  the list parameter path to unwrap, so `filter("blob__@in" => [a, b])` now works on both engines.
  (The `Qor` of single-value comparisons the refusal message suggested never worked either — a
  scalar `"blob" => bytes` filter has no spelling today — so there is nothing to migrate.)
- **A plain `[]` works as an empty `__@in` list.** `[]` is a `Vector{Any}`, which no element bound
  accepted, so the most natural spelling raised a `MethodError`; `Int[]` was the only form that
  worked. A genuinely mixed list (`Any[1, "a"]`) now reports itself instead of leaking one.
- **A scalar UUID filter works.** `filter("uid" => uuid)` raised a `convert` `MethodError`.
- **An empty `__@in` list is defined behavior.** It renders an always-false predicate instead of
  `IN ()`, which was a syntax error on SQLite and valid-but-different on PostgreSQL. `__@nin` over an
  empty list is always true.
- **An unknown field name raises `UnknownFieldError`, not a bare `KeyError`** (#446), in `filter`,
  `values` and `order_by`. The docs have promised `UnknownFieldError` since the taxonomy landed, and
  a `KeyError` was never catchable as a `PormGError` — so a `catch e; e isa KeyError` around a query
  build was also swallowing genuine internal faults, and is worth replacing rather than re-pointing.
  Same shape as the #433 rider.
- **The unknown-field message TEXT changed**, including at the sites that already raised
  `UnknownFieldError`. Before: `The field nope not found in <model name>: <unsorted list>`. After:
  `the column nope not found in <TABLE name>, that contains the fields: <sorted list>`. Note the
  model name became the **table** name, which differ whenever `db_table` is set. Nothing needs to
  change unless you match on that text — but if you do, that is the edit.

### How to find the calls to migrate

```bash
# the only thing that forces an edit: catching InvalidValueError around a READ
grep -rnE 'InvalidValueError' <your app>/ | grep -viE 'insert|update|bulk|create|save'
```

A hit inside a `try` that wraps `filter` / `values` / `list` / a `DataFrame` conversion is the case.
Hits around writes are unaffected — the insert/update path still raises `InvalidValueError`.

### Migrate your app

```julia
# ✗ before — only catches the read case by accident of the old text match
try
    df = M.Result.objects.filter("points" => user_input) |> DataFrame
catch e
    e isa PormG.InvalidValueError && return bad_request("that filter value is not valid")
    rethrow()
end

# ✓ after — name the read path's own type
catch e
    e isa PormG.FilterError && return bad_request("that filter value is not valid")
    rethrow()
end

# ✓ or catch the parent, which spans both and needs no further edit if this ever moves again
catch e
    e isa PormG.PormGError && return bad_request("that filter value is not valid")
    rethrow()
end
```
