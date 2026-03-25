# Contributing & Debugging

## Debugging PormG Internals from a Consuming App

PormG uses an internal no-op macro, `@pormg_debug`, as a compile-time debug hook.
In the published package it expands to nothing. This section explains how to activate
real breakpoints when you need to investigate a bug that occurs inside PormG while
running your own application.

### Why `@pormg_debug` is a no-op by default

Julia macros are expanded at **parse time**, before the code runs. When PormG is
loaded as a registered package, its `.ji` precompiled cache already contains every
`@pormg_debug` call expanded to `nothing`. Redefining the macro at runtime cannot
retroactively change those expansions.

The solution is to switch your app to use PormG **from source**, which forces Julia
to re-parse every file and apply the new macro definition.

---

### Step-by-step: activating breakpoints from your app

**Requirements:** `Revise.jl` and `Infiltrator.jl` must be available in your local
Julia environment (they are not required by PormG itself).

```julia
# In your global environment (run once):
] add Revise Infiltrator
```

**1. Switch your app to the local PormG source**

Open your app's Julia REPL and run:

```julia
] dev C:\path\to\PormG-new-features   # Windows
] dev /path/to/PormG-new-features      # Linux/macOS
```

This rewrites your app's `Manifest.toml` to point at the PormG source folder
instead of the cached package. Julia will now compile PormG from source on
every session.

**2. Load Revise and Infiltrator *before* PormG**

Order matters — Revise must be tracking PormG before it is loaded:

```julia
using Revise       # must come first
using Infiltrator
using PormG        # now loaded from source, tracked by Revise
```

**3. Re-wire `@pormg_debug` to real breakpoints**

```julia
PormG.eval(:(macro pormg_debug(ex); :(Infiltrator.@infiltrate($(esc(ex)))); end))
```

**4. Mark the exact line you want to break on**

Open the relevant PormG source file (e.g. `src/querybuilder/execution.jl`) and
change the call site from:

```julia
@pormg_debug false   # condition false → never fires
```

to:

```julia
@pormg_debug true    # condition true → always fires
```

Save the file. Revise detects the change and re-parses the function with the
new macro definition. The next call to that code path will drop you into the
Infiltrator REPL.

**5. Reproduce the bug in your app**

```julia
# Example: investigating a query build issue on Result joins
using MyApp   # or load your models directly

q = M.Result.objects
q.filter("driverid__nationality" => "Brazilian", "positionorder" => 1)
q.values("raceid__year", "raceid__name", "driverid__surname")
df = q |> DataFrame   # breakpoint fires inside PormG here
```

Infiltrator drops you into an interactive REPL at the marked line, where you
can inspect local variables, call functions, and step through the logic.

**6. Restore your app to the registered PormG**

When you are done debugging, switch back to the published version:

```julia
] free PormG
```

---

### The `@pormg_debug` call sites in PormG source

All debug hook placements in the source use the pattern:

```julia
@pormg_debug false     # change to `true` or a real condition to fire
```

The `false` condition means the hook is permanently silent by default. When
re-wired to Infiltrator (steps above), change `false` to `true` or any
expression that reflects the specific scenario you are investigating:

```julia
@pormg_debug variable_name == :unexpected_value
```

---

### How to contribute

1. Fork the repository on GitHub and clone your fork locally.
2. Create a feature branch: `git checkout -b my-feature`
3. Make your changes, add tests under `test/integration/` or `test/unit/`.
4. Run the unit tests (no database required):
   ```
   julia --project=. test/runtests.jl
   ```
5. Run the integration tests (requires a live PostgreSQL or SQLite database):
   ```
   julia -t auto --project=. test/integration/test.jl
   ```
6. Submit a pull request against `main`.

### Testing conventions

- Every `@testset` block must be commented: explain **what** is tested, the
  **expected SQL**, and **why** the behaviour matters.
- Use the Formula 1 dataset models (`M.Driver`, `M.Result`, `M.Race`, etc.)
  for all user-facing examples. Generic `User`/`Post` examples are not
  accepted in this codebase.
- Use `show_query=:sql` to capture generated SQL in tests for assertion.
- Avoid leaving `@pormg_debug true` in committed code — always reset to `false`.
