## `create()` / `update()` raise `UnknownFieldError` for an unknown field name, not `InvalidValueError` (#462)

- **Version**: 0.6.0
- **PormG ref**: #462 ; `src/querybuilder/sanitization.jl`, `src/querybuilder/build_helpers.jl`
- **Recorded**: 2026-09-15
- **Severity**: behavior change — only for code that catches a *specific* `PormGError` subtype.

### What changed

Naming a field that does not exist on the model reported `InvalidValueError` on the write path, a
type whose own docstring scopes it to a **value** that failed coercion. A bad field *name* is not a
bad value, and `docs/src/api.md` already promised `UnknownFieldError` for *"a field … that does not
exist on the model"* with no carve-out for writes.

It was also the only such site left. `filter` / `values` / `order_by` were converted in #446, and
`get_or_create`, `update_or_create` and every `bulk_*` writer already raised `UnknownFieldError` —
so `create()` disagreed with its own sibling on the same input.

```julia
# Every required field supplied, plus one misspelled extra — the required-field sweep runs first,
# so a call that ALSO leaves a NOT NULL field unset reports that instead, before and after.
M.Driver.objects.create("driverref" => "hamilton", "code" => "HAM", "forename" => "Lewis",
                        "surname" => "Hamilton", "dob" => Date(1985, 1, 7),
                        "nationality" => "British", "url" => "...",
                        "sirname" => "Hamilton")
# before → InvalidValueError: Error in insert for model driver, field "sirname": field does not exist in the model schema
# after  → UnknownFieldError: the column sirname not found in driver, that contains the fields: code, dob, driverid, ...
```

Both are `PormGError`, so `catch e; e isa PormGError` is unaffected. Only a `catch` naming
`InvalidValueError` specifically, around a **write**, needs to change — and only for the typo case:
a null on a `null=false` field, an oversize value, a wrong-typed value and a protected primary key
all still raise `InvalidValueError`.

The message is now the read path's, from the same funnel, so a typo reads identically wherever you
make it. One deliberate difference: the write message does **not** list the model's reverse
accessors, because they are addressable in a filter path but are not columns you can write.

### How to find the calls to migrate

```bash
grep -rnE 'InvalidValueError' <your app>/ | grep -iE 'create|update|bulk'
```

A handler that reacts to a typo — logging "check the column name", say — is the one to move. A
handler reacting to a rejected *value* stays as it is.

### Migrate your app

```julia
# ✗ before — catches both the typo and the bad value
try
    M.Driver.objects.create(payload...)
catch e
    e isa InvalidValueError && return bad_request("check the column names and values")
    rethrow()
end

# ✓ after — the two mistakes are now separable
try
    M.Driver.objects.create(payload...)
catch e
    e isa UnknownFieldError && return bad_request("unknown column: $(error_message(e))")
    e isa InvalidValueError && return bad_request("a value this column cannot store")
    rethrow()
end
```
