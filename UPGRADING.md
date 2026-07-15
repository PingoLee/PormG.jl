# Upgrading PormG — consumer-app rollout log

Tracks **breaking / behavior changes in PormG** that require source-code changes in the internal apps that depend on it. PormG is pre-publish (single maintainer, ~4 internal apps, no external users), so breaking changes are intentional and cheap on the *PormG* side — but each one still has to be rolled out by hand in every consuming app. This file is that rollout checklist.

> ⚠️ **Not database migrations.** This file is about migrating **app source code** to keep up with the PormG API. It is unrelated to the `makemigrations` / `migrate` schema engine that manages your database tables.

## How to use

- One `##` entry per breaking change, **newest first**.
- Each entry records: what changed, why, the concrete **before → after** code edit, and a **per-app rollout** table.
- An app is done when its code is updated **and** its tests pass against the new PormG.
- Rename the placeholder app rows (`app-1` … `app-4`) to your real app names once, then reuse them in every entry.

### Status legend

| Mark | Meaning |
|------|---------|
| ✅ | migrated — app updated and green |
| ⏳ | pending — not yet migrated |
| — | n/a — app does not use the affected API |

## Applying these in a consuming app

This file is the **source of truth, kept in the PormG repo**. To fix a dependent app after a
PormG bump, point an agent (or yourself) at this file — read it from the dev'd source
(e.g. `~/.julia/dev/PormG/UPGRADING.md`) or from GitHub — and work the entries
**newest first**:

1. **Scope to this app.** In each entry's rollout table, skip rows already marked ✅ or —.
   Work only the ⏳ rows for this app.
2. **Find the call sites.** Run the entry's *"How to find the calls to migrate"* grep/error
   inside the app.
3. **Apply the `before → after`.** Edit each call site to the ✓ form shown in the entry.
4. **Verify.** Run the app's own test/integration suite against the upgraded PormG. An entry
   is done for this app only when its code is updated **and** its tests pass.
5. **Record it.** Flip this app's cell in that entry's rollout table to ✅ (or — if the app
   never used the affected API), and commit the table update back to PormG so the next app
   sees accurate state.

> **Tip — make it discoverable.** Add one line to each app's `AGENTS.md`/`CLAUDE.md`:
> *"Before bumping the PormG dependency, apply any ⏳ rows in `PormG/UPGRADING.md` for this app."*
> Then an agent working in that repo will pick up the rollout automatically.

---

## Composite uniqueness (`unique_together`) via `Models.UniqueConstraint`

- **PormG ref**: issue #19 ; `src/Models.jl`, `src/migrations/planner.jl`, `src/migrations/importers.jl`
- **Recorded**: 2026-07-14
- **Severity**: new feature — **additive, non-breaking**. No existing API changed; no forced code edit.

### What changed

