## A filter on an untyped `Case`, a window value or a condition checks its value as that type (#1034)

- **Version**: 0.9.0
- **PormG ref**: #1034 (phase 3, step 4) ; `src/querybuilder/projection_types.jl` (`_expression_formatter`), `src/querybuilder/expression_kind.jl` (`_kind_formatter`)
- **Recorded**: 2026-10-19
- **Severity**: behavior change, both engines. A filter on such an alias can raise `InvalidValueError` where it built. `Sum`/`Avg` of a condition, an untyped number `Case` or a number window function used as a `When` condition, and `LPad`/`RPad` over one of them raise `QueryBuildError`. PostgreSQL binds the value as the column's text. `Max`/`Min` of a condition runs on PostgreSQL now, and reads back as a `Bool` on SQLite.

### What changed

A filter on a projection alias checks its value with the type of the projected expression, and
binds what that type writes, as a filter on a column does. That type came from an inference of its
own, which named fewer types than PormG's type walk does. These projections had none, so a value
compared with them was not checked, and reached the engine as given:

- a `Case` with no `output_field`, whose value is one of its branches';
- a window value function (`Lag`, `Lead`, `FirstValue`, `LastValue`, `NthValue`), whose value is
  its operand's, and `Rank`, `DenseRank` and `RowNumber`, which are integers;
- a function over a condition (`Max(Q(…))`, `Min(Qor(…))`, `Coalesce(Q(…), false)`, a `Case` branch
  that is a `Q`), which is a boolean.

They now take the type the walk names, and a `Sum` or `Avg` of a `DurationField` is a duration, not
a number. The same type decides how an aggregate over the projection renders and whether it can be
a `When` condition:

- `Max`/`Min` over a condition renders PostgreSQL's `BOOL_OR`/`BOOL_AND` (`max(boolean)` does not
  exist there), and reads back as a `Bool` on SQLite, as over a `BooleanField` (#953);
- `Sum`/`Avg` over a condition is refused on both engines, naming the explicit count, as over a
  `BooleanField`;
- an untyped `Case` of numbers, or a window function over a number (`When(Lag("grid", over = …))`),
  used as a `When` condition is refused, as `Count(…)` is (#942); over a boolean it builds;
- `LPad`/`RPad` over an untyped number `Case` or a number window function is refused, as over a
  number column (#122), where SQLite padded the number's text;
- `Concat` over a boolean window function or a function over a condition is refused, as before, and
  the message names what it is over (`` `LAG(…)` over the BooleanField `is_rookie` `` for a
  race-entry model with that flag,
  `` `MAX(…)` over a Q(…) condition ``).

A value of the right type returns the rows it returned before.

Examples on `Result`, whose `fastestlaptime` is a `DurationField`:

| projection | then | before | now |
|---|---|---|---|
| `"fast" => Case([When("grid" => 1, then = F("fastestlaptime"))])` | `filter("fast__@gt" => 10)` | built; PostgreSQL failed at the server, SQLite compared `10` with the duration's text | `InvalidValueError` (a duration) |
| the same | `filter("fast__@gt" => Minute(1))` | PostgreSQL bound `Minute(1)` | binds `"00:01:00"`, as a `DurationField` filter does |
| `"w" => Subquery(<projects Lag("date", over = …)>)` | `filter("w__@gt" => 10)` | built | `InvalidValueError` (a date) |
| `"ahead" => Max(Q("grid__@gt" => 1))` | `list()` | PostgreSQL: `max(boolean)` failed; SQLite read `0`/`1` | PostgreSQL `BOOL_OR`; a `Bool` on both |
| the same | `filter("ahead" => 5)` | built | `InvalidValueError` (a boolean) |
| `"n" => Sum(Q("grid__@gt" => 1))` | `list()` | SQLite added up its 0/1; PostgreSQL failed | `QueryBuildError` on both: count explicitly |

On SQLite a `Cast` to `uuid`, `inet` or `cidr` renders `CAST(x AS TEXT)`, and a value compared with
it is now checked as that text.

Arithmetic PormG does not type yet (a duration times a number, `Extract(x, "EPOCH")`) keeps the
type it had: a number when its left side is one.

### Who this affects

Code that filters a projection alias holding one of the shapes above with a value of another type,
or uses one as a `When` condition or pads one with `LPad`/`RPad`; and code that sums or averages a
`Q`/`Qor`.

### How to find the calls to migrate

```bash
grep -rnE '(Case|Lag|Lead|FirstValue|LastValue|NthValue|Rank|DenseRank|RowNumber)\(|(Max|Min|Sum|Avg|Coalesce)\(Q' --include=*.jl src/ test/
```

For each, check whether a `filter` on its alias passes a value of the type it holds.

### Migrate your app

```julia
# ✗ before: on SQLite this summed 0/1; PostgreSQL refused it at the server
q = M.Result.objects
q.values("raceid", "front" => Sum(Q("grid__@lte" => 3)))

# ✓ after: say which number a flag counts as
q = M.Result.objects
q.values("raceid", "front" => Sum(Case([When(Q("grid__@lte" => 3), then = 1)], default = 0)))

# ✗ before: a number compared with a duration built
q = M.Result.objects
q.values("resultid", "fast" => Case([When("grid" => 1, then = F("fastestlaptime"))]))
q.filter("fast__@gt" => 87)

# ✓ after: compare it with a duration, as the column takes
q.filter("fast__@gt" => Second(87))
```
