## Arithmetic over a window function on a date, a timestamp or a duration, and a duration beside a time, is typed (#1459)

- **Version**: Unreleased
- **PormG ref**: #1459, #1465 ; `src/querybuilder/expression_render.jl` (`_side_kind`, `_side_function_kind`, `_temporal_side_kind`), `src/querybuilder/expression_kind.jl` (`_typed_right_operand`)
- **Recorded**: 2026-10-29
- **Severity**: behavior change on every engine, in queries that were wrong before. Arithmetic over a window value function (`Lag`, `Lead`, …) on a date, a timestamp or a duration now builds as date, timestamp or duration arithmetic, or raises `QueryBuildError` where the engine cannot compute it. Before, it was computed as plain number arithmetic: a silently wrong value, or a server error. A duration multiplied or divided by a time cast now raises `QueryBuildError` on SQLite and MySQL.

### What changed

PormG types each side of `F` arithmetic before it writes the operator. It used to type a window
function as a side only when the function's operand was a plain column. A window function on the
right of `*` or `/` was not typed at all, whatever its operand (#1465). It typed no `Cast`, no `Case`
and no arithmetic under a window function. It also typed a time cast, or a `Case` over times, as no
type at all. Those sides now have the type of the value they hold.

Examples on `Result`, joined to its `Race`. `raceid__date` is a `DateField`, `raceid__start_at` a
`DateTimeField`, and `fastestlaptime` a `DurationField`:

| expression | engine | before | now |
|---|---|---|---|
| `Lag(Case([When("grid" => 1, then = F("raceid__date"))]), over = …) + 1` | SQLite | `LAG(…) + ?`: 1 added to the date's text | `date(LAG(…), '+' \|\| ? \|\| ' days')`: the next day |
| same | PostgreSQL | `LAG(…) + $n::bigint`: a server error (`date + bigint`) | `(LAG(…) + make_interval(days => …))::date` |
| same | MySQL | `LAG(…) + ?`: a number | `LAG(…) + INTERVAL ? DAY` |
| `Lag(Cast("raceid__start_at", "timestamp"), over = …) + 1` | PostgreSQL | a server error (`timestamp + bigint`) | `… + make_interval(days => …)` |
| same | MySQL | `LAG(…) + ?`: a number | `LAG(…) + INTERVAL ? DAY` |
| `Lag(Case([When("grid" => 1, then = F("fastestlaptime"))]), over = …) * F("grid")` | SQLite | built: multiplied the `HH:MM:SS` text | `QueryBuildError`: SQLite has no millisecond form for that interval (#881) |
| `Lag(F("raceid__start_at") - F("raceid__start_at"), over = …) * 2` | SQLite | built: multiplied the text | `QueryBuildError` |
| `F("grid") * Lag("fastestlaptime", over = …)`, and `F("grid") *` any window above over a duration (#1465) | SQLite | built: multiplied the `HH:MM:SS` text | `QueryBuildError`, as the window on the left of `*` |
| same | PostgreSQL | unchanged SQL; no type | read back as a duration; a filter on the alias checks a duration |
| same | MySQL | `grid * LAG(…)` | `CAST(ROUND((grid) * (LAG(…))) AS SIGNED)`: read back as a duration |
| `F("grid") / Lag("fastestlaptime", over = …)` (#1465) | SQLite | built: divided by the `HH:MM:SS` text | `QueryBuildError`: a number divided by an interval has no meaning |
| `Lag(Cast("fastestlaptime", "interval"), over = …) * 2`, and the two shapes above | MySQL | `LAG(…) * ?` | `CAST(ROUND(LAG(…) * (?)) AS SIGNED)`: the same microseconds, read back as a duration |
| the three window-over-a-duration shapes above | PostgreSQL | unchanged SQL | unchanged SQL; read back as a duration, and a filter on the alias checks a duration |
| `F("fastestlaptime") * Cast("raceid__start_at", "time")` (also `/`, and a `Case` over times) | SQLite, MySQL | built: the stored duration times the time's text or number | `QueryBuildError` |
| same | PostgreSQL | unchanged SQL (the server rejects `interval * time`) | unchanged |

These values also read back as the date, timestamp or duration they are, as a `Lag` over a plain
column already did. A filter on their alias checks its value as one: `filter("v__@gt" => 10)` on such
an alias now raises `InvalidValueError` naming the alias, instead of comparing the number.

### Who this affects

Code that adds a number to a window function over a `Case`, a `Cast` or arithmetic on a date or a
timestamp, or multiplies such a window over a duration. On PostgreSQL those queries failed at the
server; on SQLite and MySQL they returned wrong values. Also code that multiplies or divides a
duration by a time cast or a `Case` over times on SQLite or MySQL, which computed a meaningless number.

### How to find the calls to migrate

```bash
grep -rnE '(Lag|Lead|FirstValue|LastValue|NthValue)\(' --include=*.jl src/ test/
```

Then look for those calls used as a side of `+`, `-`, `*` or `/`.

### Migrate your app

No edit is needed for a query that now builds: the same call now computes what it says. For example:

```julia
# ✗ before — on SQLite this added 1 to the date's text; on PostgreSQL it failed at the server
q = M.Result.objects
q.values("resultid", "prev_plus" => Lag(Case([When("grid" => 1, then = F("raceid__date"))]),
                                        over = WindowOver(order_by = ["resultid"])) + 1)

# ✓ after — the same call is date arithmetic: the previous row's date, one day later
q = M.Result.objects
q.values("resultid", "prev_plus" => Lag(Case([When("grid" => 1, then = F("raceid__date"))]),
                                        over = WindowOver(order_by = ["resultid"])) + 1)
```

A query that now raises `QueryBuildError` was computing a value with no meaning on that engine. Write
what it means instead, for example `Extract(d, "epoch")` for a duration's seconds on PostgreSQL and
MySQL.
