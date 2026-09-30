## Rows returned by writes, and `Max`/`Min`/window value projections, read back as the column does (#800)

- **Version**: Unreleased
- **Recorded**: 2026-09-30
- **PormG ref**: #800; `src/querybuilder/execution.jl` (`_row_to_field_keyed_dict`,
  `_field_value_parser`), `src/querybuilder/build_query.jl` (`_function_projection_kind`)
- **Severity**: behavior change, mostly on SQLite. On PostgreSQL only an INTERVAL column changes, and
  only on the Postgres.jl driver.

### What changed

The #564 read table gives a temporal, INTERVAL or narrow `DecimalField` column the same Julia type
on every engine. Before #800 it applied only to a column read through a query. Two more paths now go
through it:

- **The row a write hands back**: `create()` and `update_or_create` on both engines, and
  `get_or_create` when it inserts on PostgreSQL. That row used to carry the driver's raw values, so
  re-reading the same row through a query changed their types. `get_or_create` on SQLite already
  read its row through `first()` and is unchanged.
- **A function that returns one of the column's own values**: `Max` and `Min`, and the window value
  functions `Lag`, `Lead`, `FirstValue`, `LastValue` and `NthValue`. That includes
  `aggregate("m" => Max(...))`.

| Value | before | after |
|---|---|---|
| `DateTimeField` on a written row, SQLite | `String` | `ZonedDateTime` (`DateTime` for a `TIMESTAMP` column) |
| `DateField` / `TimeField` on a written row, SQLite | `String` | `Date` / `Time` |
| `DurationField` on a written row, SQLite | `String` | `Dates.CompoundPeriod` |
| `DecimalField` (≤ 15 digits) on a written row, SQLite | `Float64` | `Decimal` |
| `Max("date")`, `Min("date")`, `Lag("date")`, …, SQLite | `String` | `Date`, and likewise per column kind |
| `Max("duration")` on PostgreSQL via Postgres.jl, or a written row's INTERVAL there | bare `Period` (`Second(23)`) | `Dates.CompoundPeriod` |

A computed value is unchanged: it is not the column, so it still comes back as the engine delivers
it. That covers `Sum`, `Avg`, `Count`, arithmetic, `Coalesce`/`Greatest`/`Least`/`NullIf`, and the
`F("col__@date")` transform. So does a `Max`/`Min` or window value function over a `CTE(...)` or
`Joined(...)` handle, which stays untyped exactly as the handle does when projected on its own.

### How to find the calls to migrate

```bash
# rows a write hands back
grep -rnE '\.(create|update_or_create|get_or_create)\(' src/
# extremum / window value projections, and whole-queryset aggregates
grep -rnE '(Max|Min|Lag|Lead|FirstValue|LastValue|NthValue)\(' src/
# parsing an app did itself because the value arrived as text
grep -rnE '(Date|DateTime|Time|ZonedDateTime)\(\s*(row|r|res|result)[\.\[]|parse\((Date|DateTime|Time|Float64)' src/
```

Only code that parsed the text itself needs an edit. The first two greps list where the types changed.

### Migrate your app

```julia
# before — the created row's date was text on SQLite, so the app parsed it
row = M.Race.objects.create("year" => 2031, "round" => 1, "circuitid" => 1, "name" => "Test GP",
                            "date" => Date(2031, 3, 16), "url" => "")
race_day = Date(row.date)                # `Date(::Date)` still works, so this line is harmless

last_race = M.Race.objects.values("m" => Max("date")).list(:dict)[1][:m]
days = Date(last_race) - Date(2031, 1, 1)   # also harmless now

# after — both are already `Date`s
race_day = row.date
last_race = M.Race.objects.values("m" => Max("date")).list(:dict)[1][:m]

# the one that breaks: string handling of the value
year_text = row.date[1:4]              # before: "2031"; after: MethodError on a Date
year_text = string(year(row.date))     # after
```

To keep the engine's own text on purpose, project it as text, e.g. `values("m" => Max(ToChar("date",
"YYYY-MM-DD")))`, or `Cast(F("date"), "TEXT")` for a column.
