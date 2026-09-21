## `bulk_update` — a `match_on` key PormG would auto-populate is refused, not bound (#379)

- **Version**: 0.5.0
- **PormG ref**: #379; `src/querybuilder/execution_bulk.jl`, `docs/src/write/bulk.md`,
  `docs/src/api.md`
- **Recorded**: 2026-08-21
- **Severity**: **behavior change (narrow)** — a `bulk_update()` whose `match_on=` (or primary-key
  fallback) names a field PormG auto-populates, and for which the `DataFrame` supplies **no** source
  column, now raises `UnknownFieldError` where it used to run. Runtime, not compile-time. Every other
  `match_on` shape is unaffected, and the call it refuses was already a **silent no-op**. Part of the
  `0.5.x` wave.

### What changed

A merge key was resolved mapping-first, and since #335 PormG's own injected fill values also write
that mapping. So a key naming a field `columns=` left out of scope — an `auto_now` timestamp, a
defaulted primary key — bound the value PormG had just minted for it instead of the caller's
same-named `DataFrame` column. The `UPDATE` compared every row against one per-call constant,
matched nothing, and **returned success**. No warning, no error.

Two rules replace it:

> **A column you supplied outranks a value PormG auto-populates. A `columns=` mapping you declared
> outranks both.**
>
> **A merge key must come from your data.** With no caller source at all, PormG raises instead of
> matching on a per-call constant.

The first is a **fix** and forces nothing: a call that reads your column now matches the rows it
always should have. The second is what can force an edit. It reaches the primary-key fallback
through the same helper, so an auto-populated pk absent from the frame raises too.

Also newly documented, though unchanged: a match key is **matched, never written** — it stays out of
the `SET` clause, so an `auto_now` field used as a key is not refreshed by that call.

### How to find the calls to migrate

It announces itself — the error names the field, says which fill kind would have supplied it, and why
that cannot be a key — so running the app or its tests surfaces every affected call. To pre-audit,
list the `match_on=` keys (plus the pk of any `bulk_update` without one) and check each against the
frame the call passes:

```bash
# Every bulk_update, with enough context to read its match_on= and columns=
rg -n --glob '**/*.jl' '\bbulk_update\s*\(' -A 6
```

A key is at risk only when **both** hold, and the second narrows the set sharply:

1. neither a same-named frame column nor a `columns=` Pair supplies the key, **and**
2. PormG would actually fill that field *on an update*. That is narrower than "the field has a
   default": it means `auto_now` on a `DateTimeField`/`DateField`, or a static `default` **only when
   `columns=` is omitted** — an explicit `columns=` already suppresses static defaults on `:update`,
   so a defaulted field under one raised the *generic* "column not found" error before this change
   too. `auto_now_add` alone never fills on an update, and a UUID `auto_add` fills only on
   insert/copy; neither can reach this.

Where the frame is built dynamically, the cheapest check is the call itself — the raise is exact and
immediate.

### Migrate your app

```julia
# Lap = Models.Model("lap",
#     id         = Models.IDField(),
#     points     = Models.IntegerField(null = true),
#     updated_at = Models.DateTimeField(auto_now = true, null = true))

df = DataFrames.DataFrame(new_points = [9], updated_at = ["1999-01-01T00:00:00"])

# ✓ FIXED, no edit needed — before: bound the auto_now stamp and matched 0 rows, silently.
#   Now: binds your 1999 column and matches the rows you meant.
bulk_update(M.Lap.objects, df, columns = ["new_points" => "points"], match_on = ["updated_at"])

df_no_key = DataFrames.DataFrame(new_points = [9])          # no updated_at column at all

# ✗ before — ran, matched 0 rows, reported success
bulk_update(M.Lap.objects, df_no_key, columns = ["new_points" => "points"],
                                      match_on = ["updated_at"])

# ✓ after — supply the key's values from your data...
df_with_stamps = DataFrames.DataFrame(new_points = [9], updated_at = ["1999-01-01T00:00:00"])
bulk_update(M.Lap.objects, df_with_stamps, columns = ["new_points" => "points"],
                                           match_on = ["updated_at"])

# ...or map a differently-named column onto it...
df_stamp_col = DataFrames.DataFrame(new_points = [9], stamp = ["1999-01-01T00:00:00"])
bulk_update(M.Lap.objects, df_stamp_col, columns = ["new_points" => "points",
                                                    "stamp" => "updated_at"],
                                         match_on = ["updated_at"])

# ...or, if `updated_at` was meant as a constant scope rather than a per-row key, move it to
# filters= AND name a real per-row key. Dropping it from match_on= alone is not enough: match_on=
# then falls back to the primary key, so the frame still has to carry a key column.
df_scoped = DataFrames.DataFrame(id = [42], new_points = [9])
bulk_update(M.Lap.objects, df_scoped, columns = ["new_points" => "points"],
                                      match_on = ["id"],
                                      filters  = ["updated_at" => "1999-01-01T00:00:00"])
```

For the primary-key fallback the escapes are the same, minus `filters=` — a constant predicate on
the pk still leaves no per-row key. Supply the pk column, map one in `columns=`, or name a different
key in `match_on=`.

**One adjacent failure also changes shape.** A match-key column whose values the field's formatter
rejects — an `Int` or `Float` where a timestamp is wanted, or a string the field cannot parse — now
raises `InvalidValueError` where the old code bound the fill and "succeeded" as a no-op. (A *valid*
timestamp string is fine and is what every example above passes; `DateTimeField` parses it.) That is
the same defect surfacing rather than a new one, and the fix is the same: give the key column values
the field can actually read.