Models can now declare multi-column uniqueness (Django's `Meta.unique_together`) with a
model-level `constraints=` list of named `Models.UniqueConstraint` objects:

```julia
Constructor_engine = Models.Model("constructor_engines",
  id = Models.IDField(),
  constructorid = Models.ForeignKey(Constructor, pk_field="constructorid", on_delete="CASCADE"),
  year = Models.IntegerField(),
  engine_manufacturer = Models.CharField(max_length=50),
  constraints = [
    Models.UniqueConstraint(fields=("constructorid", "year"), name="uniq_constructor_year"),
  ],
)
```

At migration time each constraint becomes a `CREATE UNIQUE INDEX` (identical on PostgreSQL and
SQLite). The Django importer now maps `Meta.unique_together` to this form automatically (resolving
the FK `_id` suffix). See [Composite Uniqueness](docs/src/models.md).

**Limitation (this release):** a constraint is materialized when its table is first created (same
lifecycle as the automatic many-to-many index). Adding/removing a constraint on an
already-migrated table is not yet diffed by `makemigrations` — deferred to a follow-up.

### How to find the calls to migrate

Nothing to grep — no API changed. This is purely additive. **Optional adoption:** if an app has a
natural composite key currently enforced only in application code (or a Django model with
`unique_together` that was imported before this feature), declare it with `UniqueConstraint` and
create the table (or add the unique index by hand on the existing table).

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | optional — review models for composite keys to enforce |
| app-2 | ⏳ | optional |
| app-3 | ⏳ | optional |
| app-4 | ⏳ | optional |

---

## Connection errors inside `run_in_transaction` now propagate (no silent statement retry)

- **PormG ref**: issue #138 ; `src/ConnectionPool.jl`
- **Recorded**: 2026-07-13
- **Severity**: behavior change (error now surfaces instead of a silent, broken retry)

### What changed

`fetch()`'s lost-connection recovery (renew the pooled connection, re-run the statement once)
no longer fires **inside a transaction context** or on a caller-pinned `conn`. Previously a
connection drop during e.g. `q.create(...)` inside `run_in_transaction` silently re-ran the
statement on a **fresh autocommit session** — committing a write that should have died with the
transaction — and released the transaction's pooled connection to the pool mid-transaction. Now
the connection error propagates out of the transaction block like any other failure; the wrapper
rolls back and renews/discards the pooled connection (#71). Plain `fetch()` outside transactions
keeps the transparent one-shot retry. This matches Django / SQLAlchemy / Rails 7.1 /
Go `database/sql`: never retry a statement inside a transaction — the application retries the
whole transaction.

### How to find the calls to migrate

Nothing to grep — no API changed. Only code that (unknowingly) relied on the mid-transaction
retry is affected: if a transaction block now fails with a driver connection error where it
previously appeared to succeed (with silently corrupted transactional semantics), wrap the
**whole** `run_in_transaction` call in an application-level retry.

### Migrate your app

```julia
# ✗ before: a connection drop mid-block silently committed the create OUTSIDE the transaction
# ✓ after: the block raises; retry the whole transaction if the work must survive reconnects
for attempt in 1:3
  try
    PormG.run_in_transaction("db_2") do
      (M.Pit_stops.objects).create(
        "raceid" => 841, "driverid" => 153, "stop" => 3, "lap" => 42,
        "time" => "17:05:23", "duration" => "22.500", "milliseconds" => 22500,
      )
    end
    break   # committed
  catch e
    attempt == 3 && rethrow()
  end
end
```

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | action needed only if the app saw mid-transaction reconnects |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |

---

## `DateTimeField` values are canonicalized to UTC — existing **SQLite** rows must be re-normalized once

- **PormG ref**: issue #79 ; `src/Models.jl` (`format_timezone_sql` / `validate_timezone`)
- **Recorded**: 2026-07-13
- **Severity**: breaking (SQLite stored-data format) / behavior fix
- **This is a data change, not a code change** — the PormG API is unchanged; there are no call
  sites to edit. The rollout is a one-time SQLite data re-normalization.

### What changed

`DateTimeField` values are now canonicalized to a single UTC ISO-8601 string
(`yyyy-mm-ddTHH:MM:SS.sss+00:00`) on **both** the write/bind path and the filter path — the
convention Django (`USE_TZ=True`), Rails, and SQLAlchemy already use. Previously PormG stored
offset-bearing strings verbatim (e.g. `auto_now` under `America/Sao_Paulo` was written as
`…-03:00`, and a `Z` / `.0` filter value was passed through unchanged).

- **PostgreSQL** is transparent: `TIMESTAMPTZ` compares by instant, so filters were already
  correct and stored data is unaffected — nothing to do.
- **SQLite** stores datetimes as TEXT and compares them lexicographically, so the old
  non-canonical strings made equality/range filters **diverge from PostgreSQL** whenever the
  filter value's spelling differed from the stored spelling (issue #79). Going forward both the
  stored value and the filter value are canonical UTC, so the comparison is correct — **but
  rows written by the old code are still in their old spelling** and must be re-normalized once.

### Who is affected

- PostgreSQL-only apps → mark `—`.
- SQLite apps whose `DateTimeField` columns are empty or freshly created after this bump → mark `—`.
- SQLite apps with **pre-existing** `DateTimeField` data → run the one-time re-normalization below.

### Re-normalize existing SQLite data (one time)

The read path already reconstructs the correct instant from any offset spelling, so a
read-modify-write through PormG reuses PormG's own parser/formatter and is the safest recipe.
For each SQLite model + `DateTimeField` column:

```julia
# `col` is any DateTimeField column on `M.Thing` (SQLite backend).
for row in M.Thing.objects.values("id", "col").list()
    (ismissing(row[:col]) || row[:col] === nothing) && continue   # skip SQL NULL (surfaces as missing)
    q = M.Thing.objects
    q.filter("id" => row[:id])
    q.update("col" => row[:col])                # re-writing stores the canonical UTC form
end
```

(An equivalent single SQL `UPDATE` that converts each value to canonical UTC works too, but the
read-modify-write above avoids hand-rolling the offset math.) Verify with a `Z`-spelled value
that previously missed on SQLite:

```julia
@assert M.Thing.objects.filter("col" => "2020-01-01T10:00:00Z").exists()  # a known stored instant
```

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |

---

## `distinct().order_by()` — the sort key must be in the projection (raises otherwise)

- **PormG ref**: issue #76 ; `src/querybuilder/build_query.jl`
- **Recorded**: 2026-07-13
- **Severity**: behavior change (new `ArgumentError`)

### What changed

A `DISTINCT` query that orders by a column outside its projection —
`.values("a").distinct().order_by("b")` with `b` not in `values(...)` — now raises a clear
`ArgumentError` on **both** backends. Previously PostgreSQL rejected it with a raw DB error while
SQLite silently ran it, returning rows in a nondeterministic `DISTINCT`/order interaction. Ordering a
`DISTINCT` result by an unprojected column is rejected by PostgreSQL and the SQL standard (SQL Server,
Oracle, DB2, and default-mode MySQL all reject it); PormG now makes SQLite conform too. The guard
matches the resolved SQL *expression*, so ordering by a *function of* a projected column
(`order_by("created_at__@date")` while only `created_at` is selected) is likewise rejected — that too
is a PostgreSQL error.

### How to find the calls to migrate

Run the app or its tests: the new error reads
`DISTINCT query cannot ORDER BY <col>: it is not in the SELECT DISTINCT projection`. Grep for
`.distinct()` and check each one's `order_by(...)` — every ordered column (or the exact ordering
expression) must also appear in `values(...)`. **Postgres-backed apps already errored on these; only
SQLite-tested queries could have been running silently.**

### Migrate your app

```julia
# ✗ raises: surname is ordered but not projected
M.Driver.objects.values("nationality").distinct().order_by("surname").list()

# ✓ include the sort key in values() (distinct is now over both columns) …
M.Driver.objects.values("nationality", "surname").distinct().order_by("surname").list()

# ✓ … or drop distinct() if you meant "one row per nationality, ordered by an aggregate"
M.Driver.objects.values("nationality", "n" => Count("driverid")).order_by("n").list()
```

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |

---

## bulk ops `copy=` kwarg removed — the pipeline never mutates (and never copies) your DataFrame

- **PormG ref**: issue #132 / PR #137 ; `src/querybuilder/execution_bulk.jl`
- **Recorded**: 2026-07-12
- **Severity**: breaking (kwarg removed) / behavior improvement

### What changed

`bulk_insert`, `bulk_copy`, and `bulk_update` no longer accept `copy::Bool`. The old
default (`copy=true`) deep-copied the entire DataFrame on every call; `copy=false` let
ORM-side normalization (default fills, `auto_now` columns) leak into the caller's frame.
The pipeline now works on a **zero-copy wrapper** (shared column vectors): the caller's
DataFrame is **never mutated and never copied**, unconditionally — strictly better than
both old modes. `allocate_primary_keys` is unchanged: `clone=true` still returns an
independent copy (that frame is *returned* to the caller, so it must not alias your
data), and `clone=false` still writes the pk column in place.

### How to find the calls to migrate

Grep each app for `copy=` / `copy =` on `bulk_insert`/`bulk_copy`/`bulk_update` calls
(or just run the app: passing the removed kwarg raises
`MethodError: ... got unsupported keyword argument "copy"`).

### Migrate your app

```julia
# ✗ before
bulk_insert(query, df, copy=true)    # paid a full deepcopy
bulk_update(query, df, columns=["points"], match_on=["id"], copy=false)  # mutated df

# ✓ after — just drop the kwarg; no-mutation is now the unconditional contract
bulk_insert(query, df)
bulk_update(query, df, columns=["points"], match_on=["id"])
```

If an app relied on `copy=false` to *receive* the injected columns (e.g. reading
`df.updated_at` after the call), that back-channel is gone — read the values back
through a query instead.

One subtle semantics shift: the old `copy=true` gave the bulk op a private *snapshot*
of your data; the zero-copy wrapper reads your live column vectors **during** the call.
Don't mutate the DataFrame from another task while a bulk op is executing on it (this
was never supported — it just happened to be masked by the default deepcopy).

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |

