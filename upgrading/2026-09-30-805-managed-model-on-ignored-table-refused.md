## `makemigrations` — a managed model on a registry- or default-ignored table is refused (#805)

- **Version**: Unreleased
- **Recorded**: 2026-09-30
- **PormG ref**: #805; `src/migrations/planner.jl` (`_refuse_managed_models_on_ignored_tables`)
- **Severity**: behavior change — `makemigrations` and `check(kinds = [:schema_drift])` now raise
  `InvalidConfigurationError` for a managed model on a table matched by `register_ignore_tables!`
  or by the backend's built-in ignore list, as they already did for the connection's
  `ignore_tables:` (#749)

### What changed

PormG never reads a table under an ignore list, so a model declared on one looked like a model with
no table. `makemigrations` planned `CREATE TABLE IF NOT EXISTS` for it on every run. Against the
existing table that statement does nothing, so the next run planned it again. `check(kinds =
[:schema_drift])` reported the same model as `"New model"` every time.

#749 refused this for the connection's `ignore_tables:` only. The refusal now covers all three lists
`makemigrations` reads with:

- the connection's `ignore_tables:` (unchanged);
- the process-wide `register_ignore_tables!` registry;
- the backend's built-in list: `pormg_migrations` on both engines, plus framework prefixes such as
  `auth_`, `django_`, `account_`, `admin_` and `celery_` on PostgreSQL (`postgres_ignore_table`).

The error names each model, the entry it matched, and the list the entry came from. `check`'s own
`ignore_table=` keyword does not trigger it and still only filters what `check` reads.

A `managed = false` model on any of these tables is unaffected, as before.

### How to find the calls to migrate

`makemigrations` fails with this message, so running it once finds every model:

```
a managed model's table matches an ignore list
```

To find them without running anything, search the models files for a table name under a built-in
prefix: a quoted name (`Model("auth_user"; …)`, which also works across lines), or a binding the
table name is derived from (`Auth_user = Models.Model(…)`). Add any prefix your app or a package
passes to `register_ignore_tables!`. A quoted hit can also be a foreign-key target, so read each one:

```bash
grep -rniP '"(auth_|django_|social_|account_|allauth_|admin_|celery_|djcelery_|kombu_|pormg_migrations)|^\s*(auth_|django_|social_|account_|allauth_|admin_|celery_|djcelery_|kombu_|pormg_migrations)\w*\s*=\s*(Models\.)?Model\(' --include=*.jl db/
```

A `ManyToManyField` can also land under a prefix without any model doing so. Its automatic join
table is `<table>_<field>`, so a model on a table named exactly `account`, `admin`, `auth`,
`social` or `celery` synthesizes `account_groups` and the like. List those models, then check
each one for a `ManyToManyField`:

```bash
grep -rniP '"(auth|django|social|account|allauth|admin|celery|djcelery|kombu)"|^\s*(auth|django|social|account|allauth|admin|celery|djcelery|kombu)\s*=\s*(Models\.)?Model\(' --include=*.jl db/
```

### Migrate your app

If the model exists only to query the table, declare it unmanaged:

```julia
# ✗ before: planned CREATE TABLE IF NOT EXISTS "auth_user" on every run (PostgreSQL)
Auth_user = Models.Model("auth_user"; id = Models.IDField(), username = Models.CharField())

# ✓ after
Auth_user = Models.Model("auth_user"; managed = false, id = Models.IDField(), username = Models.CharField())
```

If PormG should migrate the table, take it off the list that hides it, on that connection. A
built-in entry is switched off with `unignore_defaults:` in `connection.yml` (#818), for example
for your own Django app labelled `account`:

```yaml
# ✓ after: this connection reads and migrates every account_* table
dev:
  adapter: PostgreSQL
  unignore_defaults:
    - account_
```

Every table under that prefix becomes visible, and one no model declares is planned for removal,
so declare each one you keep. A table hidden only by an `ignore_tables:` entry can be migrated by
removing that entry. The registry and the built-in `pormg_migrations` entry cannot be switched off
for one connection: to have PormG own such a table anyway, give the model a table name (or
`db_table`) outside the prefix. That plans a **new, empty** table; the existing one and its rows
stay where they are, so copy the data yourself if you need it.
