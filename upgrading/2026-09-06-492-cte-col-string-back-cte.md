## The `"<cte>__<col>"` string is back, and a CTE name that shadows a model field is now an error (#492)

- **Version**: 0.6.0
- **PormG ref**: #492 (partially reverses #444 — its namespace split stays, only the *spelling*
  changes; #431/#434 stay fixed, by a loud guard instead of by construction); completed by #509,
  which extends the same gate to the one clause it had missed;
  `src/querybuilder/ctes.jl`, `src/querybuilder/build_query.jl`, `src/querybuilder/build_joins.jl`,
  `src/exceptions.jl`, `docs/src/read/subqueries_and_ctes.md`, `docs/src/read/custom_joins.md`,
  `docs/src/read/window_functions.md`, `docs/src/schema_conventions.md`
- **Recorded**: 2026-09-06 (amended 2026-09-10 for #509)
- **Severity**: **behavior change** — additive for almost every app. It forces an edit in exactly one
  shape: a `.with()` label that both (a) also names a model field, reverse accessor, many-to-many
  field or `cjoin`/`on()` join path, **and** (b) is referenced somewhere as a `"<label>__…"` string.
  Declaring such a label breaks nothing on its own — the gate fires on the reference. Part of the
  `0.6.x` pre-publish wave.

### What changed

#444 deleted the `"<cte>__col"` spelling outright and made `CTE(name, path)` the only way to reach a
CTE column. #492 restores the string as the **default** and keeps #444's namespace split. What #444
actually removed was first-match-wins **precedence** — the CTE registry being consulted ahead of the
model's own fields — and removing the precedence never required removing the string. It required
refusing to *answer* an ambiguous name instead of guessing at it.

```julia
# Both spellings work now, and render byte-identical SQL sharing one join:
q.values("points", "best" => "fast__milliseconds")
q.values("points", "best" => CTE("fast", "milliseconds"))

# `order_by` gets its `-` back, so DESC has ONE dialect again rather than two:
q.order_by("-fast__milliseconds")          # was: order_by(CTE("fast", "milliseconds"; desc = true))

# and `Sum("fast__milliseconds")` works where `Sum(CTE("fast", "milliseconds"))` was required.
```

`CTE(name, path)` is unchanged and nothing is deleted. It becomes the **disambiguator** rather than
the only spelling, and it is still required on the **right** of a filter pair, where a bare string is
a value and not a column (`filter("raceid" => CTE("r91", "raceid"))`).

**The one shape that breaks.** When a `.with()` label equals something on the model, the shared `__`
path has two readings and raises the new `AmbiguousFieldError`:

```julia
q.with("driverid" => driver_totals)      # "driverid" is ALSO a ForeignKey of Result
q.values("points", "driverid__surname")  # → AmbiguousFieldError, where #444 resolved it to the FK
```

`AmbiguousFieldError <: FieldAccessError <: PormGError`, so an app already catching either umbrella
catches it with no edit; only a handler matching `UnknownFieldError` specifically will miss it, which
is deliberate — the name is known *twice*, not unknown, and the remedy is different.

A CTE name that collides with **nothing** changes no field path at all, and a colliding label that is
only ever referenced through `CTE(...)` — never as a `"<label>__…"` string — also keeps working: the
gate fires on the string, not on the declaration.

**One clause was missed, and #509 closed it.** An `SQLOrder` entry inside a window's `order_by` —
`WindowOver(order_by = [SQLOrder("driverid__surname")])` — kept resolving a shadowed name to the
model side and rendering, with no error, while every other clause already refused it. It now raises
`AmbiguousFieldError` like the rest, in both spellings of the wrapper's field (a `String` and an
`SQLField`). Same break, same remedy, same wave: if renaming the label already migrated your app for
the clauses above, nothing further is needed. Everything else #509 added is purely additive — an
`SQLOrder` can now *carry* a CTE or `Joined` column at all (`SQLOrder(CTE("fast", "milliseconds"))`,
previously a `MethodError`), and an explicit `nulls = :first`/`:last` on a window's `SQLOrder` is
honoured instead of silently dropped.

### How to find the calls to migrate

```bash
# Every CTE declaration. Check each label against its model's field names, reverse accessors,
# many-to-many fields and cjoin/on() join paths — only a collision needs anything.
grep -rn "\.with(" --include="*.jl" .
```

### Migrate your app

```julia
# ✗ BEFORE (#444) — the string meant the ForeignKey, and the CTE needed the handle. Both worked.
q.with("driverid" => driver_totals)
q.values("points", "driverid__surname", "n" => CTE("driverid", "n"))

# ✓ AFTER — rename the CTE. While the name is taken there is no string that selects the MODEL side,
#   so renaming is the remedy the error message prints; the CTE side then has both spellings back.
q.with("totals" => driver_totals)
q.values("points", "driverid__surname", "n" => "totals__n")
```
