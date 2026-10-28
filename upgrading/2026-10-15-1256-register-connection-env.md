## `Configuration.register_connection` — outside a REPL the environment is `env=` or `PORMG_ENV`, and a resolver's refusal is raised (#1256)

- **Version**: 0.9.0
- **PormG ref**: #1256 ; `src/Configuration.jl` (`register_connection`, `_registered_env`, `_resolve_lazily!`, `register_offline`)
- **Recorded**: 2026-10-15
- **Severity**: breaking. A `register_connection` with no `env=` and no `PORMG_ENV`, outside an
  interactive session, raises `InvalidConfigurationError`. It used to record `"dev"`.

### What changed

`register_connection` recorded `app_env` from `PORMG_ENV`, else `"dev"`. That is the fallback #1228
made a REPL's only for `load`, so a service that never chose an environment still got `"dev"` on
every dynamic connection, and `Configuration.env(key)` / `status(key)` reported it. It now follows
`load`'s rule, with a new `env` keyword:

| session | `env=` | non-blank `PORMG_ENV` | neither |
|---|---|---|---|
| interactive (`isinteractive()`) | used | used | `"dev"`, with an `@info` saying so |
| service, test, script | used | used | `InvalidConfigurationError` naming the `register_connection(…; env = …)` call |

The refusal comes before any pool is built, and before an existing dynamic entry under the same key
is closed, so a refused re-registration leaves the old pool serving.

The lazy connection resolver goes through the same call. A resolver that returns a `Dict` can now
state the environment with an `"env"` entry. A `(url, adapter, pool_size)` tuple carries none, so it
takes `PORMG_ENV`. An `InvalidConfigurationError` raised while registering a resolved key is now
**raised from `get_settings`**, and so from the query that needed the key. It used to be logged at
`@error`, and the caller got `Settings for key '…' not found`. This applies to the environment refusal
above and to an unsupported adapter alike. Other errors from the resolver are still logged.

`register_offline` (new in this release) always records `"dev"`. An offline entry reads no
`connection.yml`, so there is no environment block to select.

### Who this affects

A process that is not interactive, with `PORMG_ENV` unset or blank, and that does either of these:

- calls `register_connection` without `env=`;
- relies on a connection resolver (`set_connection_resolver`) that returns no `"env"`.

That includes a multi-tenant service whose resolver returns a tuple, and a test suite that registers
dynamic connections without setting `PORMG_ENV`. A deployment that exports `PORMG_ENV` keeps working
unchanged.

### How to find the calls to migrate

```bash
grep -rn 'register_connection(' --include=*.jl . | grep -v 'env *='
grep -rn 'set_connection_resolver' --include=*.jl .
```

Each `register_connection` match needs `env = …`, and each resolver needs an `"env"` entry in the
`Dict` it returns. Neither is needed if every process that runs them exports `PORMG_ENV`. The refusal
reads `No environment was selected for the dynamic connection`.

### Migrate your app

```julia
# ✗ before — "dev" was recorded for the tenant whatever the deployment was
PormG.Configuration.register_connection("tenant_monaco", url)
PormG.Configuration.set_connection_resolver() do key
    startswith(key, "tenant_") ? (tenant_url(key), "PostgreSQL", 5) : nothing
end

# ✓ after — the application states it
PormG.Configuration.register_connection("tenant_monaco", url; env = "prod")
PormG.Configuration.set_connection_resolver() do key
    startswith(key, "tenant_") || return nothing
    return Dict("url" => tenant_url(key), "adapter" => "PostgreSQL", "pool_size" => 5, "env" => "prod")
end

# ✓ or the deployment states it, once, for every call
#   PORMG_ENV=prod julia --project=. bin/server.jl
```
