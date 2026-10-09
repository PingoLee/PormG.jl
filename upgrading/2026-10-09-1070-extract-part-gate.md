## `Extract` is checked like the `__@` transforms, and an exact filter on a date part is range-checked (#1070)

- **Version**: Unreleased
- **PormG ref**: #1070, #1088 ; `src/querybuilder/functions.jl` (`_EXTRACT_PART_ROWS`, `Extract`), `src/querybuilder/select_nodes.jl` (`_check_temporal_operand`), `src/Models.jl` (`format_month_sql`, `format_day_sql`, `format_dow_sql`, `format_doy_sql`, `unranged_formatter`), `src/querybuilder/filter_nodes.jl` (`_format_filter_value`)
- **Recorded**: 2026-10-09
- **Severity**: behavior. An `Extract` part over a column it cannot read now raises `QueryBuildError` when the query is built, on both engines. An `=` or `@in` filter value outside a date part's range now raises `InvalidValueError` where it used to match nothing. Every other lookup binds it as a bound. That relaxes the released `@quarter`/`@quadrimester` check, which refused such a value under every operator.

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
| `TIMEZONE`, `TIMEZONE_HOUR`, `TIMEZONE_MINUTE` | `DateTimeField` with a time zone (not `type = "TIMESTAMP"`) | — |
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
| `values("ym" => ToChar("date", "YYYY-MM")); filter("ym" => "March 2009")` | matched nothing | `InvalidValueError`: not `YYYY-MM`, as `"date__@yyyy_mm"` already refused |
| `values("ym" => ToChar("date", "YYYY-MM")); filter("ym__@startswith" => "2009")` | the 2009 months | `InvalidValueError`, as `"date__@yyyy_mm__@startswith"` already raised; filter `"date__@year" => 2009` instead |
| `values("y" => Extract(F("name"), "YEAR"))` — a bare `F` column | unchecked | checked as the column `name`: `QueryBuildError` |
| `values("h" => Coalesce("start_at__@hour", -1)); filter("h" => -1)` | `InvalidValueError`: the hour's range applied to the fallback | builds: a `Coalesce` keeps a number, not the part's range |
| `filter("date__@quarter__@lt" => 5)`, `filter("date__@quarter__@range" => [1, 5])` | `InvalidValueError`, for every operator | builds: a comparison's value and a range's ends are bounds (#1088) |
| `filter("date__@month__@lt" => 13)`, `filter("start_at__@hour__@lte" => 24)` | every row | every row, unchanged: only `=` and `@in` are range-checked (#1088) |
| `filter("date__@quarter" => 1.5)` | `InvalidValueError` with `kind = :range` | `InvalidValueError` with `kind = :format`, on every operator (#1088) |

A refusal names the part rather than the spelling: "The `hour` part reads a time of day, …", and a
refused filter value is located on "the `start_at` hour part" instead of "the `start_at` @hour
transform". Code that matches on that text needs the new wording.

Unchanged: an operand PormG cannot name a field for (an expression, a subquery, an untyped CTE
column) still passes through without a check. A relation (`raceid__@year`) is checked against the
key it holds, by #1068 in the same train: see that entry. `ToChar` is checked
only for the `"YYYY-MM"` mask `@yyyy_mm` uses. Arithmetic over a part is an ordinary number, and
so is a `Coalesce`/`Greatest`/`Least`/`NullIf` over one: `Extract("start_at", "HOUR") + 1` has no
range. A comparison written with `F` (`F("date__@month") > 13`) is not range-checked yet (#1083).

The range applies to `=` and `@in` only (#1088). There an out-of-range value can only be a typo,
while for `<`, `<=`, `>`, `>=`, `@range`, `@ne` and `@nin` it is a bound:
`"date__@month__@lt" => 13` matches every row. Django checks no range at all, and both engines
answer an out-of-range value with no rows, so the check is kept only where it catches a mistake. The
value's shape is still checked under every lookup: a `Bool`, a fraction or non-numeric text is
refused whatever the operator. A whole number outside the part is `kind = :range`, and a fraction is
now `kind = :format`.

### Who this affects

- Code that calls `Extract` with a part its column cannot hold: a time-of-day part over a date, a
  calendar part over a time or a duration, or any part over a text or number column. On PostgreSQL
  each of these already failed when it ran, so the change moves the failure to build time and
  makes SQLite agree.
- Code that filters a date part with `=` or `@in` and a value outside its range, which matched no row before.
- Code that relied on a `@quarter`/`@quadrimester` comparison raising for an out-of-range bound, or that matched `kind == :range` for a fractional period value.

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
