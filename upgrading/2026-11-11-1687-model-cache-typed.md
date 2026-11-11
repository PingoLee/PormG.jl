## `ModelType.cache` is a typed `ModelCache`, read by field, not by string key (#1687)

- **Version**: Unreleased
- **PormG ref**: #1687, #1599 ; `src/Models.jl`, `src/migrations/`
- **Recorded**: 2026-11-11
- **Severity**: breaking, for code that reads or writes `model.cache` by string key, or builds a
  `ModelType` with `cache = Dict(…)`. The functions that read the cache
  (`Models.declared_check_constraints`, `Models.get_many_to_many_relation`,
  `Models.has_many_to_many_accessor`, `Migrations.declared_composites`, `Migrations.live_table`) return
  what they returned before.

### What changed

A model's derived metadata was a `Dict{String, Dict{String, Any}}` under string keys, so every read
returned `Any`. It is now a `ModelCache` with one typed field per kind. A string-key read such as
`model.cache["index"]` raises a `MethodError`.

| before | now |
|---|---|
| `model.cache["many_to_many"]` | `model.cache.many_to_many` (`Dict{String, ManyToManyRelation}`) |
| `model.cache["many_to_many_auto"]["owner_column"]`, `…["related_column"]`, `…["field"]`, `…["unique_index"]` | `model.cache.many_to_many_auto` (`nothing`, or an `AutoJoinTable` with those four fields) |
| `model.cache["unique_constraints"]["constraints"]` | `model.cache.unique_constraints` (`Vector{UniqueConstraint}`) |
| `model.cache["check_constraints"]["constraints"]` | `model.cache.check_constraints` (`Vector{CheckConstraint}`) |
| `model.cache["composite_indexes"]["indexes"]` | `model.cache.composite_indexes` (`Vector{Index}`) |
| `model.cache["composite_index_owners"]` | `model.cache.composite_index_owners` |
| `model.cache["index"]` (a model `inspectdb` read) | `model.cache.index` (`Dict{String, Vector{String}}`) |
| `haskey(model.cache, "unique_constraints")` | `!isempty(model.cache.unique_constraints)` |
| `haskey(model.cache, "many_to_many_auto")` | `model.cache.many_to_many_auto !== nothing` |

A kind a model does not have is an empty field (or `nothing`), where it used to be a missing key.
`model.cache["index"]`'s values were already vectors since 0.10.0. A single index name written into
it by hand is no longer accepted: the field holds a `Vector{String}` per column. A `ModelType` built
by hand takes `cache = Models.ModelCache()` (or no `cache` at all), not a `Dict`.

Where one of the functions above answers the question, `Models.declared_check_constraints(model)` or
`Migrations.declared_composites(model)`, it reads the same data as the field.

### How to find the calls to migrate

```
grep -rnE '\.cache\[|(haskey|get!?|delete!)\([^,()]*\.cache, *"|\bcache *= *Dict' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before
uniques = get(get(M.Result.cache, "unique_constraints", Dict()), "constraints", [])
# `inspected`: a model `inspectdb` read; `cache.index` is keyed by physical column
names = get(inspected.cache["index"], "driverid", String[])

# ✓ after
uniques = M.Result.cache.unique_constraints
names = get(inspected.cache.index, "driverid", String[])
```
