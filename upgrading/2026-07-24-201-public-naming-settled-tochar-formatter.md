## Public naming settled — ToChar, formatter, aggregate, M2M `add`/`remove`/`clear`/`set`, setup unexported (#201)

- **Version**: 0.3.0
- **PormG ref**: issue #201 ; `src/querybuilder/{functions,types,many_to_many}.jl`, `src/models/fields.jl`,
  `src/PormG.jl` exports, `docs/src/{api,many_to_many,import_django}.md`
- **Recorded**: 2026-07-24
- **Severity**: **breaking (renames)** — pre-publish naming pass; every rename is old-name-gone, no aliases.
  Part of the `0.3.x` pre-publish wave — roll it forward together with the other `0.3.*` entries.

### What changed

| Old | New | Surface |
|-----|-----|---------|
| `To_char(x, fmt; formater=…)` | `ToChar(x, fmt; formatter=…)` | `PormG.Functions` export (only non-PascalCase name in the library) |
| `formater` (kwarg + struct field) | `formatter` | `Extract`/`ToChar`/math-function kwarg; fields on `FObject`/`WindowFunction` **and** all model-field structs |
| `agregate` (struct field) | `aggregate` | `InstructionObject`/`FExpression`/`FObject`/`WindowFunction` internals |
| `manager.add!/remove!/clear!/set!` | `manager.add/remove/clear/set` | M2M manager mutators (Django parity; bang implied "mutates a Julia arg", which these don't — they mutate the DB; see the rationale note in `docs/src/many_to_many.md`) |
| `setup` / `install_ai_skills` (exported) | `PormG.setup()` / `PormG.install_ai_skills()` (qualified-only) | top-level exports removed; behavior unchanged |
| `InstrucObject` | `InstructionObject` | internal QB struct (public-adjacent docstrings) |

**Deliberate non-change:** `bulk_insert` keeps its name (Django's `bulk_create` is a different API —
DataFrame-first, `on_conflict=` kwarg; documented in `docs/src/import_django.md`, "API Naming
Differences from Django").

### How to find the calls to migrate

```
rg -n 'To_char|formater|agregate|InstrucObject'        # renames: mechanical old → new
rg -n '\.(add|remove|clear|set)!\('                    # M2M mutators: drop the !
rg -n '(^|[^.\w])(setup|install_ai_skills)\('           # bare calls → prefix with PormG.
```

The first two are safe find-and-replace (whole-word). For the third, only *unqualified* calls need
the `PormG.` prefix — `PormG.setup()` calls keep working as-is.
