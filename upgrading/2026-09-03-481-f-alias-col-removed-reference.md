## `F("alias.col")` is removed; reference a `cjoin_on` joined copy with `Joined(alias, col)` (#481)

- **Version**: 0.5.0
- **PormG ref**: #481 (closes two of #174's deferred edges); `src/Kernel.jl`,
  `src/querybuilder/types.jl`, `src/querybuilder/build_helpers.jl`,
  `src/querybuilder/object_manager.jl`, `src/querybuilder/ctes.jl`,
  `src/querybuilder/execution.jl`, `src/querybuilder/functions.jl`,
  `docs/src/read/custom_joins.md`
- **Recorded**: 2026-09-03
- **Severity**: **breaking** - a spelling that built now raises. Part of the `0.5.x` pre-publish wave.

**Measured before adopting this**: `cjoin_on`, `.cjoin(`, `.on(` and `F("<alias>.` have **zero**
call sites across `esus_back`, `PortalsusBack`, `LinkS`, `LinkSUS` and `work_server` (re-measured on
the current remotes).

### What changed

A `cjoin_on` joined copy used to be referenced by a DOTTED STRING inside `F(...)`. That spelling is
gone; the reference is now a typed handle, `Joined(alias, column)` - the same move #444 made one
level down for CTE columns, and for the same reasons. What the string cost:

- **It resolved fail-open.** The alias branch lived on the filter resolver and, when the prefix
  matched no declared alias, fell through to ordinary field resolution - so `F("typo.col")` reported
  an unknown FIELD named `"typo.col"`, sending the reader after a column that was never the problem.
  A handle names the alias and lists the ones that exist.
- **It existed on ONE resolver.** `_get_select_query(::String)` has no dot branch, so the BARE
  string could not be projected: `values("d.surname")` raised. (`values("x" => F("d.surname"))` did
  work — `F` routes through the filter resolver.) The handle projects in either form, and spells
  the same thing in every clause.
- **It could not carry an operator suffix** (#174's first deferred edge). `"d.points__@gte" => 3`
  was unsupported; `filter(Joined("d", "points__@gte") => 3)` is an ordinary pair.
- **It could not name another join's alias** (#174's second edge). One `cjoin_on`'s `on` may now
  reference another's - `Joined("d2", "surname") == Joined("d1", "surname")` - under the same
  emission-order rule (#449) as before.

`order_by(Joined(alias, col; desc = true))` works, matching `CTE(...; desc = true)`. Transforms
render the same dialect-aware SQL the dotted form did, in an ON clause and everywhere else:
`Joined("b2", "dt__@year") == F("dt__@year")`. The composite `@quarter` / `@quadrimester` keys are
covered too — and this change fixes them for `CTE(...)` as well, where they had never worked.

### How to find the calls to migrate

Every leftover spelling now raises `UnknownFieldError` naming the dotted text, and the message
carries the rewrite. To find them ahead of a run:

```bash
rg -n 'F\("[A-Za-z_][A-Za-z0-9_]*\.' .
```

### Migrate your app

```julia
# ✗ before
q.cjoin_on("Driver", alias = "d", on = [F("d.driverid") == F("driverid")])
q.filter(F("d.nationality") == "Brazilian")

# ✓ after
q.cjoin_on("Driver", alias = "d", on = [Joined("d", "driverid") == F("driverid")])
q.filter(Joined("d", "nationality") => "Brazilian")   # an ordinary pair now works

# ...and things that were impossible before:
q.values("points", "who" => Joined("d", "surname"))   # project a joined column
q.filter(Joined("d", "points__@gte") => 3)            # alias-qualified operator pair
```

`Joined` is exported from `PormG` alongside `CTE`, so no new import is needed.
