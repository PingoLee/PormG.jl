## `Subquery(...)` reads back as its one column does, and functions over it are typed (#888)

- **Version**: Unreleased
- **PormG ref**: #888; `src/querybuilder/build_query.jl` (`_operand_kind`, `_subquery_kind`,
  `_record_subquery_kind!`), `src/querybuilder/build_helpers.jl` (`_get_select_query(::SubqueryObject)`)
- **Recorded**: 2026-10-03
- **Severity**: behavior change, on SQLite. On PostgreSQL the driver already delivered these values
  typed; the only change there is that an interval value is normalized to `Dates.CompoundPeriod`
  (#581), as an interval column already is — an interval subquery, and any function or arithmetic
  over a subquery that now reads as an interval (`Coalesce(Subquery(s), "duration")`, a timestamp
  difference against one).

### What changed

A projected `Subquery(...)` used to record no read type, so on SQLite its value came back as the
text SQLite stores, while PostgreSQL's driver delivered a `Date`. It now has the type of its one
projected column, decided by the same rule as every other projection (#800, #824): the column itself
and `Max`/`Min` over it are typed; `Avg`, `Sum`, `Count` and arithmetic are not. A function over the
subquery now follows its usual rule with that type.

| Value, on SQLite | before | after |
|---|---|---|
| `Subquery(s)` where `s` projects a `DateField` (`"date"`, `Max("date")`) | `String` | `Date` |
| …a `DateTimeField` / `TimeField` / `DurationField` / `DecimalField` (≤ 15 digits) | `String` / `Float64` | `ZonedDateTime` / `Time` / `Dates.CompoundPeriod` / `Decimal` |
| `Coalesce(Subquery(s), Date(…))`, `Greatest`/`Least` over date subqueries, `NullIf(Subquery(s), …)` | `String` | `Date` |
| `F("date") - Coalesce(Subquery(s), F("date"))` | `QueryBuildError` (#882, an untyped operand) | a day count, as `F("date") - F("date")` |
| `F("start_at") - Coalesce(Subquery(s), F("start_at"))` over a `DateTimeField` | `QueryBuildError` (#882) | an interval, as `F("start_at") - F("start_at")` (#814) |
| `Abs(Subquery(s))` where `s` projects a `DurationField` | `ABS` of the stored text's leading hours | `QueryBuildError`, as `Abs("duration")` (#900) |

Unchanged: a subquery over a computed column (`Avg("points")`), over a text or number column, and
`Cast(Subquery(s), "date")`, which was already a `Date` on both engines (#878). On SQLite a
subquery over a `DurationField` still orders and compares as its text, and `Greatest`/`Least` over
one still choose their result by that text; only the read type changed.

### How to find the calls to migrate

```bash
# every projected subquery, and the functions that take one
grep -rnE 'Subquery\(' src/
# parsing an app did itself because the value arrived as text on SQLite
grep -rnE '(Date|DateTime|Time|ZonedDateTime)\(\s*(row|r|res|result)[\.\[]|parse\((Date|DateTime|Time|Float64)' src/
```

Only code that handled a subquery's value as text needs an edit. An app that only runs on PostgreSQL
sees no change except a subquery over a `DurationField`.

### Migrate your app

```julia
last_race = M.Driver_standings.objects
last_race.filter("driverid" => OuterRef("driverid"))
last_race.values("t" => Max("raceid__date"))

# ✗ before — on SQLite the subquery's date arrived as text, so the app parsed it
rows = M.Driver.objects.values("driverid", "last" => Subquery(last_race)).list(:dict)
last = Date(rows[1][:last])

# ✓ after — a Date on both engines
rows = M.Driver.objects.values("driverid", "last" => Subquery(last_race)).list(:dict)
last = rows[1][:last]
```

The `Cast(Subquery(last_race), "date")` workaround keeps working; it can be dropped.