---

## `bulk_update(match_on=)` — pairs removed; `columns=` is the single df→field mapping point

- **PormG ref**: issue #107 / PR #135 ; `src/querybuilder/execution_bulk.jl`
- **Recorded**: 2026-07-12
- **Severity**: breaking

### What changed

`match_on=` no longer accepts `"df_col" => "model_field"` pairs. It takes **bare model
field names** only; `columns=` is now the **single place** a DataFrame column is mapped
to a model field ("one border crossing"). A field listed in both `columns=` and
`match_on=` is used for **matching only — it is never SET** (this was already true).
A bare `match_on` name resolves its source column **mapping-first**: the `columns=`
mapping when declared (authoritative — a same-named DataFrame column is ignored with a
warning), otherwise a DataFrame column with the field's own name.

### How to find the calls to migrate

Run the app or its tests: every old pair raises
`bulk_update: match_on= no longer accepts "df_col" => "model_field" pairs (DEPRECATED API)`
with the exact rewrite. Or grep for `match_on` and inspect any entry containing `=>`.

### Migrate your app

```julia
# ✗ before
bulk_update(query, df,
    columns  = ["new_score" => "points"],
    match_on = ["record_id" => "id"])

# ✓ after — the pair moves to columns=; match_on keeps the bare field name
bulk_update(query, df,
    columns  = ["new_score" => "points", "record_id" => "id"],
    match_on = ["id"])
```

