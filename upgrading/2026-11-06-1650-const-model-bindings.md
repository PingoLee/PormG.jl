## The generated models file binds each model with a typed global (`Race::Models.ModelType = …`); a plain or `const` file still loads (#1650)

- **Version**: Unreleased
- **PormG ref**: #1650, #1663, #1672, part of #1599 ; `src/Models.jl` (`Model_to_str`), `docs/src/models.md`
- **Recorded**: 2026-11-06
- **Severity**: behavior change. `Model_to_str`, and every models file PormG writes, returns different text. Queries are unchanged. A session that has a plain or `const` models file loaded must restart once after the file switches to the typed form (below).

### What changed

`Model_to_str` now binds each model with a typed global, and so does every models file PormG writes
(`generate_models_from_db`, the Django importer):

| written by PormG | before | now |
|---|---|---|
| a model definition | `Race = Models.Model(…)` | `Race::Models.ModelType = Models.Model(…)` |
| a model with no renderable field (commented out, #134) | `# Race = Models.Model("race")` | `# Race::Models.ModelType = Models.Model("race")` |

The documentation, the `set_models` docstring and the `pormg-usage` skill use the same form.
`Models.ModelType` is the concrete model type, public from this release (see the entry for its
rename, #1672).

Why: a plain global has no type the compiler can rely on. Every `M.Race` an application writes then
starts with an untyped read of the global. Under the JIT that is a dynamic call on every access.
Under `juliac --trim` it is a verifier error at each site, and the trimmed binary fails at run time
at the first `M.Race.objects` (#1599, the #1600 spike). A typed global fixes the binding's type,
not its value, so the read is typed. #1663 measured it against `const`: the same trim verifier report, row for
row, and the same JIT read (`getglobal(M, :Race)::ModelType`).

What stays the same:

- A models file with plain bindings is still accepted. `@import_models` and `set_models` load and
  bind it exactly as before, only with the untyped read on every access. `set_models` warns once per
  session, naming the first plain binding (#1664).
- A models file with `const` bindings is accepted too, with no warning: a `const` is typed as well.
- `@import_models` still includes the file as written. It does not rewrite the bindings for you.

Hot reload works over a typed global. Saving an edited `Race::Models.ModelType = Models.Model(…)`
with Revise loaded is an ordinary assignment to the global, so it replaces the model with no warning.
Every reader sees the new model, including a task that is already running: the REPL, a task created
after the reload and a server's long-lived loop alike. A typed global also refuses a value that is not a
model when it is assigned.

The one edit a running session cannot reload is the switch itself. Julia refuses to add a type to a
global that already has a value, so turning a plain `Race = …` into `Race::Models.ModelType = …` in a
file the session already loaded fails like any other failing expression in the reload. The reload
warns, naming the file and line, with Julia's text `cannot set type for global ….Race. It already has
a value or is already set to a different type.` The previous model stays. From `const` the text is
`cannot set type for constant ….Race.` Reloading again does not help. Restart the session once after
switching the file. Every reload after that is an assignment.

### Who this affects

- A models file written by hand, or generated before this change. It keeps working; migrate it to
  get the typed binding (from plain) or the reload that reaches a running task (from `const`).
- Code or tooling that reads a generated models file as text and expects a line to start with the
  binding name followed by ` = ` (`^Race = Models.Model(`, `^const Race = Models.Model(`).
- A development session that has the models file loaded when the file switches form: one restart.

### How to find the calls to migrate

```
grep -nE "^\s*(const\s+)?[A-Za-z_][A-Za-z0-9_]*\s*=\s*Models\.Model\(" db/*.jl
```

Run it on every models folder the application loads. It finds plain and `const` bindings, at the
start of a line or indented inside the module body. A line it does not report is already typed.

### Migrate your app

```julia
# ✗ before
module models
import PormG.Models

Circuit = Models.Model(
  circuitid = Models.IDField(),
  name      = Models.CharField(max_length = 100),
)

const Race = Models.Model(
  raceid    = Models.IDField(),
  circuitid = Models.ForeignKey(Circuit, pk_field = "circuitid", on_delete = "CASCADE"),
)
end

# ✓ after
module models
import PormG.Models

Circuit::Models.ModelType = Models.Model(
  circuitid = Models.IDField(),
  name      = Models.CharField(max_length = 100),
)

Race::Models.ModelType = Models.Model(
  raceid    = Models.IDField(),
  circuitid = Models.ForeignKey(Circuit, pk_field = "circuitid", on_delete = "CASCADE"),
)
end
```

One `sed` does it for plain and `const` bindings (review the diff before committing):

```
sed -i -E 's/^(\s*)(const\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*Models\.Model\(/\1\3::Models.ModelType = Models.Model(/' db/models.jl
```

Then restart any session that has the file loaded.
