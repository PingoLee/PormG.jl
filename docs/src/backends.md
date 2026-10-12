# Backend Capabilities

PormG runs on PostgreSQL and SQLite; MySQL is planned for the first registered release ([#1130](https://github.com/PingoLee/PormG.jl/issues/1130)). Most of what it does means the same on both. Some features exist on one backend only, and PormG does not emulate a feature a backend lacks. It raises `BackendCapabilityError` instead, and the message names the feature, the backend you are on, and the backends that support it:

```text
The @jcontains lookup (JSONB @>) needs JSONB containment and key operators (`@>`, `?`, `?|`, `?&`),
which SQLite does not support (supported on PostgreSQL).
```

The table below is the list PormG checks. A unit test fails when this page and the code disagree.

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
| Row locks: `select_for_update()` locks the rows it reads until the transaction ends ([Transactions](write/transaction.md)) | `FOR UPDATE` (and `of`, `nowait`, `skip_locked`, `no_key`); refused outside a transaction | no lock clause: inside `run_in_transaction` / `atomic` the transaction's `BEGIN IMMEDIATE` holds the database write lock until it ends; outside one, nothing is locked |
| A transaction may write a child before its parent; foreign keys are checked at `COMMIT` ([Transactions](write/transaction.md)) | the foreign keys PormG's migrations create are `DEFERRABLE INITIALLY DEFERRED` | `PRAGMA defer_foreign_keys` in the transactions PormG opens (`run_in_transaction`, `atomic`, `delete`) |
| Case-sensitive text: `@contains`, `@startswith`, `@endswith` and a plain equality respect case ([Filters](read/filters_and_aggregates.md)) | a deterministic collation (the default) | `BINARY` comparison, and `PRAGMA case_sensitive_like = ON`, which PormG sets |
| A query waits without blocking other tasks ([Async](async.md)) | non-blocking driver I/O, in parallel across connections | one worker task, shared by every SQLite database in the process, runs statements one at a time; the calling task yields while it waits |

Two promises are PormG's own meaning rather than an engine's, and hold on every backend by
construction: `F("grid") / 2` divides integers as integers, and a NULL `Concat` operand is skipped.
A backend whose operator computes something else gets a different rendering, not a different answer
([Functions and Dates](read/functions_and_dates.md)).

## What the capability table leaves out

- **A version.** Window functions need an SQLite library of 3.25 or later, checked against the one PormG loads ([Window Functions](read/window_functions.md)). `ON CONFLICT` (`bulk_insert(on_conflict = …)`, `update_or_create`, `get_or_create`) needs SQLite 3.24, which is not checked: an older library raises SQLite's own error. PormG's schema introspection (`inspectdb`, `import_models_from_postgres`, `check`, `status`) needs a PostgreSQL server of 9.6 or later, a migration plan (`makemigrations`, `migrate`) 11, and a plan statement may need more: a generated column needs 12, removing a column's generation expression 13. Each is checked against the server you connect to ([PostgreSQL Guide](postgres.md)).
- **A feature one backend supports only in part.** For example, `ToChar` formats or `Extract` parts that SQLite cannot spell, or a cast to a time type. Each raises `BackendCapabilityError` where it is used, and its page says which forms work.
- **A gap in PormG, not in an engine.** SQLite has explicit window frames, but PormG does not render `WindowOver(frame = …)` there yet, and raises `BackendCapabilityError` saying so ([Window Functions](read/window_functions.md)).
- **A difference in what a query returns.** When two backends would compute different values or rows for the same query, PormG refuses it on the backend that departs, or documents the difference. That is not a missing feature ([Functions and Dates](read/functions_and_dates.md)).
