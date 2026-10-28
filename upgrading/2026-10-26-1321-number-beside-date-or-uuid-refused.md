## A conditional over a number and a date, a time, an interval or a UUID is refused on every engine (#1321)

- **Version**: 0.9.0
- **PormG ref**: #1321 ; `src/querybuilder/projection_types.jl` (`_temporal_mix_class`, `_is_mix`, `_declaration_lifts`), `src/querybuilder/functions.jl` (`_temporal_mix_refusal`)
- **Recorded**: 2026-10-26
- **Severity**: behavior change. On SQLite, a `Coalesce`, `Greatest`, `Least`, `NullIf`, `Case`, or a `Lag`/`Lead` with a `default`, whose values include both a number and a date, a timestamp, a time, an interval or a UUID used to build. So did one whose values include a UUID and a date, a timestamp, a time or an interval. Each now raises `QueryBuildError` when the query is built, in a projection, a filter or an `update`. On PostgreSQL the same query used to fail at the server and now fails at build time.

### What changed

PostgreSQL has no common type for a number and a date (or a time, an interval, a UUID), and raises
`COALESCE types integer and date cannot be matched` when the statement runs. SQLite returns whichever
operand is not `NULL`: a number on one row, the date's text on another. Through `update` it stored
that text in a number column:

```julia
q = M.Result.objects
q.filter("resultid" => 1)
q.update("grid" => Coalesce("grid", "raceid__date"))   # SQLite: the date's text in "grid" where grid was NULL
```

That `Coalesce` has no one type, so the type walk left it untyped, and the guard that refuses a date
written into a number field (#1297) did not see it.

The rule that refuses a date beside text (#1200) and text beside a number (#1327) now refuses two
operands of different types among text, a number, a date, a timestamp, a time, an interval and a UUID.
A number is one type here (an integer, a float and a decimal), and a UUID is another. The message names both operands. No common type exists, so it names none. A
declared `output_field` does not lift the refusal when one side is a number or a UUID: it casts the
result outside the call, and the engine still meets both types inside it.

| expression | SQLite before | now, every engine |
|---|---|---|
| `update("grid" => Coalesce("grid", "raceid__date"))` on `Result` | the date's text in `grid` where `grid` was NULL | `QueryBuildError` |
| `values("v" => Coalesce("date", "year"))` on `Race` | a date on some rows, a number on others | `QueryBuildError` |
| `values("v" => Coalesce("time", 0))` on `Race` | the time's text, or `0` | `QueryBuildError` |
| `values("v" => Greatest("fastestlaptime", "grid"))` on `Result` | by SQLite's type order | `QueryBuildError` |
| `values("v" => Coalesce("date", "year"; output_field = "date"))` on `Race` | each row cast to a date | `QueryBuildError` |
| `values("v" => Coalesce("year", Extract("date", "year")))` on `Race` | built | builds, unchanged |

These keep building:

- an integer beside a float or a decimal;
- a UUID beside text: SQLite and MySQL hold a UUID as its text (a cast to `uuid` is text there), and
  PostgreSQL raises at the server for a text column beside a UUID, as before;
- an operand PormG cannot type (raw SQL, a JSON key lookup) beside anything (a boolean or a whole
  JSON document beside another type is refused since #1386, in its own entry);
- a `NULL` operand;
- a date beside a timestamp under an `output_field`, as since #1200.

### Who this affects

Code that puts a number and a date, timestamp, time, duration or UUID in the same `Coalesce`,
`Greatest`, `Least`, `NullIf`, `Case` (its branches and its `default`), or `Lag`/`Lead` `default`. That
includes a numeric literal default beside a temporal column (`Coalesce("time", 0)`).

### How to find the calls to migrate

```bash
grep -rnE '\b(Case|Coalesce|Greatest|Least|NullIf|Lag|Lead)\(' --include=*.jl src/ test/
```

For each match, check whether one operand is a number (a numeric column, a numeric literal, an
aggregate over one) while another is a date, timestamp, time, duration or UUID column or literal.

### Migrate your app

```julia
# ✗ before — on SQLite, rows where grid is NULL received the date's text
q = M.Result.objects
q.filter("raceid__year" => 2009)
q.update("grid" => Coalesce("grid", "raceid__date"))

# ✓ after — say which number the date stands for
q = M.Result.objects
q.filter("raceid__year" => 2009)
q.update("grid" => Coalesce("grid", Extract("raceid__date", "year")))
```

A default for a temporal column is a value of its own type: `Coalesce("time", Time(0))`, not
`Coalesce("time", 0)`.
