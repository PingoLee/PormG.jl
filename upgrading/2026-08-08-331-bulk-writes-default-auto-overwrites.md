## Bulk writes — a `default` / `auto_now` no longer overwrites a blank cell in a column the DataFrame carries (#331)

- **Version**: 0.4.0
- **PormG ref**: #331; `src/querybuilder/execution_bulk.jl`
- **Recorded**: 2026-08-08
- **Severity**: **behavior change** — persisted values can differ, and a `null=false` column can now
  raise where the write used to succeed. Part of the `0.4.x` wave.

### What changed

`create()` and the bulk paths disagreed about what an explicit "no value" meant on a field carrying a
static `default`. `create()` honored it and stored `NULL`; `bulk_insert` / `bulk_copy` / `bulk_update`
rewrote the cell with the default. There was no spelling of `NULL` that survived, so the two insert
paths were not substitutable: swapping a `create()` loop for one `bulk_insert` silently changed what
was stored.

There is now one rule, shared by all three bulk operations:

> **For a field the write touches, PormG supplies a value only when the `DataFrame` has no column
> for it. A column that *is* present is caller-authored data, and PormG never rewrites its cells.**

That covers every fill kind — a static `default`, `auto_now`, `auto_now_add`, and a UUID `auto_add` —
on `:insert`, `:copy` and `:update` alike, nullable or not. Four consequences:

- A blank cell (`missing`/`nothing`) in a present, **nullable** defaulted or auto column now persists
  as SQL `NULL` instead of the fill value. On `bulk_update` that turns what used to be a silent no-op
  — writing the default back over the live value — into an actual null-out.
- A blank cell in a present **`null=false`** defaulted or auto column now raises `InvalidValueError`
  (*"null values are not allowed"*) — PormG's own validation naming the field, not a database
  constraint error, and nothing is persisted (the write is wrapped in a transaction, so a row that
  fails part-way rolls back the chunks already sent). That is the same error `create()` has always
  raised for an explicit `"field" => nothing`.
- A blank cell in a `match_on` key column is no longer back-filled from that field's `default`. Match
  keys are exempt from the per-row null check, so this changes **which rows are updated** rather than
  raising: a row keyed on a blank no longer merges into the default-valued row by accident.
- A `UUIDField(auto_add = true)` **primary key** carried in the frame with blank cells now raises
  instead of being minted in place. The old behavior was not usable anyway — it reused a single UUID
  for every row in the batch, so any multi-row insert violated the key. **Fill the column yourself**
  — `df[!, :token] = [UUIDs.uuid4() for _ in 1:DataFrames.nrow(df)]` — which works precisely because
  a present column is now honored verbatim. Do **not** drop the column instead: the absent path
  currently mints one UUID for the whole batch (#334), so a multi-row insert collides on the key.
  (The all-blank-means-absent rescue applies to `auto_increment` primary keys only; it does not
  cover UUID ones.)

**Absent columns are unchanged.** A defaulted or auto column the `DataFrame` does not carry is still
injected exactly as before — including that `bulk_update(..., columns = [...])` does not synthesize a
static `default`, and that an all-blank auto-increment primary key column still counts as absent.

**A field you leave out of `columns=` is also unchanged.** It is out of scope by your own
instruction, so its cells are not read from the frame even when the frame carries them; on
`bulk_insert`/`bulk_copy` PormG still supplies its default, which is what keeps a partial `columns=`
insert satisfying the model's `null=false` fields.

### How to find the calls to migrate

The `null=false` half announces itself: run the app or its tests and the new `InvalidValueError` names
the model and the field. The nullable half is silent, so grep for it:

```bash
# 1. Which of your models declare a fill? Only these fields are affected.
rg -n --glob '**/models*.jl' 'default\s*=|auto_now(_add)?\s*=\s*true|auto_add\s*=\s*true'

# 2. Which files build a DataFrame for a bulk write AND can produce blanks?
rg -l '\b(bulk_insert|bulk_copy|bulk_update)\s*\(' \
  | xargs rg -n 'missing|nothing|CSV\.(File|read)|allowmissing'
```

Cross-check each hit's column list against the field names from step 1. A CSV import is the common
case: an empty cell parses to `missing`, so a column that was silently receiving the model default now
receives `NULL` — or raises, if the field is `null=false`.

### Migrate your app

```julia
# Stint = Models.Model("stint",
#     driver    = Models.CharField(),
#     laps      = Models.IntegerField(default = 0),               # null = false
#     note      = Models.CharField(default = "", null = true))

df = DataFrames.DataFrame(
    driver = ["Senna", "Prost"],
    laps   = [missing, 71],      # ✗ before: stored 0 and 71
    note   = [missing, "wet"],   # ✗ before: stored "" and "wet"
)

# ✗ before — the blanks silently became the model defaults
bulk_insert(M.Stint.objects, df)

# ✓ after, option A — you WANTED the default: write it yourself, explicitly.
df[!, :laps] = coalesce.(df.laps, 0)
df[!, :note] = coalesce.(df.note, "")
bulk_insert(M.Stint.objects, df)

# ✓ after, option B — you wanted PormG to supply it: drop the column.
#   An ABSENT column is still filled from the model default, exactly as before.
bulk_insert(M.Stint.objects, DataFrames.select(df, DataFrames.Not([:laps, :note])))

# ✓ after, option C — you wanted NULL: change nothing. That is now what the nullable
#   `note` stores, matching what create() always gave you. On the null=false `laps`
#   it is now an InvalidValueError instead of a silent 0 — fix that one with A or B.
```
