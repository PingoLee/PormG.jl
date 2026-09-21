## `PormG.Migrations` no longer exports its schema-introspection helpers (#274)

- **Version**: 0.4.0
- **PormG ref**: #274; `src/Migrations.jl`
- **Recorded**: 2026-08-01
- **Severity**: **breaking (export surface)** — narrow: it affects only code that does
  `using PormG.Migrations` *and* calls one of nine names unqualified. Part of the `0.3.x`
  pre-publish wave.

### What changed

Nine names were exported by `PormG.Migrations` that are schema-introspection and module-scanning
plumbing, not API. None appears anywhere in the documentation, every call site outside
`src/migrations/` was already qualified, and `get_sequence_name` had no caller anywhere in the repo.
Exporting them made them read as public, and put them on the docstring-coverage guard for a surface
nobody consumes.

They are **still there and still work** — they are just no longer exported, so reach them qualified:

```
get_database_schema   get_all_models        get_all_dicts
get_constraints_fk    get_constraints_index get_sequence_name
get_constraints_pk    get_constraints_unique get_constraints_check
```

The last three are a special case: they are `PormG.Kernel` generics that `Kernel` already exports,
so `Migrations` was re-exporting a name it did not own. **`PormG.get_constraints_check(...)` and
friends keep resolving as qualified calls** — including extending them with your own method for a
mock.

> **Amended by #283:** one exception to "unchanged". `get_constraints_pk`'s second parameter was
> narrowed from `Symbol` to `String`, so a qualified call passing a `Symbol` table name — or a mock
> method typed `(::MyMock, ::Symbol, ::String)` — no longer dispatches. Pass a `String` instead. It
> was unreachable through PormG itself (its only caller passed the wrong arity and always raised
> `MethodError`), which is why it is recorded here rather than as its own entry.

`names(PormG)` is unchanged (63), so nothing that only does `using PormG` is affected.

### How to find the calls to migrate

```bash
# Only files that pull the module in wholesale can be affected:
rg -l 'using PormG\.Migrations|using PormG: Migrations' --type julia
# …then, within those, look for the nine bare names:
rg -n '\b(get_database_schema|get_all_models|get_all_dicts|get_constraints_fk|get_constraints_index|get_sequence_name|get_constraints_pk|get_constraints_unique|get_constraints_check)\s*\(' --type julia
```

An already-qualified call (`Migrations.get_migration_plan(...)`, `PormG.get_constraints_check(...)`)
needs no change.

### Before → after

```julia
# before — relied on the export
using PormG.Migrations
schema = get_database_schema(conn)
models = get_all_models(my_models_module)

# after — qualify
using PormG.Migrations
schema = PormG.Migrations.get_database_schema(conn)
models = PormG.Migrations.get_all_models(my_models_module)
```

Note `get_all_models` also collides with a *different* `Models.get_all_models`; qualifying removes
the ambiguity as a side effect.
