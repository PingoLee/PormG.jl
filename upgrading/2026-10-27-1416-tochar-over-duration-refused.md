## `ToChar` over a duration is refused on every engine, under every format (#1416)

- **Version**: Unreleased
- **PormG ref**: #1416 ; `src/querybuilder/select_nodes.jl` (`_check_tochar_of_duration`)
- **Recorded**: 2026-10-27
- **Severity**: behavior change. Expressions that built on PostgreSQL and SQLite now raise `QueryBuildError` when the query is built.

### What changed

A duration has no calendar date, so a `ToChar` format that writes a year, a month or a day has no
value over one (the #1388 rule for `Extract`). Its clock has no single meaning either. PostgreSQL's
`to_char` formats the interval's own fields, which depend on how the interval was formed: a 62-hour
timestamp difference is `2 days 14:00:00`, so `HH24` writes `14`. SQLite's `strftime` reads the
stored text as a time of day, so `strftime('%Y', '00:01:27.452')` is `2000` and a duration past 24
hours is `NULL`. MySQL holds a duration as its microseconds and already refused it.

So `ToChar` over a duration is refused on every engine, whatever the format: every portable key and
a native PostgreSQL template alike. The operand is the type walk's. That covers a `DurationField`
column, interval arithmetic, a timestamp difference, `Sum` of a duration, and a time minus a time
(#1406). `ToChar` over a date, a timestamp or a time (its clock keys) builds as before.

Examples on `Result`, whose `fastestlaptime` is a `DurationField`:

| expression | before | now |
|---|---|---|
| `ToChar("fastestlaptime", "YYYY")` | SQLite `2000`, PostgreSQL `0000` | raises `QueryBuildError` (#1416) |
| `ToChar("fastestlaptime", "HH:MI:SS")` | SQLite the text read as a time of day, PostgreSQL the interval's fields | raises `QueryBuildError` (#1416) |
| `ToChar(F("fastestlaptime") * 2, "MI")` | as above, over the product | raises `QueryBuildError` (#1416) |
| `Cast("fastestlaptime", "text")` | the duration's text | builds, unchanged |

On MySQL the error was already a `QueryBuildError`; only its message changes.

### Who this affects

Code that formats a `DurationField`, or an expression over one, with `ToChar`, on any engine.

### How to find the calls to migrate

```bash
grep -rn 'ToChar(' --include=*.jl src/ test/
```

For each match, check whether the operand is a duration.

### Migrate your app

```julia
# ✗ before — 2000 on SQLite; now raises QueryBuildError (#1416)
q = M.Result.objects
q.values("lap" => ToChar("fastestlaptime", "YYYY"))

# ✓ after — the duration's text, or its seconds (PostgreSQL, MySQL)
q = M.Result.objects
q.values("lap" => Cast("fastestlaptime", "text"))
q.values("lap_s" => Extract("fastestlaptime", "epoch"))
```
