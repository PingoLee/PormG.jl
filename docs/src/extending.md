# Extending PormG

PormG is designed to be built **on top of**. A framework or application that depends on
PormG — like [Nitro.jl](https://github.com/) — should register its own behaviour through
PormG's extension points rather than forking the ORM or hardcoding consumer-specific knowledge
into PormG itself.

This page is for **framework authors**: people building a package that depends on PormG. If you
are just *using* PormG to query a database, see [Reading](read/index.md) and
[Writing](write/index.md) instead.

## Philosophy: the library stays generic, the consumer registers

The dependency points **PormG ← your package** (your package depends on PormG, never the
reverse). So PormG must not know about your tables, your fields, or your connection setup.
Instead, PormG exposes small **registration hooks**, and your package calls them once at load
time to teach PormG what it needs.

A concrete example: Nitro stores background jobs in a `nitro_task` table. PormG's schema
introspection (`import_models_*`, `makemigrations`) should *skip* that table so it isn't
reverse-engineered into a user model. Rather than baking `"nitro_task"` into PormG's default
ignore list — which would couple a general-purpose ORM to one application's schema — Nitro
**registers** it:

```julia
PormG.register_ignore_tables!(["nitro_session", "nitro_task"])
```

The knowledge lives where the tables are defined, and PormG ships nothing application-specific.

## Extension points

All of these are callable as `PormG.<name>(...)` after `using PormG`.

### `register_ignore_tables!(tables)`

Register table-name patterns that schema introspection (`convert_schema_to_models`,
`import_models_from_postgres`, `import_models_from_sqlite`, `makemigrations`) should always
skip. Additive and idempotent. Use it for your framework's own infrastructure tables.

```julia
PormG.register_ignore_tables!(["myframework_jobs", "myframework_cache"])
```

### `set_before_connect_hook(f)`

Register a callback invoked **before** PormG opens a physical connection (not on pool reuse,
and outside the pool lock). It receives `(key::String, settings)` and returns `true` to proceed
or `false` to abort. Typical uses: VPN/SSH-tunnel activation, credential refresh.

```julia
PormG.set_before_connect_hook() do key, settings
    # Only the production cluster needs the tunnel
    if basename(settings.db_def_folder) == "db_prod"
        ensure_tunnel_up()
    end
    return true
end
```

### `set_connection_resolver(f)`

Register a callback that **lazily resolves unknown connection keys** — useful for multi-tenant
apps where the connection list isn't known up front. `f(key::String)` returns `nothing` (can't
resolve) or `(url, adapter, pool_size)` / a `Dict` with those keys.

```julia
PormG.set_connection_resolver() do key
    startswith(key, "tenant_") || return nothing
    return (tenant_url(key), "PostgreSQL", 3)
end
```

### `register_connection(key, url; adapter, pool_size)`

Register a connection pool dynamically at runtime (instead of from a `connection.yml` folder).
See [Dynamic & Multi-Tenancy](configuration/dynamic.md).

!!! note "Planned hook"
    Nitro guards a call to `PormG.register_field_hook(:PasswordField, :auto_hash, …)` with
    `isdefined(PormG, :register_field_hook)`. That field-normalization seam is **not yet
    implemented** in PormG — the guard makes Nitro's extension a forward-compatible no-op until
    it lands. Don't rely on `register_field_hook` until this note is removed.

## The package-extension pattern

The idiomatic way to wire a consumer to PormG is a [Julia package extension](https://docs.julialang.org/en/v1/manual/code-loading/#man-extensions):
your package declares PormG as a **weak** dependency and ships an extension module that only
loads when PormG is present. This keeps PormG optional for your users while giving you full
integration when they opt in.

In your package's `Project.toml`:

```toml
[weakdeps]
PormG = "7d8d7541-4d3d-4580-80a2-17064efb0993"

[extensions]
MyPkgPormGExt = "PormG"

# When co-developing both packages, point at the local checkout:
[sources]
PormG = {path = "../PormG.jl"}
```

In `ext/MyPkgPormGExt.jl`, register everything from `__init__` and **guard each call with
`isdefined`** so your extension stays compatible across PormG versions:

```julia
module MyPkgPormGExt

using MyPkg
using PormG

function __init__()
    # Skip our framework's own tables during introspection / makemigrations.
    if isdefined(PormG, :register_ignore_tables!)
        PormG.register_ignore_tables!(["myframework_jobs"])
    end
end

end # module
```

### Defining models from an extension

Define your tables as PormG models, but build them **lazily** — the model objects depend on
PormG being loaded, so create them behind a `Ref` populated in `__init__` (or on first use):

```julia
function _define_job_model()
    isdefined(PormG, :Models) || return nothing
    return PormG.Models.Model("myframework_jobs",
        id         = PormG.Models.CharField(max_length=100, primary_key=true),
        status     = PormG.Models.CharField(max_length=20),
        created_at = PormG.Models.DateTimeField(),
    )
end

const _JOB_MODEL = Ref{Any}(nothing)
job_model() = (isnothing(_JOB_MODEL[]) && (_JOB_MODEL[] = _define_job_model()); _JOB_MODEL[])
```

You can then query through the model exactly like application code, routing to a chosen
connection with `.db(key)`:

```julia
job_model().objects.
    filter("status" => "PENDING").
    db("db").
    list()
```

### Implementing PormG-backed store interfaces

If your framework defines abstract store interfaces (session stores, job stores, …), a PormG
backend is just a struct holding a model reference plus method implementations that delegate to
`model.objects`. Nitro's `NitroPormGExt` is the reference implementation: `PormGSessionStore`
and `PormGWorkerStore` implement Nitro's `AbstractSessionStore` / `AbstractWorkerStore` using
ordinary `create` / `filter().update()` / `filter().delete()` calls, and bootstrap their tables
with `PormG.Dialect.create_table` + `CREATE TABLE IF NOT EXISTS`.

## Verifying your extension

Because PormG is a **weakdep**, `using PormG` fails in your package's *default* environment
(`Package PormG not found in current path`) — the extension only loads when something pulls in
both packages. To exercise it, dev-add **both** into a throwaway environment:

```julia
using Pkg
Pkg.activate(mktempdir())
Pkg.develop([PackageSpec(path="/path/to/MyPkg"), PackageSpec(path="/path/to/PormG.jl")])

using MyPkg, PormG   # extension precompiles and its __init__ runs here

@assert "myframework_jobs" in PormG._EXTRA_IGNORE_TABLES[]
```

(Your package's `test` target listing PormG works too — that's the environment `Pkg.test()`
runs in.)
