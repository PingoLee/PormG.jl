# Database Configuration in PormG

PormG uses a flexible configuration system to manage connections to your PostgreSQL and SQLite databases. You can define connections statically via files or dynamically at runtime (perfect for multi-tenant applications).

## Static Configuration (File-based)

- By default, PormG looks for a folder named `db` containing a `connection.yml` file.
- You can use any folder name (e.g., `db_2`, `test/integration/f1`) to manage multiple separate databases. Each folder represents a unique connection key.

### Supported Adapters
- **PostgreSQL**: Primary adapter using `LibPQ.jl`. Supports high-performance async operations and standard parameterized queries (`$1`, `$2`).
- **SQLite**: Fully supported with connection pooling and async-wrapping using `SQLite.jl`. Uses a **Contextual Buckets Strategy** for positional parameters (`?`), enabling advanced features like complex joins, CTEs, and nested subqueries that were previously difficult on purely positional backends.

### Creating a Configuration

The easiest way to set up a new project is using the interactive setup tool:

```julia
using PormG
PormG.setup() # Guide you through folder and connection.yml creation
```

Alternatively, you can set it up manually:

1. **Create a Folder**
   - Example: `db_tenant_a`
2. **Run the Configuration Loader**
   - If the configuration file does not exist, PormG will create a template for you:
     ```julia
     PormG.Configuration.load("db_tenant_a")
     ```
3. **Edit the `connection.yml`**
   - Fill in your details. For SQLite, point the `host` or `database` field to your `.db` file path.

---

## Dynamic Multi-Tenancy

For applications that need to connect to databases on the fly (e.g., based on a user ID or subdomain), PormG provides a Dynamic Registration API.

### Runtime Registration

You can register a connection pool manually at any time:

```julia
# PostgreSQL example
PormG.register_connection("client_01", "postgres://user:pass@localhost/client_db")

# SQLite example
PormG.register_connection("temp_cache", "cache.db"; adapter="SQLite")
```

### Lazy Connection Resolution (Recommended for Servers)

Instead of managing connections manually, you can provide a **resolver function**. PormG will call this function automatically whenever a query tries to use an unknown database key.

```julia
PormG.Configuration.set_connection_resolver() do key
    # Logic to fetch connection details from a master DB or vault
    if startswith(key, "tenant_")
        tenant_id = split(key, "_")[2]
        url = "postgres://user:pass@server/db_$(tenant_id)"
        return (url, "PostgreSQL", 5) # (url, adapter, pool_size)
    end
    return nothing # Key not found
end

# Now you can just use the key! PormG will load it lazily.
results = M.Driver.objects.db("tenant_42").list()
```

---

## Connection Pooling & Async-First Design
- Use `with_advisory_lock(settings, "my_job_name") do ... end` to ensure long-running tasks (migrations, seeds, imports) do not run in parallel across processes.
- Choose strategy: default `strategy = :poll` retries every `interval_ms`; use `strategy = :block` to let Postgres block with a `statement_timeout = timeout_ms` (avoids client-side polling).
- Keys are hashed to a 64-bit bigint via MD5 to reduce collisions vs. `hashtext`.
- If the session drops, Postgres releases the lock automatically; a subsequent unlock on a new session returns `false` but is harmless.
- SQLite does not support advisory locks; the helper will no-op with a warning on that backend.

---
For more details, see the [PormG Documentation](index.md) or the example scripts in the `test/integration/` folder.
