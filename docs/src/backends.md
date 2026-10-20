# Backend Capabilities

PormG runs on PostgreSQL and SQLite. MySQL is in progress for the first registered release ([#1130](https://github.com/PingoLee/PormG.jl/issues/1130)); see [MySQL (in progress)](@ref) for what works today. Most of what PormG does means the same on every backend. Some features exist on one backend only, and PormG does not emulate a feature a backend lacks. It raises `BackendCapabilityError` instead, and the message names the feature, the backend you are on, and the backends that support it:

```text
The @jcontains lookup (JSONB @>) needs JSONB containment and key operators (`@>`, `?`, `?|`, `?&`),
which SQLite does not support (supported on PostgreSQL).
```

The table below is the list PormG checks. A unit test fails when this page and the code disagree. MySQL's column says what it has today: a row it gains in a later phase of #1130 reads `no` until then, and is refused with `BackendCapabilityError` like any feature a backend lacks.

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
| `network_types` | `GenericIPAddressField`, `CIDRField`, the `@net_*`, `@family` and `@prefixlen` lookups | yes | no | no |
| `full_text_search` | `SearchVectorField`, the `@search` lookup, `SearchVector`, `SearchQuery`, `SearchRank`, `SearchHeadline` | yes | no | no |
| `regex` | `@regex`, `@iregex` and their negations | yes | no | no |
| `unaccent` | `@iunaccent_contains`, `@iunaccent_exact` and their negations | yes | no | no |
| `index_methods` | an `Index` with `method` other than `"btree"`, `opclasses`, or `include` | yes | no | no |
| `explain_options` | `explain(analyze = true)`, `buffers`, `verbose` | yes | no | no |
| `copy` | `bulk_copy` | yes | no | no |
| `advisory_locks` | `with_advisory_lock(…; on_missing_lock = :error)` | yes | no | yes |
| `no_key_locks` | `select_for_update(no_key = true)` (SQLite takes no row lock at all, so it renders no clause, as for every `select_for_update`) | yes | no | no |
| `negative_round_precision` | `Round(x, d)` with a negative `d` (SQLite's `ROUND` reads it as 0) | yes | no | no |
| `window_functions` | `RowNumber`, `Rank`, `DenseRank`, `Lag`, `Lead`, `FirstValue`, `LastValue`, `NthValue` (refused below the version) | yes | from 3.25.0 | no |
| `nulls_order` | `order_by` NULL placement; below the version SQLite sorts on an `(expr IS NULL)` key instead | yes | from 3.30.0 | no |
| `table_list` | reading the schema leaves out virtual and shadow tables; below the version SQLite recognizes them from their DDL and names | no | from 3.37.0 | no |
| `schema_introspection` | `inspectdb`, `import_models_from_postgres`, `check` (refused below the version); `status` skips its drift check below it | from 9.6 | yes | no |
| `migration_plans` | `makemigrations`, `migrate`, `check(kinds = [:schema_drift])` (refused below the version) | from 11 | yes | no |
| `identity_columns` | reading the schema: an identity key; below the version, no column is one | from 10 | no | no |
| `declarative_partitions` | reading the schema leaves partitions out; below the version there are none | from 10 | no | no |
| `include_columns` | reading the schema: an index's `INCLUDE` columns; below the version every index column is a key column | from 11 | no | no |
| `generated_columns` | a plan adding `SearchVectorField(generated_from = …)` (refused below the version); reading the schema: below the version, no column is generated | from 12 | no | no |
| `drop_expression` | a plan removing `generated_from` (refused below the version) | from 13 | no | no |
| `input_validity` | `migrate`'s count of the rows a column retype would reject; below the version it matches the new type's input grammar instead | from 16 | no | no |
| `supported_server` | opening a connection: a backend with a version here refuses an older server when a connection opens | yes | yes | from 8.4 |

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

MySQL support is being built in phases ([#1130](https://github.com/PingoLee/PormG.jl/issues/1130)). The capability table above has its column; the guarantees table gains one when the writes and migrations phases decide its promises. What works today:

- `adapter: MySQL` in `connection.yml` ([connection.yml](configuration/connection_yml.md)), with `using MySQL` (MySQL.jl 2.0) loading the extension.
- **MySQL 8.4 or newer.** A connection to an older server is refused when it opens, with a `BackendCapabilityError` naming both versions. A MariaDB server is refused with an `InvalidConfigurationError`: it is planned as a separate backend.
- The connection pool, raw `fetch` with `?` placeholders, `run_in_transaction` / `atomic`, and `with_advisory_lock` (`GET_LOCK`).
- Server errors arrive as `IntegrityError`, `OperationalError` or `StatementError`, classified by MySQL's error number.
- **Plain-column reads** through `M.Model.objects`: `filter` (comparisons, `__@in` lists and subqueries, `Q`/`Qor`, the pattern lookups), joins along relation paths, `on()` and `cjoin_on`, `values`, `order_by`, `limit`/`offset`, `distinct`, `count` (plain, distinct, sliced), `exists`, `first`, `list`, `Exists`/`Subquery`/CTEs over the same, `Sum`/`Avg`/`Count`/`Max`/`Min` with `HAVING`, and `select_for_update` inside a transaction.

What a read means on MySQL:

- **Text compares code points.** A table PormG creates declares its text columns `utf8mb4_0900_bin`, and each connection's collation is the same, so `filter("surname" => "senna")` does not match `Senna`, `"Senna "` (a trailing space) is not `"Senna"`, and `@contains`, `@startswith` and `@endswith` respect case and accents, as on PostgreSQL ([#1265](https://github.com/PingoLee/PormG.jl/issues/1265)). The case-insensitive lookups (`@icontains`, `@iexact`, …) fold case with `LOWER` and stay accent-sensitive. A table PormG did not create keeps its own collation, and MySQL compares by it: under the server default `utf8mb4_0900_ai_ci`, `=` ignores case and accents there.
- **`order_by` on text sorts by code point**, not by a locale (a representation difference: PostgreSQL sorts by its collation's locale).
- **NULL placement** is PormG's default on every engine (last ascending, first descending). MySQL has no `NULLS FIRST`/`NULLS LAST`, so PormG sorts on an `(expr IS NULL)` key first. Two orderings it cannot place are refused with an error naming the fix: an ordering expression that binds a value (`BackendCapabilityError`; project it and order by the name), and an ordering on a projection named after a column of a table the query reads, such as `values("laps" => "position").order_by("laps")` (`QueryBuildError`; MySQL would read `laps` in the key as the column).
- **A boolean** is a `TINYINT(1)` and reads as a `Bool`, from its declared field type, since MySQL has none on the wire.
- **A `DateTimeField`** is a `DATETIME(3)` ([#1270](https://github.com/PingoLee/PormG.jl/issues/1270)), the precision a Julia `DateTime` holds, read in the connection's UTC as a `ZonedDateTime`. A value with digits below the millisecond (a `DATETIME(6)` column PormG did not create, `NOW(6)`) raises `InvalidValueError` instead of losing them.
- **`Sum` over integers** reads as an integer, and a sum past the 64-bit range raises, as on PostgreSQL; MySQL itself computes a `DECIMAL`, which PormG turns back with `DIV 1`. `Avg` over integers reads as a `Float64` (each connection sets `div_precision_increment = 30`, so the mean is not cut to 4 decimals).
- **`select_for_update(no_key = true)`** is refused with `BackendCapabilityError`: MySQL has no lock weaker than `FOR UPDATE` that leaves foreign-key checks free.
- **Division** means what it means on every engine: `F("grid") / 2` divides integers as integers (truncating toward zero, `-9 / 4` is `-2`). MySQL's own `/` keeps the fraction (`7 / 2` is `3.5`), so PormG writes `DIV` between two sides it types as integers and `/` beside a float or a decimal side. A side whose type PormG cannot name (a text column) is refused with `QueryBuildError`, naming the casts that say which division you mean. A quotient over a `Sum` PormG cannot type is refused too, since MySQL's `SUM` of integers is a `DECIMAL`. Division by zero reads `NULL` (the server records a warning), as on SQLite; PostgreSQL raises.
- **`Cast`** maps each type name to the MySQL `CAST` target that holds its meaning: text and the character types to `CHAR` (a size kept), every integer to `SIGNED`, a sized `numeric` to `DECIMAL(p, s)`, a bare `numeric` to `DECIMAL(65, 30)` (MySQL's own bare `DECIMAL` has no fraction), `real` to `FLOAT` (a `Float32`), the doubles to `DOUBLE`, `date` to `DATE`, a timestamp to `DATETIME(3)`, `time` to `TIME(6)`, `json` to `JSON` and `uuid` to `CHAR(36)`. A type with no such target (`boolean`, `interval`, `bytea`, a type of your own) raises `UnsupportedConnectionError` before any SQL; an array or a network type raises `BackendCapabilityError`. Where MySQL computes another value than the cast means, the cast is refused with `QueryBuildError`: a boolean's text (`'1'`, not `'true'`), a date, a timestamp, a time or an interval cast to a number (MySQL reads the digits, `2009-03-29` → `20090329`), and a literal a `numeric(p, s)` cannot hold (MySQL clamps it to the largest value the type holds). A column value too large for its cast is clamped the same way, with only a server warning, where PostgreSQL raises "numeric field overflow": that depends on the row, so PormG cannot refuse it before the query runs. A bare `numeric` (`DECIMAL(65, 30)`) holds 35 digits before the point. An unsized `char` keeps one character, as on PostgreSQL (`CHAR(1)`).
- **`Concat`** skips a NULL operand, as on every engine, and renders `CONCAT_WS('', …)`. PormG never writes `||` for MySQL, where it is a logical OR (`'a' || 'b'` is `0`).
- **Date arithmetic** renders MySQL's date functions, since MySQL's own `+` reads a date as the number its digits spell (`DATE '2009-03-29' + 1` is `20090330`). `F("date") + Day(3)` and every other duration is `± INTERVAL ? <unit>` per component, with years and months as one month count, as PostgreSQL adds them (`2008-02-29` plus one year and one month is `2009-03-29`); a whole number of days, a literal or an integer column, is `± INTERVAL (n) DAY`; `F("date") - F("date")` is the whole days between them (`DATEDIFF`). A DATE shifted by whole days stays a `Date`, and by hours becomes a timestamp. A value PormG cannot type beside a date (`F("date") + Sum("year")`) is refused with `QueryBuildError`. A shift past MySQL's last date, 9999-12-31, reads `NULL` (MySQL records a warning).
- **Intervals** are not rendered yet: a timestamp difference, and a `DurationField` in arithmetic, an ordering, an aggregate or a filter (other than `__@isnull`), raise `UnsupportedConnectionError` before any SQL. What a `DurationField` stores on MySQL is the migrations phase's decision, and the millisecond form MySQL computes an interval in follows phase 2b. A projected `DurationField` reads as whatever the column's own type gives.

Not yet: writes (`create`, `update`, `delete`, bulk), migrations and `inspectdb`, and in reads, intervals (above), and most functions and transforms (`Coalesce`, `Case`, `Greatest`/`Least`, the math functions, `Extract` and the date parts, the text functions, window functions). Each fails before any SQL is sent, with a `MethodError` at the first part of the query builder that MySQL does not have yet, or an `UnsupportedConnectionError` that says so.

Each connection runs in UTC (`time_zone = '+00:00'`), with `utf8mb4`, the `utf8mb4_0900_bin` connection collation, and MySQL 8.4's default `sql_mode`, so neither the server's global settings nor a DBA's change to them alters what a statement means. A statement whose connection is lost is never retried: MySQL reports the same error whether or not the statement ran ([MySQL.jl#248](https://github.com/JuliaDatabases/MySQL.jl/issues/248)). That includes a connection the server closed while it sat idle in the pool past the server's `wait_timeout` (8 hours by default, often less on a hosted server): its next statement raises `OperationalError`, and the pool renews the connection after it. `idle_timeout:` does not prevent this: it closes only the overflow connections above `pool_size` ([Advanced Configuration](configuration/advanced.md)), and the base connections stay open however long they sit idle. Keep the server's `wait_timeout` above the application's longest idle period, or expect the first statement after such a gap to fail once with `OperationalError` while the pool renews the connection.

## What the capability table leaves out

- **A version PormG does not check.** `ON CONFLICT` (`bulk_insert(on_conflict = …)`, `update_or_create`, `get_or_create`) needs SQLite 3.24, and an older library raises SQLite's own error. A query feature newer than your PostgreSQL server fails with PostgreSQL's own error ([PostgreSQL Guide](postgres.md#Server-versions)).
- **A number that depends on a version.** SQLite accepts 999 bind parameters per statement before 3.32 and 32766 from it. PormG sizes `bulk_insert` and `bulk_update` batches to the library it loads, so this is a limit, not a feature.
- **A feature one backend supports only in part.** For example, `ToChar` formats or `Extract` parts that SQLite cannot spell, or a cast to a time type. Each raises `BackendCapabilityError` where it is used, and its page says which forms work.
- **A gap in PormG, not in an engine.** SQLite has explicit window frames, but PormG does not render `WindowOver(frame = …)` there yet, and raises `BackendCapabilityError` saying so ([Window Functions](read/window_functions.md)).
- **A difference in what a query returns.** When two backends would compute different values or rows for the same query, PormG refuses it on the backend that departs, or documents the difference. That is not a missing feature ([Functions and Dates](read/functions_and_dates.md); for a declared scale or a cast to an integer, [Rounding](read/rounding.md)).