Bare-name calls (`match_on = ["id"]` with an `id` DataFrame column, or relying on the
primary-key fallback) need no change.

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |

---

## `SQLOrder` orientation is now whitelisted — only `"ASC"`/`"DESC"` (case-insensitive) construct and render

- **PormG ref**: issue #77 / PR #133 ; `src/querybuilder/types.jl`, `src/querybuilder/build_query.jl`
- **Recorded**: 2026-07-12
- **Severity**: behavior change (new `ArgumentError`; closes an injection seam)

### What changed

A directly constructed `SQLOrder` used to accept **any** string as `orientation` and interpolate
it verbatim into the rendered `ORDER BY` — a SQL-injection seam for apps forwarding a
user-controlled sort direction. Every construction path (and render, guarding post-construction
mutation) now normalizes (`uppercase` + `strip`) and whitelists against `"ASC"`/`"DESC"`, raising
`ArgumentError` for anything else. The documented string API — `.order_by("field")` /
`.order_by("-field")` — was always safe and is unchanged.

### How to find the calls to migrate

Grep the app for direct `SQLOrder(` construction. Only call sites passing a *dynamic*
(user- or data-derived) `orientation` need action; literal `"ASC"`/`"DESC"` in any case keep
working.

### Migrate your app

```julia
# ✗ before — a user-controlled direction string reached the SQL verbatim
dir = params["dir"]   # e.g. "ASC; DROP TABLE results" used to render as-is
query.order_by(SQLOrder(SQLField("points", "points"); orientation = dir))

# ✓ after — map untrusted input onto the whitelist yourself (or handle the ArgumentError)
query.order_by(SQLOrder(SQLField("points", "points");
    orientation = lowercase(dir) == "desc" ? "DESC" : "ASC"))
```

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |

---

## Pool exhaustion now raises typed `PoolTimeoutError`; expansion ceiling raised to `pool_size × 10`

- **PormG ref**: issue #37 / PR #129 ; `src/ConnectionPool.jl`
- **Recorded**: 2026-07-12
- **Severity**: behavior change (error type changed; pool sizing change)

### What changed

Exhausting the connection pool used to throw a **bare `String`** after a noisy busy-retry loop.
Both the PostgreSQL and SQLite acquire paths now throw `PormG.PoolTimeoutError` (exported; fields
`adapter` / `pool_size` / `max_size` / `attempts` / `elapsed`, with a "raise pool_size" remedy in
`showerror`). The lazy expansion ceiling grew from `pool_size × 5` to `pool_size × 10` (default
pool: 3 base → up to 30 on demand; idle footprint unchanged), and per-retry logging dropped to
`@debug` — a single actionable `@warn` fires only when the pool hits its ceiling.

