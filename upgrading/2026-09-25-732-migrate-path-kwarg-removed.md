## `migrate(connection, settings; path=…)`: the unused `path` keyword is removed (#732)

- **Version**: Unreleased
- **Recorded**: 2026-09-25
- **PormG ref**: #732; `src/migrations/runner.jl` (`migrate`)
- **Severity**: breaking (keyword argument removed)

### What changed

The connection-level `migrate(connection, settings; …)` method declared
`path::String = "db/models/models.jl"` and never read it. The plan always comes from
`settings.db_def_folder`. The keyword is removed, so passing it is now a `MethodError`
(``no method matching migrate(…; path::String)``). The `migrate("db"; …)` entry point never
accepted `path`, so calls through it are unaffected.

### How to find the calls to migrate

```bash
grep -rnE -A3 'migrate\(' --include=*.jl . | grep -E '[^_[:alnum:]]path[[:space:]]*='
```

`-A3` catches a call whose keywords sit on the following lines.

### Migrate your app

```julia
# ✗ before — `path` was accepted and ignored
PormG.Migrations.migrate(settings.connections, settings; path = "db/models/models.jl")

# ✓ after — drop it; the plan is read from settings.db_def_folder either way
PormG.Migrations.migrate(settings.connections, settings)
```
