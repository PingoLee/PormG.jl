## One models folder now resolves to exactly one connection key (#550)

- **Version**: 0.6.0
- **PormG ref**: #550 ; `src/Models.jl`, `src/Configuration.jl`, `src/Kernel.jl`
- **Recorded**: 2026-09-11
- **Severity**: behavior change

### What changed

Binding a models folder to a connection used to be decided by `Dict` hash order, in two places that
each scanned `config` and took the **first** entry satisfying any of several match conditions of
different strength. A weak match on the folder's final component could therefore beat an exact path
match, and nothing was logged when it did.

Worse, one folder could be registered **twice** — once implicitly by `set_models` under an absolute
path (with the environment taken from the file's `default_env:`, not from the application), and once
explicitly by `Configuration.load("db"; env = ...)`. Two entries meant two pools and possibly two
databases for one folder. Which one a query reached depended on which key its model happened to bind
to, so a safety check written against `config["db"]` could be inspecting an entry the queries never
touched.

Three changes, together:

- Matches are **ranked** (resolved path beats folder name) instead of raced, so hash order decides
  nothing.
- Within a rank, an **explicitly loaded key beats an implicitly minted absolute-path one**. This is
  load-bearing rather than cosmetic: both keys match at the path rank, and a plain lexicographic
  tiebreak picks the absolute path *every* time, because `/` sorts below every letter and digit.
- `Configuration.load` no longer **creates** the duplicate. A folder already registered under
  another spelling is reused in place, or migrated to the explicit key when the entry it holds was
  the implicit one. The duplicate is now unrepresentable rather than merely detected.

`set_models` also warns when it falls through to the implicit load, and the `connect_key` remap in
`ensure_model_initialized` was raised from `@info` to `@warn` — it is a recovery, not a routine
event.

### Who this affects

Apps whose configured folder names are distinct and that load configuration before importing models
— the documented shape — are unaffected: the same key resolves, silently.

Two things did change for everyone, though, and they are the real migration surface:

- **`load` now returns the connection key it registered**, and `load_many` returns the keys it
  really registered rather than the strings it was handed. When a folder was already loaded under
  another spelling, that key is **not** the string you passed.
- **A folder already registered under an implicit absolute-path key is migrated to your explicit
  key, and the old entry is deleted** — its pool closed with it. Anything holding the absolute path
  as a name (`haskey(config, "/srv/app/db")`, `get_settings("/srv/app/db")`) stops finding it. A
  safety gate written that way fails loudly rather than silently, which is the intent, but it is an
  app edit.

Do this at boot, before requests are in flight. `load` closes the pool of any entry it replaces and
`close_pool!` does not spare checked-out connections, so in-flight queries holding one will fail.
That applies to **both** branches — the migration above *and* the plainer case where a folder
already loaded under another spelling is simply reloaded in place. When connections are actually
checked out at that moment, PormG raises the report from `@warn` to `@error` and names the count.

### How to find the calls to migrate

There is no call pattern to grep: the resolution is internal. Check the **binding** instead, at a
REPL with your app loaded:

```julia
julia> MyApp.models.SomeModel.objects        # the access that re-derives the key
julia> MyApp.models.SomeModel.connect_key    # want your short key, not an absolute path
"db"
```

Also watch the boot log. Any of these three warnings means a folder was resolving ambiguously
before, silently:

```
PormG: no configured connection matches this models folder …
PormG: this models folder is registered under more than one configuration key …
PormG: this folder was already loaded under an implicit absolute-path key …
```

### Migrate your app

```julia
# ✗ before — the implicit load ran first, so `config` held BOTH "/srv/app/db" and "db";
#   models bound to one, safety checks inspected the other.
PormG.@import_models "../db/models.jl" models
PormG.Configuration.load("db"; env = "prod")

# ✓ after — load the folder once, before the models are registered, and for a PRECOMPILED
#   package do it in the module body AND in `__init__` (the body bakes the key into the image,
#   `__init__` puts the connection in `config` for the session).
_load_configs() = cd(APP_ROOT) do
    PormG.Configuration.load_many(["db"]; env = get(ENV, "MYAPP_ENV", "dev"))
end

_load_configs()
PormG.@import_models "../db/models.jl" models

__init__() = _load_configs()
```

If your app relied on reaching two different databases through two keys for the *same* folder, give
them separate folders — that shape is no longer representable.
