## Error contract, final pass: renames, capability split, and closed escape hatches (audit / #268)

- **Version**: 0.4.0
- **PormG ref**: the 2026-07-30 taxonomy audit; `src/exceptions.jl`, `src/Backend.jl`,
  `src/Configuration.jl`, `src/ConnectionPool.jl`, `src/Dialect.jl`, `src/migrations/*`,
  `src/querybuilder/*`, `docs/src/api.md`; boundary decision deferred to #268
- **Recorded**: 2026-07-30
- **Severity**: **breaking (error contract)** — the last pre-publish pass over error types. Three
  renames, one type split, two new types, one umbrella, and ~20 formerly-untyped escape hatches now
  raise taxonomy types. Part of the `0.3.x` pre-publish wave.

### Renames (mechanical)

| Before | After | Why |
|---|---|---|
| `PermissionError` | `WritesDisabledError` (now `<: ConfigurationError`) | The old name read as OS/file permissions or DB GRANTs; it means PormG's own `change_data: false` switch, and its remedy is a `connection.yml` edit |
| `MissingDatabaseConfigurationException` | `MissingConfigurationError` | The sole `*Exception` that survived the #231 clean break |
| `UnsupportedConnectionError` (capability cases) | `BackendCapabilityError` | See the split below |

### The `UnsupportedConnectionError` split

One type covered three disjoint remedies, distinguishable only by message text:

- **Backend capability limits** → **`BackendCapabilityError`** (new): JSONB / `iunaccent_*` lookups
  on SQLite, window `frame=` on SQLite (was `QueryBuildError`), `bulk_copy` on SQLite, too-old
  SQLite library, an importer pointed at the wrong backend.
- **Model not bound to a connection** → **`InvalidConfigurationError`** (whose docstring always
  claimed this case). All three former entry-path variants now agree, and a fourth path that
  produced a raw `MethodError` (config entry present but pool never built) is typed too.
- **Internal dispatch bugs** keep `UnsupportedConnectionError` — "please report" cases only.

### New types and umbrella

- **`ProtectedError`** (new): `delete()` refused because rows reference the target via
  `on_delete = PROTECT`/`RESTRICT`. Was the long-tail `QueryBuildError`, which made "the data
  forbids this" indistinguishable from "your delete call is malformed". Mirrors Django.
- **`DefinitionError`** (new abstract): umbrella over `FieldValidationError` +
  `ModelDefinitionError` — one `include("models.jl")` can raise either. Non-breaking to catch.

### Formerly untyped escapes — `catch PormGError` now actually covers these

- **Bulk row validation** (`bulk_insert`/`bulk_copy`/`bulk_update`): a failing row now rethrows
  PormG's own error (e.g. `InvalidValueError`) instead of stringifying it into `ErrorException` —
  `catch InvalidValueError` now behaves the same for `insert()` and `bulk_insert()`.
- **Missing driver** (`using SQLite`/`using LibPQ` forgotten): all backend generics now raise
  `InvalidConfigurationError` instead of `ErrorException` (message unchanged).
- **Migration engine**: no-pending-plan, SQLite PK-column deletion, missing models file
  (`MissingConfigurationError`), unparseable introspected DDL, importer field failures — all typed
  (`InvalidMigrationError` unless noted); a wrapped `FieldValidationError` now rethrows as itself.
- **`before_connect` hook abort** → `PoolConnectError` (so `catch PoolError` covers it).
- **`get_or_create` unknown lookup/defaults field** → `UnknownFieldError`, matching
  `update_or_create` (they disagreed).
- **`SET_NULL` on a `null=false` FK** → `ModelDefinitionError` (schema self-contradiction; was
  `InvalidValueError`).

**Still outside the taxonomy, deliberately:** runtime database failures (constraint violations,
rejected SQL, dropped connections) still propagate as raw driver exceptions — that boundary is the
open pre-publish decision in **#268**, now stated honestly in `api.md`. `with_advisory_lock`'s
timeout stays `ErrorException` pending the same decision.

### How to find the calls to migrate

```
rg -n 'PermissionError|MissingDatabaseConfigurationException' <app>
rg -n 'UnsupportedConnectionError' <app>   # decide per site: capability → BackendCapabilityError
rg -n 'catch|@test_throws|isa' <app> | rg 'ErrorException'   # bulk/migration/driver-hint catches
```

### Migrate your app

```julia
# ✗ before
catch e
    e isa PermissionError && fall_back_to_readonly()

# ✓ after
catch e
    e isa WritesDisabledError && fall_back_to_readonly()
```

A `catch UnsupportedConnectionError` around a query that might hit a backend limit must become
`catch BackendCapabilityError`; one guarding against a missing driver becomes
`catch InvalidConfigurationError`.
