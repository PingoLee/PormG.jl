## `create_models_jl` and the models importers refuse a file name that cannot be a module name (#1486)

- **Version**: Unreleased
- **PormG ref**: #1486 ; `src/Generator.jl` (`_models_module_name`), `src/tools.jl` (`setup`)
- **Recorded**: 2026-10-30
- **Severity**: behavior change. A models-file name that is not a Julia identifier once its `.jl` is
  removed, or that names a binding the file imports (`Models.jl`, `CASCADE.jl`), now raises
  `ModelDefinitionError` and writes no file. Before, the call wrote a file that could not be loaded.

### What changed

A generated models file is `module <name> … end`, and `<name>` is the file name without `.jl`. That
name was never checked, so the call succeeded and the error came later, at `include` or
`@import_models`:

| file name | module line written before | loading it |
|---|---|---|
| `f1-models.jl` | `module f1-models` | `UndefVarError` (parsed as `module f1` with `-models` for a body) |
| `module.jl` | `module module` | `ParseError` |
| `1975.jl` | `module 1975` | `TypeError` |

Each of these now raises `ModelDefinitionError` naming the file and an example that works
(`f1_models.jl`), and no file is written. This applies to `Generator.create_models_jl` and to the
`file` keyword of the models importers (`import_models_from_sqlite`, `import_models_from_postgres`,
`import_models_from_mysql`, `import_models_from_django`). A name that was already an identifier
writes the same file as before.

A file named after a binding the generated file imports from `PormG.Models` (`Models.jl`,
`CASCADE.jl`, `RESTRICT.jl`, `SET_NULL.jl`, `SET_DEFAULT.jl`, `DO_NOTHING.jl`, `PROTECT.jl`) is
refused the same way. Its module hid that binding: in `Models.jl` the first `Models.IDField()` raised
`UndefVarError`, and in `CASCADE.jl` `on_delete = CASCADE` passed the module itself.

Two smaller changes come with it:

- The module name is now the file name without its **last** extension. Before, every `.jl` was
  removed, including one in the middle, so `f1.jl_models.jl` became `module f1_models`. It is now
  `f1.jl_models`, which is not an identifier, so it is refused.
- `create_models_jl` still returns without writing when the file already exists, and it does not
  check that file's name: a file you wrote can declare any module.

`PormG.setup` asks for the models file name again when it is refused. Before, it wrote the unusable
file.

### How to find the calls to migrate

```bash
grep -rnE 'create_models_jl|import_models_from_(sqlite|postgres|mysql|django)' --include='*.jl' .   # then check each `file =` name
```

### Migrate your app

Rename the file so that its name without `.jl` is a Julia identifier (letters, digits and
underscores, not starting with a digit and not a keyword) and is not `Models` or one of the
`on_delete` names.

```julia
# ✗ before: wrote `module f1-models`, which `include` could not load
import_models_from_sqlite("db"; file = "f1-models.jl")

# ✓ after
import_models_from_sqlite("db"; file = "f1_models.jl")
```
