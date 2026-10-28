## SQLite: a labelled order term over an interval sorts its length (#1313)

- **Version**: 0.9.0
- **PormG ref**: #1313 ; `src/querybuilder/build_select.jl` (`get_order_query`)
- **Recorded**: 2026-10-21
- **Severity**: behavior change, SQLite only. A labelled order term whose expression is an interval with a millisecond form returns its rows in the interval's order, where it returned them in its `HH:MM:SS` text's order, with no error. PostgreSQL is unchanged.

### What changed

`order_by(SQLOrder(SQLField(expr, "label")))` orders by an expression without projecting it. On
SQLite, where an interval is its `HH:MM:SS` text, such a term rendered the expression as a projection
does, so it sorted:

- the stored text, for a `DurationField` written `F("time")`;
- the interval re-formatted as text, for interval arithmetic (`F("time") * 2`), a timestamp
  difference, or an aggregate over one.

A labelled path (`SQLField("time", "x")`) already sorted its milliseconds, and is unchanged.

Text sorts in the interval's order only below 100 hours and for non-negative values
(`"100:00:00"` sorts before `"99:00:00"`). The same interval ordered by its path (`order_by("time")`)
or by its projected alias already sorted its milliseconds (#894).

The term now orders by the millisecond form on SQLite. The text stays the term's SQL wherever it is
not the sort key: in a grouped query its `GROUP BY` copy keeps the text, with its own bound values.
An interval with no millisecond form (a `Case` over durations, `NullIf`, `Lag`) is still refused
there (#1311). PostgreSQL orders the `interval` itself, as before.

Examples on SQLite, where `scaled = (F("start_at") - F("date")) * F("round")` spans both sides of
100 hours over the 2009 season:

| order term | before | now |
|---|---|---|
| `SQLOrder(SQLField(F("time"), "x"))` on `Lap_times` | `ORDER BY "Tb"."time"`: the text | the lap time's length |
| `SQLOrder(SQLField(F("time") * 2, "x"))` | the doubled interval re-formatted as text | its length |
| `SQLOrder(SQLField(scaled, "s"); orientation = "DESC")` on `Race` | a 99-hour value before a 100-hour one | the longest first |

### Who this affects

Code that passes `SQLOrder(SQLField(<interval expression>, "label"))` to `order_by` on SQLite, with
values of 100 hours or more, or negative ones.

### How to find the calls to migrate

```bash
grep -rnE 'SQLOrder\(\s*SQLField\(' --include=*.jl src/ test/
```

For each match, check whether the expression is an interval: a `DurationField`, a timestamp
difference, or arithmetic or an aggregate over one.

### Migrate your app

```julia
# ✗ before — on SQLite a 99-hour value sorted before a 100-hour one (its text)
q = M.Race.objects
q.filter("year" => 2009)
q.values("raceid")
q.order_by(SQLOrder(SQLField((F("start_at") - F("date")) * F("round"), "s"); orientation = "DESC"))

# ✓ after — the same call sorts by the interval's length on both engines; nothing to change
```
