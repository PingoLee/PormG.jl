## `Configuration.load` / `load_many` — outside a REPL the environment is `env=` or `PORMG_ENV`; a blank `PORMG_ENV` is unset (#1228)

- **Version**: Unreleased
- **PormG ref**: #1228 ; `src/Configuration.jl` (`_effective_env`, `_pormg_env`, `load`, `Settings`, `register_connection`)
- **Recorded**: 2026-10-15
- **Severity**: breaking. A `load` with no `env=` and no `PORMG_ENV`, outside an interactive
  session, raises `InvalidConfigurationError`. It used to take the file's `default_env:`, else `dev`.

### What changed

`load` chose the environment from four sources, first wins: `env=`, `ENV["PORMG_ENV"]`, the file's
top-level `default_env:`, then `"dev"`. The last two are guesses. In many deployments `dev` points at
production, and a service that never chose an environment silently got one.

The last two are now a REPL's only, under the same rule that decides the implicit load of a models
folder (#1248):

| session | `env=` | non-blank `PORMG_ENV` | neither |
|---|---|---|---|
| interactive (`isinteractive()`) | used | used | `default_env:`, else `dev`, with an `@info` naming which one decided |
| service, test, script | used | used | `InvalidConfigurationError` naming the `load(…; env = …)` call |

A package's `__init__` follows the session that loads it: run by a service it refuses, but `using`
the package from a REPL is interactive and gets the fallback. A package therefore states `env` in
its own `load` calls.

A blank `PORMG_ENV` (`""` or whitespace) counts as unset everywhere, and surrounding whitespace is
trimmed from a set one, including `Settings()` and
`register_connection`. It used to select the environment `""`, which no `connection.yml` defines,
so the load failed on a missing block.

The implicit load in `set_models(…; implicit = true)` asked for a guess, so it keeps the fallback.

### Who this affects

A process that is not interactive and calls `Configuration.load` / `load_many` without `env=`, and
with `PORMG_ENV` unset or blank: it relied on `default_env:` or on `dev`. That includes a script run
as `julia script.jl`, a service, a test suite that does not set `PORMG_ENV`, and a package's
`__init__`. A host framework that publishes its environment into `PORMG_ENV` keeps working, and
no longer needs to treat a blank value as unset itself.

### How to find the calls to migrate

```bash
grep -rnE 'Configuration\.load(_many)?\(' --include=*.jl . | grep -v 'env *='
```

Each match needs `env = …`, unless the process that runs it always exports `PORMG_ENV`. The refusal
reads `No environment was selected for the configuration folder`.

### Migrate your app

```julia
# ✗ before — the file's `default_env:` (or `dev`) chose the database
PormG.Configuration.load("db"; root = APP_ROOT)

# ✓ after — the application states it
PormG.Configuration.load("db"; root = APP_ROOT, env = get(ENV, "RACECONTROL_ENV", "prod"))

# ✓ or the deployment states it, once, for every load
#   PORMG_ENV=prod julia --project=. bin/server.jl
```
