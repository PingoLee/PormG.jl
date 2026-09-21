## Query-builder errors are a typed `PormGError` taxonomy — stop catching `ArgumentError` (#231)

- **Version**: 0.3.0
- **PormG ref**: issue #231 ; `src/PormG.jl` (abstract root + exports), `src/querybuilder/exceptions.jl`
  (subtypes + `showerror` + `_write_not_allowed`), the throw sites across `src/querybuilder/*.jl`,
  `docs/src/api.md`
- **Recorded**: 2026-07-24
- **Severity**: **breaking (error contract)** — every query-builder misuse now raises a subtype of
  `PormGError` (`<: Exception`) instead of a bare `ArgumentError`/`ErrorException`. The subtypes are
  **NOT** `<: ArgumentError` (a clean break), so `catch ArgumentError` / `occursin(text, e.msg)` blocks
  around PormG query calls stop matching. Part of the `0.3.x` pre-publish wave; extends the #197
  typed-exception lineage. **Supersedes the type in the #205 entry below:** the standardized
  write-disabled error is now `PermissionError`, not `ArgumentError`.

### What changed

Query-builder failures now carry a semantic **type**, so callers react programmatically instead of
matching a message string. The root is `PormGError <: Exception`; catch it for any query-builder
failure, or a specific subtype:

| Subtype | Raised when |
|---------|-------------|
| `UnknownFieldError` / `LazyTraversalError` (both `<: FieldAccessError`) | field/column/`__`-path not found; or an unprojected `ForeignKey` read off a fetched row (steer to `values(...)`) |
| `FilterError` | invalid filter argument/shape; operator misuse on a JSON/subquery column |
| `QueryBuildError` | structural/API misuse (joins, CTEs, projection, ordering, window/bulk config) — the long-tail default |
| `UnsafeMutationError` | `update()`/`delete()` without a filter (or another unsafe shape) |
| `InvalidValueError` | value coercion/type mismatch on insert/update; identifier-safety guard; interval/duration parse |
| `PermissionError` | connection not allowed to insert/update/delete (`change_data=false`) — this is the #205 write-disabled error, now typed |
| `UnsupportedConnectionError` | connection is neither PostgreSQL nor SQLite, or a model is not bound to a connection |
| `DoesNotExist` / `MultipleObjectsReturned` | `get()` found zero / more than one row (reparented under `PormGError`) |

**Out of scope in `0.3.0` (still `ArgumentError` at the time):** field-constructor validation
(`src/models/fields.jl`) and model/schema-definition errors (`src/Models.jl`). ⚠️ **This is no longer
true** — #239 migrated them; see *"The `PormGError` taxonomy now covers all of PormG"* above. Do not
plan a migration from this paragraph.

### How to find the calls to migrate

```
rg -n 'catch|@test_throws|isa' <app> | rg 'ArgumentError|ErrorException'
```

Focus on blocks wrapping PormG query calls (`filter`/`values`/`update`/`delete`/`get`/row access/`bulk_*`).
Field-definition and model-definition errors still throw `ArgumentError` — leave those. ⚠️ **This is no
longer true** — #239 retyped them to `FieldValidationError` / `ModelDefinitionError`. If you already
migrated on this instruction, revisit exactly those catches; see *"The `PormGError` taxonomy now covers
all of PormG"* above.

### Migrate your app

```julia
# ✗ before — coupled to the message wording (incl. the #205 write-disabled catch)
try
    run_query()
catch e
    e isa ArgumentError && occursin("not allowed to write", e.msg) && fall_back_to_readonly()
    rethrow(e)
end

# ✓ after — catch the semantic type, or the abstract root for any query-builder misuse
try
    run_query()
catch e
    e isa PormG.PermissionError    && return fall_back_to_readonly()  # the #205 write-disabled case
    e isa PormG.LazyTraversalError && return steer_to_projection()    # unprojected FK read
    e isa PormG.PormGError         && return handle_pormg_error(e)    # anything the QB rejected
    rethrow(e)
end
```
