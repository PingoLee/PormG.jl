# Dynamic Multi-Tenancy

For applications that connect to databases on the fly (e.g., per user or per subdomain), use the dynamic registration API.

## Runtime Registration

Register a connection pool manually at any time using a connection string or adapter-specific parameters:

!!! warning "Dynamically registered connections are read-only unless you enable writes"
    `change_data` and `change_db` default to **`false`**, as in `connection.yml`, so the first write
    to an entry registered without them raises `WritesDisabledError`. Pass them to
    `register_connection` (#1606):

    ```julia
    PormG.register_connection("tenant_01", "postgres://user:pass@host/db_01"; env = "prod",
                              change_data = true)    # writes; `change_db = true` for migrations
    ```

    A connection resolver states them with `"change_data"` and `"change_db"` entries in its `Dict`.

!!! note "Limitation: keys are namespaced against static configs"
    Three guards, all `InvalidConfigurationError`. Two on the way in: a key that names an existing
    **directory** is rejected outright (folder paths are reserved for `load()`), and a key already
    bound to a static configuration cannot be overwritten. One on the way out: `load()` will not
    take over a key a dynamic connection already holds — call `unregister_connection(key)` first,
    or load the folder under a different key.

    That third guard is not redundant with the first. `register_connection`'s directory check sees
    the working directory as it is *at registration time*, so a folder created afterwards — or one
    that exists relative to a later `cd` — slips past it. Without the refusal in `load()`, that
    folder's configuration would silently replace your pool and close it.

    It protects the **exact key**, though, not every spelling of it. A dynamic key names no
    folder, so there is nothing for a folder to collide with: with `"db"` held dynamically,
    `load("./db")` still succeeds and registers a *second* entry beside it. Nothing is closed or
    replaced, but `is_loaded("db")` then answers about the dynamic entry while models importing
    `"./db"` bind to the static one. Prefer keys that cannot be read as paths.

    Re-registering an existing *dynamic* key is still allowed — it closes the old pool first and
    logs a warning, so make sure nothing is still borrowing a connection from it.

```julia
# PostgreSQL
PormG.register_connection("tenant_01", "postgres://user:pass@localhost/db_01"; env = "prod")

# SQLite
PormG.register_connection("temp_cache", "cache.db"; adapter="SQLite", env = "prod")
```

### Binding models to a dynamic connection

`Models.set_models(models; key = "tenant_01")` binds a models module to a connection by its key, with
no folder (#1606). It is the form for a connection built in code: `register_connection` entries have
no folder for the folder form, `set_models(models, "db")`, to match.

```julia
PormG.register_connection("f1", "db/f1.sqlite"; adapter = "SQLite", env = "prod",
                          change_data = true)          # writes are off unless asked for
PormG.Models.set_models(models; key = "f1")            # `models` ends with `Models.@models …`
```

The key is recorded in the models module's model set, so a restored package image, the self-heal
and the Revise reload bind the models again to the same key, and refuse while it is not registered,
rather than look for a folder. Registering the key again (after `unregister_connection`, or in a new
process) is enough for the next query to rebind. This is also the configuration a `juliac --trim`
binary uses: it reads no `connection.yml`.

A MySQL connection takes a `mysql://` URL (#1614):

```julia
PormG.register_connection("f1", "mysql://f1:s3cr%40t@db.internal:3306/f1?sslmode=verify_identity";
                          adapter = "MySQL", env = "prod")
```

The URL is read into the keys of a `connection.yml` MySQL block, so the pool is the one `load` would
build from that block, the 60-second idle ping included ([Advanced Configuration](advanced.md)). Write
`mysql://user:password@host:port/database`, and percent-encode the user name and password when they
hold a reserved character (`%40` for `@`, `%2F` for `/`, `%3A` for a `:` in the user name). A missing
port, host or database means what the missing key means: MySQL's 3306, `localhost`, and no default
database. The query string takes the block's other connection keys: `connect_timeout`, `sslmode`
(`disabled`, `preferred`, `required`, `verify_ca`, `verify_identity`), `sslrootcert`, `sslcert` and
`sslkey`. Any other option, or a URL that does not parse, raises `InvalidConfigurationError` before
a pool is built. The message says what is wrong and never quotes the URL, since any part of it can
hold the password.

!!! note "The environment is stated, not guessed (#1256)"
    The entry records an environment — what `Configuration.env(key)` and `status(key)` report —
    chosen the way [`load` chooses one](connection_yml.md): `env =` when passed, else a non-blank
    `PORMG_ENV`, else, in an interactive session (a REPL) only, `"dev"` with an `@info` saying so.
    A service, a test or a script that states neither gets `InvalidConfigurationError`, raised before
    any pool is built or an existing one under the key is closed. A deployment that exports
    `PORMG_ENV` needs no `env =` on each call.

A PostgreSQL connection can pick its driver with `postgres_driver = "Postgres"` (the
default is `"LibPQ"`), as the `postgres_driver:` key does in `connection.yml` — see
[Choosing the PostgreSQL driver](connection_yml.md#Choosing-the-PostgreSQL-driver). A resolver returning a `Dict` may
carry a `"postgres_driver"` entry for the same purpose.

!!! note "LibPQ cannot be used in a `juliac --trim` build"
    A trimmed binary that connects to PostgreSQL registers its connection with
    `postgres_driver = "Postgres"`. Built with LibPQ 1.18, the binary aborts before `main` runs:
    LibPQ depends on Infinity.jl, whose `__init__` uses Requires' `@require`, and a trimmed binary
    cannot run it (Memento, another LibPQ dependency, would likely stop it too). Postgres.jl has neither
    dependency, and a trimmed binary built with it compiles. It has not been run, and no trimmed
    build runs a query end to end yet ([#1599](https://github.com/PingoLee/PormG.jl/issues/1599)).
    The cause is upstream, and this applies until LibPQ's dependencies stop using Requires
    ([#1614](https://github.com/PingoLee/PormG.jl/issues/1614)).

To tell a dynamic entry from a folder-backed one, read `PormG.Configuration.status(key).dynamic`,
or `settings.dynamic` inside a `before_connect` hook. Do not compare `db_def_folder`: a dynamic
entry stores the label `"dynamic_connection"` there, and so does a static folder of that name
loaded as `load("dynamic_connection")`.

!!! warning "Migrations and model import need a folder"
    A dynamic connection has no models folder, so the migration workflow and the model importers
    refuse it with `InvalidConfigurationError`: `makemigrations`, `migrate`, `status`, `dry_run` and
    `discard_pending_migration` from `PormG.Migrations`, and
    `import_models_from_sqlite` / `import_models_from_postgres`. Before this refusal they followed
    the `"dynamic_connection"` label as a path relative to the working directory, so a static folder
    of that name stood in for the tenant: `dry_run` reported *its* pending plan,
    `discard_pending_migration` moved it, and with `change_db` enabled `makemigrations` overwrote it
    with the tenant's diff and `migrate` applied it to the tenant's database.

    To migrate a tenant database, give it a folder: a `connection.yml` pointing at that database,
    loaded with `Configuration.load(folder)`, and run the migration against that key.
    `import_models_from_django` still accepts a dynamic `db` when you pass `output_path`, because
    the output then goes to a real folder. The calls that only touch the database — the
    `pormg_migrations` history-table calls (`init_migrations`, `mark_applied`, `mark_failed`,
    `remove_migration_record`) and the read-only `check` — accept a dynamic key as before.

---

## Lazy Connection Resolution (Recommended)

You can provide a **resolver function** that PormG calls automatically whenever it encounters an unknown database key.

```julia
PormG.Configuration.set_connection_resolver() do key
    # Fetch connection details from a master DB or Vault
    if startswith(key, "client_")
        client_id = split(key, "_")[2]
        url = "postgres://user:pass@server/db_$(client_id)"
        return Dict("url" => url, "adapter" => "PostgreSQL", "pool_size" => 5, "env" => "prod")
    end
    return nothing
end

# Use the key! PormG loads it lazily.
results = M.Driver.objects.db("client_42").list()
```

The resolver may also return a `(url, adapter, pool_size)` tuple, which carries no environment, so
the key then takes it from `PORMG_ENV` (see the note above). A resolved key that cannot state one
raises that `InvalidConfigurationError` from the query, rather than a generic "not found".

This is the standard way to implement multi-tenancy in PormG. The developer logic resides in the resolver function, keeping the app code clean of connection-management details.
