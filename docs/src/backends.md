# Backend Capabilities

PormG runs on PostgreSQL and SQLite. MySQL is in progress for the first registered release ([#1130](https://github.com/PingoLee/PormG.jl/issues/1130)); see [MySQL (in progress)](@ref) for what works today. Most of what it does means the same on both. Some features exist on one backend only, and PormG does not emulate a feature a backend lacks. It raises `BackendCapabilityError` instead, and the message names the feature, the backend you are on, and the backends that support it:

```text
The @jcontains lookup (JSONB @>) needs JSONB containment and key operators (`@>`, `?`, `?|`, `?&`),
which SQLite does not support (supported on PostgreSQL).
```

The table below is the list PormG checks. A unit test fails when this page and the code disagree.

Some features exist from a server version on. Their cell says which, as `from 13` (PostgreSQL's `server_version_num` major version) or `from 3.25.0` (the SQLite library PormG loads). PormG asks the server its version where it needs the answer. Where a feature is refused, an older server gets `BackendCapabilityError` naming both versions:

```text
A window function needs SQLite 3.25.0 or newer, for window functions (`OVER (…)`); the SQLite
library PormG loads is 3.24.0.
```

Where PormG reads the schema, an older server is not refused: the feature reads as absent, which is exact there, because a server without the feature has none of it.

| Feature | Used by | PostgreSQL | SQLite |
|---|---|---|---|
| `jsonb_operators` | `@jcontains`, `@has_key`, `@has_any_keys`, `@has_keys` | yes | no |
| `arrays` | `ArrayField`, its lookups (`@acontains`, `@contained_by`, `@overlap`), `@len`, an index or slice, a cast to an array type | yes | no |
| `network_types` | `GenericIPAddressField`, `CIDRField`, the `@net_*`, `@family` and `@prefixlen` lookups | yes | no |
| `full_text_search` | `SearchVectorField`, the `@search` lookup, `SearchVector`, `SearchQuery`, `SearchRank`, `SearchHeadline` | yes | no |
| `regex` | `@regex`, `@iregex` and their negations | yes | no |
| `unaccent` | `@iunaccent_contains`, `@iunaccent_exact` and their negations | yes | no |
| `index_methods` | an `Index` with `method` other than `"btree"`, `opclasses`, or `include` | yes | no |
| `explain_options` | `explain(analyze = true)`, `buffers`, `verbose` | yes | no |
| `copy` | `bulk_copy` | yes | no |
| `advisory_locks` | `with_advisory_lock(…; on_missing_lock = :error)` | yes | no |
| `window_functions` | `RowNumber`, `Rank`, `DenseRank`, `Lag`, `Lead`, `FirstValue`, `LastValue`, `NthValue` (refused below the version) | yes | from 3.25.0 |
| `nulls_order` | `order_by` NULL placement; below the version SQLite sorts on an `(expr IS NULL)` key instead | yes | from 3.30.0 |
| `table_list` | reading the schema leaves out virtual and shadow tables; below the version SQLite recognizes them from their DDL and names | no | from 3.37.0 |
| `schema_introspection` | `inspectdb`, `import_models_from_postgres`, `check` (refused below the version); `status` skips its drift check below it | from 9.6 | yes |
| `migration_plans` | `makemigrations`, `migrate`, `check(kinds = [:schema_drift])` (refused below the version) | from 11 | yes |
| `identity_columns` | reading the schema: an identity key; below the version, no column is one | from 10 | no |
| `declarative_partitions` | reading the schema leaves partitions out; below the version there are none | from 10 | no |
| `include_columns` | reading the schema: an index's `INCLUDE` columns; below the version every index column is a key column | from 11 | no |
| `generated_columns` | a plan adding `SearchVectorField(generated_from = …)` (refused below the version); reading the schema: below the version, no column is generated | from 12 | no |
| `drop_expression` | a plan removing `generated_from` (refused below the version) | from 13 | no |
| `input_validity` | `migrate`'s count of the rows a column retype would reject; below the version it matches the new type's input grammar instead | from 16 | no |
| `supported_server` | opening a connection: a backend with a version here refuses an older server when a connection opens | yes | yes |

`with_advisory_lock` on SQLite without `on_missing_lock = :error` runs the body with no lock, and warns unless you pass `on_missing_lock = :ignore` ([Advisory Locks](advisory_lock.md)).

## Guarantees that rest on an engine feature

Some promises PormG makes hold because the engine underneath provides something, not because PormG
computes them. They hold on PostgreSQL and SQLite, each in its own way. A backend added later states
its own column here: where it cannot keep a promise, PormG refuses or documents the difference rather
than emulating it.

| Promise | PostgreSQL | SQLite |
|---|---|---|
| Atomic migrations: `migrate` applies a plan whole, and a failed statement leaves nothing applied ([Migrations](migrations/workflow.md)) | transactional DDL | transactional DDL, inside `BEGIN IMMEDIATE` |
| Two instances running `migrate` at once apply a plan once ([Deploying](migrations/deploying.md)) | an advisory lock | the database write lock (`BEGIN IMMEDIATE`) |
| Writes return their row: `create`, `get_or_create` and `update_or_create` return what they wrote, generated columns included ([Creating rows](write/create.md)) | `INSERT … RETURNING *` | no `RETURNING`: the `INSERT`, then a `SELECT` of the row on the same connection, in one transaction |
| Upserts: `bulk_insert(on_conflict = …)`, `update_or_create`, and a race-safe `get_or_create` ([Bulk operations](write/bulk.md)) | `INSERT … ON CONFLICT` | `INSERT … ON CONFLICT` (SQLite 3.24 or later); `get_or_create` also runs under the write lock |
| Row locks: `select_for_update()` locks the rows it reads until the transaction ends ([Transactions](write/transaction.md)) | `FOR UPDATE` (and `of`, `nowait`, `skip_locked`, `no_key`); refused outside a transaction | no lock clause: inside `run_in_transaction` / `atomic` the transaction's `BEGIN IMMEDIATE` holds the database write lock until it ends; refused outside a transaction, as on PostgreSQL |
| A transaction may write a child before its parent; foreign keys are checked at `COMMIT` ([Transactions](write/transaction.md)) | the foreign keys PormG's migrations create are `DEFERRABLE INITIALLY DEFERRED` | `PRAGMA defer_foreign_keys` in the transactions PormG opens (`run_in_transaction`, `atomic`, `delete`) |
| Case-sensitive text: `@contains`, `@startswith`, `@endswith` and a plain equality respect case ([Filters](read/filters_and_aggregates.md)) | a deterministic collation (the default) | `BINARY` comparison, and `PRAGMA case_sensitive_like = ON`, which PormG sets |
| A query waits without blocking other tasks ([Async](async.md)) | non-blocking driver I/O, in parallel across connections | one worker task, shared by every SQLite database in the process, runs statements one at a time; the calling task yields while it waits |

Two promises are PormG's own meaning rather than an engine's, and hold on every backend by
construction: `F("grid") / 2` divides integers as integers, and a NULL `Concat` operand is skipped.
A backend whose operator computes something else gets a different rendering, not a different answer
([Functions and Dates](read/functions_and_dates.md)).

## MySQL (in progress)

MySQL support is being built in phases ([#1130](https://github.com/PingoLee/PormG.jl/issues/1130)), and it is not in the tables above until each phase decides its rows. What works today:

- `adapter: MySQL` in `connection.yml` ([connection.yml](configuration/connection_yml.md)), with `using MySQL` (MySQL.jl 2.0) loading the extension.
- **MySQL 8.4 or newer.** A connection to an older server is refused when it opens, with a `BackendCapabilityError` naming both versions. A MariaDB server is refused with an `InvalidConfigurationError`: it is planned as a separate backend.
- The connection pool, raw `fetch` with `?` placeholders, `run_in_transaction` / `atomic`, and `with_advisory_lock` (`GET_LOCK`).
- Server errors arrive as `IntegrityError`, `OperationalError` or `StatementError`, classified by MySQL's error number.

Not yet: model queries and writes (`M.Driver.objects…`), migrations and `inspectdb`. A query built on a MySQL pool raises a `MethodError` naming the first engine decision MySQL has not made yet.

Each connection runs in UTC (`time_zone = '+00:00'`), with `utf8mb4` and MySQL 8.4's default `sql_mode`, so neither the server's global settings nor a DBA's change to them alters what a statement means. A statement whose connection is lost is never retried: MySQL reports the same error whether or not the statement ran ([MySQL.jl#248](https://github.com/JuliaDatabases/MySQL.jl/issues/248)).

## What the capability table leaves out

- **A version PormG does not check.** `ON CONFLICT` (`bulk_insert(on_conflict = …)`, `update_or_create`, `get_or_create`) needs SQLite 3.24, and an older library raises SQLite's own error. A query feature newer than your PostgreSQL server fails with PostgreSQL's own error ([PostgreSQL Guide](postgres.md#Server-versions)).
- **A number that depends on a version.** SQLite accepts 999 bind parameters per statement before 3.32 and 32766 from it. PormG sizes `bulk_insert` and `bulk_update` batches to the library it loads, so this is a limit, not a feature.
- **A feature one backend supports only in part.** For example, `ToChar` formats or `Extract` parts that SQLite cannot spell, or a cast to a time type. Each raises `BackendCapabilityError` where it is used, and its page says which forms work.
- **A gap in PormG, not in an engine.** SQLite has explicit window frames, but PormG does not render `WindowOver(frame = …)` there yet, and raises `BackendCapabilityError` saying so ([Window Functions](read/window_functions.md)).
- **A difference in what a query returns.** When two backends would compute different values or rows for the same query, PormG refuses it on the backend that departs, or documents the difference. That is not a missing feature ([Functions and Dates](read/functions_and_dates.md)).
