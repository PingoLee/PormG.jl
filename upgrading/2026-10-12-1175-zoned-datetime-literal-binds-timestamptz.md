## PostgreSQL: a `ZonedDateTime` literal binds typed `::timestamptz` (#1175)

- **Version**: Unreleased
- **PormG ref**: #1175 ; `src/querybuilder/field_resolution.jl` (`_infer_parameter_sql_type`)
- **Recorded**: 2026-10-12
- **Severity**: behavior change, PostgreSQL only. Calls return a different value or type, and an
  expression that mixed a zoned literal with text now fails PostgreSQL's type check.

### What changed

A `ZonedDateTime` passed as a literal bound as an untyped `$1`. That covers `Value(zdt)`, a function
operand, a `Case` branch and a `Lag`/`Lead` default. The driver sent the text with its offset
(`2021-01-01T00:30:00+02:00`) and PostgreSQL typed it from context, so the offset could be dropped.
The `default` of a `Case` with an `output_field` was cast straight to the declared type
(`$1::date`), which dropped the offset the same way. Both changes:
- the literal now binds as `$1::timestamptz`, as a `Date`, `DateTime` or `Time` literal already
  carries its own type;
- that `default` binds as `$1::timestamptz::<type>`.

The value means the instant, read in UTC, the session time zone PormG opens both drivers with.
SQLite already bound the UTC text and is unchanged.

With `zdt = ZonedDateTime(DateTime(2021, 1, 1, 0, 30), FixedTimeZone("UTC+2", 7200))`, which is
2020-12-31 22:30 UTC:

| Expression, on PostgreSQL | before | after |
|---|---|---|
| `values("z" => Value(zdt))` reads | a `String` | a `ZonedDateTime` (the same instant) |
| `Cast(Value(zdt), "date")` | `2021-01-01`, the wall-clock date of the offset written | `2020-12-31`, the date of the instant |
| `Extract(Cast(Value(zdt), "date"), "ISODOW")` | `5` | `4` |
| `Case(…, default = zdt, output_field = "date")` | `2021-01-01` | `2020-12-31` |
| `Cast(Value(zdt), "text")` | `"2021-01-01T00:30:00+02:00"` | `"2020-12-31 22:30:00+00"` |
| `Coalesce("fp1_date", zdt)`, a `DateField` and a zoned literal; `Greatest`, `Least` and a `Lag`/`Lead` `default` likewise | a `Date`: the column's, or the literal cut to its wall-clock date (`2021-01-01`) | a `ZonedDateTime` on **every** row: the column's date at midnight UTC, or the literal's instant |
| `NullIf("date", zdt)` | compares the column to the literal's wall-clock date | compares it to the instant |
| `Case(When(…, then = Value(zdt)), default = Value(DateTime(…)))` | a `DateTime`, the zoned branch read without its offset (`2021-01-01T00:30`) | a `ZonedDateTime` (`2020-12-31T22:30Z`) |
| `Coalesce("name", zdt)`, a text column and a zoned literal | ran, typed as text | PostgreSQL refuses it: `COALESCE types character varying and timestamp with time zone cannot be matched` |

The same holds where such an expression is a filter or a written value. For example,
`filter("date" => Coalesce("fp1_date", zdt))` compares against the instant, and
`update("fp1_date" => Coalesce("fp1_date", zdt))` stores the instant's UTC date.

On PostgreSQL 12 and older, a `lag`/`lead` default must have the column's own type. On those
servers, `Lag("fp1_date"; default = zdt)` now fails as a function that does not exist: pass
`Date(zdt)` there.

A bare `ZonedDateTime` as a filter value or a written value is unchanged: `filter("start_at__@gte" => zdt)`,
`F("start_at") >= zdt`, or a field set to `zdt`. These still bind the canonical UTC text, typed by
the column.

### Who this affects

PostgreSQL queries that use a `ZonedDateTime` inside an expression rather than as a bare filter or
written value. This includes:
- code that parsed the `String` a projected `Value(zdt)` returned;
- golden tests that pin the SQL.

### How to find the calls to migrate

```bash
# zoned values, then the expressions that may hold one
grep -rnE 'ZonedDateTime|astimezone|now\(tz' --include=*.jl .
grep -rnE '(Value|Coalesce|Greatest|Least|NullIf|Case|When|Lag|Lead|Cast)\(' --include=*.jl . | grep -iE 'zdt|zoned|tz'
# hand-parsing of a projected value read back as text
grep -rnE '(Date|DateTime|Time|ZonedDateTime)\(\s*(row|r|res|result)[\.\[]|parse\((Date|DateTime|Time|Float64)' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before — the projected literal came back as text and was parsed by hand
row = only(M.Race.objects.filter("raceid" => 1).values("z" => Value(zdt)).list())
z = ZonedDateTime(row[:z], dateformat"yyyy-mm-ddTHH:MM:SSzzzz")

# ✓ after — it reads back as a ZonedDateTime
z = only(M.Race.objects.filter("raceid" => 1).values("z" => Value(zdt)).list())[:z]

# ✓ when you meant the wall-clock date of the offset, take it in Julia
Value(Date(zdt))

# ✓ a date column beside a zoned fallback: say which type you mean
Coalesce("fp1_date", Date(zdt))                 # stays a Date
```
