## The generated models file binds each model with `const`; a file without `const` still loads (#1650)

- **Version**: Unreleased
- **PormG ref**: #1650, part of #1599 ; `src/Models.jl` (`Model_to_str`), `docs/src/models.md`
- **Recorded**: 2026-11-06
- **Severity**: behavior change. `Model_to_str`, and every models file PormG writes, returns different text. Queries are unchanged. Hot reload of a `const` binding does not reach a task created before the reload (below).

### What changed

`Model_to_str`, and with it every models file PormG writes (`generate_models_from_db`, the Django
importer), now binds each model with `const`:

| written by PormG | before | now |
|---|---|---|
| a model definition | `Race = Models.Model(…)` | `const Race = Models.Model(…)` |
| a model with no renderable field (commented out, #134) | `# Race = Models.Model("race")` | `# const Race = Models.Model("race")` |

The documentation and the `set_models` docstring use the same form.

Why: a plain global has no type the compiler can rely on. Every `M.Race` an application writes then
starts with an untyped read of the global. Under the JIT that is a dynamic call on every access.
Under `juliac --trim` it is a verifier error at each site, and the trimmed binary fails at run time
at the first `M.Race.objects` (#1599, the #1600 spike). A `const` binding is typed, and the read goes
away.

What stays the same:

- A models file without `const` is still accepted. `@import_models` and `set_models` load and bind
  it exactly as before, only with the untyped read on every access.
- `@import_models` still includes the file as written. It does not add `const` for you.
- Hot reload works over a `const` binding. Julia 1.13 lets a `const` be redefined in a new world, so
  saving an edited `const Race = Models.Model(…)` with Revise loaded replaces the model, with no
  warning. The REPL, and any task created after the reload, uses the new model.

A task created before the file was reloaded, running or not, keeps the old model: a `const` is
redefined in a new world, and a task stays in the world it was created in. That is how Revise
treats an edited method too. A plain global is not tied to a world, so before this change such a
task read the new model. A server's long-lived loop picks up an edited model once its task is
recreated, or by reading it through `Base.invokelatest`.

The one edit a running session cannot reload at all is the switch itself. Turning a plain
`Race = …` into `const Race = …` (or the reverse) in a file the session already loaded fails like
any other failing expression in the reload: a warning naming the file and line, and the previous
model stays. Restart the session once after adding `const`.

### Who this affects

- A models file written by hand, or generated before this change. It keeps working; migrate it to
  get the typed binding.
- Code or tooling that reads a generated models file as text and expects a line to start with the
  binding name (`^Race = Models.Model(`).
- A development session that hot-reloads its models file (Revise) while a long-lived task (a
  server's worker loop) is running: once the file is `const`, that task keeps the model it was
  created with until it is recreated.

### How to find the calls to migrate

```
grep -nE "^[A-Za-z_][A-Za-z0-9_]* = Models\.Model\(" db/*.jl
```

Run it on every models folder the application loads. Bindings indented inside the module body need
the same change: `grep -nE "^\s*[A-Za-z_][A-Za-z0-9_]* = Models\.Model\(" db/*.jl`.

### Migrate your app

```julia
# ✗ before
module models
import PormG.Models

Circuit = Models.Model(
  circuitid = Models.IDField(),
  name      = Models.CharField(max_length = 100),
)

Race = Models.Model(
  raceid    = Models.IDField(),
  circuitid = Models.ForeignKey(Circuit, pk_field = "circuitid", on_delete = "CASCADE"),
)
end

# ✓ after
module models
import PormG.Models

const Circuit = Models.Model(
  circuitid = Models.IDField(),
  name      = Models.CharField(max_length = 100),
)

const Race = Models.Model(
  raceid    = Models.IDField(),
  circuitid = Models.ForeignKey(Circuit, pk_field = "circuitid", on_delete = "CASCADE"),
)
end
```

One `sed` does it for bindings at the start of a line (review the diff before committing):

```
sed -i -E 's/^([A-Za-z_][A-Za-z0-9_]*) = Models\.Model\(/const \1 = Models.Model(/' db/models.jl
```

Then restart any session that has the file loaded.
