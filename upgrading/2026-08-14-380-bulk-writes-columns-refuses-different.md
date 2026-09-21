## Bulk writes — `columns=` refuses two different source columns for one model field (#380)

- **Version**: 0.5.0
- **PormG ref**: #380; `src/querybuilder/execution_bulk.jl`, `docs/src/write/bulk.md`
- **Recorded**: 2026-08-14
- **Severity**: **behavior change (narrow)** — a `columns=` list that names the same model field twice
  from *different* `DataFrame` columns now raises `QueryBuildError` where it used to run. Runtime, not
  compile-time: the call only fails once it executes. Exact repeats are unaffected. Part of the
  `0.5.x` wave.

### What changed

`columns=` accepted two entries claiming the same model field from different source columns, and
resolved the conflict by last-wins. One of the two columns you named was dropped without a word, and
*which* one survived depended on list position — so reordering the list silently changed what got
written. It was the only `columns=` mistake the loop swallowed: a source column that does not exist
is a hard error, and one differing only in case is a hard error with a paste-ready hint.

The rule now is:

> **A model field may not be claimed from two different source columns.**

It applies identically to `bulk_insert()`, `bulk_copy()` and `bulk_update()`, which share the same
column-resolution helper.

**An unambiguous repeat is still legal**, because nothing is being chosen between and nothing is
lost — `["c1" => "laps", "c1" => "laps"]`, and a bare `"laps"` alongside `"laps" => "laps"`, both
still run. So does a bare `"laps"` the frame has no column for paired with an explicit
`"c2" => "laps"`: the bare string names a field that may be auto-populated later and claims no source
at all, so the Pair is the only claim on frame data.

### How to find the calls to migrate

It announces itself — the error is hard and names the field and both offending columns
(*"the field `laps` is mapped from two different columns in `columns=`: `c1` and `c2`"*), so running
the app or its tests surfaces every affected call. To pre-audit instead, enumerate the call sites and
check each list's right-hand sides for a repeat:

```bash
# Every bulk call that passes an explicit column list
rg -n --glob '**/*.jl' '\b(bulk_insert|bulk_copy|bulk_update)\s*\(' -A 4 | rg 'columns\s*='
```

Literal lists can be read off directly. Pay attention to lists built programmatically (`columns =
col_update`, a `vcat`, a comprehension), which is where a duplicate target arrives unnoticed — this
one-liner reports it for a list you already have in hand:

```julia
targets = [c isa Pair ? c.second : c for c in columns]
duplicated = [t for t in unique(targets) if count(==(t), targets) > 1]
```

A field in `duplicated` is only a problem when its entries name *different* sources; an exact repeat
still runs.

### Migrate your app

```julia
# Stint = Models.Model("stint",
#     driver = Models.CharField(),
#     laps   = Models.IntegerField(default = 0))

df = DataFrames.DataFrame(driver = ["Senna"], c1 = [61], c2 = [45])

# ✗ before — ran, wrote laps = 45 (c2 won because it came last); reordering wrote 61 instead
bulk_insert(M.Stint.objects, df, columns = ["driver", "c1" => "laps", "c2" => "laps"])

# ✓ after — keep the one you meant
bulk_insert(M.Stint.objects, df, columns = ["driver", "c2" => "laps"])
```

If both columns genuinely carry data you want, they belong in two different fields — or combine them
in the `DataFrame` first (`df[!, :laps] = coalesce.(df.c1, df.c2)`) and map that one column.
