## `Coalesce`, `Greatest`, `Least`, `NullIf`, `Case` and a `Lag`/`Lead` default refuse mixed date, time and text operands (#1200)

- **Version**: Unreleased
- **PormG ref**: #1200 ; `src/querybuilder/projection_types.jl` (`_temporal_mix`), `src/querybuilder/functions.jl` (`_temporal_mix_refusal`), `src/querybuilder/select_nodes.jl`
- **Recorded**: 2026-10-12
- **Severity**: breaking. An expression that built at v0.7.0 now raises `QueryBuildError` when the query is built, on every engine.

### What changed

Several functions return one of their operands' own values: `Coalesce`, `Greatest`, `Least`,
`NullIf`, a `Case` with no `output_field` (its `then`s and its default), and a `Lag`/`Lead` with a
`default`. When those operands have different temporal types, or a temporal type sits beside text,
the query does not say which type the value has. Each engine then picks its own. With a
`DateField` beside `zdt = ZonedDateTime(DateTime(2021, 1, 1, 0, 30), FixedTimeZone("UTC+2", 7200))`:

| expression | PostgreSQL | SQLite |
|---|---|---|
| `Coalesce("fp1_date", zdt)` | a `ZonedDateTime` on every row | each row's own text: a date, or the UTC timestamp |
| `Coalesce("name", zdt)` | fails at the server (`COALESCE types … cannot be matched`) | text |

These now raise `QueryBuildError` when the query is built, on every engine, as Django refuses them
(`Expression contains mixed types … You must set output_field`). The types are a date, a timestamp
without a time zone, a timestamp with one, a time, an interval, and text. A `DateTimeField` is a
timestamp with a time zone unless it is declared `type = "TIMESTAMP"`, so a plain `DateTime` beside
one is a mix too.

| before (built) | after |
|---|---|
| `Coalesce("fp1_date", zdt)`, and the same in `Greatest`, `Least`, `NullIf` | `QueryBuildError` |
| `Case(When(…, then = F("date")), default = zdt)` | `QueryBuildError` |
| `Lag("date"; default = zdt, over = …)`, and `Lead` | `QueryBuildError` |
| `Coalesce("date", "start_at")`, a `DateField` and a `DateTimeField` | `QueryBuildError` |
| `Coalesce("start_at", DateTime(2021, 1, 1))`, a zoned column and a naive literal | `QueryBuildError` |
| `Case(When(…, then = Value(zdt)), default = Value(DateTime(…)))` | `QueryBuildError` |
| `Coalesce("name", zdt)`, `Coalesce("positiontext", "fastestlaptime")`, text beside a temporal value | `QueryBuildError` |
| `Coalesce("raceid__time", "fastestlaptime")`, a time and an interval; `Coalesce("date", "fp1_time")`, a date and a time | `QueryBuildError` |

Unchanged: operands of one temporal type (`Coalesce("fp1_date", "date")`,
`Coalesce("start_at", zdt)`); any of these with an `output_field`; an operand PormG cannot type
(timestamp arithmetic, a JSON key lookup) beside a typed one; NULLs; and numbers beside numbers,
which #1150 normalizes.

### Who this affects

Code that combines date, time, timestamp, interval or text values in one of these functions without
an `output_field`. That includes the common `Coalesce(<DateTimeField>, now())` and
`Greatest(<DateTimeField>, DateTime(…))`, because Julia's `DateTime` is naive.

### How to find the calls to migrate

```bash
grep -rnE '(Coalesce|Greatest|Least|NullIf|Case|When|Lag|Lead)\(' --include=*.jl . | grep -iE 'date|time|zdt|zoned|now\(|Hour|Minute|Day\('
```

Run the suite. Each refusal names the function, the two types, the operands that carry them, and the
spelling that works for that pair.

### Migrate your app

```julia
# ✗ before — a date column beside a zoned literal
M.Race.objects.values("first_day" => Coalesce("fp1_date", zdt))

# ✓ convert the literal in Julia
M.Race.objects.values("first_day" => Coalesce("fp1_date", Date(zdt)))
# ✓ or, for a date beside a timestamp, say the type with `output_field` (`"date"` casts on both engines)
M.Race.objects.values("first_day" => Coalesce("fp1_date", zdt; output_field = "date"))

# ✗ before — a text column beside a timestamp
M.Race.objects.values("label" => Coalesce("name", zdt))
# ✓ cast the timestamp to text (an `output_field` cannot: PostgreSQL unifies the operands first)
M.Race.objects.values("label" => Coalesce("name", Cast(Value(zdt), "text")))

# ✗ before — a zoned DateTimeField beside a naive DateTime
Greatest("start_at", DateTime(2021, 1, 1))
# ✓ make the literal zoned
Greatest("start_at", ZonedDateTime(DateTime(2021, 1, 1), tz"UTC"))

# NullIf, Lag and Lead take no `output_field`: convert the literal, or cast an operand
NullIf("date", Date(zdt))
Lag("date"; default = Date(zdt), over = WindowOver(order_by = "raceid"))
```
