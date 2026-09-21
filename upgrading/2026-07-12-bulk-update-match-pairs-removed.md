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
