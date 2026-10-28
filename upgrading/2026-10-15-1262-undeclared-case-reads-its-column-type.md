## A Case with no output_field reads back as its branches' column type (#1262)

- **Version**: 0.9.0
- **PormG ref**: #1262 ; `src/querybuilder/expression_kind.jl` (`_read_kind`)
- **Recorded**: 2026-10-15
- **Severity**: behavior change. On SQLite a `Case` without `output_field` reads back as a typed value where it read back as stored text or a number before. On PostgreSQL its value is normalized as the column's is: an array as a 1-based `Vector`, an interval as a `Dates.CompoundPeriod` on every driver.

### What changed

A `Case` with no `output_field` takes one of its branch values on each row, as `Coalesce` takes one of
its operands. `Coalesce` over columns of one type already read back as that type on both engines
(#824). A `Case` recorded no read type, so SQLite handed back each value as it stores it: an interval
as its `HH:MM:SS.sss` text, a date or a timestamp as its ISO text, a time as `HH:MM:SS`, a decimal as
a REAL. PostgreSQL's driver delivered the typed value.

The `Case` now reads back as the type its `then` values and its `default` agree on, on every engine.
A branch with no `default` (NULL) is never the value, so it does not count. Values that disagree (two
decimal widths, a decimal beside a number literal) still read back untyped, as before.

On PostgreSQL the driver already typed these values. What changes there is the normalization a column
of the same type gets: a `Case` over an `ArrayField` reads as a 1-based `Vector` (LibPQ hands back a
non-numeric array as its raw `{…}` text and a numeric one as an offset-indexed `Array`), and one over
a `DurationField` as a `Dates.CompoundPeriod` whichever driver is loaded (#581).

Examples on the F1 models (`Result.fastestlaptime` is a `DurationField`, `Race.date` a `DateField`,
`Constructor_results.points` a `DecimalField`):

| expression | PostgreSQL | SQLite before | SQLite now |
|---|---|---|---|
| `Case([When("grid" => 1, then = F("fastestlaptime"))])` | `Dates.CompoundPeriod` | `"00:01:27.452"` (`String`) | `Dates.CompoundPeriod` |
| `Case([When("year" => 2009, then = F("date"))])` | `Date` | `"2009-03-29"` (`String`) | `Date` |
| `Case([When("year" => 2009, then = F("start_at"))])` | `ZonedDateTime` | the stored text (`String`) | `ZonedDateTime` |
| `Case([When("constructorresultsid" => 3835, then = F("points"))])` | `Decimal` | `5.5` (`Float64`) | `Decimal` |

The same holds for the `Case` under a CTE and inside a `Subquery`.

### Who this affects

On SQLite, code that projects a `Case` without `output_field` whose branches are all columns (or
literals) of one temporal or decimal type, and converts the text or the number it received by hand.
That conversion now receives the typed value. On PostgreSQL, code that parses the `{…}` text of a
`Case` over an array column, or expects a single `Dates.Period` from one over a duration on the
Postgres.jl driver.

### How to find the calls to migrate

```bash
grep -rn 'Case(' --include=*.jl src/ test/ | grep -v output_field
```

For each match on SQLite, check whether the result is parsed after it is read.

### Migrate your app

```julia
# ✗ before — on SQLite the interval came back as text and was parsed by hand
q = M.Result.objects
q.values("lap" => Case([When("grid" => 1, then = F("fastestlaptime"))]))
lap = parse_lap(q.list()[1][:lap])

# ✓ after — the value is already a Dates.CompoundPeriod on every engine
q = M.Result.objects
q.values("lap" => Case([When("grid" => 1, then = F("fastestlaptime"))]))
lap = q.list()[1][:lap]
```
