## A value PormG cannot type, beside a date or a duration, is refused on SQLite and MySQL (#1310)

- **Version**: Unreleased
- **PormG ref**: #1310 ; `src/querybuilder/expression_render.jl` (`_refuse_unnamed_temporal`), `src/querybuilder/expression_kind.jl` (`_unnamed_temporal_side`), `src/querybuilder/engine_facts.jl` (`_types_temporal_operands`)
- **Recorded**: 2026-10-21
- **Severity**: behavior change, SQLite and MySQL. F arithmetic (`+`, `-`, `*`, `/`) or an ordering (`<`, `>`, `<=`, `>=`) that built and returned a number computed on a date's or a duration's text now raises `QueryBuildError` when the query is built. PostgreSQL is unchanged.

### What changed

PormG writes the SQL of arithmetic and of an ordering beside a date, a timestamp or an interval by its
type: a whole-day shift, an interval in milliseconds, a date's text. A side whose type PormG cannot
name fell to the generic `(l op r)`:

- a JSON key lookup (`"meta__round"`), whose type is the data's;
- a `Case` or a `Coalesce` whose values have different types (a duration or `0`, a date or `0`, a JSON
  key or a date);
- a function over one of those (`Max(<such a Case>)`), or a number function over a duration, which
  names no type (`Floor(F("fastestlaptime") * 2)`).

SQLite computes that SQL on what it stores: a date's text, and an interval's `HH:MM:SS` text. So
`Case(<a duration or 0>) * 2` read `0` (the #1301 shape), `Case(<a JSON key or a date>) + 1` read
`2010` (the #1307 shape), and a JSON number compared with a date sorted before every date, since every
number sorts before every text. Each of those shapes was found by a review after it shipped.

The rule now covers the class. On an engine that computes on what it stores (SQLite and MySQL), the
build refuses arithmetic or an ordering where a side PormG cannot type:

- stands beside a date, a timestamp or an interval; or
- holds one: one of its values, or the operand of a function whose value is that operand's, is a date,
  a timestamp or an interval.

The message names the operator, the side as you wrote it (`` `CASE(…)` ``, `` `meta__round` ``), the
engine, and the spellings that state the type there.

These keep building, on every engine:

- equality and `@in`;
- a value PormG cannot type beside a number (`F("meta__round") * 2`, `F("meta__round") > 2`);
- a function that names its own result over a date (`Count("date")`, `Extract("date", "YEAR")`);
- a shape an earlier rule already refused, which keeps its own message.

PostgreSQL resolves the operands' types itself, so its SQL does not change. It still raises at the
server when the types have no operator or common type, as `CASE` over an interval and a `bigint` does.

MySQL renders none of these shapes yet: `Case`, `Coalesce`, JSON lookups and `Extract` are later
phases of #1130. The refusal is in place for when they render.

Examples, where `case_lap = Case(When("rank" => 1, then = F("fastestlaptime")), default = 0)` on
`Result`:

| expression | SQLite before | SQLite now | PostgreSQL |
|---|---|---|---|
| `values("d" => case_lap * 2)` | `0` on the rank-1 rows (the text times 2) | `QueryBuildError` | unchanged: the server rejects `CASE` over an interval and a `bigint` |
| `values("d" => Case(When(…, then = F("meta__round")), default = F("date")) + 1)` | the year plus one (`2010`) | `QueryBuildError` | unchanged |
| `values("d" => Coalesce("meta__round", "date") + 1)` | the year plus one | `QueryBuildError` | unchanged |
| `values("d" => F("raceid") + Coalesce("date", 0))` on `Race` | the race id plus the year | `QueryBuildError` | unchanged |
| `values("d" => Floor(F("fastestlaptime") * 2) / 2)`, also under a `Cast` | the floor of the interval's text (`0`), halved; under `Cast(…, "integer")` it was refused naming the cast (#1259) | `QueryBuildError` naming `` `FLOOR(…)` `` and `/` | unchanged |
| `filter(F("meta__round") > F("date"))` | a JSON number sorts before every date | `QueryBuildError` | unchanged |
| `filter(F("fastestlaptime") > F("meta__round"))` | the text compared with the JSON value | `QueryBuildError` | unchanged |
| `filter(F("meta__round") < Date(2009, 1, 1))` | the JSON value compared with `'2009-01-01'` | `QueryBuildError` | unchanged |
| `values("d" => F("date") * F("meta__round"))` | the year times the value | `QueryBuildError` | unchanged: the server has no `date * …` |
| `filter(F("meta__round") == F("date"))`, `values("d" => F("meta__round") * 2)` | built | builds, unchanged | unchanged |

### Who this affects

Code on SQLite that does arithmetic, or orders, with a date, a timestamp or a `DurationField` beside:

- a JSON key lookup;
- a `Case` or a `Coalesce` whose values have different types;
- a function over one of those.

### How to find the calls to migrate

```bash
grep -rnE 'Case\(|Coalesce\(|Greatest\(|Least\(|NullIf\(' --include=*.jl src/ test/ | grep -E '[-+*/<>]'
```

For each match, check whether the expression mixes a date, a timestamp or a duration with a value of
another type, or a JSON key lookup. Then check whether it sits in arithmetic or an ordering. Also
search for JSON key paths (`"<jsonfield>__<key>"`) used inside `F(...)` beside a date or a duration.

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

A value that is a date, a number or text in every row can instead be cast: `Cast(<the value>, "date")`
or `Cast(<the value>, "integer")`. On SQLite a cast to a timestamp or an interval is a
`BackendCapabilityError`; do the arithmetic in each branch.
