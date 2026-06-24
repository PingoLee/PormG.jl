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
