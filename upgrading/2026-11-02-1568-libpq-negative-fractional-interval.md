## A negative interval with a fraction of a second reads back exact through LibPQ (#1568)

- **Version**: 0.10.0
- **PormG ref**: #1568 ; `ext/PormGLibPQExt.jl`
- **Recorded**: 2026-11-02
- **Severity**: behavior (bug fix, silent wrong value). PostgreSQL through the LibPQ driver only. Postgres.jl, SQLite and MySQL read these values unchanged.

### What changed

LibPQ.jl reads a PostgreSQL `interval` from its ISO 8601 text. In LibPQ.jl 1.18.0 the fraction of a
second in that text is read without its sign, so an interval below zero with a sub-second part came back
wrong, with no error. PormG now reads every interval on its LibPQ connections with the fraction signed
like the seconds it belongs to (the rule of the unreleased LibPQ.jl#321). Every interval LibPQ already
read correctly reads back identically, components included.

| server value | before (LibPQ) | now (LibPQ, and Postgres.jl as before) |
|---|---|---|
| `-00:02:37.754` | `-2 minutes, -37 seconds, 754 milliseconds` (`Dates.toms` = −156246) | `-2 minutes, -37 seconds, -754 milliseconds` (−157754) |
| `-00:00:00.754` | `754 milliseconds` (**positive**) | `-754 milliseconds` |
| `-00:00:37`, `00:02:37.754`, any non-negative interval | unchanged | unchanged |

Such values come from expressions that can go below zero, for example a timestamp difference taken
the wrong way round (`F("date") - F("start_at")`), `Minute(2) - F("time")` for a lap slower than two
minutes, or `F("time") - F("time") * 2`. A `DurationField` column that stores a negative duration with a
fraction reads back the same way.

### Who this affects

Code on PostgreSQL through LibPQ that reads a negative interval with a fraction of a second and
compensated for the wrong value, or stored or compared it as read. Code that never produces a negative
interval with a fraction is unaffected.

### How to find the calls to migrate

```bash
# interval arithmetic that can go negative: a subtraction with an F expression or a duration literal
grep -rnE 'F\("[^"]+"\) *- *(F\(|Dates\.|(Hour|Minute|Second|Millisecond)\()|(Hour|Minute|Second|Millisecond)\([^)]*\) *- *F\(' --include=*.jl .
# code that may have worked around the old value
grep -rnE 'toms|tons|CompoundPeriod' --include=*.jl .
```

### Migrate your app

```julia
# A lap slower than two minutes, less two minutes, is a negative interval with milliseconds.
q = M.Lap_times.objects
q.filter("raceid__year" => 2009, "raceid__round" => 1, "lap" => 1, "milliseconds__@gte" => 120_000)
q.values("milliseconds", "under_two" => Dates.Minute(2) - F("time"))
row = first(q.list())

# ✗ before, on LibPQ: the milliseconds read back with the wrong sign, so this was off by 2 × the fraction
# ✓ now: exact on every driver; drop any correction you applied
Dates.toms(row["under_two"]) == 120_000 - row["milliseconds"]
```
