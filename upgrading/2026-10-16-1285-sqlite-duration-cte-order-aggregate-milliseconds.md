## Ordering or aggregating a duration CTE column uses its length on SQLite, not its text (#1285)

- **Version**: 0.9.0
- **PormG ref**: #1285 ; `src/querybuilder/expression_render.jl` (`_is_bare_column`, `_interval_ms_candidate`), `src/querybuilder/build_select.jl` (`_orders_as_sqlite_interval`)
- **Recorded**: 2026-10-16
- **Severity**: behavior change, SQLite. Ordering by a CTE column that holds a duration can return the rows in another order, an aggregate over one can return another value, and a filter on such an aggregate's alias can return other rows. PostgreSQL renders the same SQL; one read type changes there (below).

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
  `Sum`/`Avg` added up the text's leading hours as a float;
- a filter on such an aggregate's alias (`"m__@gt" => Hour(99)` over `"m" => Max(CTE("r", "fast"))`,
  a `HAVING`), which compared the text with the value's text, and binds milliseconds now;
- arithmetic over such an aggregate, as over the model column's (#907): `Sum(CTE(…)) / Count(…)`
  returned a float of hours and is a duration now, and `Max(CTE(…)) - Min(CTE(…))`, which was
  refused, now builds;
- a `Cast` of such an aggregate to text, whose value is now the true maximum, not the text's.

Examples on `Result`, whose `fastestlaptime` is a `DurationField`, under
`q.with("r" => body, join_field = "raceid" => "raceid")`, where the body projects
`"fast" => Sum("fastestlaptime")` and the totals are 99 h, 120 h and -1 h:

| call | SQLite before | SQLite now |
|---|---|---|
| `order_by("r__fast")` | `ORDER BY "R1_1"."fast"`: -1 h, 120 h, 99 h (text order) | the column's milliseconds: -1 h, 99 h, 120 h |
| `values("m" => Max(CTE("r", "fast")))` | `99 hours`, the text's maximum | `120 hours` |
| `values("m" => Sum(CTE("r", "fast")))`, one `Result` row per race | `218.0`, the sum of the leading hours | `218 hours` |
| `values("raceid", "m" => Max(CTE("r", "fast"))); filter("m__@gt" => Hour(100))` | `HAVING MAX("R1_1"."fast") > ?` with `"100:00:00"`: the 99 h and 120 h rows (text order) | milliseconds with `360000000`: the 120 h row |
| `values("m" => Sum(CTE("r", "fast")) / Count("raceid"))` | `72.666…`, hours as a float | `72 hours, 40 minutes` |
| `values("m" => Max(CTE("r", "fast")) - Min(CTE("r", "fast")))` | `QueryBuildError` | `121 hours` |

**PostgreSQL** renders the same SQL. Arithmetic over a `Sum` or `Avg` of a CTE duration column
(`Sum(CTE(…)) / Count(…)`, `Avg(CTE(…)) * 2`) is now typed as a duration, as over the model column
(over `Max`/`Min` it already was), so the Postgres.jl
driver hands back a `Dates.CompoundPeriod` where it handed back a bare `Period` for a one-component
interval. LibPQ already delivered a `CompoundPeriod`.

### Who this affects

On SQLite, code that orders by a CTE column holding a duration, or aggregates over one, where a value
is 100 hours or longer, or negative. Shorter non-negative values were already sorted the same way by
their text, so their order does not change, and neither does `Max`/`Min` over them. A filter on such
an aggregate's alias also changes when the filter's own value is 100 hours or longer, or negative
(`"m__@gt" => Hour(100)` matched a 99 h row as text). `Sum` and `Avg`, and arithmetic over them, change for every value, because they summed the text's
leading hours. On PostgreSQL with the Postgres.jl driver, code that reads such arithmetic as a bare
`Period` now gets a `Dates.CompoundPeriod`.

### How to find the calls to migrate

```bash
grep -rnE '\.with\(|CTE\(' --include=*.jl src/ test/
```

For each CTE, check whether a column holds a duration and whether an `order_by`, an aggregate, a
filter on the aggregate's alias, or arithmetic over it reads it.

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
