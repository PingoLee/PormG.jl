## A date or time transform over a column of the wrong type is refused when the query is built (#955)

- **Version**: Unreleased
- **PormG ref**: #955 ; `src/querybuilder/select_nodes.jl` (the check, called from `_render_function_body`). #1070 replaced its transform tag with a table keyed by part, which also checks `Extract` — see that entry
- **Recorded**: 2026-10-08
- **Severity**: behavior. A transform over a column of the wrong type now raises `QueryBuildError` when the query is built. Before, it failed on PostgreSQL, and on SQLite it answered from the column's text, which for a `CharField` of ISO dates was the right answer.

### What changed

Nothing checked a transform's column before. `"surname__@month"` built, and PostgreSQL rejected the
statement when it ran. SQLite's `strftime` read whatever the text held: NULL for a surname, but the
right month for a `CharField` that stores ISO dates (`'2024-03-15'`). That query worked on SQLite
only, and it is refused now too. `@hour` over a plain `DateField` returned `0` on SQLite, and
PostgreSQL 14+ rejected it (`unit "hour" not supported for type date`).

Each transform now checks the model field it reads, in `values()`, `filter()` and `order_by()`
alike, through both the string and the `F(...)` spelling:

| transform | column it reads |
|---|---|
| `@hour`, `@minute`, `@second` | `DateTimeField`, `TimeField` |
| `@year`, `@month`, `@day`, `@date`, `@quarter`, `@quadrimester`, `@week`, `@week_day`, `@iso_week_day`, `@iso_year`, `@yyyy_mm`, `@yyyy_q`, `@yyyy_quad` | `DateField`, `DateTimeField` |

| call | before | after |
|---|---|---|
| `filter("surname__@month" => 3)` | built; failed on PostgreSQL, matched nothing on SQLite | `QueryBuildError` naming `surname` and `CharField` |
| `values("h" => "date__@hour")` on a `DateField` | `0` on SQLite, an error on PostgreSQL | `QueryBuildError` |
| `values("w" => "time__@week")` on a `TimeField` | engine-dependent | `QueryBuildError` |
| `values("h" => "lap__@hour")` on a `DurationField` | the interval's hours on PostgreSQL; on SQLite the text read as a clock (NULL from 24 hours) | `QueryBuildError`, and since #1070 `Extract("lap", "hour")` too |
| `filter("logged_on__@month" => 3)` on a `CharField` holding ISO dates | correct on SQLite, an error on PostgreSQL | `QueryBuildError` |

Unchanged: these all pass through without a check.
- A transform over a column PormG cannot name a field for: an expression, a subquery, or an untyped CTE column.
- A transform over a relation (`raceid__@year`). Its value is the related key.
- The public `Extract` and `ToChar` functions were left unchecked here. #1070 checks `Extract` by the same rule, as part of the same train: see its entry.

### Who this affects

Code that applies a date or time transform to a column that is not a date, a timestamp or (for the
time parts) a time of day. On PostgreSQL each such query already failed when it ran.

### How to find the calls to migrate

```bash
grep -rnE '__@(year|month|day|date|quarter|quadrimester|week|week_day|iso_week_day|iso_year|yyyy_mm|yyyy_q|yyyy_quad|hour|minute|second)\b' --include=*.jl src/ test/
```

For each hit, check the type of the field before the `__@` in its model. Running the query is the
definitive check: the refusal names the column, its type and the date part, and cites #1070.

### Migrate your app

```julia
# ✗ before — a text column holding ISO dates: PostgreSQL rejected it, SQLite answered from the text
M.Event.objects.filter("logged_on__@month" => 3)        # logged_on = CharField()
# ✓ after — declare the column as the date it holds (a schema migration), or compare the text itself
M.Event.objects.filter("logged_on__@startswith" => "2024-03")

# ✗ before — a date has no hour: 0 on SQLite, an error on PostgreSQL
M.Race.objects.values("h" => "date__@hour")
# ✓ after — read the hour from the timestamp column
M.Race.objects.values("h" => "start_at__@hour")
```
