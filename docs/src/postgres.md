# PostgreSQL Guide

PormG is PostgreSQL-first for production and SQLite-friendly for local development and tests. For standard relational models the same models, the same fluent query API and the same migration engine run on both, so most application code is backend-agnostic. This page is the entry point for the three things that are *not* symmetric:

1. **PostgreSQL-only capabilities** — features that exist only on PostgreSQL, most with a documented SQLite fallback or no-op.
2. **PostgreSQL-only field types** — specialized types SQLite has no column for. PormG refuses them on SQLite rather than emulate them, so a model that declares one runs on PostgreSQL only.
3. **PostgreSQL ↔ SQLite divergences** — behaviour a power user must know when the same code runs on both backends.

The deep-dive pages own the full reference and verified examples; this guide points you to them rather than restating them.

!!! tip "Keep code backend-agnostic"
    Where a query or write feature is PostgreSQL-only, PormG provides a SQLite-safe fallback (`with_advisory_lock` becomes a no-op; use `bulk_insert` instead of `bulk_copy`) so the *same* source runs against SQLite in tests and PostgreSQL in production. Prefer that over branching on the backend. The exception is a [PostgreSQL-only field type](#PostgreSQL-only-field-types): a model that declares one has no SQLite table, so its tests run on PostgreSQL.

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

## PostgreSQL-only field types

Some PostgreSQL types have no SQLite counterpart that keeps their semantics. PormG does not emulate
them: on SQLite, `makemigrations` raises `BackendCapabilityError` for a model that declares one, before
any migration is written. Such a model runs on PostgreSQL only.

### `GenericIPAddressField` / `CIDRField` — `inet` / `cidr`

```julia
Pit_wall_session = Models.Model("pit_wall_session",
  id = Models.IDField(),
  client_ip = Models.GenericIPAddressField(),   # one host address
  garage_lan = Models.CIDRField(null=true),     # one network
)
```

- Native `inet` and `cidr`: they compare, sort and index by network, and every spelling of an
  address is one value.
- A text → `inet`/`cidr` retype is parsed by the server, and a row that does not parse is counted
  before anything runs. An `inet` → text retype writes the printed form (`abbrev`, `10.0.0.1`), not the
  masked `10.0.0.1/32` PostgreSQL's own cast would.
- A `GenericIPAddressField` → `CIDRField` retype keeps every host (`10.0.0.1` becomes `10.0.0.1/32`).
  An address with bits set right of its mask (`10.0.0.1/24`, written outside PormG) is not a network:
  PostgreSQL's own cast would quietly zero those bits (`10.0.0.0/24`), so such rows are counted and the
  plan is refused. To keep the network, set those values to it yourself (PostgreSQL's `network()`)
  and migrate again.
- `Cast(…, "text")` over an `inet` column follows PostgreSQL's cast and includes the mask
  (`10.0.0.1/32`); the column's value, read directly, does not.
- Why SQLite is refused: it has no type that compares an address by network. A text column would sort
  `10.0.0.10` before `10.0.0.9` and store each spelling of an address as a different value.

Reference: **[Fields → Network Address Fields](fields.md#Network-Address-Fields)**.

### `ArrayField` — `integer[]`, `character varying(n)[]`, …

```julia
Race_strategy = Models.Model("race_strategy",
  id = Models.IDField(),
  tyre_compounds = Models.ArrayField(Models.CharField(max_length = 12); size = 6),
  pit_laps = Models.ArrayField(Models.IntegerField(), default = Int[]),
)
```

- A native one-dimensional array of the element field's type. A value is a Julia `Vector`, and it
  reads back as `Vector{T}` with `T` the element field's scalar read type, on both PostgreSQL drivers.
- `size` is checked by PormG on write. PostgreSQL neither enforces nor keeps it, so it is not part of
  the schema.
- A vector filter value is an equality against the whole array. The array lookups are
  `@acontains` (`@>`), `@contained_by` (`<@`), `@overlap` (`&&`), the `@len` transform
  (`cardinality`), an index (`"tyre_compounds__0"`, 0-based) and a slice (`"pit_laps__0_2"`).
- A text → array retype parses each value as an array literal and counts the rows that do not parse.
  An array whose elements only widen (`integer[]` → `bigint[]`) is a plain `ALTER`; any other element
  change converts through text, and the rows with an element that no longer fits are counted first.
- Why SQLite is refused: it has no array type. A text column would store the array's literal, which no
  query could compare, index or take apart by element.

Reference: **[Fields → Array Fields](fields.md#Array-Fields)**.

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
- **Array lookups** — `@acontains` (`@>`), `@contained_by` (`<@`), `@overlap` (`&&`), the `@len`
  transform, and an index or slice (`"tyre_compounds__0"`, `"pit_laps__0_2"`) on an `ArrayField`
  column. The column itself cannot exist on SQLite, so these refuse there for completeness: a build
  against an unmanaged SQLite table that declares one still raises `BackendCapabilityError`. See
  [Fields → Array Fields](fields.md#Array-Fields).
  ```julia
  M.Race_strategy.objects.filter("tyre_compounds__@acontains" => ["SOFT", "HARD"])
  ```
- **Accent-insensitive matching** — `@iunaccent_contains`, `@iunaccent_exact` and their negated
  twins `@niunaccent_contains`, `@niunaccent_exact`. They need the `unaccent` extension, declared
  in `connection.yml` and installed by `migrate()`. See
  [Accent-Insensitive lookups](read/filters_and_aggregates.md#Accent-Insensitive-(@iunaccent_contains,-@iunaccent_exact)).
  ```julia
  M.Driver.objects.filter("surname__@iunaccent_contains" => "raikkonen")   # finds "Räikkönen"
  ```
- **Regular expressions** — `@regex` (`~`), `@iregex` (`~*`) and their negated twins `@nregex`,
  `@niregex`. The pattern is PostgreSQL's POSIX syntax. SQLite has no regex engine, and PormG does
  not emulate one: an emulation would read the pattern in a different dialect and return
  different rows. See
  [Regular Expressions](read/filters_and_aggregates.md#Regular-Expressions-(@regex,-@iregex)).
  ```julia
  M.Driver.objects.filter("surname__@regex" => "^Ver")   # surnames starting with "Ver"
  ```
- **Full-text search** — the `@search` lookup and `SearchQuery`, `SearchVector`, `SearchRank` and
  `SearchHeadline`, over `tsvector`/`tsquery`. SQLite's FTS5 is a separate index table with its own
  syntax and ranking, so PormG does not emulate it. See [Full-Text Search](read/full_text_search.md).
  ```julia
  M.Driver.objects.filter("surname__@search" => SearchQuery("senna"; config = "simple"))
  ```
- **Network containment** — `@net_contained` (`<<`), `@net_contained_or_equal` (`<<=`),
  `@net_contains` (`>>`), `@net_contains_or_equals` (`>>=`), `@net_overlaps` (`&&`), `@family` and
  `@prefixlen`, on a `GenericIPAddressField` or `CIDRField` column. See
  [Fields → Network containment lookups](fields.md#Network-containment-lookups).
  ```julia
  M.Pit_wall_session.objects.filter("client_ip__@net_contained" => "10.20.0.0/16")
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
- **Casts to a time type** — `Cast(x, "timestamp")`, `"timestamptz"`, `"time"`, `"interval"`, and
  `DateTimeField()` / `TimeField()` / `DurationField()` as a `Cast` target or as the
  `output_field` of `Case`, `Coalesce`, `Greatest` or `Least`. SQLite
  has no time types, so its `CAST` would turn the text into a number. A cast to `"date"` works on
  both and renders `date(x)` on SQLite. See
  [Functions and Dates → Cast](read/functions_and_dates.md#Cast-—-Type-Conversion).

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
| **`GenericIPAddressField` / `CIDRField`** | native `inet` / `cidr` | not supported — `makemigrations` raises `BackendCapabilityError` |
| **`ArrayField`** | native arrays (`integer[]`, …) | not supported — `makemigrations` raises `BackendCapabilityError` |
| **`DecimalField` width** | `numeric`, exact at any `max_digits` | `NUMERIC` affinity, exact up to `max_digits = 15`; a wider declaration raises `BackendCapabilityError` at `makemigrations` |
| **Window frames** | explicit `frame=` clauses | default frame only |
| **JSONB lookups** (`@jcontains`, `@has_key`, `@has_any_keys`, `@has_keys`) | JSONB operators | `BackendCapabilityError` — `__` key paths still work |
| **Array lookups** (`@acontains`, `@contained_by`, `@overlap`, `@len`, index, slice) | array operators and subscripts | `BackendCapabilityError` |
| **Network lookups** (`@net_contained`, `@net_contains`, `@net_overlaps`, …, `@family`, `@prefixlen`) | `inet` operators | `BackendCapabilityError` |
| **Accent-insensitive lookups** (`@iunaccent_*`, `@niunaccent_*`) | `unaccent` extension | `BackendCapabilityError` |
| **Regex lookups** (`@regex`, `@iregex`, `@nregex`, `@niregex`) | POSIX `~` / `~*` | `BackendCapabilityError` |
| **Full-text search** (`@search`, `SearchQuery`, `SearchVector`, `SearchRank`, `SearchHeadline`) | `tsvector` / `tsquery` | `BackendCapabilityError` |
| **`Cast` to a time type** | `::date`, `::timestamp`, `::time`, `::interval` | `date` renders `date(x)`; the others raise `BackendCapabilityError` |
| **`ToChar` formats** | any `to_char` template | the portable table only; others raise `BackendCapabilityError` |
| **`Extract` parts** | every PostgreSQL `EXTRACT` field, any case; a non-field raises `InvalidValueError` | `YEAR` `MONTH` `DAY` `HOUR` `MINUTE` `SECOND` `DOW` `DOY`, any case; other PostgreSQL fields raise `BackendCapabilityError`, a non-field `InvalidValueError` |
| **Row locks** (`select_for_update()`) | `SELECT … FOR UPDATE` | silent no-op — a SQLite write already locks the whole database |
| **`without_foreign_keys`** | `SET CONSTRAINTS ALL DEFERRED`; an orphan fails `COMMIT` with `IntegrityError` | `PRAGMA foreign_keys = OFF` plus a `foreign_key_check` before `COMMIT` (`UnsafeMutationError`) |
| **Engine-pinned `db_default`** | `db_default = (postgres = "now()",)` renders | rendering it raises `BackendCapabilityError` — add `sqlite = "…"`, or `sqlite = nothing` for no default |

Notes:

- **Placeholders.** The generated SQL uses `$1`/`$2` on PostgreSQL and `?` on SQLite. Doc SQL blocks conventionally show the PostgreSQL form; the shape is otherwise identical. You never write placeholders yourself — parameters are always bound, never interpolated. The one exception is the raw-SQL manual-params escape hatch (`fetch`/`fetch_async` with a values array), where you write the backend-native placeholder yourself and PormG binds the values — see [Async & Concurrency](async.md).
- **DateTime is canonicalized to UTC.** `DateTimeField` values are stored as a single UTC ISO-8601 string on both backends (see the `#79` entry in the change log); prefer `ZonedDateTime` when the source has a real civil timezone.
- **Suspending foreign keys.** Inside a plain transaction PormG already defers foreign-key checks
  to `COMMIT` on both backends, so `atomic` handles children written before their parents.
  `without_foreign_keys` is still a single transaction. It is for repairing an already-inconsistent
  database, or for planting a violation in a SQLite test. On both engines it must be the outermost
  transaction: nested inside `atomic`, it raises `TransactionError` before touching the database.
  The two engines differ in two ways:
  - **Mechanism:** see the table above.
  - **Orphans at the end:** SQLite rolls back with `UnsafeMutationError` when `check_on_exit = true`.
    PostgreSQL ignores `check_on_exit` and refuses the `COMMIT` with `IntegrityError`.
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

  Projected as the column itself, a `DecimalField` of at most fifteen digits reads back as a
  `Decimals.Decimal` on both engines. On SQLite everything else keeps the `Int64`/`Float64` SQLite
  holds or computed: an expression over the column (`Sum`, `F("price") * 2`, a SQL function, a
  `Joined`/`CTE` reference, a subquery), a row returned by `create()` or `update_or_create`, a value
  that does not fit the declaration (the unrounded result of an `F`-arithmetic `update`, which
  PostgreSQL rounds to the column's scale), and a field declared wider than fifteen digits. See
  [Serializing rows to JSON](read/index.md#Serializing-rows-to-JSON).
- **Primary-key allocation** (`allocate_primary_keys`) presents one API over both backends; PostgreSQL reserves ids via the column sequence, SQLite emulates the same reservation. See [Bulk Insert, Copy, and Update](write/bulk.md).
- **Sequence resync.** After inserting rows with *explicit* primary keys, PostgreSQL's sequence can fall behind, so a later auto-id insert collides — a class of "duplicate key" surprise that doesn't exist on SQLite's `AUTOINCREMENT`. `bulk_insert`/`bulk_copy` resynchronize automatically (and `bulk_insert` retries a duplicate-key error once by resyncing first); row-level writers (`create`/`insert`, `update_or_create`, `get_or_create`) do not — call `resync_sequences(model)` explicitly after one of them writes an explicit primary key. See [Sequence synchronisation](schema_conventions.md#Sequence-synchronisation).

## Production notes

- **Connection pooling.** Pool sizing, health, and multi-tenant/dynamic connections: **[Configuration](configuration/index.md)** and **[Advanced Configuration](configuration/advanced.md)**.
- **Transactions & savepoints.** `run_in_transaction`, `with_savepoint`, and connection-loss semantics inside a transaction: **[Transactions](write/transaction.md)**.
- **Statement timeouts.** A long query is cancelled by PostgreSQL's `statement_timeout` (surfacing as a query-canceled error); the `:block` advisory-lock strategy also sets `statement_timeout` for the acquisition window (see [Advisory Locks](advisory_lock.md)).
- **Composite uniqueness.** Multi-column unique constraints render as a `CREATE UNIQUE INDEX` on both backends — see [Composite Uniqueness](models.md#Composite-Uniqueness-(unique_together)). A table-level `UNIQUE (…)` constraint already in the schema — what Django's `unique_together` creates — is read back too, and satisfies a declaration over the same columns rather than gaining a second index beside it.
- **Composite indexes.** Multi-column *non-unique* indexes render as a plain `CREATE INDEX`, likewise identical on both backends — see [Composite Indexes](models.md#Composite-Indexes-(Meta.indexes)).
- **Index methods, operator classes and descending columns.** `Models.Index(method = "gin")` (also `hash`, `gist`, `spgist`, `brin`), `opclasses = ("jsonb_path_ops",)` and a `"-field"` render as PostgreSQL writes them, followed by `COMMENT ON INDEX … IS 'pormg:index'` — PormG's ownership marker — in the same step ([Methods, operator classes and descending columns](models.md#Methods,-operator-classes-and-descending-columns)). The marker decides what `makemigrations` may drop: an undeclared index of one of these shapes is removed only when it carries one, so a GIN or `varchar_pattern_ops` index written by hand is never planned away, and declaring it adopts it with a `COMMENT ON INDEX` that keeps any comment already there. A `COMMENT ON INDEX` that replaces the comment later, or a `pg_restore --no-comments`, removes the marker and with it PormG's ownership — the index is then treated as hand-made. Operator classes are rendered unqualified and resolve through the connection's `search_path`, so a class from an extension (`gin_trgm_ops` from `pg_trgm`) needs the extension installed first — PormG does not manage extensions. Every `CREATE INDEX` runs inside `migrate`'s transaction and blocks writes to its table while it builds; for a large table, build it with `CREATE INDEX CONCURRENTLY` in a `run_once` step and declare it afterwards.
- **Expression and partial indexes.** `Models.Index(expressions = ("lower(surname)",), …)` and `Models.Index(fields = …, condition = "position IS NOT NULL", …)` render their SQL text verbatim — a `WHERE` after the member list — and the marker carries a hash of that text: `pormg:index:<16 hex>` ([Expression and partial indexes](models.md#Expression-and-partial-indexes)). PostgreSQL stores a rewritten form of the text (`lower(surname::text)`, a re-parenthesised predicate), so the hash, not the text, is what `makemigrations` compares; a hand-made one is adopted only by a declaration of the catalog's own text, which `inspectdb` writes. Every function an expression or a predicate calls must be `IMMUTABLE`, or `migrate` fails at the `CREATE INDEX`.
- **Covering indexes.** `Models.Index(fields = ("raceid",), include = ("points",), name = …)` renders `INCLUDE ("points")` after the member list, followed by the `pormg:index` marker, and is owned like an index with a `method` ([Covering indexes](models.md#Covering-indexes-(include))). SQLite has no covering indexes: `makemigrations` refuses a model that declares one there with `BackendCapabilityError`, at the planner and at the renderer, rather than create the index without its payload.
- **What introspection reads back.** Of the indexes already in a live schema, it reads only what a declaration can re-create: a b-tree index over plain columns, unique or not, and — when it is not unique — any of the six methods, a `DESC` key (with its default `NULLS FIRST`), a non-default operator class whose name is a lower-case identifier, and, as SQL text, an expression member, an explicitly collated member and a partial index's predicate, and — on a non-unique index — an `INCLUDE (…)` payload, as `include`. A `NULLS` placement other than the direction's default makes a member text too (`points DESC NULLS LAST`), declarable through `expressions`. An extension's access method (`bloom`), an `EXCLUDE` constraint's backing index, an `INCLUDE (…)` clause on a unique index, storage parameters on an advanced index, `NULLS NOT DISTINCT`, a `DEFERRABLE` unique constraint, a unique index with a method, direction or operator class, or an invalid index is left alone rather than regenerated as something else. (A unique index with an expression or a predicate is read, as a `UniqueConstraint(expressions = …)` / `UniqueConstraint(condition = …)`.) (An invalid index — a failed `CREATE INDEX CONCURRENTLY` — is worth removing, and `check("db"; kinds = [:invalid_index])` lists every one with the remedy: [Finding invalid indexes](migrations/workflow.md#Finding-Invalid-Indexes).) Those shapes stay hand-managed, and because they are never read, `makemigrations` never drops them ([Changing composites on an existing table](models.md#Changing-composites-on-an-existing-table)).

    The **single-column** reader that feeds `db_index` applies the same rules: a one-column GIN, `DESC`, `varchar_pattern_ops`, collated, partial, functional, `INCLUDE`, invalid or `EXCLUDE` index is not read as `db_index = true`, so `makemigrations` never drops it as one — a GIN, `DESC`, operator-class, collated, partial or functional one is read as an `Index` instead, under the ownership rule above, and so is any index carrying the `pormg:index` marker. It used to be read, which planned a destructive `DROP INDEX` for it whenever the field did not declare `db_index` — and on an `EXCLUDE` constraint that `DROP INDEX` failed at `migrate`. A field that *does* declare `db_index = true` on such a column gets PormG's own plain b-tree index beside it, because the hand-made one is not the index `db_index` describes.
