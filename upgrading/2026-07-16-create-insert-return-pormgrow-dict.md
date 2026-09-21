## `create()` / `insert()` return a `PormGRow` (was `Dict`)

- **PormG ref**: issue #166 ; `src/querybuilder/execution.jl`
- **Recorded**: 2026-07-16
- **Severity**: **breaking (return type)** / behavior improvement — the row surface is now uniform.

### What changed

`create()` / `insert()` now return a **`PormGRow`** on the execute path — the same row object
`get()`, `first()`, `list()`, and `update_or_create()` already return — instead of a bare
`Dict{Symbol,Any}`. This makes the row surface consistent and lets a created row be mutated and
`.save()`d:

```julia
row = M.Driver.objects.create("forename" => "Ayrton", "surname" => "Senna")
row[:driverid]        # unchanged — PormGRow delegates indexing/haskey/keys/get/pairs/iterate
row.surname           # now also works (dot-access)
row.surname = "SENNA"; row.save()   # and it round-trips
```

`show_query=:sql/:dict/:params` still return their inspection shapes (String/Dict/Vector) — only the
`:execute` return changed. `list(:dict)` and `values()` still return plain dicts. `update()` still
returns a matched-row count.

### How to find the calls to migrate

Because `PormGRow` delegates `getindex`/`haskey`/`get`/`keys`/`values`/`pairs`/`iterate`, the common
patterns (`row[:id]`, `haskey(row, :x)`, iterating pairs) keep working unchanged. Only these break:

```
# 1. Type checks that assumed a Dict:
grep -rn "create(" src/ | grep -i "isa Dict"
grep -rn "= .*\.create(" src/            # then check for `isa Dict`, `merge(`, `delete!(`

# 2. Dict-only MUTATION of a create() result (PormGRow has no setindex!):
grep -rn "\.create(" src/ | ...          # then look for `result[:x] = ...` on that result
```

### Migrate your app

- `@assert result isa Dict` → `@assert result isa PormG.QueryBuilder.PormGRow` (or drop the type
  check — field access is unchanged).
- Adding/overwriting a key on the result: `result[:x] = v` → `result.x = v` (dot-assign), and
  `result.save()` if you want it persisted. (Read access `result[:x]` is unchanged.)
- Passing the result somewhere typed `::Dict`, or `merge(result, …)` / `collect(result)` /
  `length(result)` / `result == Dict(…)`: convert first with `Dict(pairs(result))`.
