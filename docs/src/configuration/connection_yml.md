# The `connection.yml` Configuration File

PormG uses a centralized YAML configuration file—typically located at `db/connection.yml`, or in your specific folder path like `nitro_server/db/connection.yml`—to govern how the application connects to databases and what operations it's authorized to execute.

## Creating `connection.yml`

During standard initialization, `PormG.Configuration.load()` will check for a `connection.yml` in your `DB_PATH`. If it does not exist, PormG provides interactive prompts (in `dev` environments) or throws an error.

To scaffold it programmatically, you can run:

```julia
using PormG
# Provide your path, typically DB_PATH, for instance "nitro_server/db"
PormG.Generator.create_db_folder_and_yml(path="nitro_server/db", adapter="PostgreSQL", database="my_database")
```

Or you can manually create the `connection.yml` file and populate it using the structures below:

## Adapters & Environments

PormG uses an explicit `env` key at the root of the file to determine which nested configuration maps to the current active environment. The primary supported adapters are `PostgreSQL` and `SQLite`.

### Using PostgreSQL

To use a PostgreSQL database, assign `adapter: PostgreSQL` and configure your credentials.

```yaml
env: dev

dev:
  adapter: PostgreSQL
  database: my_database
  host: 127.0.0.1
  username: my_user
  password: my_password
  port: 5432
  extensions:
    - unaccent
  config:
    change_db: true
    change_data: true
    time_zone: 'UTC'

prod:
  adapter: PostgreSQL
  database: my_prod_database
  host: prod.database.server.com
  username: prod_user
  password: secure_password
  port: 5432
  config:
    change_db: false
    change_data: true
    time_zone: 'UTC'
```

### Using SQLite

When using SQLite, the parameters are simplified. You specify `adapter: SQLite` and pass the path (or file name) of the SQLite database to the `database` property. Missing elements like host, username, or port safely get ignored.

```yaml
env: dev

dev:
  adapter: SQLite
  database: dev_database.sqlite  # Will be generated inside your DB folder 
  config:
    change_db: true
    change_data: true
    time_zone: 'UTC'
```

## Security and Write Permissions (`change_data` & `change_db`)

At the core of `connection.yml` is the `config` sub-dictionary. This section decides whether the application acts internally as a read-only client or a full administrative client:

### `change_data`
- **`true`**: DML operations (Data Manipulation Language) are permitted. You can `save()`, `update()`, and `delete()` records through PormG models.
- **`false`**: Makes the database connection read-only internally. Queries fetch data securely, but any invocation of model-mutating functions will fail safely at the ORM layer before generating SQL.

### `change_db`
- **`true`**: DDL operations (Data Definition Language) are permitted. PormG's migration subsystem is authorized to create tables, alter columns, and perform schema patches directly against the database.
- **`false`**: Blocks schema changes. All `Migrations.migrate()` commands will be defensively rejected, protecting your production database from unintended, automated alteration.

## PostgreSQL Extensions

PostgreSQL extensions can be declared in the active environment block with a simple `extensions` list.

```yaml
dev:
  adapter: PostgreSQL
  database: my_database
  extensions:
    - unaccent
```

Currently supported extensions:

- `unaccent`: installs the `unaccent` extension **and** an `IMMUTABLE` helper function `public.immutable_unaccent(text)`, then enables accent-insensitive lookups:
    - `field__@iunaccent_contains` — accent- and case-insensitive substring match (`ILIKE` on `immutable_unaccent`).
    - `field__@iunaccent_exact` — accent- and case-insensitive equality (`LOWER(immutable_unaccent(field)) = LOWER(immutable_unaccent($1))`).

**When are extensions installed?** Installing an extension is DDL, so PormG applies it through the migration runner — the same place schema changes happen — gated by `config.change_db`. Running `PormG.migrate(db)` provisions the configured extensions (and the helper function) before applying the schema plan, even when there is no schema diff; `CREATE ... IF NOT EXISTS` keeps it idempotent. `PormG.Configuration.load(...)` performs **no DDL**: it only probes `pg_extension` and warns if a configured extension is still missing, so misconfiguration surfaces before the first query fails.

The database user must be allowed to create the extension and function. If PostgreSQL rejects the commands (or `change_db` is `false`, as in production), run them once as the database owner/admin:

```sql
CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA public;

-- unaccent(text) is only STABLE, so it cannot back an index. This IMMUTABLE
-- wrapper (explicit dictionary) is what iunaccent_contains emits, so it can.
CREATE OR REPLACE FUNCTION public.immutable_unaccent(text)
  RETURNS text LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
  AS $$ SELECT public.unaccent('public.unaccent', $1) $$;
```

### Making `iunaccent_contains` index-assisted

`field__@iunaccent_contains` emits `public.immutable_unaccent(column) ILIKE public.immutable_unaccent($1)`. Without a matching index this is a sequential scan. For large tables, add a `pg_trgm` GIN index on the **same expression** so the `ILIKE '%…%'` pattern can use it:

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_drivers_forename_unaccent
  ON drivers USING gin (public.immutable_unaccent(forename) gin_trgm_ops);
```

For `iunaccent_exact` (equality), a plain btree on the lowered expression is enough:

```sql
CREATE INDEX idx_drivers_forename_unaccent_exact
  ON drivers (lower(public.immutable_unaccent(forename)));
```

SQLite configurations ignore `extensions` with a warning, and `iunaccent_contains` raises a clear error on SQLite.

## Multi-environment Routing

The line `env: dev` instructs PormG to read from the block named `dev`. When you deploy your application (or if running `nitro_server` in another environment), you can change `env: prod` or set the system environment variable `PORMG_ENV=prod` to override the top-level YAML key seamlessly without modifying code.

## Pre-connect hooks

Some databases are only reachable after external setup such as a VPN, SSH tunnel, or credential refresh. PormG keeps that logic out of the ORM: register an app-level hook once at boot and decide inside the callback which connections need setup.

Register the hook **before** the first query or `ping`:

```julia
using PormG

PormG.Configuration.set_before_connect_hook() do key, settings
    folder = basename(settings.db_def_folder)
    folder == "db_esus" && return ensure_vpn_connection()
    return true
end

PormG.Configuration.load_many(["db", "db_esus"]; env="dev")
```

The callback receives `(key::String, settings::Settings)` and must return `true` to allow the physical connection or `false` to abort.

Semantics:

- It runs **only when a new physical connection must be opened**, not on connection reuse — so a warm pool does not pay the hook cost on every query.
- It runs **outside the pool lock**, so a slow hook (VPN bring-up, `sleep`) does not block other tasks acquiring connections.
- Returning `false` aborts the acquire with a clear error naming the connection key.
- When no hook is registered, connections proceed normally.
