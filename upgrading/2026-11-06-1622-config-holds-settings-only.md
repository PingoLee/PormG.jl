## `PormG.config` holds `Configuration.Settings` only (#1622)

- **Version**: Unreleased
- **PormG ref**: #1622, part of #1599 ; `src/Kernel.jl`, `src/Configuration.jl`
- **Recorded**: 2026-11-06
- **Severity**: breaking, for code that stores its own `PormGSettings` subtype in `PormG.config` or
  passes its own dictionary as `config =`. Code that loads or registers connections is unaffected.

### What changed

The registry of loaded connections is typed by the one concrete settings type:

| | before | now |
|---|---|---|
| `PormG.config` | `Dict{String,PormGSettings}` | `Dict{String,PormG.Configuration.Settings}` |
| `get_settings(key)` | inferred `PormGSettings` | returns `Settings` |
| the `config =` keyword of `load`, `load_many`, `migrate`, `status`, `check`, `dry_run`, … | `Dict{String,PormGSettings}` | `Dict{String,Settings}` |

With the abstract value type, every read of `get_settings(key).<field>` was an untyped value: one
dynamic dispatch per read, and a call `juliac --trim` refuses (#1599). `Settings` moved into
`PormG.Kernel` so the registry can name it. `PormG.Configuration.Settings` still names it, and
`PormGSettings` stays its abstract supertype.

Storing any other `PormGSettings` subtype now raises a `MethodError` (no `convert` to `Settings`).
So does passing a `Dict{String,PormGSettings}` as `config =` (a `TypeError`). Nothing in PormG ever
built either. The pattern is a test stand-in: a struct with a `connections` field registered under
a test key.

### How to find the calls to migrate

```
grep -rn "<: *\(PormG\.\)\?PormGSettings\|Dict{String, *\(PormG\.\)\?\(Configuration\.\)\?PormGSettings}" --include=*.jl .
```

### Migrate your app

`Settings.connections` takes any pool, a test's own `<: PormGSQLite` stand-in included, so build a
`Settings` around it instead of declaring a settings type:

```julia
# ✗ before
struct FakeSettings <: PormG.PormGSettings
    connections::FakePool
end
PormG.config["fake"] = FakeSettings(FakePool())

# ✓ after
PormG.config["fake"] = PormG.Configuration.Settings(connections = FakePool())
```

```julia
# ✗ before
cfg = Dict{String, PormG.PormGSettings}()
PormG.Configuration.load("db"; env = "test", config = cfg)

# ✓ after
cfg = Dict{String, PormG.Configuration.Settings}()
PormG.Configuration.load("db"; env = "test", config = cfg)
```
