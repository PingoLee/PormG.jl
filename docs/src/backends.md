# Backend Capabilities

PormG runs on PostgreSQL, SQLite and MySQL (see the [MySQL Guide](mysql.md)). Most of what PormG does means the same on every backend. Some features exist on one backend only, and PormG does not emulate a feature a backend lacks. It raises `BackendCapabilityError` instead, and the message names the feature, the backend you are on, and the backends that support it:

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

| Feature | Used by | PostgreSQL | SQLite | MySQL |
|---|---|---|---|---|
| `jsonb_operators` | `@jcontains`, `@has_key`, `@has_any_keys`, `@has_keys` | yes | no | no |
| `arrays` | `ArrayField`, its lookups (`@acontains`, `@contained_by`, `@overlap`), `@len`, an index or slice, a cast to an array type | yes | no | no |
| `network_types` | `GenericIPAddressField`, `CIDRField`, the `@net_*`, `@family` and `@prefixlen` lookups, a `Sockets.IPv4`/`IPv6` literal (`Value(ip"…")`) | yes | no | no |
| `full_text_search` | `SearchVectorField`, the `@search` lookup, `SearchVector`, `SearchQuery`, `SearchRank`, `SearchHeadline` | yes | no | no |
| `regex` | `@regex`, `@iregex` and their negations | yes | no | no |
| `unaccent` | `@iunaccent_contains`, `@iunaccent_exact` and their negations | yes | no | no |
| `index_methods` | an `Index` with `method` other than `"btree"`, `opclasses`, or `include` | yes | no | no |
| `explain_options` | `explain(analyze = true)`, `buffers`, `verbose` | yes | no | no |
| `copy` | `bulk_copy` | yes | no | no |
| `advisory_locks` | `with_advisory_lock(…; on_missing_lock = :error)` | yes | no | yes |
| `no_key_locks` | `select_for_update(no_key = true)` (SQLite takes no row lock at all, so it renders no clause, as for every `select_for_update`) | yes | no | no |
| `negative_round_precision` | `Round(x, d)` with a negative `d` (SQLite's `ROUND` reads it as 0) | yes | no | yes |
| `window_functions` | `RowNumber`, `Rank`, `DenseRank`, `Lag`, `Lead`, `FirstValue`, `LastValue`, `NthValue` (refused below the version) | yes | from 3.25.0 | yes |
| `window_groups_frame` | a window `frame` that starts with `GROUPS` | yes | no | no |
| `window_frame_exclusion` | a window `frame` with an `EXCLUDE` clause | yes | no | no |
| `deferred_foreign_keys` | foreign keys checked at `COMMIT`, so a transaction may write a child before its parent; `without_foreign_keys` | yes | yes | no |
| `upsert_conflict_target` | `update_or_create` on a row that could also conflict on a unique key other than its lookup (MySQL's `ON DUPLICATE KEY UPDATE` fires on any unique key, so there it is refused unless the lookup is the only key the row can conflict on) | yes | yes | no |
| `preallocated_keys` | `allocate_primary_keys`, and `bulk_insert(returning = …)` for an auto-increment pk the DataFrame does not carry, with no `on_conflict` target (MySQL cannot draw `AUTO_INCREMENT` values ahead of the INSERT; supply the pk, or give a target) | yes | yes | no |
| `transactional_ddl` | `migrate` of a plan with more than one statement: each MySQL DDL statement commits on its own, so there `migrate` raises unless it is called with `atomic = false`; a failed run leaves the plan part-applied, and the next `makemigrations` plans what is missing | yes | yes | no |
| `partial_indexes` | an `Index` or `UniqueConstraint` with a `condition` | yes | yes | no |
| `unbounded_text_indexes` | a primary key, `unique`, `db_index`, `Index` or `UniqueConstraint` over a field MySQL writes as `LONGTEXT`, `LONGBLOB` or `JSON` (such as a `TextField`, `EmailField`, `ImageField`, `FileField`, `PasswordField`, `BinaryField` or `JSONField`), which MySQL indexes only by a prefix: refused by `makemigrations`; declare a `CharField` with a `max_length` | yes | yes | no |
| `statement_timeouts` | `migrate(…; statement_timeout)`: a bound on how long one plan statement may run. SQLite accepts it and ignores it; MySQL bounds no DDL statement's run time, so there it is refused (use `lock_timeout`, which becomes `lock_wait_timeout`) | yes | yes | no |
| `nulls_order` | `order_by` NULL placement; below the version SQLite sorts on an `(expr IS NULL)` key instead | yes | from 3.30.0 | no |
| `right_joins` | a `"RIGHT"` join type — `on()`, `cjoin`, `cjoin_on`, a CTE (`with(…; join_type)`) or a `ForeignKey(how = …)` — refused below the version, writes included | yes | from 3.39.0 | yes |
| `full_joins` | a `"FULL"` join type — `on()`, `cjoin`, `cjoin_on`, a CTE (`with(…; join_type)`) or a `ForeignKey(how = …)` — refused below the version, writes included | yes | from 3.39.0 | no |
| `table_list` | reading the schema leaves out virtual and shadow tables; below the version SQLite recognizes them from their DDL and names | no | from 3.37.0 | no |
| `schema_introspection` | `inspectdb`, `import_models_from_postgres`, `check` (refused below the version); `status` skips its drift check below it. On MySQL, `inspectdb` is `import_models_from_mysql` | from 9.6 | yes | yes |
| `migration_plans` | `makemigrations`, `migrate`, `check(kinds = [:schema_drift])` (refused below the version) | from 11 | yes | yes |
| `identity_columns` | reading the schema: an identity key; below the version, no column is one | from 10 | no | no |
| `declarative_partitions` | reading the schema leaves partitions out; below the version there are none | from 10 | no | no |
| `include_columns` | reading the schema: an index's `INCLUDE` columns; below the version every index column is a key column | from 11 | no | no |
| `generated_columns` | a plan adding `SearchVectorField(generated_from = …)`, a `tsvector` column `GENERATED ALWAYS AS (…) STORED` (refused below the version); reading the schema: below the version, no column is generated. SQLite and MySQL have generated columns, but not the `tsvector` this one computes | from 12 | no | no |
| `drop_expression` | a plan removing `generated_from` (refused below the version) | from 13 | no | no |
| `input_validity` | `migrate`'s count of the rows a column retype would reject; below the version it matches the new type's input grammar instead | from 16 | no | no |
| `supported_server` | opening a connection: a backend with a version here refuses an older server when a connection opens | yes | yes | from 8.4 |

`with_advisory_lock` on SQLite without `on_missing_lock = :error` runs the body with no lock, and warns unless you pass `on_missing_lock = :ignore` ([Advisory Locks](advisory_lock.md)).

## Guarantees that rest on an engine feature

Some promises PormG makes hold because the engine underneath provides something, not because PormG
computes them. Each backend keeps them in its own way, and its column says how. Where a backend
cannot keep a promise, PormG refuses or documents the difference rather than emulating it.

| Promise | PostgreSQL | SQLite | MySQL |
|---|---|---|---|
| Atomic migrations: `migrate` applies a plan whole, and a failed statement leaves nothing applied ([Migrations](migrations/workflow.md)) | transactional DDL | transactional DDL, inside `BEGIN IMMEDIATE` | **no**: each DDL statement commits on its own (`transactional_ddl`, [#1268](https://github.com/PingoLee/PormG.jl/issues/1268)). A plan of more than one statement runs only with `migrate(…; atomic = false)`; a failed statement leaves the ones before it applied and records the plan as `failed`, and `makemigrations` then plans what is missing |
| Two instances running `migrate` at once apply a plan once ([Deploying](migrations/deploying.md)) | an advisory lock | the database write lock (`BEGIN IMMEDIATE`) | a named lock (`GET_LOCK`); MySQL's lock names are server-wide, so PormG hashes the database name into it, and two databases on one server migrate independently |
| Writes return their row: `create`, `get_or_create` and `update_or_create` return what they wrote, generated columns included ([Creating rows](write/create.md)) | `INSERT … RETURNING *` | no `RETURNING`: the `INSERT`, then a `SELECT` of the row on the same connection, in one transaction | no `RETURNING`: the `INSERT`, then a `SELECT` of the row on the same connection: `create` by its primary key (the `AUTO_INCREMENT` id the `INSERT` reports, or the key it supplied), `get_or_create` and `update_or_create` by their lookup |
| Upserts: `bulk_insert(on_conflict = …)`, `update_or_create`, and a race-safe `get_or_create` ([Bulk operations](write/bulk.md)) | `INSERT … ON CONFLICT` | `INSERT … ON CONFLICT` (SQLite 3.24 or later); `get_or_create` also runs under the write lock | `ON DUPLICATE KEY UPDATE`, which names no target ([#1267](https://github.com/PingoLee/PormG.jl/issues/1267)): `update_or_create` runs only when its lookup is the one unique key the row can conflict on (`upsert_conflict_target`), and reads `created` from the statement's report, or from a pre-check when the primary key is not `AUTO_INCREMENT`. `get_or_create` is a plain `INSERT` whose duplicate-key error re-reads the winner. Either lookup must be a unique key declared on the model. `bulk_insert(on_conflict = …)`: a targeted `DO NOTHING` or a `DO UPDATE` runs only when the target is the one unique key the rows can conflict on; an untargeted `:nothing` skips a conflict on any key, as everywhere. The `DO NOTHING` count comes from MySQL's report of each multi-row `INSERT` |
| Row locks: `select_for_update()` locks the rows it reads until the transaction ends ([Transactions](write/transaction.md)) | `FOR UPDATE` (and `of`, `nowait`, `skip_locked`, `no_key`); refused outside a transaction | no lock clause: inside `run_in_transaction` / `atomic` the transaction's `BEGIN IMMEDIATE` holds the database write lock until it ends; refused outside a transaction, as on PostgreSQL | `FOR UPDATE` (and `of`, `nowait`, `skip_locked`; `no_key` is refused); refused outside a transaction |
| A transaction may write a child before its parent; foreign keys are checked at `COMMIT` ([Transactions](write/transaction.md)) | the foreign keys PormG's migrations create are `DEFERRABLE INITIALLY DEFERRED` | `PRAGMA defer_foreign_keys` in the transactions PormG opens (`run_in_transaction`, `atomic`, `delete`) | **no**: InnoDB checks a foreign key at each statement ([#1272](https://github.com/PingoLee/PormG.jl/issues/1272)), so a child written before its parent raises `IntegrityError` at once. `delete()` runs children first, as on every engine, and refuses a delete whose rows' foreign keys form a cycle with `QueryBuildError`, as on every engine; `without_foreign_keys` raises `BackendCapabilityError` (`deferred_foreign_keys`) |
| Case-sensitive text: `@contains`, `@startswith`, `@endswith` and a plain equality respect case ([Filters](read/filters_and_aggregates.md)) | a deterministic collation (the default) | `BINARY` comparison, and `PRAGMA case_sensitive_like = ON`, which PormG sets | the `utf8mb4_0900_bin` collation of the columns PormG creates and of each connection ([#1265](https://github.com/PingoLee/PormG.jl/issues/1265)) |
| A query waits without blocking other tasks ([Async](async.md)) | non-blocking driver I/O, in parallel across connections | one worker task, shared by every SQLite database in the process, runs statements one at a time; the calling task yields while it waits | each statement runs on a task of its own, in parallel across connections; the calling task yields while it waits |

Three promises are PormG's own meaning rather than an engine's, and hold on every backend by
construction: `F("grid") / 2` divides integers as integers, a NULL `Concat` operand is skipped, and
`Cast(x, "smallint" | "integer" | "bigint")` raises `StatementError` with `sqlstate == "22003"` on a value
outside the type, on the row, in every clause. PostgreSQL's cast does that itself; MySQL's `SIGNED` is
64-bit and SQLite's `INTEGER` applies no range below 64 bits, so there PormG renders a guard that raises
it ([#1356](https://github.com/PingoLee/PormG.jl/issues/1356)). A declared `output_field` of the same type
on `Coalesce`, `Greatest`, `Least` or `Case` is the same cast over the whole function, and renders the same
guard ([#1405](https://github.com/PingoLee/PormG.jl/issues/1405)). One limit: SQLite saturates a value past
64 bits to the largest integer, which nothing can tell from a real one, so a `bigint` cast there is not
guarded. The guard names its operand three times, so every value it binds is bound three times, and a
`Subquery` operand runs three times per row. The cost compounds when declarations nest: a declared
`Coalesce` over a declared `Case` binds the `Case`'s values nine times.
A backend whose operator computes something else gets a different rendering, not a different answer
([Functions and Dates](read/functions_and_dates.md)).

## MySQL

MySQL 8.4 or newer is supported through MySQL.jl 2.0. The tables above have its column. What it means for a query, a write and a migration, from its collation to its non-transactional DDL, is on the [MySQL Guide](mysql.md).

## What the capability table leaves out

- **A version PormG does not check.** `ON CONFLICT` (`bulk_insert(on_conflict = …)`, `update_or_create`, `get_or_create`) needs SQLite 3.24, and an older library raises SQLite's own error. A query feature newer than your PostgreSQL server fails with PostgreSQL's own error ([PostgreSQL Guide](postgres.md#Server-versions)).
- **A number that depends on a version.** SQLite accepts 999 bind parameters per statement before 3.32 and 32766 from it. PormG sizes `bulk_insert` and `bulk_update` batches to the library it loads, so this is a limit, not a feature. On MySQL the limit is MySQL.jl's, 4096 parameters per statement (the protocol itself allows 65535): the bulk writers split under it, and any other statement past it (a `__@in` list of 5000 values) is refused with `QueryBuildError` before it is sent.
- **A feature one backend supports only in part.** For example, `ToChar` formats or `Extract` parts that SQLite cannot spell, or a cast to a time type. Each raises `BackendCapabilityError` where it is used, and its page says which forms work.
- **A gap in PormG, not in an engine.** SQLite has explicit window frames, but PormG does not render `WindowOver(frame = …)` there yet, and raises `BackendCapabilityError` saying so ([Window Functions](read/window_functions.md)).
- **A difference in what a query returns.** When backends would compute different values or rows for the same query, PormG refuses it on the backend that departs, or documents the difference. That is not a missing feature ([Functions and Dates](read/functions_and_dates.md); for a declared scale or a cast to an integer, [Rounding](read/rounding.md)).
