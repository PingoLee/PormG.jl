## Arithmetic on a time of day is refused on SQLite and MySQL (#1323)

- **Version**: Unreleased
- **PormG ref**: #1323 ; `src/querybuilder/expression_render.jl` (`_time_arithmetic_side`, `_time_arithmetic_refusal`, `_refuse_unnamed_temporal`), `src/querybuilder/expression_kind.jl` (`_is_temporal_kind`, `_side_walk_kind`)
- **Recorded**: 2026-10-26
- **Severity**: behavior change, SQLite and MySQL. Arithmetic (`+`, `-`, `*`, `/`) with a `TimeField` on either side, and an ordering between a time and a value PormG cannot type (a JSON key lookup), used to build and return a number computed on the time's text. They now raise `QueryBuildError` when the query is built. PostgreSQL is unchanged.

### What changed

SQLite stores a `TimeField` as its `HH:MM:SS` text. Arithmetic on it fell to the generic `(l op r)`,
and SQLite computes that on the number the text's leading digits spell. MySQL reads a time as the
number its digits spell. On the 2009 Australian Grand Prix (`time = 06:00:00`):

| expression on `Race` | SQLite before | SQLite and MySQL now | PostgreSQL |
|---|---|---|---|
| `values("x" => F("time") + 1)` | `7` | `QueryBuildError` | unchanged: fails at the server (no `time + bigint`) |
| `values("x" => F("time") * 2)` | `12` | `QueryBuildError` | unchanged: fails at the server |
| `values("x" => F("year") + F("time"))` | the year plus the hour | `QueryBuildError` | unchanged: fails at the server |
| `filter(F("meta__round") > F("time"))`, a JSON key | text against the key's value | `QueryBuildError` | unchanged |
| `values("x" => Coalesce("time", 0) * 2)` | the hour times two | `QueryBuildError` on every engine (#1321's mix) | refused at build (#1321) |
| `filter("time__@lt" => Time(12))`, `F("time") > Time(12)` | built | builds, unchanged | unchanged |

The refusal names the operator, the side and the engine. What arithmetic on a time of day would mean
(a time shifted by a duration, wrapping at midnight; the difference of two times) has no spelling on
SQLite or MySQL in PormG, so the message names none. `F("time") + Hour(1)` was already refused, and
still is.

A time of day also joins the dates, timestamps and intervals of #1310's check: a value PormG cannot
type (a JSON key lookup), beside a time in arithmetic or an ordering, is refused on SQLite and MySQL.

### Who this affects

Code on SQLite that does arithmetic with a `TimeField`, or that orders a `TimeField` against a JSON
key lookup.

### How to find the calls to migrate

```bash
grep -rnE 'F\("[A-Za-z_]*time[A-Za-z_]*"\) *[-+*/]' --include=*.jl src/ test/
```

Also look for `TimeField` columns of your models used with `+`, `-`, `*` or `/` in `F(...)`
expressions, in `values`, `annotate`, `filter` and `update`.

### Migrate your app

```julia
# ✗ before — on SQLite each row read the hour plus one
q = M.Race.objects
q.filter("year" => 2009)
q.values("raceid", "later" => F("time") + 1)

# ✓ after — read the time and do the arithmetic in Julia
q = M.Race.objects
q.filter("year" => 2009)
rows = q.values("raceid", "time").list()
later = [r[:time] + Hour(1) for r in rows]
```

To filter by time of day, compare with a `Time` literal, which builds on every engine:
`filter("time__@lt" => Time(12))`.
