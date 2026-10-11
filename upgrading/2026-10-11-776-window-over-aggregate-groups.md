## Window functions: a window beside or over an aggregate groups the columns it reads, and SQLite binds a window's own arguments first (#776, #789)

- **Version**: Unreleased
- **PormG ref**: #776, #789, `16fb2ca7` ; `src/querybuilder/types.jl` (`_contains_agg`), `src/querybuilder/build_select.jl` (the GROUP BY decision), `src/querybuilder/select_nodes.jl` (`_get_select_query(::WindowFunction)`)
- **Recorded**: 2026-10-11
- **Severity**: behavior change. Three window shapes return different rows or values on SQLite;
  the two grouping changes also render on PostgreSQL where they used to fail.

### What changed

**A window over an aggregate, beside a plain column (#776).** `Lag(Sum("points"), …)`, or a
`WindowOver(partition_by = [Sum(…)])`, next to a plain column rendered with no `GROUP BY`. SQLite
collapsed the query into **one row** with an arbitrary value in the plain column; PostgreSQL
rejected it. The plain columns are now grouped:

| Query | before | after |
|---|---|---|
| `values("raceid", "prev" => Lag(Sum("points"), over = WindowOver(order_by = ["raceid"])))` on `Result` | SQLite: one row; PostgreSQL: `StatementError` (SQLSTATE `42803`) | one row per race on both engines, `GROUP BY "raceid"` |
| `values("total" => Sum("points"), "r" => Rank(over = WindowOver(order_by = ["raceid"])))` — a column read only inside `OVER (…)` of an aggregating query (#789) | SQLite: one arbitrary row; PostgreSQL: `StatementError` (SQLSTATE `42803`) | the `OVER` columns join `GROUP BY` on both engines (`GROUP BY "raceid"`), so `total` becomes a per-race sum, one row per race |

**A window's own bound arguments come before its `OVER` clause (`16fb2ca7`).** The `OVER (…)` text
was rendered first, so a binding term inside it (a transform such as `partition_by =
["date__@yyyy_q"]`) bound its values ahead of the function's own (`Lag`/`Lead`'s offset and
default, a bound value in the function's column), while the SQL text prints them after. SQLite binds
by position, so every value shifted by one: with the `@yyyy_q` partition, LAG's offset received the
label's `"-Q"`. The values now bind in text order. PostgreSQL was always right; only its `$N`
numbering changes.

### Who this affects

- SQLite code that used a window over an aggregate beside a plain column and read the single row it
  returned.
- SQLite code that projected an aggregate beside a window whose `OVER (…)` names a column, and read
  the grand total from the single row it returned.
- SQLite code that combined `Lag`/`Lead` (or a window over a bound expression) with a transform in
  `partition_by` / `order_by`.
- Golden tests that pin the PostgreSQL `$N` numbering or the parameter order of such a window.

### How to find the calls to migrate

```bash
grep -rnE '(Lag|Lead|FirstValue|LastValue|NthValue|Rank|DenseRank|RowNumber)\(' --include=*.jl . | grep -E 'Sum\(|Count\(|Avg\(|Max\(|Min\(|__@'
```

### Migrate your app

```julia
q = M.Result.objects.
    values("raceid", "prev" => Lag(Sum("points"), over = WindowOver(order_by = ["raceid"])))

# ✗ before — SQLite returned one row; code took first() of it
prev = q.list()[1]["prev"]

# ✓ after — one row per race: index the race you want
rows = q.list()
```
