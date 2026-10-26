## A value PormG cannot type, beside a date or a duration, is refused on SQLite and MySQL (#1310)

- **Version**: Unreleased
- **PormG ref**: #1310 ; `src/querybuilder/expression_render.jl` (`_checking_unnamed_temporal`), `src/querybuilder/expression_kind.jl` (`_unnamed_temporal_side`), `src/querybuilder/engine_facts.jl` (`_types_temporal_operands`), `src/querybuilder/filter_nodes.jl`, `src/querybuilder/projection_types.jl`
- **Recorded**: 2026-10-21
- **Severity**: behavior change, SQLite and MySQL. Arithmetic (`+`, `-`, `*`, `/`) or an ordering (`<`, `>`, `<=`, `>=`, `@range`) that built and returned a number computed on a date's or a duration's text, or rows chosen by comparing that text, now raises `QueryBuildError` when the query is built. PostgreSQL is unchanged.

### What changed

PormG writes the SQL of arithmetic and of an ordering beside a date, a timestamp or an interval by its
type: a whole-day shift, an interval in milliseconds, a date's text. A side whose type PormG cannot
name fell to the generic `(l op r)`:

- a JSON key lookup (`"meta__round"`), whose type is the data's;
- a `Case` or a `Coalesce` whose values have different types (a duration or `0`, a date or `0`, a JSON
  key or a date);
- a function over one of those (`Max(<such a Case>)`), or a number function over a duration, which
  names no type (`Floor(F("fastestlaptime") * 2)`).

SQLite computes that SQL on what it stores: a date's text, and an interval's `HH:MM:SS` text.

