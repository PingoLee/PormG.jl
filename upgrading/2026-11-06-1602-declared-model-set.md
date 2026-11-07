## A models module declares its models with `Models.@models`; PormG no longer scans the module's names (#1602)

- **Version**: Unreleased
- **PormG ref**: #1602, #1599, #354 ; `src/Models.jl`, `src/Utils.jl`, `src/Generator.jl`, `src/migrations/planner.jl`
- **Recorded**: 2026-11-06
- **Severity**: breaking, for a models module registered with `set_models` after a plain `include`
  (the package boot), and for a model the registering module reaches through `using`. A file loaded
  with `@import_models`, `import_models` or `@models_module` keeps working unchanged.

### What changed

Registration used to find a module's models by walking its names (`names(mod; all = true,
imported = true)`, then a second pass with `usings = true`) and keeping every value that was a model.
It now reads a declaration the module carries, `Models.@models Circuit Race`, written after the
models. The line binds the module's `MODEL_SET`, which holds those models and their bindings:

| | before | now |
|---|---|---|
| a module included with `include` and registered with `set_models(models, "db")` | its models found by a scan of its names | its `Models.@models …` line is read; a module without one raises `ModelDefinitionError` naming the line to add |
| a file loaded with `@import_models` / `import_models`, or `@models_module` | scanned | the declaration is added for you from the file's top-level `X = Models.Model(…)` assignments when the file does not write one |
| a model the module reaches through `using` (#354) | registered by the second scan pass | registered only when the module lists it in `Models.@models` |
| a model built by a function, a loop or `@eval` in an `@import_models` file | registered by the scan | registered only when the file lists it in `Models.@models` |
| `Models.get_all_models(mod)` | every model bound in `mod` | the models `mod` declares, in declaration order; empty for a module that declares none |
| `makemigrations` / `check` reading the models file | scanned the module | read the declaration (added as `@import_models` adds it) |

`generate_models_from_db` and the Django importer write the line at the end of the module. Why: a
scan of a module's names is reflection a `juliac --trim` binary cannot follow (#1599), and which
models it found depended on how each was brought into scope.

An `@import_models` file that writes its own `Models.@models` line is read as written; a top-level
`X = Models.Model(…)` the line leaves out is not registered, and loading the file warns naming it.

The line captures the models its bindings hold when it runs, so it goes after their definitions (a
binding not yet assigned fails at the line with `UndefVarError`). A model rebound by hand afterwards
is registered only once the line runs again; the Revise reload re-evaluates the whole module, so it
does. A module that already binds a global named `MODEL_SET` must rename it.

### How to find the calls to migrate

Modules registered with `set_models` after a plain `include` (each needs the line):

```
grep -rn "set_models(" --include=*.jl .
```

Models a module reaches only through `using` (list them in its `Models.@models` line):

```
grep -rn "^\s*using \.\." --include=*.jl <your models folders>
```

### Migrate your app

```julia
# ✗ before: db/models.jl, included by the package and registered from __init__
module models
import PormG.Models
Circuit::Models.ModelType = Models.Model(circuitid = Models.IDField(), name = Models.CharField())
Race::Models.ModelType    = Models.Model(raceid = Models.IDField(),
                                         circuitid = Models.ForeignKey(Circuit, on_delete = "CASCADE"))
end

# ✓ after: the same file, ending with the model set
module models
import PormG.Models
Circuit::Models.ModelType = Models.Model(circuitid = Models.IDField(), name = Models.CharField())
Race::Models.ModelType    = Models.Model(raceid = Models.IDField(),
                                         circuitid = Models.ForeignKey(Circuit, on_delete = "CASCADE"))

Models.@models Circuit Race
end
```

A long list may be written across lines as `Models.@models(Circuit, Race, …)`.
