# Dynamic Multi-Tenancy

For applications that connect to databases on the fly (e.g., per user or per subdomain), use the dynamic registration API.

## Runtime Registration

Register a connection pool manually at any time using a connection string or adapter-specific parameters:

!!! warning "Dynamically registered connections are read-only until you enable writes"
    `register_connection` builds its `Settings` from the defaults, so `change_data` and
    `change_db` are **`false`** — and there is no `connection.yml` `config:` block to set them in.
    The first write raises `WritesDisabledError`. Enable it on the settings object directly:

    ```julia
    PormG.register_connection("tenant_01", "postgres://user:pass@host/db_01")
    PormG.config["tenant_01"].change_data = true    # otherwise every write is refused
    ```

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
PormG.register_connection("tenant_01", "postgres://user:pass@localhost/db_01")

# SQLite
PormG.register_connection("temp_cache", "cache.db"; adapter="SQLite")
```

To tell a dynamic entry from a folder-backed one, read `PormG.Configuration.status(key).dynamic`,
or `settings.dynamic` inside a `before_connect` hook. Do not compare `db_def_folder`: a dynamic
entry stores the label `"dynamic_connection"` there, and so does a static folder of that name
loaded as `load("dynamic_connection")`.

---

## Lazy Connection Resolution (Recommended)

You can provide a **resolver function** that PormG calls automatically whenever it encounters an unknown database key.

```julia
PormG.Configuration.set_connection_resolver() do key
    # Fetch connection details from a master DB or Vault
    if startswith(key, "client_")
        client_id = split(key, "_")[2]
        url = "postgres://user:pass@server/db_$(client_id)"
        return (url, "PostgreSQL", 5) # (url, adapter, pool_size)
    end
    return nothing
end

# Use the key! PormG loads it lazily.
results = M.Driver.objects.db("client_42").list()
```

This is the standard way to implement multi-tenancy in PormG. The developer logic resides in the resolver function, keeping the app code clean of connection-management details.
