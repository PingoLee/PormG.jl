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

#### In-memory databases

Two `database:` values are **SQLite keywords rather than file paths**, and PormG hands them to the driver untouched instead of resolving them inside your DB folder:

```yaml
test:
  adapter: SQLite
  database: ":memory:"   # in-memory, private to each pool connection
```

```yaml
test:
  adapter: SQLite
  database: "file:pormg_test?mode=memory&cache=shared"   # in-memory, shared across the pool
```

The distinction matters as soon as `pool_size` is above 1 (it defaults to 3). A bare `:memory:` database belongs to the **connection that opened it** — a table created through one pool slot is invisible from the next, which surfaces as a puzzling `no such table` rather than as a connection error. The `file:…?mode=memory&cache=shared` URI form gives every connection in the pool one shared database and still writes nothing to disk, so prefer it unless you have deliberately set `pool_size: 1`.

PormG does not leave you to discover that on your own:

| configuration | what happens |
|---|---|
| `:memory:` with `pool_size: 1` | nothing to warn about — one connection, one database |
| `:memory:` with `pool_size` above 1 | a **warning**, issued the first time a second connection is actually opened (most pools never do) |
| `:memory:` with `sqlite_split_read_write: true` | **`InvalidConfigurationError` on load** |

The last one is refused rather than warned about because it cannot work at all: split mode sends writes to one fixed connection and reads to the others, so with a per-connection database every read would look in an empty one. Use the shared-cache URI, or `pool_size: 1`.

## Environment-block Keys

