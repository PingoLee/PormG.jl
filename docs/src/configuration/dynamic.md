# Dynamic Multi-Tenancy

For applications that connect to databases on the fly (e.g., per user or per subdomain), use the dynamic registration API.

## Runtime Registration

Register a connection pool manually at any time using a connection string or adapter-specific parameters:

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
