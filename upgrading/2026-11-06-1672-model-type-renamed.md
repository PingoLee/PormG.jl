## `PormG.Models.Model_Type` is renamed `PormG.Models.ModelType`, and is public (#1672)

- **Version**: Unreleased
- **PormG ref**: #1672, #1663 ; `src/Models.jl`
- **Recorded**: 2026-11-06
- **Severity**: breaking, for code that names the concrete model type. Code that holds a model (`M.Race`) without naming its type is unaffected.

### What changed

The concrete model type, which `Models.Model(…)` returns and `M.Race` is, is renamed:

| | before | now |
|---|---|---|
| the type | `PormG.Models.Model_Type` (not public) | `PormG.Models.ModelType` (public) |

No alias is kept. Code that still names the old name gets
``UndefVarError: `Model_Type` not defined in `PormG.Models` `` when it runs, or when the file that
names it is loaded (a method signature `f(m::Models.Model_Type)` fails at its definition).

The old name was never public: it was left out of `Models`' `public` declarations on purpose, and the
documentation did not name it. It is renamed now because the typed binding a models file uses since
#1672, `Race::Models.ModelType = Models.Model(…)`, names it in every models file. That needs a public
name in Julia's type casing. Publishing `Model_Type` as it was would freeze a name outside that
casing, and an alias would give one type two names. The
abstract `PormGModel` is not a substitute in that binding: #1663 measured `Race::Models.PormGModel = …`,
and `M.Race.objects` reads back untyped.

### How to find the calls to migrate

```
grep -rn "Model_Type" --include=*.jl .
```

### Migrate your app

```julia
# ✗ before
describe(m::PormG.Models.Model_Type) = m.name

# ✓ after
describe(m::PormG.Models.ModelType) = m.name
```

A `sed` does the rename (review the diff before committing):

```
grep -rlZ "Model_Type" --include=*.jl . | xargs -0 sed -i 's/\bModel_Type\b/ModelType/g'
```

(GNU sed. BSD and macOS sed take `-i ''` and spell the word boundary `[[:<:]]Model_Type[[:>:]]`.)