These are the keys PormG reads **directly under an environment block** — the peers of `config:`. Anything else in that block is not read by anything, and warns on load (see [Unrecognised keys](#Unrecognised-keys) below).

| Key | Applies to | Meaning |
|---|---|---|
| `adapter` | both | **Required.** `PostgreSQL` or `SQLite`. A block without it raises `InvalidConfigurationError` on load. |
| `database` | both | Database name (PostgreSQL) or file path (SQLite). A relative SQLite path resolves inside the config folder — except for the two keyword forms, `:memory:` and a `file:` URI, which are passed to SQLite verbatim (see [In-memory databases](#In-memory-databases)). |
| `host` | both | Server host on PostgreSQL. **On SQLite it is the database file name and takes precedence over `database:`** — a historical quirk, not a typo. |
| `url` | PostgreSQL | A complete connection string, in either the libpq keyword form or the URL form (`postgres://user:password@host/db`). When present, **every other PostgreSQL target key is ignored** — PormG passes it through verbatim. Both forms are redacted wherever PormG logs, displays or serializes the connection — see [Credentials never leave through `show` or `JSON.json`](advanced.md#Credentials-never-leave-through-show-or-JSON.json). Setting it under `adapter: SQLite` does nothing and warns; use `database:` there. |
| `username`, `password`, `port`, `hostaddr` | PostgreSQL | Standard credentials/target. Forwarded into the libpq DSN. |
| `passfile`, `connect_timeout`, `client_encoding` | PostgreSQL | Forwarded into the libpq DSN. |
| `sslmode`, `sslrootcert`, `sslcert`, `sslkey` | PostgreSQL | TLS settings, forwarded into the libpq DSN. |
| `extensions` | PostgreSQL | List of extensions to require — see [PostgreSQL Extensions](#PostgreSQL-Extensions). Ignored with a warning on SQLite. |
| `postgres_driver` | PostgreSQL | The driver that opens the connections: `LibPQ` (the default) or `Postgres` (**experimental**). Case-insensitive. Unset, the `PORMG_POSTGRES_DRIVER` environment variable decides, then LibPQ. See [Choosing the PostgreSQL driver](#Choosing-the-PostgreSQL-driver). Ignored with a warning on SQLite. |
| `sqlite_split_read_write` | SQLite | Split the pool into read and write connections. |
| `ignore_tables` | both | Table-name prefixes that introspection skips on **this connection only**: `makemigrations`, `check` and the importers never read them. See [Tables PormG leaves alone](#Tables-PormG-leaves-alone). Never forwarded to the driver. |
| `unignore_defaults` | PostgreSQL | Entries of PormG's **built-in** ignore list that this connection reads and migrates after all, such as `account_` for a Django app labelled `account`. Each must equal a built-in entry exactly. See [Switching a built-in entry off](#Switching-a-built-in-entry-off). Any entry is refused on SQLite, whose list has none to remove. Never forwarded to the driver. |
| `pool_size`, `pool_timeout`, `idle_timeout`, `max_lifetime`, `leak_detection_threshold`, `fail_fast_on_connect` | both | Connection-pool tuning — documented in [Advanced Configuration](advanced.md). |
| `options` | both | Legacy nesting for `sqlite_split_read_write` only. Prefer setting that key directly on the block. |
| `config` | both | The settings sub-dictionary described in the next section. |

The PostgreSQL-only keys are inert under `adapter: SQLite`, so a block may carry both sets without harm. `hostaddr`, `port`, `password`, `passfile`, `connect_timeout`, `client_encoding` and the four `ssl*` keys reach libpq under exactly the names written here; `username` and `database` are translated to libpq's `user=` and `dbname=` for you.

Every forwarded value is single-quoted and escaped for libpq, so write it exactly as it is: a password such as `corr3ct horse 'battery'`, or a certificate path such as `C:\certs\root ca.crt`, needs no quoting of its own beyond what YAML requires. YAML's own typing still applies first, so quote any value YAML would read as a number or a boolean — `password: 007` reaches libpq as `7`, and `password: '007'` as `007`. A value containing a NUL character cannot be sent to PostgreSQL at all and is rejected when the connection is built. (Only `url:` is passed through untouched, so a value inside it follows libpq's own quoting rules.)

## Choosing the PostgreSQL driver

PostgreSQL pools use [LibPQ.jl](https://github.com/iamed2/LibPQ.jl) unless told otherwise. [Postgres.jl](https://github.com/JuliaDatabases/Postgres.jl), a pure-Julia driver with no libpq underneath, is available as an **experimental** alternative:

```yaml
dev:
  adapter: PostgreSQL
  database: f1
  host: 127.0.0.1
  username: my_user
  password: my_password
  postgres_driver: Postgres
```

Load the driver package as you would LibPQ — `using PormG, Postgres` — so its extension loads. `register_connection(...; postgres_driver = "Postgres")` does the same for a dynamic connection, and `PORMG_POSTGRES_DRIVER=Postgres` switches every PostgreSQL pool that does not name a driver, which is how the test suite runs through it.

PormG opens Postgres.jl sessions the way LibPQ.jl opens its own — `DateStyle=ISO,YMD` and `TimeZone=UTC` — and decodes results to the same types (`Decimals.Decimal`, `ZonedDateTime` in UTC, `DateTime`). Server notices go to `@debug` rather than the log. Known gaps while it is experimental:

- **A hand-written string holding several statements fails** when you send it yourself, for example two `ALTER TABLE`s in one `fetch` call. Postgres.jl runs every statement over the extended protocol; see [JuliaDatabases/Postgres.jl#23](https://github.com/JuliaDatabases/Postgres.jl/issues/23). Send one statement per call. Migrations are not affected: `migrate` sends a plan one statement at a time under either driver.
- `passfile`, `hostaddr`, `service`, multiple hosts and Unix-socket hosts are not supported, nor is a `client_encoding` other than UTF-8 or a `target_session_attrs` other than `any`; `reconnect=true` in a connection string is refused (the pool renews connections itself).
- `fetch_copy` reports the number of CSV records it sent rather than the server's `COPY n` count. That is exact for PormG's own `bulk_copy`, but can differ for a hand-written `COPY` with `HEADER true`, `FORMAT text` or `binary`, or a custom `QUOTE`.
- `interval` values cast to text render in PostgreSQL's default style rather than ISO 8601.

## Tables PormG leaves alone

Some tables in a database belong to another system, like a timing feed another service loads or a
reporting job's staging tables. PormG must not migrate them, and you do not want to model them.
List them under `ignore_tables:` and PormG never reads them on **that connection**:

```yaml
dev:
  adapter: PostgreSQL
  database: f1
  host: 127.0.0.1
  username: my_user
  password: my_password
  ignore_tables:
    - legacy_timing_
    - etl_staging
```

- **Entries are prefixes.** `legacy_timing_` skips `legacy_timing_laps` and `legacy_timing_pits`.
  A whole table name is its own prefix, so `etl_staging` skips that table, but it also skips
  `etl_staging_2`. This is the same rule as every other ignore list.
- **Skipped tables are invisible to** `makemigrations` (never dropped, never altered), to
  [`check`](../migrations/workflow.md#Checking-the-Database-Against-the-Models), and to
  `import_models_from_postgres` / `import_models_from_sqlite`.
- **The list adds to the others and replaces none of them.** Those others are the backend's
  built-in list (see [below](#The-built-in-list)), the process-wide
  [`register_ignore_tables!`](../extending.md#Extension-points), and the `ignore_table=` keyword
  that `check` and the importers take. The difference is scope: `ignore_tables:` applies to one
  connection. An app that drives two databases can skip a table on the replica and still migrate it
  on the primary.
- **Case is kept.** Entries are table names, not keywords.

`ignore_tables:` left empty, or set to `''`, means the key is not set. Two values are refused when
the file loads, with `InvalidConfigurationError`. The first is a value that is not a string or a
list of strings. The second is a blank string inside a list: as a prefix, `""` matches every
table.

**Declaring a model for an ignored table is a contradiction, and it is refused.** The model asks
PormG to migrate the table, and the list asks PormG never to read it. Because PormG would not see
the existing table, it would plan to create it again on every run. So `makemigrations` and
`check(kinds = [:schema_drift])` raise `InvalidConfigurationError`, naming the model, the entry it
matched, and the list the entry came from. (`makemigrations` plans nothing at all under
`change_db: false`, so there only `check` reports it.) The same rule covers all three lists:
this key, `register_ignore_tables!`, and the backend's built-in list. So a managed model on an
`auth_` or `django_` table is refused on PostgreSQL. The one list it does not cover is `check`'s own
`ignore_table=` keyword, which only filters what `check` reads. The check covers every declared
model, so `check`'s `include_table=` does not narrow it.

The fix depends on what you want:

- **Query the table without migrating it:** declare the model with
  [`managed = false`](../models.md#Unmanaged-models). An unmanaged model on an ignored table is fine.
- **Migrate it after all:** take the table off every list that hides it, on that connection. Remove
  the entry from `ignore_tables:`, and list a built-in entry under
  [`unignore_defaults:`](#Switching-a-built-in-entry-off). `register_ignore_tables!` cannot be
  switched off for one connection, and neither can the built-in `pormg_migrations` entry. The error
  names every list the table matches, and offers only the fixes that would work.
- **Let PormG own a new table instead:** give the model a table name (or `db_table`) outside the
  prefix. That plans a new, empty table; the existing table and its rows stay where they are.

A `ManyToManyField` on an unmanaged model is not always fine. Its automatic join table,
`<table>_<field>`, is managed whenever the other end is, and it usually shares the prefix. Give that
field a `db_table` outside the prefix, or declare an explicit `through` model.

### The built-in list

PormG skips these prefixes on every connection, before `ignore_tables:` adds any:

| Engine | Built-in entries |
|---|---|
| PostgreSQL (`postgres_ignore_table`) | `auth_`, `django_`, `social_`, `account_`, `allauth_`, `admin_`, `celery_`, `django_celery_`, `djcelery_`, `kombu_`, `pormg_migrations` |
| SQLite (`sqlite_ignore_schema`) | `sqlite_sequence`, `sqlite_autoindex`, `pormg_migrations` |

The PostgreSQL list hides the tables of Django, django-allauth, python-social-auth and Celery, which
often share a PostgreSQL database with the tables PormG migrates. The SQLite list holds no framework
prefix, so the two engines differ: a model on an `auth_` table is refused on PostgreSQL and
migrated on SQLite.

### Switching a built-in entry off

Django names a table `<app_label>_<model>`, so your own Django app labelled `account` keeps its
tables under `account_`, a prefix the PostgreSQL list hides. List the entry under
`unignore_defaults:` and that connection reads and migrates those tables like any other:

```yaml
dev:
  adapter: PostgreSQL
  database: f1
  host: 127.0.0.1
  username: my_user
  password: my_password
  unignore_defaults:
    - account_
```

- **Each entry must equal a built-in entry.** `account_` is one; `account` or `account_sponsor` is
  not. A value that is not an entry is refused when the file loads, with `InvalidConfigurationError`
  naming the entries you can remove, so a typo cannot silently do nothing. Use `ignore_tables:` to
  hide more tables, not this key.
- **The whole prefix comes back.** Every table under `account_` becomes visible to `makemigrations`,
  `check` and the importers on that connection, including any that belong to django-allauth. A
  visible table that no model declares is planned for removal, like any other undeclared table, so
  declare a model for each one you keep (with `managed = false` if PormG should only read it).
- **Entries are independent, and some overlap.** Removing `django_` leaves `django_celery_` in
  place, so `django_celery_beat_*` stays hidden; list both to read those tables. When a managed
  model is refused, the error names every entry that hides its table.
- **`pormg_migrations` and the SQLite engine tables cannot be removed.** They belong to PormG and to
  the engine. On SQLite that leaves nothing to remove, so any entry is refused. The entries are
  prefixes, so `pormg_migrations` also covers `pormg_migrations_data`, the table
  [`run_once`](../migrations/advanced.md#Data-Migrations) records its steps in.
- **It is per connection, like `ignore_tables:`.** Another connection in the same process keeps the
  full list. `register_ignore_tables!` is not affected.

## Configuration Settings (`config:`)

At the core of `connection.yml` is the `config` sub-dictionary. This section governs runtime permissions, timezones, and naming conventions for the loaded environment:

### Unrecognised keys

!!! warning "A key PormG does not read is reported, never silently dropped"
    Every level of the file is checked on load, and anything unrecognised emits a `@warn` naming the
    key — plus a *"did you mean"* when the name is close to a real one:

    - **Under `config:`** — only `change_db`, `change_data`, `django_prefix`, `time_zone` and
      `model_file` are accepted (e.g. `djago_prefix` → `django_prefix`).
    - **Directly under an environment block** — only the keys in the table above
      (e.g. `sslmod` → `sslmode`). Spellings borrowed from other tools are recognised too:
      `user` → `username`, `pool` → `pool_size`, `dbname` → `database`, `ENGINE` → `adapter`.
    - **At the top level of the file** — anything that is not `default_env:` and not an environment
      block (e.g. `defaultenv:` → `default_env`).
    - **Between the two levels** — a `config:` setting written on the environment block, or an
      environment key written under `config:`, is reported as misplaced and tells you where it
      belongs, rather than being reported as unknown.

    A malformed `config:` (one that is not a block of settings) is reported the same way. An
    environment block that is not a block of settings, and one with no `adapter:`, raise
    `InvalidConfigurationError` instead — they leave nothing to connect with.

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
    folder == "db_legacy" && return ensure_vpn_connection()
    return true
end

PormG.Configuration.load_many(["db", "db_legacy"]; env="dev")
```

The callback receives `(key::String, settings::Settings)` and must return `true` to allow the physical connection or `false` to abort.

Semantics:

- It runs **only when a new physical connection must be opened**, not on connection reuse — so a warm pool does not pay the hook cost on every query.
- It runs **outside the pool lock**, so a slow hook (VPN bring-up, `sleep`) does not block other tasks acquiring connections.
- Returning `false` aborts the acquire with a clear error naming the connection key.
- When no hook is registered, connections proceed normally.
