## Whole-day arithmetic on a `DateField` reads back as a `Date` on PostgreSQL (#572)

- **Version**: Unreleased
- **Recorded**: 2026-09-29
- **PormG ref**: #572; `src/value_repr.jl` (`sql_canonicalize(::CDate, ::PormGPostgres)`),
  `src/querybuilder/execution.jl` (`_render_temporal_shift`)
- **Severity**: behavior change — PostgreSQL only. SQLite already returned a `Date`.

### What changed

PostgreSQL's own `date + interval` is a `timestamp` for **any** interval, whole days included, so a
projected whole-day shift on a `DateField` read back as a `DateTime` on PostgreSQL while SQLite
returned a `Date`. PormG's promotion rule says a whole-day shift stays a date (only a sub-day
component promotes to a timestamp), and the PostgreSQL render now follows it: the expression is cast
back to `date`.

| Expression on a `DateField` | before (PostgreSQL) | after (both engines) |
|---|---|---|
| `F("date") + Day(1)` | `DateTime("2009-03-30T00:00:00")` | `Date("2009-03-30")` |
| `F("date") + 7`, `(F("date") + 7) + 3` | `DateTime` | `Date` |
| `F("date") - Month(1)`, `+ Year(n)`, `+ Week(n)` | `DateTime` | `Date` |
| `F("date") + Hour(6)` (sub-day) | `DateTime` | `DateTime` — unchanged |

Two expressions **built on top of** such a shift change with it on PostgreSQL, because they now
start from a `date` rather than a `timestamp` — they behave exactly as they already did on the plain
`DateField` column:

| Expression | before (PostgreSQL) | after (PostgreSQL) |
|---|---|---|
| `(F("date") + Day(30)) - F("date")` — a shift minus a date | an interval (`Dates.CompoundPeriod`, 30 days) | an integer day count (`30`), as `F("date") - F("date")` already was |
| `Extract(F("date") + Day(1), "hour")` (also `"minute"`, `"second"`) | `0` | raises an error (PostgreSQL: `unit "hour" not supported for type date`), as `Extract(F("date"), "hour")` already did |

The rendered SQL gains a cast, e.g. `(("Tb"."date" + make_interval(days => $1::integer)))::date`.
Comparing the shift itself — in a `filter`, an `update()`, an `ORDER BY` — returns the same rows as
before: the shifted value is midnight either way, and a date literal compared against it was already
bound as the calendar date.

### How to find the calls to migrate

```bash
# a whole-day duration or a bare integer added to / subtracted from a column, either operand order
grep -rnE 'F\("[^"]+"\)\s*[-+]\s*\(?\s*((Dates\.)?(Day|Week|Month|Quarter|Year)\(|Interval\(|[0-9]+)' src/
grep -rnE '((Dates\.)?(Day|Week|Month|Quarter|Year)\([^)]*\)|[0-9]+)\s*\+\s*F\("' src/
# broad pass: any F(...) ± something — catches a duration held in a variable (`F("date") + offset`)
grep -rnE 'F\("[^"]+"\)\s*[-+]\s*[A-Za-z_(]' src/
```

Only hits on a `DateField` whose result is **read back** (in `values(...)`, `annotate`, a
`DataFrame` column), or that feed one of the two expressions in the second table, are affected. A
hit on a `DateTimeField`, or one that only compares the shift itself in `filter` or `update`, needs
no edit.

### Migrate your app

```julia
# ✗ before — the app relied on PostgreSQL handing back a DateTime
row = M.Race.objects.filter("raceid" => 1).values("next" => F("date") + Day(1)).list(:dict)[1]
Dates.hour(row[:next])                 # MethodError now: a Date has no hour
row[:next] isa DateTime                # false now

# ✓ after — it is a Date on both engines
DateTime(row[:next])                   # when a timestamp is genuinely wanted
```

`==` against a `DateTime` keeps working unchanged — Julia promotes `Date(2009, 3, 30) ==
DateTime(2009, 3, 30)` to `true` — so a comparison needs no edit; only code that calls a
time-of-day accessor (`hour`, `minute`, …) or dispatches / type-checks on `DateTime` does.

```julia
# unchanged, and still true
row[:next] == DateTime(2009, 3, 30)
```