### How to find the calls to migrate

Grep the app for `catch` blocks that match the old exhaustion message as a string
(e.g. `occursin("No available"` …). Most apps have none — then there is nothing to change; the
new error type and quieter logs just apply.

### Migrate your app

```julia
# ✗ before — the only way to detect exhaustion was string-matching a bare String throw
catch e
    e isa String && occursin("No available", e) && back_off()

# ✓ after — catch the typed error; consider raising pool_size in connection.yml if it fires
catch e
    e isa PormG.PoolTimeoutError || rethrow()
    back_off()
```

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |

---

## `order_by` on nullable columns — NULL placement normalized to PostgreSQL's convention on both backends

- **PormG ref**: issue #75 / PR #120 ; `src/querybuilder/build_query.jl`
- **Recorded**: 2026-07-12
- **Severity**: behavior change (result order can change on SQLite)

### What changed

Top-level `ORDER BY` used to render a bare `expr ASC|DESC`, and PostgreSQL and SQLite default
NULLs to **opposite ends** — so ordering a nullable column returned different rows per backend,
and with `.first()` / `.page()` that changed *which* rows you got. PormG now emits an explicit
NULLS clause matching PostgreSQL's default on **both** backends: ASC → `NULLS LAST`,
DESC → `NULLS FIRST` (SQLite < 3.30.0 gets an equivalent portable `(expr IS NULL)` prefix).
Per-term override: `SQLOrder(field; nulls = :first | :last)`. Window `OVER(...)` ordering is
**not** yet normalized (follow-up pending).

**PostgreSQL-backed apps see no change.** SQLite-backed apps: any `order_by` on a nullable key
may now sort NULL rows to the other end.

### How to find the calls to migrate

No API change and nothing errors. In SQLite-backed apps, review `order_by` calls on **nullable**
columns whose consumers depend on row order — `.first()`, pagination, "top N" reports.

### Migrate your app

```julia
# Only if the app depended on SQLite's old NULLS-first-on-ASC ordering — pin it explicitly:
using PormG.QueryBuilder: SQLOrder, SQLField

M.Driver.objects.values("surname", "nationality").order_by(
    SQLOrder(SQLField("nationality", "nationality"); orientation = "ASC", nulls = :first)
).list()
```

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |

---

## `bulk_copy` — field formatters now applied; `""` and `missing` no longer collapse to NULL

- **PormG ref**: issue #86 / PR #115 ; `src/querybuilder/execution_bulk.jl`
- **Recorded**: 2026-07-12
- **Severity**: behavior change (persisted values can differ)

### What changed

`bulk_copy` wrote **raw** DataFrame values (each field's formatter result was validated, then
discarded), so datetime/bool/float values could silently diverge from what `bulk_insert` /
`create()` store; and the COPY payload carried no NULL marker, collapsing `""` and `missing`
into the same NULL. It now formats every cell exactly like `bulk_insert` and serializes with a
`\N` NULL sentinel: `missing` → SQL `NULL`, `""` → empty string, and the two round-trip
distinctly.

### How to find the calls to migrate

No API change. Review `bulk_copy` call sites that (a) pre-formatted datetimes/bools/floats to
compensate for the old raw write — the workaround is now redundant (but harmless), or
(b) relied on empty strings being stored as NULL.

### Migrate your app

```julia
# The old behavior stored NULL for BOTH of these; they now persist differently:
df = DataFrames.DataFrame(surname = ["Senna", "Prost"], code = ["", missing])
bulk_copy(M.Driver.objects, df)   # row 1 code → '' (empty string), row 2 code → NULL

# Keep the NULL semantics only where you actually want it — coerce before the call:
df[!, :code] = map(x -> !ismissing(x) && x == "" ? missing : x, df[!, :code])
```

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |

---

## Template for new entries

<!--
Copy the block below to the top of the log (under the legend) for each new breaking change.

## `<api>` — <one-line summary of the change>

- **PormG ref**: <TODO.md item / PR / commit> ; <src file>
- **Recorded**: <YYYY-MM-DD>
- **Severity**: breaking | behavior change | deprecation

### What changed
<what the old API did vs. the new contract>

### How to find the calls to migrate
<error message to grep for, or the call pattern>

### Migrate your app
```julia
# ✗ before
...
# ✓ after
...
```

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |
-->
