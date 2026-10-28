## `ToChar` with a date in its format over a time is refused on every engine (#1336)

- **Version**: 0.9.0
- **PormG ref**: #1336 ; `src/querybuilder/select_nodes.jl` (`_check_tochar_date_of_time`), `src/Dialect.jl` (`_tochar_reads_date`)
- **Recorded**: 2026-10-27
- **Severity**: behavior change. Expressions that built on PostgreSQL and SQLite now raise `QueryBuildError` when the query is built.

### What changed

A time of day has no date, so a `ToChar` format that writes a year, a month or a day has no value
over one. No engine had the meaning: SQLite's `strftime('%Y-%m-%d', '06:00:00')` wrote
`2000-01-01` for every row, PostgreSQL's `to_char` read the time as an interval, and MySQL's
`DATE_FORMAT` gave it today's date. That is a query that does not say what it means, so it is refused
on every engine, as `Extract`'s calendar parts are over a `TimeField` (#1070).

The refusal covers every portable format that writes a date (`"YYYY"`, `"MM"`, `"DD"`,
`"YYYY-MM-DD"`, `"DD/MM/YYYY"`, `"YYYY-MM-DD HH:MI:SS"`, …) over a `TimeField` column and
`Max`/`Min` of one: any operand the type walk names a time. The clock formats (`"HH"`, `"MI"`, `"SS"`, `"HH:MI"`,
`"HH:MI:SS"`, `"HH:MI:SS.SSS"`) build over a time as before, and every format builds over a date or a
timestamp. A native PostgreSQL template outside the portable table is not read, and builds as before.

Examples on `Race`, whose `time` is a `TimeField` and `start_at` a `DateTimeField`:

| expression | before | now |
|---|---|---|
| `ToChar("time", "YYYY-MM-DD")` | SQLite `2000-01-01`, PostgreSQL its own text | raises `QueryBuildError` (#1336) |
| `ToChar(Max("time"), "YYYY")` | SQLite `2000` | raises `QueryBuildError` (#1336) |
| `ToChar("time", "HH:MI")` | `06:00` | builds, unchanged |
| `ToChar("start_at", "YYYY-MM-DD")` | `2009-03-29` | builds, unchanged |

### Who this affects

Code that formats a `TimeField` with a `ToChar` format holding `YYYY`, `MM` or `DD`, on any engine.

### How to find the calls to migrate

```bash
grep -rn 'ToChar(' --include=*.jl src/ test/ | grep -E 'YYYY|MM-|-MM|"MM"|DD'
```

For each match, check whether the operand is a time of day.

### Migrate your app

```julia
# ✗ before — 2000-01-01 on SQLite; now raises QueryBuildError (#1336)
q = M.Race.objects
q.values("t" => ToChar("time", "YYYY-MM-DD HH:MI:SS"))

# ✓ after — format the clock alone, or take the date from a timestamp
q = M.Race.objects
q.values("t" => ToChar("time", "HH:MI:SS"))
q.values("t" => ToChar("start_at", "YYYY-MM-DD HH:MI:SS"))
```
