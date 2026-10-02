## Date arithmetic: an integer column is a day count; other untyped sides are refused on SQLite (#882)

- **Version**: Unreleased
- **Recorded**: 2026-10-02
- **PormG ref**: #882; `src/querybuilder/execution.jl` (`_day_count_column_kind`,
  `_refuse_untyped_date_operand`, `_set_update_query_typed`)
- **Severity**: behavior change. A silently wrong SQLite result becomes a date shift or an error, and
  one PostgreSQL error becomes a result.

### What changed

A date combined with an integer column (`IntegerField`, `PositiveIntegerField`,
`PositiveSmallIntegerField`, `BigIntegerField`) is a whole-day shift on both engines, as an integer
literal (`F("date") + 7`) already was. Anything else PormG cannot type beside a
date is refused on SQLite, where a date is text and `+`/`-` used only its year.

| Expression | before | after |
|---|---|---|
| `F("date") - F("round")` on **SQLite** | the year minus `round` (a number) | the date `round` days earlier |
| `F("round") + F("date")` on **SQLite** | the year plus `round` | the shifted date |
| `F("start_at") - F("round")` on **PostgreSQL** | `StatementError` (`timestamp - integer`) | the timestamp `round` days earlier |
| `F("date") - F(<BigIntegerField>)` on **PostgreSQL** | `StatementError` (`date - bigint`) | the shifted date (the count is cast to `integer`) |
| `F("date") ± <text column, ForeignKey, float, Sum(...), F("n") * 2, __@year>` on **SQLite** | a number from the date's year | `QueryBuildError` |
| `F("round") - F("date")` | SQLite: a number; PostgreSQL: `StatementError` | `QueryBuildError` on both |
| `(F("date") - F("round")) + Day(1)` read back on **PostgreSQL** | a `DateTime` (the shift was untyped) | a `Date`: the result is cast `::date`, as a whole-day shift of any `DateField` is (#572) |
| `F("date") + F(<TimeField>)` on **SQLite** | a number from the date's year | `QueryBuildError`; PostgreSQL's `date + time` (a timestamp) is unchanged |

PostgreSQL SQL is unchanged for a bare `date ± integer column`, and for every shape SQLite now
refuses. A shift built on one is now typed, which is what changes the read-back above.

### How to find the calls to migrate

Two `F(...)` columns joined by `+` or `-`:

```bash
grep -rnP 'F\("[^"]+"\)\s*[-+]\s*F\(' src/
```

For each match, check whether one side is a date and the other is not a date.

### Migrate your app

```julia
# ✗ before: on SQLite this was the year minus a number, never a date
values("deadline" => F("date") - F("round"))
# ✓ after: unchanged source — it is now the date shifted back by `round` days on both engines

# ✗ before: a ForeignKey or a float beside a date returned a number on SQLite
values("x" => F("date") + F("amount"))
# ✓ after: say how many whole days, or which duration, you mean
values("x" => F("date") + Day(7))
```
