## `@yyyy_q` / `@yyyy_quad` — a NULL date gives a NULL label on PostgreSQL, not `"-Q"` (#997)

- **Version**: Unreleased
- **PormG ref**: #997 ; `src/querybuilder/functions.jl` (`Y_Q`, `Y_QUAD`), `src/Dialect.jl` (`CONCAT`), `src/querybuilder/build_helpers.jl` (the #972 `@isnull` refusal removed; `_is_null_propagating_label` licenses `IS NULL` on the label)
- **Recorded**: 2026-10-07
- **Severity**: behavior change. On PostgreSQL, `"date__@yyyy_q"` and `"date__@yyyy_quad"` read `missing` for a row whose date is NULL, where they read the partial label `"-Q"`. SQLite already returned NULL, so nothing changes there. `"date__@yyyy_q__@isnull"` and `"date__@yyyy_quad__@isnull"` build now, where they raised `FilterError`.

### What changed

Both labels render a concatenation of the year, the `-Q` separator and the period. PostgreSQL's
`CONCAT` skips a NULL argument, so a NULL date dropped the year and the period and kept the
separator. SQLite's `||` propagates the NULL. The labels now join with `||` on PostgreSQL too, so a
NULL date gives a NULL label on both engines, as every other date transform does. The `@isnull`
refusal added in #972 existed only because of this divergence, and is gone.

The public `Concat` function is not changed by this entry. It still renders `CONCAT(…)` on
PostgreSQL; its NULL handling on SQLite is the #1006 entry's.

| PostgreSQL, a race with no sprint | before | after |
|---|---|---|
| `values("q" => "sprint_date__@yyyy_q")` | `"-Q"` | `missing` |
| `filter("sprint_date__@yyyy_q__@isnull" => true)` | `FilterError` | the races with no sprint |

### Who this affects

Code on PostgreSQL that reads a label over a nullable date and treats `"-Q"` as the "no date"
marker: a comparison against `"-Q"`, or a group keyed on it. Measured on 2026-10-07: **0** call sites
in the consuming apps use `@yyyy_q`, `@yyyy_quad`, `@quarter` or `@quadrimester`.

### How to find the calls to migrate

```bash
grep -rnE '@yyyy_q|@yyyy_quad|"-Q"' --include=*.jl src/ test/
```

Read each hit whose date column is nullable.

### Migrate your app

```julia
# before — PostgreSQL only: a NULL date read as "-Q"
no_sprint = filter(r -> r[:q] == "-Q", M.Race.objects.values("raceid", "q" => "sprint_date__@yyyy_q").list())

# after — the label is NULL on both engines
no_sprint = filter(r -> ismissing(r[:q]), M.Race.objects.values("raceid", "q" => "sprint_date__@yyyy_q").list())
# or ask the database: M.Race.objects.filter("sprint_date__@isnull" => true)
```
