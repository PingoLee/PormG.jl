## `set_models` / `@import_models` — a models folder with no loaded configuration is refused; the implicit load is a REPL's (#1226, #1248)

- **Version**: Unreleased
- **PormG ref**: #1226, #1248, #1227 ; `src/Models.jl` (`set_models`, `ensure_model_initialized`, `_bind_if_loaded`, `_rebind_from_record`), `src/Configuration.jl` (`_is_interactive`), `src/Utils.jl` (the injected `__init__`s)
- **Recorded**: 2026-10-14
- **Severity**: breaking. Registering models against a folder that no `Configuration.load` has
  loaded raises `InvalidConfigurationError` outside an interactive session. It used to load the
  folder itself, with a warning, everywhere.

### What changed

When `Models.set_models(mod, folder)` found no loaded configuration for `folder`, it called
`Configuration.load(folder)` itself. That load chose two things the application never stated: the
environment (`PORMG_ENV`, else the file's `default_env:`, else `dev`) and the key (the folder's
absolute path). The only signal was a `@warn`. In a service that had not selected its environment,
`dev` is often the production database.

Now it raises `InvalidConfigurationError`. The message names the folder, the keys that are loaded,
and the `load` call to add. The same rule holds wherever models are registered:

| where | before | after |
|---|---|---|
| `@import_models` / `@models_module` / `set_models`, folder not loaded | `@warn`, then an implicit load | `InvalidConfigurationError`; in a REPL, the `@warn` and the load as before |
| first `M.Model.objects` after a precompiled image is restored, the import-time key not loaded | self-heal re-registered the module and loaded the folder implicitly, or remapped the models to any loaded key matching the folder | `InvalidConfigurationError` naming that key and its `load(key; root, env)` call; it binds only to the key recorded at import (#1227) |
| the `__init__` that `@import_models`/`@models_module` inject, folder not loaded | implicit load, errors swallowed | nothing; the first `.objects` raises the error above |

The implicit load is still there in a REPL: when `isinteractive()` is true, a direct
`@import_models` or `set_models` loads the folder, with the old warning. A service, a test or a
script is not interactive and gets the refusal; `Models.set_models(mod, folder; implicit = true)`
asks for the implicit load in one call. There is no process-wide switch. The self-heal and the
injected `__init__` (the last two rows) never load a folder, not even in a REPL.

The self-heal also stopped re-deriving the key (#1227). `@import_models` records in the models
module the key the folder was loaded under and its `root`. On the first `.objects` of a restored
image the models bind to that key when it is loaded and raise when it is not. A configuration loaded
under a different key — the same folder by its absolute path, say — is no longer used in its place.

### Who this affects

Code that registers models before loading their configuration: `@import_models`,
`@models_module` or `set_models` with no earlier `Configuration.load`/`load_many` of that folder in
the same session, including a precompiled package that loads only in its module body. A log that
contains `PormG: no configured connection matches this models folder, so it is being loaded
implicitly` came from this path.

### How to find the calls to migrate

```bash
grep -rnE '@import_models|@models_module|set_models\(|Configuration\.load(_many)?\(' --include=*.jl .
grep -rn 'being loaded implicitly' <your logs>
```

For each models import, check that the same folder is loaded first, in the module body and again in
`__init__` for a package.

### Migrate your app

```julia
# ✗ before — the folder was loaded implicitly, in an environment nobody chose
module RaceControl
using PormG
PormG.@import_models "../db/models.jl" models
end

# ✓ after — load it, with the environment, before importing the models
module RaceControl
using PormG
const APP_ROOT = normpath(joinpath(@__DIR__, ".."))
_load_configs() = PormG.Configuration.load("db"; root = APP_ROOT, env = get(ENV, "RACECONTROL_ENV", "dev"))
_load_configs()
PormG.@import_models "../db/models.jl" models
__init__() = _load_configs()
end

# ✓ a script that wants the old convenience for one registration (a REPL has it already)
PormG.Models.set_models(MyModels, "db"; implicit = true)
```
