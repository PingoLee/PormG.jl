## `Coalesce`/`Greatest`/`Least`/`NullIf`, the `@date` transform, and `CTE`/`Joined` columns read back as the column does (#824)

- **Version**: Unreleased
- **PormG ref**: #824; `src/querybuilder/build_query.jl` (`_function_projection_kind`,
  `_multi_operand_kind`, `_operand_kind`, `_cte_column_kind`)
- **Recorded**: 2026-10-01
- **Severity**: behavior change, on SQLite. PostgreSQL already delivered these values typed; the
  only change there is the INTERVAL normalization #581 applies, on the Postgres.jl driver.

### What changed

#800 made a function that returns one of the column's own values (`Max`, `Min`, the window value
functions) read back with the column's Julia type on every engine. These projections now follow the
same rule:

- **`Coalesce`, `Greatest`, `Least`** when every argument is of one type: columns with the same
  declaration, or a column and a matching literal (`Coalesce("date", Date(2021, 3, 28))`). A `NULL`
  argument is ignored. Arguments of different types keep the engine's value.
- **`NullIf(a, b)`** takes `a`'s type, because its value is `a`'s.
- **The `@date` transform** (`"start_at__@date"`, `F("start_at__@date")`): a `Date`, on any column.
- **A `Joined(...)` reference** to a column, and `Max`/`Min` over one.
- **A `CTE(...)` column** (`CTE("ev", "col")` or `"ev__col"`), and `Max`/`Min` over one, typed as the
  CTE body projected it. A column the body *selects* (`"date"`, `Max("date")`, `Cast(x, "date")`) is
  typed. A column the body *computes* (`Avg`, `Sum`, `Count`, arithmetic) is unchanged.

| Value, on SQLite | before | after |
|---|---|---|
| `Coalesce("date", "fp1_date")`, `Greatest(…)`, `Least(…)` over date columns | `String` | `Date` |
| the same over `DateTimeField` / `TimeField` / `DurationField` / `DecimalField` (≤ 15 digits) columns | `String` / `Float64` | `ZonedDateTime` / `Time` / `Dates.CompoundPeriod` / `Decimal` |
| `NullIf("date", …)` | `String` | `Date` |
| `"start_at__@date"`, `F("start_at__@date")` | `String` | `Date` |
| `Joined("b2", "date")`, `Max(Joined(…))` | `String` | `Date` |
| `CTE("ev", "date")` / `"ev__date"` where the body selects `date`, and `Max` over it | `String` | `Date` |

The engine's value is unchanged for a computed CTE column (`"ev__avg_points"`) and for a
`Coalesce` whose arguments differ (`Coalesce("date", "name")`, `Coalesce("amount", 0)`).

### How to find the calls to migrate

```bash
# the multi-argument functions, and NullIf
grep -rnE '(Coalesce|Greatest|Least|NullIf)\(' src/
# the @date transform, as a path or inside F(...)
grep -rnE '__@date' src/
# Joined and CTE handles
grep -rnE '(Joined|CTE)\(' src/
# "<cte>__col" paths: list each CTE name passed to .with(...), then grep for "<name>__"
grep -rnE '\.with\(' src/
# parsing an app did itself because the value arrived as text
grep -rnE '(Date|DateTime|Time|ZonedDateTime)\(\s*(row|r|res|result)[\.\[]|parse\((Date|DateTime|Time|Float64)' src/
```

Only code that handled the value as text needs an edit. The first four greps list where the types
changed.

### Migrate your app

```julia
# before — on SQLite the transform's day arrived as text, so the app parsed it
rows = M.Race.objects.filter("year" => 2009).values("raceid", "day" => "start_at__@date").list(:dict)
race_day = Date(rows[1][:day])        # `Date(::Date)` still works, so this line is harmless

# after — already a `Date`
race_day = rows[1][:day]

# the one that breaks: string handling of the value
month_text = rows[1][:day][6:7]                       # before: "03"; after: MethodError on a Date
month_text = lpad(string(month(rows[1][:day])), 2, '0')   # after
```

To keep the engine's own text on purpose, project it as text: `ToChar("start_at", "YYYY-MM-DD")`
for the `@date` transform, or `Cast(Coalesce("date", "fp1_date"), "TEXT")` for a function.
