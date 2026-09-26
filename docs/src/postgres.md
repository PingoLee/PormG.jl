# PostgreSQL Guide

PormG treats PostgreSQL and SQLite as equals: the same models, the same fluent query API, and the same migration engine run on both, so most application code is backend-agnostic. This page is the entry point for the two things that are *not* symmetric:

1. **PostgreSQL-only capabilities** — features that exist only on PostgreSQL (with a documented SQLite fallback or no-op).
2. **PostgreSQL ↔ SQLite divergences** — behaviour a power user must know when the same code runs on both backends.

The deep-dive pages own the full reference and verified examples; this guide points you to them rather than restating them.

!!! tip "Keep code backend-agnostic"
    Where a feature is PostgreSQL-only, PormG provides a SQLite-safe fallback (`with_advisory_lock` becomes a no-op; use `bulk_insert` instead of `bulk_copy`) so the *same* source runs against SQLite in tests and PostgreSQL in production. Prefer that over branching on the backend.

## PostgreSQL-only capabilities

### Ultra-fast bulk loading — `bulk_copy()`

`bulk_copy()` streams a `DataFrame` through PostgreSQL's native `COPY FROM STDIN` protocol — **10–100× faster** than row-by-row inserts, ideal for initial data loads and migrations.

```julia
using PormG, LibPQ, DataFrames   # "db_2" is a PostgreSQL connection

handler = M.Result.objects
bulk_copy(handler, results_df)   # results_df columns match the model fields by exact name
```

- **PostgreSQL only.** On SQLite, `bulk_copy` is not available — use [`bulk_insert()`](write/bulk.md) instead (still chunked and fast, just not COPY-fast).
- The COPY protocol has no `ON CONFLICT` clause; when duplicates are possible use `bulk_insert(...; on_conflict=...)`.

Full reference, column auto-detection rules, and `ON CONFLICT` handling: **[Bulk Insert, Copy, and Update](write/bulk.md)**.

### Application-level locking — `with_advisory_lock()`

Advisory locks let you serialize application-level critical sections that have no single row to lock — generating a report, syncing an external API, or coordinating multi-table logic across async tasks.

```julia
driver_id = 1
PormG.with_advisory_lock("db_2", "driver_update_$(driver_id)"; wait=true, timeout_ms=10000) do
  # Only one process holding this key can be inside this block at a time.
  driver = M.Driver.objects.filter("driverid" => driver_id) |> DataFrame
  @info "Updating stats for $(driver[1, :surname])"
end
```

- **PostgreSQL** uses `pg_advisory_lock` / `pg_try_advisory_lock`.
- **SQLite** does not support advisory locks, so `with_advisory_lock` is a **no-op** — the block still runs, just without cross-process locking. This is deliberate, so the same code is correct in production and in SQLite tests. It warns once per lock key; `on_missing_lock = :ignore` accepts that silently and `on_missing_lock = :error` raises `BackendCapabilityError` rather than running unprotected.

Waiting strategies (`:poll` vs `:block`), timeouts, and async safety: **[Advisory Locks](advisory_lock.md)**.

## PostgreSQL-native storage types

These field types work on both backends, but PostgreSQL gives them a **native, indexable representation** that SQLite (which stores them as text) cannot match — worth choosing PostgreSQL for when the workload leans on them.

### `JSONField` — `JSONB` vs `TEXT`

```julia
Race_config = Models.Model("race_configs",
  id = Models.IDField(),
  settings = Models.JSONField(),
  metadata = Models.JSONField(null=true, blank=true),
)
```

- **PostgreSQL** stores it as `JSONB` — binary, queryable, and **indexable** (GIN indexes, containment operators, key extraction).
- **SQLite** stores it as a `TEXT` JSON string — fine for round-tripping a blob, but without server-side JSON indexing/querying.

### `UUIDField` — native `UUID` vs `TEXT`

```julia
Api_token = Models.Model("api_tokens",
  id = Models.IDField(),
  token = Models.UUIDField(unique=true, auto_add=true),  # auto_add ⇒ uuid4() on create
)
```

- **PostgreSQL** uses the native `UUID` type (compact 16-byte storage, type-checked).
- **SQLite** stores the canonical 8-4-4-4-12 string as `TEXT`.
- `auto_add=true` generates a `uuid4()` application-side on insert, so identity is the same on both backends.

