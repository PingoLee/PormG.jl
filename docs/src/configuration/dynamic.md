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
    Two guards, both `InvalidConfigurationError`: a key that names an existing **directory** is
    rejected outright (folder paths are reserved for `load()`), and a key already bound to a
    static configuration cannot be overwritten. Re-registering an existing *dynamic* key is
    allowed — it closes the old pool first and logs a warning, so make sure nothing is still
    borrowing a connection from it.

```julia
# PostgreSQL
PormG.register_connection("tenant_01", "postgres://user:pass@localhost/db_01")

# SQLite
PormG.register_connection("temp_cache", "cache.db"; adapter="SQLite")
```

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
