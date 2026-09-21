## Removed `Base.first` type piracy — curried `first(; kwargs…)` form (#200)

- **Version**: 0.3.0
- **PormG ref**: issue #200 ; `src/querybuilder/execution.jl`
- **Recorded**: 2026-07-24
- **Severity**: **breaking (method removal)** — but the removed form was undocumented, unexported, and
  used nowhere in-repo, so real impact is expected to be nil. Bumped `y` anyway because the method was
  globally reachable, so `compat = "0.2"` should reject it.

### What changed

The convenience method

```julia
first(; kwargs...) = (objct) -> first(objct; kwargs...)   # removed
```

was **type piracy**: a zero-positional method on `Base.first` with no PormG type in its signature, so
after `using PormG` it claimed the global `Base.first(; kwargs…)` call for every module in the process.
There is no piracy-free version (a nullary method on someone else's function has no owned type to
anchor it), so it was removed. The normal ergonomics are unaffected — only passing keywords *inside a
pipe* is gone, and it has a direct equivalent:

```julia
# ✗ before — curried, kwargs-in-a-pipe (the only removed form):
sql = M.Driver.objects.filter("nationality" => "British") |> first(show_query = :sql)

# ✓ after — pass the handler explicitly (or use the method form):
sql = first(M.Driver.objects.filter("nationality" => "British"); show_query = :sql)
sql = M.Driver.objects.filter("nationality" => "British").first(show_query = :sql)
```

Still valid, untouched: `q.first()`, `first(q)`, `q.first(show_query=:sql)`, the bare pipe
`q |> first` (that's `first(q)`), and `list() |> first` (that's `Base.first(::Vector)`). The sibling
curried forms `delete(; kwargs…)` / `inspect_query(; kwargs…)` are **not** affected — those functions
are package-owned, so a kwargs-only method on them is not piracy.

### How to find the calls to migrate

Grep each app for a `first` that is piped **with keyword arguments** (bare `|> first` is fine):

```
rg -n '\|>\s*first\(' <app>/src        # curried first(...) in a pipe — the only form to change
```