Full parameter reference and validation rules: **[Fields → JSON](fields.md) / [UUID](fields.md#UUID-Fields)**.

## PostgreSQL-only lookups and functions

A few query features compile to PostgreSQL operators or functions that SQLite does not have. On
SQLite each of them raises `BackendCapabilityError` when the query is built. It never quietly
returns a different answer, so a test suite running on SQLite fails where production would diverge.

- **JSONB containment and key existence** — `@jcontains` (`@>`), `@has_key` (`?`),
  `@has_any_keys` (`?|`), `@has_keys` (`?&`) on a `JSONField` column. The `__` key-path extraction
  (`"metadata__wins" => 121`) is **not** in this group: it works on both backends. See
  [Filters and Aggregates → JSON](read/filters_and_aggregates.md#Containment-and-key-existence-operators-(PostgreSQL-only)).
  ```julia
  M.Constructor.objects.filter("metadata__@has_keys" => ["principal", "wins"])
  ```
- **Accent-insensitive matching** — `@iunaccent_contains`, `@iunaccent_exact` and their negated
  twins `@niunaccent_contains`, `@niunaccent_exact`. They need the `unaccent` extension, declared
  in `connection.yml` and installed by `migrate()`. See
  [Accent-Insensitive lookups](read/filters_and_aggregates.md#Accent-Insensitive-(@iunaccent_contains,-@iunaccent_exact)).
  ```julia
  M.Driver.objects.filter("surname__@iunaccent_contains" => "raikkonen")   # finds "Räikkönen"
  ```
- **`ToChar` templates beyond the portable table.** The formats listed in
  [Functions and Dates → ToChar](read/functions_and_dates.md#ToChar-—-Format-as-String) render the
  same text on both engines. Any other template (`"HH12:MI AM"`) goes to PostgreSQL's `to_char`
  as written.
- **`Extract` parts beyond the portable eight.** SQLite supports `YEAR`, `MONTH`, `DAY`, `HOUR`,
  `MINUTE`, `SECOND`, `DOW` and `DOY`, in any case (`"year"` works as well as `"YEAR"`).
  PostgreSQL also accepts the rest of its `EXTRACT` fields (`epoch`, `week`, `isoyear`, `century`,
  …). Code that uses those eight runs on both. A string outside that list — including
  PostgreSQL's synonyms such as `years` or `hr` — raises `InvalidValueError` on both engines; see
  [Functions and Dates → Extract](read/functions_and_dates.md#Extract-—-Extract-Date/Time-Part).
- **Explicit window frames** — `WindowOver(...; frame = "ROWS BETWEEN …")`. See
  [Window Functions](read/window_functions.md).

## Advanced SQL (both backends, PostgreSQL-first)

These run on SQLite too, but they are where PostgreSQL shines for analytical work. Reach for them before dropping to raw SQL:

- **[Window Functions](read/window_functions.md)** — `Rank`, `Lag`, `Lead`, `LastValue`, … over `WindowOver(partition_by=…, order_by=…)`. The default frame works on both backends; **explicit frame clauses** (`frame="ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING"`, which change `LastValue`/`NthValue` semantics) are **PostgreSQL-only** — SQLite supports only the default frame.
- **[Subqueries and CTEs](read/subqueries_and_ctes.md)** — `.with(...)` and its `"<cte>__<column>"` columns, correlated subqueries, `Exists`/`OuterRef`, and CTE joins.
- **[Filters and Aggregates](read/filters_and_aggregates.md)** and **[Functions and Dates](read/functions_and_dates.md)** — the `Sum`/`Count`/`Max`, date-bucket, and SQL-function surface.
- **[Field Expressions](read/field_expressions.md)** — `F("...")` database-side arithmetic and field-to-field comparisons.

## PostgreSQL ↔ SQLite divergences

PormG keeps the two backends aligned wherever it can and documents the differences where it can't. The ones a power user hits:

| Area | PostgreSQL | SQLite |
|------|-----------|--------|
| **Bind placeholders** | `$1`, `$2`, … | `?` |
| **Bulk load** | `bulk_copy()` (COPY) | `bulk_insert()` (no COPY) |
| **`bulk_insert` / `bulk_update` rows** | one array parameter per column, `unnest(...)`; no parameter cap on `chunk_size` | one `?` per cell in `VALUES`; `chunk_size` capped at SQLite's parameter limit — see [How rows reach the database](write/bulk.md#How-rows-reach-the-database) |
| **Advisory locks** | real (`pg_advisory_lock`) | no-op (warns once per key; `on_missing_lock=:error` raises) |
| **PK allocation** | real sequences (`nextval`) | emulated via `sqlite_sequence` high-water mark |
| **Drop a constraint (migrations)** | `ALTER TABLE … DROP CONSTRAINT` | full table rebuild (SQLite has no `DROP CONSTRAINT`) |
| **`ON CONFLICT`** | supported | supported (SQLite ≥ 3.24) — same syntax |
| **`JSONField` storage** | `JSONB` (binary, indexable) | `TEXT` (JSON string) |
| **`UUIDField` storage** | native `UUID` | `TEXT` |
| **`DecimalField` width** | `numeric`, exact at any `max_digits` | `NUMERIC` affinity, exact up to `max_digits = 15`; a wider declaration raises `BackendCapabilityError` at `makemigrations` |
| **Window frames** | explicit `frame=` clauses | default frame only |
| **JSONB lookups** (`@jcontains`, `@has_key`, `@has_any_keys`, `@has_keys`) | JSONB operators | `BackendCapabilityError` — `__` key paths still work |
| **Accent-insensitive lookups** (`@iunaccent_*`, `@niunaccent_*`) | `unaccent` extension | `BackendCapabilityError` |
| **`ToChar` formats** | any `to_char` template | the portable table only; others raise `BackendCapabilityError` |
| **`Extract` parts** | every PostgreSQL `EXTRACT` field, any case; a non-field raises `InvalidValueError` | `YEAR` `MONTH` `DAY` `HOUR` `MINUTE` `SECOND` `DOW` `DOY`, any case; other PostgreSQL fields raise `BackendCapabilityError`, a non-field `InvalidValueError` |
| **Row locks** (`select_for_update()`) | `SELECT … FOR UPDATE` | silent no-op — a SQLite write already locks the whole database |
| **`without_foreign_keys`** | `SET CONSTRAINTS ALL DEFERRED`; may nest inside `atomic`; an orphan fails `COMMIT` with `IntegrityError` | `PRAGMA foreign_keys = OFF` plus a `foreign_key_check` before `COMMIT` (`UnsafeMutationError`); must be the outermost transaction (`TransactionError` otherwise) |
| **Engine-pinned `db_default`** | `db_default = (postgres = "now()",)` renders | rendering it raises `BackendCapabilityError` — add `sqlite = "…"`, or `sqlite = nothing` for no default |

Notes:

- **Placeholders.** The generated SQL uses `$1`/`$2` on PostgreSQL and `?` on SQLite. Doc SQL blocks conventionally show the PostgreSQL form; the shape is otherwise identical. You never write placeholders yourself — parameters are always bound, never interpolated. The one exception is the raw-SQL manual-params escape hatch (`fetch`/`fetch_async` with a values array), where you write the backend-native placeholder yourself and PormG binds the values — see [Async & Concurrency](async.md).
- **DateTime is canonicalized to UTC.** `DateTimeField` values are stored as a single UTC ISO-8601 string on both backends (see the `#79` entry in the change log); prefer `ZonedDateTime` when the source has a real civil timezone.
- **Suspending foreign keys.** Inside a plain transaction PormG already defers foreign-key checks
  to `COMMIT` on both backends, so `atomic` handles children written before their parents.
  `without_foreign_keys` is still a single transaction. It is for repairing an already-inconsistent
  database, or for planting a violation in a SQLite test. The two engines differ in three ways:
  - **Mechanism:** see the table above.
  - **Nesting:** SQLite refuses to run it inside another transaction, because `PRAGMA foreign_keys`
    is ignored there. PostgreSQL runs it, and the deferral covers the enclosing transaction.
  - **Orphans at the end:** SQLite rolls back with `UnsafeMutationError`. PostgreSQL refuses the
    `COMMIT` with `IntegrityError`.

  Write it as the outermost block; the nesting difference is tracked in
  [#686](https://github.com/PingoLee/PormG.jl/issues/686).
- **Engine-pinned database defaults.** A `db_default` is raw SQL, so PormG will not translate it:
  a NamedTuple naming only `postgres` refuses to render for SQLite rather than emit DDL SQLite
  rejects. Give each engine a spelling, or use a portable expression (`CURRENT_TIMESTAMP`,
  `CURRENT_DATE`). See [Column defaults](schema_conventions.md#Column-defaults).
- **Decimal width on SQLite.** SQLite has no exact decimal type: a `DECIMAL(p, s)` column stores each
  value as an `Int64` or a `Float64`, and a `Float64` keeps fifteen significant digits exactly. So
  PormG refuses to create a wider one rather than let it round values as they are written (#648).
  The refusal fires whenever PormG would create or **re-create** the column — and a SQLite table
  rebuild re-creates every column, so a change elsewhere in a table that already holds a wide column
  (created before the refusal, or by another tool) is refused too. Narrow `max_digits` to 15 in that
  same change; the rebuild carries it. An untouched existing column is left alone.
- **Primary-key allocation** (`allocate_primary_keys`) presents one API over both backends; PostgreSQL reserves ids via the column sequence, SQLite emulates the same reservation. See [Bulk Insert, Copy, and Update](write/bulk.md).
- **Sequence resync.** After inserting rows with *explicit* primary keys, PostgreSQL's sequence can fall behind, so a later auto-id insert collides — a class of "duplicate key" surprise that doesn't exist on SQLite's `AUTOINCREMENT`. `bulk_insert`/`bulk_copy` resynchronize automatically (and `bulk_insert` retries a duplicate-key error once by resyncing first); row-level writers (`create`/`insert`, `update_or_create`, `get_or_create`) do not — call `resync_sequences(model)` explicitly after one of them writes an explicit primary key. See [Sequence synchronisation](schema_conventions.md#Sequence-synchronisation).

## Production notes

- **Connection pooling.** Pool sizing, health, and multi-tenant/dynamic connections: **[Configuration](configuration/index.md)** and **[Advanced Configuration](configuration/advanced.md)**.
- **Transactions & savepoints.** `run_in_transaction`, `with_savepoint`, and connection-loss semantics inside a transaction: **[Transactions](write/transaction.md)**.
- **Statement timeouts.** A long query is cancelled by PostgreSQL's `statement_timeout` (surfacing as a query-canceled error); the `:block` advisory-lock strategy also sets `statement_timeout` for the acquisition window (see [Advisory Locks](advisory_lock.md)).
- **Composite uniqueness.** Multi-column unique constraints render as a `CREATE UNIQUE INDEX` on both backends — see [Composite Uniqueness](models.md#Composite-Uniqueness-(unique_together)). A table-level `UNIQUE (…)` constraint already in the schema — what Django's `unique_together` creates — is read back too, and satisfies a declaration over the same columns rather than gaining a second index beside it.
- **Composite indexes.** Multi-column *non-unique* indexes render as a plain `CREATE INDEX`, likewise identical on both backends — see [Composite Indexes](models.md#Composite-Indexes-(Meta.indexes)). Of the **multi-column** indexes already in a live schema, introspection reads back only what PormG can re-emit: a **default b-tree, all-ascending, default-operator-class** index over plain columns, unique or not. A GIN/GiST/BRIN/hash index, a partial or functional one, an `EXCLUDE` constraint's backing index, a `DESC` key, a non-default operator class (`varchar_pattern_ops`) or collation, an `INCLUDE (…)` clause, `NULLS NOT DISTINCT`, a `DEFERRABLE` unique constraint, or an invalid index is left alone rather than regenerated as something else. Those shapes stay hand-managed — and because they are never read, `makemigrations` never drops them, while every composite it *does* read and no model declares is planned for removal ([Changing composites on an existing table](models.md#Changing-composites-on-an-existing-table)).

    The **single-column** reader that feeds `db_index` is older and more permissive: a one-column GIN, `DESC`, or `varchar_pattern_ops` index still reads back as a plain `db_index=true`, and regenerating from that model would produce an ordinary b-tree. Tightening it would make a legacy index of that kind stop reading back at all, which is its own churn problem, so it is deliberately left as is.
