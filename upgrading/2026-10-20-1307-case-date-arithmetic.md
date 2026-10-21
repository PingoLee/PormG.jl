## A `Case` whose value is a date is the date side of date arithmetic (#1307)

- **Version**: Unreleased
- **PormG ref**: #1307 ; `src/querybuilder/expression_kind.jl` (`_render_side_kind`)
- **Recorded**: 2026-10-20
- **Severity**: behavior change, both engines. On SQLite a `Case` over dates shifted by a number returns the shifted date where it returned a number from the date's text, with no error. On SQLite the same `Case` plus a float, a text column or a `Sum` raises `QueryBuildError` where it returned a number. On PostgreSQL the same expression runs where the statement failed (`date + bigint`), and a `Case` over dates minus a date, or plus an interval, is typed. A filter on such an alias checks its value as a date or timestamp and raises `InvalidValueError` for one that is not, where it built.

### What changed

A `Case` with no `output_field` whose branches are dates (or timestamps), used as a side of `+` or
`-`, was not typed. PormG renders date arithmetic by the date's type (#568, #814, #881), so the
`Case` fell through to a bare `+`:

- on SQLite, where a date is its `YYYY-MM-DD` text, `'2009-03-29' + 1` is `2010`;
- on PostgreSQL the number was bound as a `bigint`, and PostgreSQL has no `date + bigint` operator, so
  the query failed when it ran.

PormG now types that side as the date or timestamp its branches agree on, as it already did for
`Max`, `Coalesce`, `Greatest`, `Least`, `NullIf` and `Lag` over a date column. A function over such a
`Case` (`Max(Case(…))`) moves with it. The arithmetic takes the same path as a `DateField` column:

- plus or minus a whole number, or an integer column, is the date shifted by that many days;
- minus a date is the whole number of days between them;
- plus an interval is a timestamp;
- plus anything else PormG cannot type as a day count (a float, a text column, a `Sum`) is refused
  on SQLite, where it would use only the date's year, as it is for a `DateField` column.

Each reads back as the `Date`, `Int` or `DateTime` the column form gives. A filter on its alias
checks the value as that type.

Examples on `Race`, where `dc` is `Case(When("round" => 1, then = F("date")), default = F("date"))`:

| expression | engine | before | now |
|---|---|---|---|
| `values("d" => dc + 1)` | SQLite | built; read `2010` for `2009-03-29` | `Date(2009, 3, 30)` |
| `values("d" => dc + 1)` | PostgreSQL | built; the query failed when it ran (`date + bigint`) | `Date(2009, 3, 30)` |
| `values("d" => dc - F("date"))` | SQLite | raised `QueryBuildError` (a value PormG cannot type) | `0`, the day count |
| `values("d" => dc - F("date"))` | PostgreSQL | built; an untyped integer | `0`, typed as an integer |
| `values("d" => Max(dc) + 1)` | both | as `dc + 1` | as `dc + 1`: the date one day later |
| `values("d" => dc + 1.5)` | SQLite | built; read `2010.5` | raises `QueryBuildError`, as `F("date") + 1.5` does |
| `values("d" => dc + 1)`, `filter("d__@gt" => 10)` | both | built; compared the date with `10` | raises `InvalidValueError` (not a date) |

Unchanged: a `Case` that mixes a date and a timestamp is still refused (#1200), and a `Case` with an
`output_field` was typed already.

### Who this affects

Code that adds or subtracts a number, an integer column, a date or an interval to a `Case` whose
branches are dates or timestamps. On SQLite that code returned wrong values. On PostgreSQL the shift
by a number failed when it ran. Code that filters such an alias with a value that is not a date.

### How to find the calls to migrate

```bash
grep -rnE 'Case\(.*\)\s*[-+]' --include=*.jl src/ test/
grep -rnE '[-+]\s*Case\(' --include=*.jl src/ test/
```

For each match, check whether the `Case`'s branches are dates or timestamps.

### Migrate your app

```julia
# ✗ before — SQLite read 2010 for 2009-03-29; PostgreSQL failed when the query ran
q = M.Race.objects
q.values("next_day" => Case(When("round" => 1, then = F("date")), default = F("date")) + 1)

# ✓ after — the same call returns the date one day later, as a Date, on both engines.
# A filter on the alias takes a date:
q.filter("next_day__@gt" => Date(2009, 6, 1))
```
