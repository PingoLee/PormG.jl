## The migration diff compares the physical column, not the Julia field type (#325)

- **Version**: 0.4.0
- **PormG ref**: #325; `src/Dialect.jl`, `src/migrations/introspection.jl`,
  `src/migrations/planner.jl`, `src/models/fields.jl`, `src/constants.jl`
- **Recorded**: 2026-08-07
- **Severity**: **behavior-visible (one-time migration plan against existing databases)** — no source
  edit is required. Part of the `0.4.x` wave.

### What changed

The remainder of the churn [#318](#introspection-now-reads-single-column-unique-back-318) fixed for
`unique`. A model declaring `URLField`, `SlugField`, `UUIDField`, `JSONField`, `ImageField`,
`FileField` or a `varchar` longer than 255 never compared equal to its own live table, so
`makemigrations` proposed the same alteration **on every run** — on SQLite the full
`CREATE new → INSERT SELECT → DROP old → RENAME` table rebuild. The same held for **every**
`db_index=true` field on both backends.

The root cause is that introspection *cannot* reproduce the declared Julia type: several field types
render the same column, so the information is not in the schema to read. PostgreSQL renders
`CharField`, `URLField` and `SlugField` all as `varchar(n)` and `ImageField`/`FileField` as `text`;
SQLite renders `UUIDField`, `JSONField`, `ImageField` and `TextField` all as bare `TEXT`. The diff
now compares **what the database actually holds** — the rendered column type plus the bounds only a
CHECK can express — and falls back to Julia struct identity only when the two structs match. Two
fields that render the same column are the same column, and an ALTER between them was always a no-op.

Six lossy reads are fixed alongside it:

- **PostgreSQL `max_length`** — any `varchar(n > 255)` was retyped to `text` with no length, because
  `CharField` refused a `max_length` above 255. That ceiling is gone (a MySQL-ism; PostgreSQL takes
  up to 10,485,760 characters and SQLite ignores the length), so `varchar(n)` now round-trips as
  `CharField(n)`, symmetric with `text` ⇒ `TextField`.
- **SQLite `max_length`** — a bare `TEXT` column read back as `CharField`, whose constructor invents
  `max_length = 250`. A lengthless textual column is now a `TextField`; only a declared `TEXT(n)`
  (or a hand-written `VARCHAR(n)`/`CHAR(n)`, now recognized) is a `CharField`.
- **`db_index`** — never read on either backend. PostgreSQL probed a `Dict{String,String}` with a
  `Symbol` key, which never matches; SQLite did not look at indexes at all. Both now read the
  single-column, non-unique, non-partial secondary indexes that `db_index=true` actually emits.
- **`get_constraints_unique`** — returned the first row of an unordered result matching any
  constraint the column merely belonged to, so a column in both `UNIQUE(a)` and `UNIQUE(a, b)` could
  drop the composite one. It is now restricted to single-column constraints and ordered.
- **`auto_now` / `auto_now_add`** — these emit **no DDL at all**: PormG stamps the timestamp in Julia
  on write, it is not a column `DEFAULT` and not a trigger. So they can never be read back, and
  `alter_field` had nothing to emit for them. Every `DateTimeField(auto_now_add=true)` was producing
  an empty alteration on every run — a full table rebuild on SQLite. They are now recognized as
  model-layer-only, like `blank` and `editable`.
- **The introspection ignore list** (`postgres_ignore_table` / `sqlite_ignore_schema`) now matches a
  **prefix** on both backends. PostgreSQL used `occursin`, so a user table merely *containing* an
  entry — `oauth_tokens` contains `auth_`, `company_admin_log` contains `admin_` — vanished from the
  live schema entirely. A table PormG cannot see does not read as "ignored" downstream, it reads as
  "does not exist", so `makemigrations` proposed `CREATE TABLE` for it forever. (SQLite used `==`,
  which could never match `sqlite_autoindex`, only ever a prefix.)

An index difference is also no longer routed through a column `ALTER`: it emits `CREATE INDEX` /
`DROP INDEX` alone. On SQLite that removes a full table rebuild that did nothing.

### What you may see once

Nothing to edit — but the **first** `makemigrations` after upgrading can propose a one-time plan:

- A live secondary index on a field declaring `db_index=false` is now visible as drift, so PormG will
  propose **dropping** it. Previously it was invisible. If the index should stay, add
  `db_index=true` to the field before applying.
- Conversely, a field declaring `db_index=true` whose index never actually got created (the create
  path could be skipped while the attribute was unreadable) now gets one `CREATE INDEX`, once.
- On SQLite, a **hand-written** lengthless `TEXT` column that your model declares as
  `CharField(max_length=n)` now reads back as a `TextField`, so PormG will propose rebuilding it as
  `TEXT(n)`. Tables PormG created are unaffected — it has always emitted the length.
- On PostgreSQL, a table whose name merely *contained* a framework prefix — `oauth_tokens`,
  `company_admin_log`, `my_social_graph` — used to be invisible, so `makemigrations` re-proposed
  `CREATE TABLE` for it every run and any real drift on it was never reported. It is now
  introspected normally, so the **first** run after upgrading may propose genuine changes that were
  being hidden. Tables that actually *start* with a framework prefix (`django_*`, `auth_*`,
  `celery_*`, …) are still skipped, exactly as before.

Review that plan before applying it, as always. After it converges, `makemigrations` on an unchanged
model set proposes **nothing** — which is the point: a clean baseline is what makes real drift
visible.
