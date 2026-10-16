## Ordering or aggregating a duration CTE column uses its length on SQLite, not its text (#1285)

- **Version**: Unreleased
- **PormG ref**: #1285 ; `src/querybuilder/expression_render.jl` (`_is_bare_column`, `_interval_ms_candidate`), `src/querybuilder/build_select.jl` (`_orders_as_sqlite_interval`)
- **Recorded**: 2026-10-16
- **Severity**: behavior change, SQLite only. Ordering by a CTE column that holds a duration can return the rows in another order, and an aggregate over one can return another value. PostgreSQL is unchanged.

### What changed

SQLite stores a duration as text (`HH:MM:SS[.sss]`), and a CTE body leaves one as its text too. That
text sorts wrongly at 100 hours and above (`"100:00:00"` sorts before `"99:00:00"`) and for negative
durations. A model `DurationField` has been ordered and aggregated by its milliseconds since #894 and
#900, and #1219 made a filter on the CTE column compare milliseconds. Ordering by the CTE column and
aggregating over it still used the text.

Both now convert the CTE column to milliseconds once, as the model column does:
- `order_by` on the column, projected or not, in every spelling: `"r__fast"`, `"-r__fast"`,
  `CTE("r", "fast"; desc = true)`, an `SQLOrder` entry, and a path on through a CTE key column to a
  related model's `DurationField`;
- `Max`, `Min`, `Sum`, `Avg`, `Greatest`, `Least` and `Coalesce` over it. The result is the
  duration, read back as a `Dates.CompoundPeriod`, where `Max`/`Min` picked by the text and
  `Sum`/`Avg` added up the text's leading hours.

Examples on `Result`, whose `fastestlaptime` is a `DurationField`, under
`q.with("r" => body, join_field = "raceid" => "raceid")`, where the body projects
`"fast" => Sum("fastestlaptime")` and the totals are 99 h, 120 h and -1 h:

| call | SQLite before | SQLite now |
|---|---|---|
| `order_by("r__fast")` | `ORDER BY "R1_1"."fast"`: -1 h, 120 h, 99 h (text order) | the column's milliseconds: -1 h, 99 h, 120 h |
| `values("m" => Max(CTE("r", "fast")))` | `99 hours`, the text's maximum | `120 hours` |
| `values("m" => Sum(CTE("r", "fast")))` | `218`, the sum of the leading hours | `218 hours` |

### Who this affects

On SQLite, code that orders by a CTE column holding a duration, or aggregates over one, where a value
is 100 hours or longer, or negative. Shorter non-negative values were already sorted the same way by
their text, so their order does not change, and neither does `Max`/`Min` over them. `Sum` and `Avg`
change for every value, because they summed the text's leading hours.

### How to find the calls to migrate

```bash
grep -rnE '\.with\(|CTE\(' --include=*.jl src/ test/
```

For each CTE, check whether a column holds a duration and whether an `order_by` or an aggregate reads
it.

### Migrate your app

```julia
# Before: on SQLite a total of 120 h sorted below 99 h, and Sum returned whole hours as a number
# Now: ordered and summed by length, as on PostgreSQL; no change is needed to get PostgreSQL's rows
body = M.Result.objects
body.values("raceid", "fast" => Sum("fastestlaptime"))
q = M.Result.objects
q.with("r" => body, join_field = "raceid" => "raceid")
q.values("raceid", "r__fast")
q.order_by("-r__fast")
```
