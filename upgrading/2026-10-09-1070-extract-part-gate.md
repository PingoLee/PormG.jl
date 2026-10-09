## `Extract` is checked like the `__@` transforms, and every date part's filter value is range-checked (#1070)

- **Version**: Unreleased
- **PormG ref**: #1070 ; `src/querybuilder/functions.jl` (`_EXTRACT_PART_ROWS`, `Extract`), `src/querybuilder/select_nodes.jl` (`_check_temporal_operand`), `src/Models.jl` (`format_month_sql`, `format_day_sql`, `format_dow_sql`, `format_doy_sql`)
- **Recorded**: 2026-10-09
- **Severity**: behavior. An `Extract` part over a column it cannot read now raises `QueryBuildError` when the query is built, on both engines. A filter value outside a date part's range now raises `InvalidValueError` where it used to match nothing.

### What changed

#955 checked a date transform's column, but only for the `"col__@hour"` spelling: it tagged the
nodes the `__@` ladder built and checked the tagged ones. `Extract("date", "HOUR")` builds the same
expression and was not checked, so it still answered `0` on SQLite while PostgreSQL refused the
statement. The value range had the same gap: it came from the formatter each ladder constructor
picked, so `"start_at__@hour" => 25` was refused while an `Extract` alias filtered with `25` was not,
and `@month` and `@day` had no range at all.

The rule now lives on the part. A transform is shorthand for `Extract`, so both spellings are
checked against the same table, with the same message, and get the same range:

| part | column it reads | filter value |
|---|---|---|
| `HOUR`, `MINUTE`, `SECOND`, `MILLISECONDS`, `MICROSECONDS` | `DateTimeField`, `TimeField` | `HOUR` 0–23, `MINUTE`/`SECOND` 0–59 |
| `TIMEZONE`, `TIMEZONE_HOUR`, `TIMEZONE_MINUTE` | `DateTimeField` | — |
| `EPOCH` | `DateField`, `DateTimeField`, `TimeField`, `DurationField` | — |
| `MONTH`, `DAY`, `DOW`, `DOY` | `DateField`, `DateTimeField` | 1–12, 1–31, 0–6, 1–366 |
| `QUARTER`, `WEEK`, `ISODOW` | `DateField`, `DateTimeField` | 1–4, 1–53, 1–7 |
| every other part (`YEAR`, `ISOYEAR`, `CENTURY`, …) | `DateField`, `DateTimeField` | — |

| call | before | after |
|---|---|---|
| `values("h" => Extract("date", "HOUR"))` on a `DateField` | `0` on SQLite, an error on PostgreSQL | `QueryBuildError` on both |
| `values("h" => Extract("lap", "HOUR"))` on a `DurationField` | the interval's hours on PostgreSQL; on SQLite the text read as a clock | `QueryBuildError`; `Extract("lap", "EPOCH")` still builds |
| `values("y" => Extract("name", "YEAR"))` on a `CharField` | an error on PostgreSQL; on SQLite the text's year, if it held one | `QueryBuildError` |
| `filter("date__@month" => 13)` | matched nothing | `InvalidValueError` |
| `filter("date__@day" => 32)` | matched nothing | `InvalidValueError` |
| `values("h" => Extract("start_at", "HOUR")); filter("h" => 25)` | matched nothing | `InvalidValueError` |

A refusal names the part rather than the spelling: "The `hour` part reads a time of day, …", and a
refused filter value is located on "the `start_at` hour part" instead of "the `start_at` @hour
transform". Code that matches on that text needs the new wording.

Unchanged: an operand PormG cannot name a field for (an expression, a subquery, an untyped CTE
column) still passes through without a check. A relation (`raceid__@year`) is checked against the
key it holds, by #1068 in the same train: see that entry. `ToChar` is checked
only for the `"YYYY-MM"` mask `@yyyy_mm` uses. Arithmetic over a part is an ordinary number:
`Extract("start_at", "HOUR") + 1` has no range.

### Who this affects

- Code that calls `Extract` with a part its column cannot hold: a time-of-day part over a date, a
  calendar part over a time or a duration, or any part over a text or number column. On PostgreSQL
  each of these already failed when it ran, so the change moves the failure to build time and
  makes SQLite agree.
- Code that filters a date part with a value outside its range, which matched no row before.

### How to find the calls to migrate

```bash
grep -rnE 'Extract\(' --include=*.jl src/ test/
grep -rnE '__@(month|day)(__@[a-z]+)?"\s*=>' --include=*.jl src/ test/
```

For an `Extract`, check the part against the column's field type in the table above. For a
`@month` or `@day` filter, check whether the value can come from outside the range (user input, a
computed value). Running the query is the definitive check: the refusal names the part, the column
and its type, and cites #1070.

### Migrate your app

```julia
using PormG.Functions: Extract

# ✗ before — a date has no hour: 0 on SQLite, an error on PostgreSQL
M.Race.objects.values("h" => Extract("date", "HOUR"))
# ✓ after — read the hour from the timestamp column
M.Race.objects.values("h" => Extract("start_at", "HOUR"))

# ✗ before — a month taken from a request, which can be out of range: matched nothing
M.Race.objects.filter("date__@month" => month)
# ✓ after — validate it first, or catch the refusal
1 <= month <= 12 || throw(ArgumentError("month must be 1 to 12"))
M.Race.objects.filter("date__@month" => month)
```
