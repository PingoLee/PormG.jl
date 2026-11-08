## A models module declares its models with `Models.@models`; PormG no longer scans the module's names (#1602)

- **Version**: Unreleased
- **PormG ref**: #1602, #1599, #354 ; `src/Models.jl`, `src/Utils.jl`, `src/Generator.jl`, `src/migrations/planner.jl`
- **Recorded**: 2026-11-06
- **Severity**: breaking, for a models module registered with `set_models` after a plain `include`
  (the package boot), and for any model that is not a top-level `X = Models.Model(…)` assignment of
  its module's file: one reached through `using`, built by a function, a loop or `@eval`, or defined
  in a file the module `include`s. A file loaded with `@import_models`, `import_models` or
  `@models_module` whose models are all top-level assignments of one binding each (plain, typed,
  `const` or `global`, with or without a docstring, in a module with or without one) and that
  `include`s no other file keeps working unchanged; one that builds a model any other way (a chained
  `X = Y = Models.Model(…)` included) or `include`s a file, and writes no `Models.@models` line, is
  refused when it loads, naming the call, instead of loading without that model.

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
| a documented model (`"""…""" X = Models.Model(…)`) or a `global X = Models.Model(…)`, in an `@import_models` file | registered by the scan | read by the generated line like a plain assignment |
| a documented module (`"""…""" module models … end`) loaded with `@import_models` | scanned | gets the generated line like a plain module |
| a model built by a function, a loop or `@eval`, or a file the module `include`s, in an `@import_models` file with no `Models.@models` line | registered by the scan | `ModelDefinitionError` when the file loads, naming the call and its line: write the line |
| a chained `Circuit = Track = Models.Model(…)`, or an `include` of a file that defines no model (helpers, constants), in an `@import_models` file with no `Models.@models` line | registered by the scan (both bindings) / loaded | the same `ModelDefinitionError`: write the line |
| the same, in a file that writes its own `Models.@models` line | registered by the scan | registered only when the line lists it |
| a module body with two `Models.@models` lines, or the line run again | — (the line is new) | the lines merge: every listed model is in the set |
| a module whose generated line would be empty: no `Model(…)` call at all (the Generator's commented template) | nothing to register | the bare `Models.@models`, an empty set |
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
does. **Several `Models.@models` lines merge:** a second line in the module, or the line run again,
adds its models to the set, and a binding listed again takes the value it holds then. A model
leaves the set only through PormG's reload of the file (`set_models(…; source)` with Revise loaded)
or a fresh `include` of it; Revise re-evaluating one changed line of a package's own file only adds.
A module that already
binds a global named `MODEL_SET` must rename it.

### How to find the calls to migrate

Modules registered with `set_models` after a plain `include` (each needs the line):

```
grep -rn "set_models(" --include=*.jl .
```

Models a module reaches only through `using` (list them in its `Models.@models` line):

```
grep -rn "^\s*using \.\." --include=*.jl <your models folders>
```

Models in the shapes the generated line reads beside a plain assignment (a documented or a `global`
one; check them in the first plan, below), and models files that build a model in a shape it refuses
(a loop, a function, `@eval` or an `include`; each file needs its own `Models.@models` line):

```
grep -rn -B1 "Model(" --include=*.jl <your models folders> | grep '"""'          # documented
grep -rnE "^\s*global\s+\w+.*Model\(" --include=*.jl <your models folders>  # global
# a Model( / ModelType( call that is not a one-binding assignment starting in column 1
grep -rnE "Model(Type)?\(" --include=*.jl <your models folders> |
  grep -vE ':[0-9]+:(const |global )?\w+(::[A-Za-z.]+)?\s*=\s*([A-Za-z]+\.)*Model(Type)?\('
grep -rnE "^\s*(Base\.)?include\(" --include=*.jl <your models folders>         # an include
```

The refusal reads calls named `Model` or `ModelType`, wherever they are, quoted code included: a
`Model(…)` kept in a quote as data refuses the file too, and the fix is the same line. A model made by
a function with another name
(`Race = deepcopy(Circuit)`, a `make_model()` defined elsewhere), or by `include_string`, is not seen:
a file that builds one writes its own `Models.@models` line.

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

**Check the migration plan after upgrading.** `makemigrations` reads the same set, so a model that is
not in it is not a model of the file any more: the planner sees its live table as one the models no
longer declare and plans to drop it (applied only by `migrate(destructive = true)`). Run
`makemigrations` once after the upgrade and read the plan before applying it; a `Drop table` for a
table you still use means that model belongs in the `Models.@models` line. A file that writes its own
line warns, when it is loaded, about a top-level `X = Models.Model(…)` the line leaves out.

An older generated file that ends with `Models.set_models(@__MODULE__, @__DIR__)` keeps loading
through `@import_models`: the generated declaration is inserted right after the last model, before
that call. Delete the call anyway; it registers the module a second time.
