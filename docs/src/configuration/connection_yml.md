# The `connection.yml` Configuration File

PormG uses a centralized YAML configuration file—typically located at `db/connection.yml`, or in your specific folder path like `nitro_server/db/connection.yml`—to govern how the application connects to databases and what operations it's authorized to execute.

## Creating `connection.yml`

During standard initialization, `PormG.Configuration.load(path)` reads a `connection.yml` from `path` (default `DB_PATH`). If the folder or file is missing it **throws** a `MissingConfigurationError` that points you at `PormG.setup(path)` (interactive) or `load(path; scaffold=true)` (writes an editable skeleton) — it no longer silently scaffolds a file and returns.

To scaffold it programmatically, you can run:

```julia
using PormG
# Provide your path, typically DB_PATH, for instance "nitro_server/db"
PormG.Generator.create_db_folder_and_yml(path="nitro_server/db", adapter="PostgreSQL", database="my_database")
```

Or you can manually create the `connection.yml` file and populate it using the structures below:

## Adapters & Environments

Each top-level block (`dev`, `prod`, `test`, …) describes one environment, and PormG loads whichever one is active. The active environment is chosen by the `env=` argument to `load(...)`, the `PORMG_ENV` variable, or an optional top-level `default_env:` key — see [Multi-environment Routing](#Multi-environment-Routing) below. The primary supported adapters are `PostgreSQL` and `SQLite`.

### Using PostgreSQL

To use a PostgreSQL database, assign `adapter: PostgreSQL` and configure your credentials.

```yaml
default_env: dev

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
default_env: dev

dev:
  adapter: SQLite
  database: dev_database.sqlite  # Will be generated inside your DB folder 
  config:
    change_db: true
    change_data: true
    time_zone: 'UTC'
```

## Environment-block Keys

These are the keys PormG reads **directly under an environment block** — the peers of `config:`. Anything else in that block is not read by anything, and warns on load (see [Unrecognised keys](#Unrecognised-keys) below).

| Key | Applies to | Meaning |
|---|---|---|
| `adapter` | both | **Required.** `PostgreSQL` or `SQLite`. A block without it raises `InvalidConfigurationError` on load. |
| `database` | both | Database name (PostgreSQL) or file path (SQLite). A relative SQLite path resolves inside the config folder. |
| `host` | both | Server host on PostgreSQL. **On SQLite it is the database file name and takes precedence over `database:`** — a historical quirk, not a typo. |
| `url` | PostgreSQL | A complete connection string. When present, **every other PostgreSQL target key is ignored** — PormG passes it through verbatim. Setting it under `adapter: SQLite` does nothing and warns; use `database:` there. |
| `username`, `password`, `port`, `hostaddr` | PostgreSQL | Standard credentials/target. Forwarded into the libpq DSN. |
| `passfile`, `connect_timeout`, `client_encoding` | PostgreSQL | Forwarded into the libpq DSN verbatim. |
| `sslmode`, `sslrootcert`, `sslcert`, `sslkey` | PostgreSQL | TLS settings, forwarded into the libpq DSN verbatim. |
| `extensions` | PostgreSQL | List of extensions to require — see [PostgreSQL Extensions](#PostgreSQL-Extensions). Ignored with a warning on SQLite. |
| `sqlite_split_read_write` | SQLite | Split the pool into read and write connections. |
| `pool_size`, `pool_timeout`, `idle_timeout`, `max_lifetime`, `leak_detection_threshold`, `fail_fast_on_connect` | both | Connection-pool tuning — documented in [Advanced Configuration](advanced.md). |
| `options` | both | Legacy nesting for `sqlite_split_read_write` only. Prefer setting that key directly on the block. |
| `config` | both | The settings sub-dictionary described in the next section. |

The PostgreSQL-only keys are inert under `adapter: SQLite`, so a block may carry both sets without harm. `hostaddr`, `port`, `password`, `passfile`, `connect_timeout`, `client_encoding` and the four `ssl*` keys reach libpq under exactly the names written here; `username` and `database` are translated to libpq's `user=` and `dbname=` for you.

## Configuration Settings (`config:`)

At the core of `connection.yml` is the `config` sub-dictionary. This section governs runtime permissions, logging, timezones, and naming conventions for the loaded environment:

### Unrecognised keys

!!! warning "A key PormG does not read is reported, never silently dropped"
    Every level of the file is checked on load, and anything unrecognised emits a `@warn` naming the
    key — plus a *"did you mean"* when the name is close to a real one:

    - **Under `config:`** — only `change_db`, `change_data`, `django_prefix`, `time_zone`,
      `log_queries`, `log_level`, `log_to_file` and `model_file` are accepted
      (e.g. `djago_prefix` → `django_prefix`).
    - **Directly under an environment block** — only the keys in the table above
      (e.g. `sslmod` → `sslmode`). Spellings borrowed from other tools are recognised too:
      `user` → `username`, `pool` → `pool_size`, `dbname` → `database`, `ENGINE` → `adapter`.
    - **At the top level of the file** — anything that is not `default_env:` and not an environment
      block (e.g. `defaultenv:` → `default_env`).
    - **Between the two levels** — a `config:` setting written on the environment block, or an
      environment key written under `config:`, is reported as misplaced and tells you where it
      belongs, rather than being reported as unknown.

    A malformed `config:` (one that is not a block of settings) and an unrecognised `log_level:`
    value are reported the same way. An environment block that is not a block of settings, and one
    with no `adapter:`, raise `InvalidConfigurationError` instead — they leave nothing to connect
    with.

!!! warning "Both default to `false`, and a key under the wrong environment is silent"
    Omit the `config:` block and you get `change_data: false` **and** `change_db: false` — writes
    raise `WritesDisabledError` and migrations are rejected. Both keys are only read from the
    `config:` sub-dictionary of the environment you actually loaded. Writing one at the environment
    level instead now warns and names `config:` as its home, but writing it **under a different
    environment** stays silent — only the active block is read, so there is nothing to check it
    against. A config scaffolded by `PormG.setup()` already sets `change_data: true`; one written by
    hand or registered through `register_connection` does not.

### `change_data`
- **`true`**: DML operations (Data Manipulation Language) are permitted. You can `save()`, `update()`, and `delete()` records through PormG models.
- **`false`**: Makes the database connection read-only internally. Queries fetch data securely, but any invocation of model-mutating functions will fail safely at the ORM layer before generating SQL.

### `change_db`
- **`true`**: DDL operations (Data Definition Language) are permitted. PormG's migration subsystem is authorized to create tables, alter columns, and perform schema patches directly against the database.
- **`false`**: Blocks schema changes. All `Migrations.migrate()` commands will be defensively rejected, protecting your production database from unintended, automated alteration.

### `django_prefix`

Optional (default: unset). Names the Django **app label** whose tables this connection reads, when the
schema is owned by a Django project:

```yaml
dev:
  adapter: PostgreSQL
  database: sgrh
  config:
    change_data: true
    django_prefix: dash      # Django tables are dash_<model>
```

It only ever shapes **names**. The Django importer emits it as each generated model's `db_table`;
relationship accessor names strip it; and it is the fallback used to spell the physical table of a
reverse-join target that declares no `db_table`. It does **not** switch any behaviour on: not
sequence synchronisation, not Django-style short-form join paths. See
[`django_prefix` interop](../schema_conventions.md#django_prefix-interop).

`django_prefix: ''` means the same as omitting the key — an empty app label is the absence of one,
not a prefix that happens to be empty. Earlier versions composed `"$(prefix)_"` regardless and
derived table names beginning with `_`.

**Leave it unset for a multi-app Django project.** One connection-level value cannot name three app
labels, and `import_models_from_django` takes `"<app_label>" => "<models.py>"` pairs for that case —
it *refuses* to run when this key is set, because accessor derivation strips one prefix from every
logical name regardless of which app the model came from. See
[Importing a multi-app project](../import_django.md#Importing-a-multi-app-project).

!!! note "DDL only"
    `change_db` governs schema changes and nothing else. Earlier versions also secretly switched
    PostgreSQL sequence synchronisation on, so the `change_db: false` production posture shown above
    silently stopped repairing `id` sequences after an explicit-primary-key insert — until a later
    insert failed with a duplicate-key error. Sequence repair no longer consults this key (or
    `django_prefix`); see
    [Sequence synchronisation](../schema_conventions.md#Sequence-synchronisation).

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

PormG selects the active environment block by this precedence — **first match wins**:

1. the `env=` argument to `load(...)` — e.g. `PormG.Configuration.load("db"; env="prod")`;
2. the `PORMG_ENV` environment variable — e.g. `PORMG_ENV=prod`;
3. the optional top-level `default_env:` key in this file — e.g. `default_env: prod`;
4. otherwise `dev`.

The recommended pattern for a server is to let the **host** resolve its own environment and pass it explicitly: a framework (or your `bootstrap`) reads its own env var and calls `load(...; env=…)`, so the same `connection.yml` works unchanged in every environment. `default_env:` is a convenience for scripts and single-environment apps that would rather pin a default in the file than set an env var — omit it and PormG falls back to `dev`.

!!! note "The bare `env:` key is ignored"
    A top-level `env:` key (as opposed to `default_env:`) does **nothing** — it was renamed to `default_env:`. If a stale config still has `env:`, PormG warns once on load and keeps using the environment resolved above.

Any other top-level value that is not an environment block is warned about on load, with a `default_env` suggestion for near-misses like `defaultenv:` — a common way to lose the setting silently. An environment block written with an empty body (`prod:` with nothing under it) is still a block and is never flagged.

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