- `Case(<a duration or 0>) * 2` read `0` (the #1301 shape).
- `Case(<a JSON key or a date>) + 1` read `2010` (the #1307 shape).
- A JSON number compared with a date sorted before every date, since every number sorts before every
  text.

Each of those shapes was found by a review after it shipped.

The rule now covers the class. On an engine that computes on what it stores (SQLite and MySQL), the
build refuses arithmetic or an ordering where a side PormG cannot type:

- stands beside a date, a timestamp or an interval; or
- holds one: one of its values, the operand of a function whose value is that operand's, or a
  `Lag`/`Lead` `default`, is a date, a timestamp or an interval.

Every spelling of the ordering is checked: `F(…) > F(…)`, a filter pair (`"date__@gt" => F(…)`), a
filter on a projected alias, `Q(…)`, a `When` condition, and an `update()` value. The message names:

- the operator;
- the side as you wrote it (`` `CASE(…)` ``, `` `meta__round` ``);
- the engine;
- the spellings that state the type there.

These keep building, on every engine:

- equality and `@in`;
- a value PormG cannot type, holding no date or duration, beside a number (`F("meta__round") * 2`,
  `F("meta__round") > 2`);
- a function that names its own result over a date (`Count("date")`, `Extract("date", "YEAR")`);
- a shape an earlier rule already refused, which keeps its own message.

A time of day (`TimeField`) is covered too, since #1323, in the same train (its own entry,
`2026-10-26-1323-time-of-day-arithmetic-refused.md`). A `Case` or a `Coalesce` whose values are two
types PormG can name (a duration or `0`, a date or `0`) is refused before this check, on every engine,
by #1321 (`2026-10-26-1321-number-beside-date-or-uuid-refused.md`). A number function over a duration
(`Floor(F("fastestlaptime") * 2)`) is refused at the function, on every engine, by #1324
(`2026-10-26-1324-math-over-duration-refused.md`), so the `Floor` row below now raises on PostgreSQL too.
The rows below that use one of these still raise `QueryBuildError`, with that message.

PostgreSQL resolves the operands' types itself, so its SQL does not change. It still raises at the
server when the types have no operator or common type, as `CASE` over an interval and a `bigint` does.

On MySQL, `Case` and `Coalesce` render since #1130 phase 2c-1, and their shapes above meet this
refusal there. A `Case` or a `Coalesce` of a duration and a number (`case_lap` below) is refused on
MySQL before any arithmetic, since MySQL stores a duration as its count of microseconds. JSON lookups
and `Extract` are later phases of #1130; the refusal is in place for when they render.

Examples, where `case_lap = Case(When("rank" => 1, then = F("fastestlaptime")), default = 0)` on
`Result`:

| expression | SQLite before | SQLite now | PostgreSQL |
|---|---|---|---|
| `values("d" => case_lap * 2)` | `0` on the rank-1 rows (the text times 2) | `QueryBuildError` | unchanged: the server rejects `CASE` over an interval and a `bigint` |
| `values("d" => Case(When(…, then = F("meta__round")), default = F("date")) + 1)` | the year plus one (`2010`) | `QueryBuildError` | unchanged |
| `values("d" => Coalesce("meta__round", "date") + 1)` | the year plus one | `QueryBuildError` | unchanged |
| `values("d" => F("raceid") + Coalesce("date", 0))` on `Race` | the race id plus the year | `QueryBuildError` | unchanged |
| `values("d" => Floor(F("fastestlaptime") * 2) / 2)`, also under a `Cast` | the floor of the interval's text (`0`), halved; under `Cast(…, "integer")` it was refused naming the cast (#1259) | `QueryBuildError` naming `` `FLOOR(…)` `` and `/` | unchanged |
| `filter(F("meta__round") > F("date"))`, `filter("date__@gt" => F("meta__round"))` | a JSON number sorts before every date | `QueryBuildError` | unchanged |
| `filter("fastestlaptime__@gt" => case_lap)` | the text compared with the `Case`'s value | `QueryBuildError` | unchanged |
| `values("c" => <a Case over a JSON key or a date>)`, then `filter("c__@gt" => Date(2009, 1, 1))` | the value's text compared with `'2009-01-01'` | `QueryBuildError` | unchanged |
| `values("d" => F("date") * F("meta__round"))` | the year times the value | `QueryBuildError` | unchanged: the server has no `date * …` |
| `filter(F("meta__round") == F("date"))`, `values("d" => F("meta__round") * 2)` | built | builds, unchanged | unchanged |

### Who this affects

Code on SQLite that does arithmetic, or orders, with a date, a timestamp or a `DurationField` beside:

- a JSON key lookup;
- a `Case` or a `Coalesce` whose values have different types;
- a function over one of those.

### How to find the calls to migrate

```bash
grep -rnE '\b(Case|Coalesce|Greatest|Least|NullIf|Lag|Lead|Floor|Ceil)\(' --include=*.jl src/ test/
```

For each match, check two things:

- whether the expression mixes a date, a timestamp or a duration with a value of another type, or with
  a JSON key lookup;
- whether it is used in arithmetic (`+`, `-`, `*`, `/`) or an ordering: `>`, `<`, `>=`, `<=`, an
  `__@gt`-style lookup or `__@range`.

Also search for JSON key paths (`"<jsonfield>__<key>"`) beside a date or a duration in `F(...)` or in a
filter pair's value.

### Migrate your app

```julia
# ✗ before — on SQLite the rank-1 rows read 0: the duration's text times 2
q = M.Result.objects
q.filter("raceid__year" => 2009)
q.values("driverid__surname", "d" => Case(When("rank" => 1, then = F("fastestlaptime")), default = 0) * 2)

# ✓ after — the arithmetic inside the branch, and a default of the same type
q = M.Result.objects
q.filter("raceid__year" => 2009)
q.values("driverid__surname", "d" => Case(When("rank" => 1, then = F("fastestlaptime") * 2), default = Second(0)))
```

A value that holds a date in every row can instead be cast: `Cast(<the value>, "date")`. On SQLite a
cast to a timestamp or an interval is a `BackendCapabilityError`, so for those give every value one
type and do the arithmetic in each branch.
