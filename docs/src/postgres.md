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
- **SQLite** does not support advisory locks, so `with_advisory_lock` is a **no-op** — the block still runs, just without cross-process locking. This is deliberate, so the same code is correct in production and in SQLite tests.

Waiting strategies (`:poll` vs `:block`), timeouts, and async safety: **[Advisory Locks](advisory_lock.md)**.

## Advanced SQL (both backends, PostgreSQL-first)

These run on SQLite too, but they are where PostgreSQL shines for analytical work. Reach for them before dropping to raw SQL:

- **[Window Functions](read/window_functions.md)** — `Rank`, `Lag`, `Lead`, `LastValue`, … over `WindowOver(partition_by=…, order_by=…)` frames.
- **[Subqueries and CTEs](read/subqueries_and_ctes.md)** — `.with(...)`, correlated subqueries, `Exists`/`OuterRef`, and CTE joins.
- **[Filters and Aggregates](read/filters_and_aggregates.md)** and **[Functions and Dates](read/functions_and_dates.md)** — the `Sum`/`Count`/`Max`, date-bucket, and SQL-function surface.
- **[Field Expressions](read/field_expressions.md)** — `F("...")` database-side arithmetic and field-to-field comparisons.

## PostgreSQL ↔ SQLite divergences

PormG keeps the two backends aligned wherever it can and documents the differences where it can't. The ones a power user hits:

| Area | PostgreSQL | SQLite |
|------|-----------|--------|
| **Bind placeholders** | `$1`, `$2`, … | `?` |
| **Bulk load** | `bulk_copy()` (COPY) | `bulk_insert()` (no COPY) |
| **Advisory locks** | real (`pg_advisory_lock`) | no-op |
| **PK allocation** | real sequences (`nextval`) | emulated via `sqlite_sequence` high-water mark |
| **Drop a constraint (migrations)** | `ALTER TABLE … DROP CONSTRAINT` | full table rebuild (SQLite has no `DROP CONSTRAINT`) |
| **`ON CONFLICT`** | supported | supported (SQLite ≥ 3.24) — same syntax |

Notes:

- **Placeholders.** The generated SQL uses `$1`/`$2` on PostgreSQL and `?` on SQLite. Doc SQL blocks conventionally show the PostgreSQL form; the shape is otherwise identical. You never write placeholders yourself — parameters are always bound, never interpolated.
- **DateTime is canonicalized to UTC.** `DateTimeField` values are stored as a single UTC ISO-8601 string on both backends (see the `#79` entry in `UPGRADING.md`); prefer `ZonedDateTime` when the source has a real civil timezone.
- **Primary-key allocation** (`allocate_primary_keys`) presents one API over both backends; PostgreSQL reserves ids via the column sequence, SQLite emulates the same reservation. See [Bulk Insert, Copy, and Update](write/bulk.md).

## Production notes

- **Connection pooling.** Pool sizing, health, and multi-tenant/dynamic connections: **[Configuration](configuration/index.md)** and **[Advanced Configuration](configuration/advanced.md)**.
- **Transactions & savepoints.** `run_in_transaction`, `with_savepoint`, and connection-loss semantics inside a transaction: **[Transactions](write/transaction.md)**.
- **Statement timeouts.** A long query is cancelled by PostgreSQL's `statement_timeout` (surfacing as a query-canceled error); the `:block` advisory-lock strategy also sets `statement_timeout` for the acquisition window (see [Advisory Locks](advisory_lock.md)).
- **Composite uniqueness.** Multi-column unique constraints render as a `CREATE UNIQUE INDEX` on both backends — see [Composite Uniqueness](models.md#Composite-Uniqueness-(unique_together)).
