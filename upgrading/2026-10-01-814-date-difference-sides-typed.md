## Date differences: `DATE - DATE` is a day count on SQLite, every side is typed, a day count shifts a date (#801, #814)

- **Version**: 0.8.0
- **Recorded**: 2026-10-01
- **PormG ref**: #801, #814; `src/querybuilder/execution.jl` (`_side_kind`, `_render_temporal_difference`,
  `_render_day_count_shift`, `_render_operand_typed`), `src/querybuilder/types.jl` (`_CompareLiteral`,
  `-` with a date literal)
- **Severity**: behavior change. Most rows below change a silently wrong SQLite result. Two change a
  PostgreSQL result or error.

### What changed

SQLite stores a date as text, and `-` between two text values subtracts their leading numbers — the
years. In the same release, #801 made `DATE - DATE` a whole number of days on SQLite, as PostgreSQL
already returned, and #814 finished that work. Its sides are now typed even when they are not plain columns: an
extremum, a window value function, a `__@date` path, a date literal. The same typing applies to a
shift or a comparison built on such a side, so a few shapes outside differences change too.

| Expression | before | after |
|---|---|---|
| `F("date") - F("dob")` on **SQLite** (#801) | the difference of the two YEARS | a whole number of days, as on PostgreSQL |
| `F("start_at") - F("date")` on **SQLite** | a wrong number (the years' difference) | an interval: `Dates.CompoundPeriod`, as on PostgreSQL |
| `F("date") + F("dob")`, and `*` or `/` between two temporal values (#801) | SQLite: the years combined, silently; PostgreSQL: failed at the server | `QueryBuildError` on both |
| `F("date") - Max("date")`, `Max("date") - Min("date")`, `F("d__@date") - F("e__@date")` on **SQLite** | the difference of the two YEARS (`0`) | a whole number of days |
| `F("date") + (F("date") - F("dob"))`, `count + F("date")` on **SQLite** | the year plus the count (a number) | the shifted date |
| `F("ts__@date") + Day(1)`, `Max("date") + 1` | PostgreSQL: a `DateTime` (`Max + 1` failed outright); SQLite: a `String` (`Max + 1` was the year plus one) | a `Date` on both engines (#572's rule) |
| `F("ts__@date") == DateTime(2009, 3, 1, 12)` on **SQLite** | bound the timestamp text; matched **no** rows (PostgreSQL's date input dropped the time and matched) | binds the calendar date, like `filter("ts__@date" => …)`; matches that day |
| `F("date") - "2009-03-01"` (a text literal) | PostgreSQL: `StatementError` (`date - text`); SQLite: a wrong number | `QueryBuildError` on both: pass `Date(2009, 3, 1)` |

One new refusal, on SQLite only: a window function as a side of a timestamp difference (it returned a wrong
number, as every SQLite timestamp difference did).

(Ordering against a difference, arithmetic on one and a date shifted by an interval value were also
refused on SQLite by #814. #881 renders all three before any release carried those refusals; see its
own entry.)

### How to find the calls to migrate

```bash
# a `__@date` path, an extremum or a window function used in date arithmetic or compared to a DateTime
grep -rnE 'F\("[^"]*__@date"\)\s*([-+]|==|!=|[<>]=?)' src/
grep -rnE '(Max|Min|Lag|Lead|FirstValue|LastValue|NthValue)\(.*\)\s*[-+]' src/
grep -rnE '[-+]\s*(Max|Min|Lag|Lead|FirstValue|LastValue|NthValue)\(' src/
# a day count combined with a date: `F("a") ± (F("b") - F("c"))`, and `(F("b") - F("c")) + F("a")`
grep -rnE 'F\("[^"]+"\)\s*[-+]\s*\(F\("[^"]+"\)\s*-' src/
grep -rnE '\(F\("[^"]+"\)\s*-\s*F\("[^"]+"\)\)\s*\+' src/
# a text literal on the right of date arithmetic
grep -rnE 'F\("[^"]+"\)\s*[-+]\s*"[0-9]{4}-' src/
```

A hit matters only if its value is **read back** (in `values(...)`, a `DataFrame` column), or if it
filters with `==` against a `DateTime`. A hit that already returned the right answer on your engine
keeps doing so.

### Migrate your app

```julia
# ✗ before — a text literal: a wrong number on SQLite, a StatementError on PostgreSQL
M.Race.objects.values("since" => F("date") - "2009-03-29")
# ✓ after — a date literal, typed and bound as a date on both engines
M.Race.objects.values("since" => F("date") - Date(2009, 3, 29))

# ✗ before — the app relied on PostgreSQL returning a DateTime for a whole-day shift of `@date`
Dates.hour(row[:next])                 # `row[:next]` is now a Date
# ✓ after
DateTime(row[:next])                   # when a timestamp is genuinely wanted
```

Ordering and arithmetic on a timestamp difference work on both engines since #881.
