## Revise reloads an edited models file, and `set_models` takes `source =` (#1487)

- **Version**: Unreleased
- **PormG ref**: #1487 ; `ext/PormGReviseExt.jl`, `src/Models.jl` (`set_models`), `src/Utils.jl`
- **Recorded**: 2026-10-30
- **Severity**: behavior change, only in a session with Revise loaded. Without Revise, nothing changes.

### What changed

`@import_models` and `import_models` registered a Revise callback for the models file, but the call
named no file. Revise requires the files it watches, so the registration was a `MethodError`, and a
bare `catch` swallowed it. Editing a models file therefore never changed the models in memory, on
any path. The documented hot reload has not worked since it was written.

The callback now watches the file. With Revise loaded, an edit to a models file is applied at the
next `Revise.revise()` (in a REPL, before each command). The module body is re-evaluated into the
same module, and `set_models` binds it again:

| with Revise loaded, after editing `db/models.jl` | before | now |
|---|---|---|
| a field added to `Driver`, bound by `@import_models` in the session | `M.Driver.fields` unchanged until a restart | holds the new field |
| a model added to the file | not defined | defined and bound to the folder's connection |
| a typo in the edited file | nothing happens, silently | a warning names the file and line, and that model keeps its previous definition |
| an edit that leaves the file unparseable | nothing happens, silently | a warning names the file, and nothing is reloaded |

`Models.set_models(models, folder; source = file)` is new, for the run-time bind a package writes
in `__init__` (`include` the models file in the module body, bind at run time). It registers the
same reload. Without Revise it does nothing, so the same boot runs in production. The documented
package boot is now this bind; see `docs/src/configuration/setup.md`, *The Bootstrap Sequence*.

`@import_models` in a **package's** module body still gets no reload. It runs in the precompile
worker, and the restored session does not run it again.

### Who this affects

A session with Revise loaded that edits a models file it bound with `@import_models` or
`import_models`. The edit now takes effect, where before it was ignored until a restart, so the
running session queries with the edited models.

### How to find the calls to migrate

```
grep -rn "@import_models\|import_models(\|set_models(" --include=*.jl .
```

Nothing has to change. To get the reload on a package's run-time bind, add `source`.

### Migrate your app

```julia
# ✗ before: a package's run-time bind, no reload under Revise
include(MODELS_FILE)
function __init__()
    PormG.Configuration.load("db"; root = APP_ROOT, env = get(ENV, "RACECONTROL_ENV", "dev"))
    PormG.Models.set_models(models, "db")
end

# ✓ after: the same bind; with Revise loaded, edits to MODELS_FILE are applied
include(MODELS_FILE)
function __init__()
    PormG.Configuration.load("db"; root = APP_ROOT, env = get(ENV, "RACECONTROL_ENV", "dev"))
    PormG.Models.set_models(models, "db"; source = MODELS_FILE)
end
```
