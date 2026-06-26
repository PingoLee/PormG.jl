# In-App Migration Log

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

---

## Export surface — SQL function constructors moved to `PormG.Functions`

- **PormG ref**: issue #35 (Tier 2 pre-publish · curate the public export surface); [src/PormG.jl](src/PormG.jl) (`module Functions`), [docs/src/api.md](docs/src/api.md)
- **Recorded**: 2026-06-25
- **Severity**: **breaking** — only for code that relied on **bare `using PormG`** putting the function names into scope. Explicit imports are unaffected.

### What changed

`using PormG` no longer exports the ~42 SQL function constructors (`Sum`, `Avg`, `Count`, `Max`, `Min`, `Case`, `When`, `Cast`, `Concat`, `Extract`, `To_char`, `Value`, `Coalesce`, `Greatest`, `Least`, `Lower`, `Upper`, `Length`, `Abs`, `Round`, `NullIf`, `Replace`, `Trim`, `LTrim`, `RTrim`, `Floor`, `Ceil`, `Sqrt`, `Exp`, `Ln`, `Power`, `Mod`, `WindowOver`, `WindowSpec`, `Rank`, `DenseRank`, `RowNumber`, `Lag`, `Lead`, `FirstValue`, `LastValue`, `NthValue`). They now live in the `PormG.Functions` submodule. The curated top-level surface dropped from 73 names to 31 (query primitives, bulk ops, transactions, async, lifecycle).

`F`, `Q`, `Qor`, `Exists`, `OuterRef`, `object`, `get`, `show_query`, `inspect_query`, the `bulk_*` ops and the transaction/async API **stay at the top level**. `fetch` now extends `Base.fetch` (no longer a shadow) and needs no import.

**What still works unchanged** (no migration needed): `using PormG: Sum, Count` (explicit opt-in) and `PormG.Sum` (qualified) — the names remain accessible, just not auto-exported.

### How to find the calls to migrate

Only a `using PormG` followed by an **unqualified** function constructor breaks:

```text
ERROR: UndefVarError: `Sum` not defined
```

Grep the app for bare `using PormG` whose module then calls `Sum(`/`Count(`/`Max(`/… without a `using PormG: …` or `PormG.Functions` import.

### Migrate your app

Pick one (all equivalent):

```julia
# ✗ before — relied on bare `using PormG` exporting Sum/Count
using PormG
M.Result.objects.values("pts" => Sum("points"), "n" => Count("resultid"))

# ✓ after — opt in to the whole function library
using PormG, PormG.Functions

# ✓ after — opt in to specific names (also works, smallest diff)
using PormG: Sum, Count

# ✓ after — or qualify at the call site, no import
M.Result.objects.values("pts" => PormG.Functions.Sum("points"))
```

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |

---

## Driver loading — `LibPQ`/`SQLite` are now weak dependencies (load the driver yourself)

- **PormG ref**: issue #34 (Tier 2 pre-publish · decouple SQL adapters); [src/Backend.jl](src/Backend.jl), [ext/PormGLibPQExt.jl](ext/PormGLibPQExt.jl), [ext/PormGSQLiteExt.jl](ext/PormGSQLiteExt.jl), [Project.toml](Project.toml)
- **Recorded**: 2026-06-25
- **Severity**: **breaking** — `using PormG` no longer loads any SQL driver. The first database operation raises a clear error until the driver is loaded.

### What changed

`LibPQ` and `SQLite` moved from `[deps]` to `[weakdeps]` and their driver code now lives in package extensions (`ext/PormGLibPQExt.jl`, `ext/PormGSQLiteExt.jl`). Core no longer references any concrete driver type; it dispatches through the `backend_*` generics in `src/Backend.jl`, whose methods are supplied by the extension that loads when you run `using LibPQ` / `using SQLite`.

Consequence: **each app must load the driver(s) it uses**, and **declare them as direct dependencies** (they no longer arrive transitively through PormG).

### How to find the calls to migrate

The app starts fine but the first query/connection throws:

```text
PormG: the PostgreSQL backend requires LibPQ. Run `using LibPQ` (or `using PormG, LibPQ`) so the PostgreSQL extension loads.
```

(or the `SQLite` variant). Grep the app's startup for `using PormG`.

### Migrate your app

1. Add the driver to your app's `Project.toml` (`] add LibPQ` and/or `] add SQLite`).
2. Load it alongside PormG:

```julia
# ✗ before — driver came in transitively
using PormG

# ✓ after — PostgreSQL app
using PormG, LibPQ

# ✓ after — SQLite app
using PormG, SQLite

# ✓ after — app that talks to both backends
using PormG, LibPQ, SQLite
```

Also note: a handful of driver internals are **no longer exported** — `libpq_execute`, `libpq_execute_async`, `is_connection_alive`, `reconnect_db`, `is_connection_error`. They became internal `backend_*` generics inside the extensions. Apps that reached for them (rare) should use the public API (`PormG.fetch`, `run_in_transaction`, …) instead.

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |

---

## `bulk_update` — `match_on=` replaces dynamic match keys in `filters=`

- **PormG ref**: "Bulk Operation API Refactoring" in [TODO.md](TODO.md#L7); implemented in [src/querybuilder/execution_bulk.jl](src/querybuilder/execution_bulk.jl)
- **Recorded**: 2026-06-23
- **Severity**: **breaking** — raises a migration error at runtime if a call is not updated.

### What changed

`bulk_update` now separates **per-row match keys** from **constant predicates**:

- **`match_on=`** holds the per-row match keys — the SQL merge condition `Tb.field = source.df_col`. Same grammar as `columns=`: a `String`, or `"df_col" => "model_field"`. If omitted, the model primary key(s) are used and must be present in the DataFrame (**PK fallback is unchanged**).
- **`filters=`** is now **constant predicates only** — `"model_field" => value` (e.g. `"category_id" => 172100`, `"points__@in" => [18, 25]`), AND'd onto every row's `WHERE`.
- A per-row match key left in `filters=` is **rejected with a migration error** pointing to `match_on=`.
- A missing `match_on` column now **errors** instead of silently degrading to a static filter.

### How to find the calls to migrate

Run the app's test/integration suite against the new PormG, or grep for the calls. Any legacy call that smuggled a `"df_col" => "field"` match key through `filters=` now throws:

```text
bulk_update: `filters=` no longer accepts per-row match keys (DEPRECATED API).
"df_raceid" => "raceid" references a DataFrame column, so it is a match key — move it to `match_on=`.
`filters=` is now for constant predicates only.

  Change:  filters  = ["df_raceid" => "raceid"]
  To:      match_on = ["df_raceid" => "raceid"]
```

### Migrate your app

Move the row-matching keys out of `filters=` and into `match_on=`; keep only constant predicates in `filters=`.

```julia
# ✗ before — per-row match key smuggled into filters=
M.Result.objects.bulk_update(df;
    columns = ["new_points" => "points"],
    filters = ["df_raceid" => "raceid"],     # df column → field: this is a match key
)

# ✓ after — match_on= for the row key; filters= holds only constant predicates
M.Result.objects.bulk_update(df;
    columns  = ["new_points" => "points"],
    match_on = ["df_raceid" => "raceid"],    # match Result.raceid = source.df_raceid
    filters  = ["statusid" => 1],            # constant predicate (optional)
)
```

Calls that matched **only on the primary key** (no dynamic key in `filters=`) need **no change** — PK fallback still applies when `match_on=` is omitted:

```julia
# unchanged — PK present in df, no match_on needed
M.Result.objects.bulk_update(df; columns = ["points"])
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
