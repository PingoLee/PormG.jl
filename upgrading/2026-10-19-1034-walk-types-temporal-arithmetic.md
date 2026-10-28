## Date and duration arithmetic has a type outside its own render: filters, `Coalesce` and division checks see it (#1034)

- **Version**: 0.9.0
- **PormG ref**: #1034 (phase 3, steps 5a and 5c) ; `src/querybuilder/expression_kind.jl` (`_temporal_arith_kind`), `src/querybuilder/projection_types.jl` (`_textless_temporal`)
- **Recorded**: 2026-10-19
- **Severity**: behavior change, both engines. A filter on an alias of date or duration arithmetic checks its value and can raise `InvalidValueError` where it built. A `Coalesce`/`Greatest`/`Least` that mixes shifted timestamps with dates raises `QueryBuildError` where it built. A pattern lookup on a duration alias raises `FilterError`. A `Concat` over a `Case`, `Lag`, `NullIf` or `Min` of such arithmetic raises `QueryBuildError` where it built, and on SQLite so does a cast to a number of a duration from arithmetic, or of `Mod` over one. A `Sum` of day counts, divided, builds where PostgreSQL refused it. Some values read back as a `Date` or `DateTime` instead of text on SQLite, and an `Avg` of day counts as a `Float64` instead of a `Decimal` on PostgreSQL.

### What changed

PormG typed date and duration arithmetic only while writing its SQL. `F("date") - F("date")` was a
day count, `F("start_at") - F("start_at")` an interval and `F("date") + Day(1)` a date there, but every
other part of a query saw no type for them. PormG's type inference now names the same type as the
SQL it writes:

| expression | type |
|---|---|
| `F("date") + Day(1)`, `F("date") + 1`, `F("date") + F("year")` | date |
| `F("date") + Hour(1)`, `F("date") + <a duration>` | timestamp |
| a timestamp shifted, or plus a duration | the timestamp's own type |
| `F("date") - F("date")` | integer (days) |
| `F("start_at") - F("start_at")` | duration |
| duration ± duration, duration × or ÷ a number, a number × a duration | duration |

Everything that asks for a type sees it now:

- **A filter on such an alias** checks and binds its value as that type, as a filter on a column of
  that type does (#1034 step 4). A value of another type raises `InvalidValueError`, and PostgreSQL
  binds the value as the column's text: `"01:00:00"`, not `Hour(1)`.
- **`Coalesce`, `Greatest`, `Least` and `Case`** refuse a mix of a timestamp and a date (#1200) when
  one side is a shifted timestamp, as they already did for the column.
- **A pattern lookup** (`@contains`, `@startswith`, …) on a duration alias is refused on every engine
  (#1183), as on a `DurationField`. On SQLite it matched the duration's text before.
- **`Concat` over a value that carries such arithmetic** — a `Case` with no `output_field`, a `Lag`, a
  `NullIf`, a `Min` — is refused on every engine (#1028), as `Concat` over the arithmetic itself and
  over a `DateTimeField` already were: each engine writes its own text for a timestamp or a duration.
  Name the format (`ToChar(…, "YYYY-MM-DD HH:MI:SS")`) or cast it to text (step 5c).
- **A cast to a number of a duration from arithmetic** — a duration times or divided by a float or a
  decimal (`Cast(F("fastestlaptime") * 1.5, "float8")`), the same under a further step
  (`Floor(F("fastestlaptime") * 2) / 2`), or wrapped in `Lag` or `Coalesce` with a number
  `output_field` — is refused on SQLite (#1259), as the `DurationField` column already was: SQLite
  cast the leading digits of the duration's text, its hours. PostgreSQL builds it, and its server
  raises the error such a cast means. A cast to an integer of `Mod` over such arithmetic is refused on
  SQLite with the #1028 message `Mod("fastestlaptime", 3)` already had (step 5c).
- **`Abs`/`Round` over a day count** keep the integer (#1147), so PostgreSQL renders a bare `ABS(…)`.
- **A `Sum` of day counts, divided,** is an integer quotient on both engines and builds. PostgreSQL
  refused it before as a sum PormG could not type (#1111).
- **A value that is one of its operands'** (`Greatest("date", F("date") + 1)`, `Max(F("date") + Hour(1))`,
  `Coalesce(F("date") + 1, "date")`) has the date or timestamp its operands agree on, so SQLite's text
  reads back as a `Date` or a `DateTime`, as PostgreSQL's driver returned it.
- **An `Avg` of day counts** (`Avg(F("date") - F("date"))`) is the float it means (#1121), on both
  engines: PostgreSQL's driver handed back a `Decimal` before.

Examples on `Race` (`date` a `DateField`, `start_at` a `DateTimeField`) and `Result`
(`fastestlaptime` a `DurationField`):

| query | before | now |
|---|---|---|
| `values("d" => F("date") + Day(1)); filter("d__@gt" => 10)` | built; PostgreSQL failed at the server | `InvalidValueError` (a date) |
| `values("gap" => F("start_at") - F("start_at")); filter("gap__@gt" => Hour(1))` on PostgreSQL | bound `Hour(1)` | binds `"01:00:00"` |
| `values("c" => Coalesce(F("start_at") - Day(1), "date"))` | built | `QueryBuildError`: mixes a timestamp and a date (#1200) |
| `values("gap" => F("start_at") - F("start_at")); filter("gap__@contains" => "06")` | SQLite matched the text; PostgreSQL failed | `FilterError` on both (#1183) |
| `values("n" => Cast(Sum(F("date") - F("date")) / 2, "integer"))` on PostgreSQL | `QueryBuildError` (#1111) | builds: the integer quotient on both engines |
| `values("g" => Greatest("date", F("date") + 1))` on SQLite | read `"2009-03-30"` | reads `Date(2009, 3, 30)` |
| `values("a" => Avg(F("date") - F("date")))` on PostgreSQL | read a `Decimal` | reads a `Float64` |
| `values("t" => F("grid") * F("fastestlaptime")); filter("t__@gt" => 10)` | bound `10` as a number | `InvalidValueError` (a duration) |
| `values("s" => Concat(Value("-"), Case(When("year" => 2009, then = F("date") + Hour(1)))))` | built; each engine wrote its own timestamp text | `QueryBuildError` (#1028) |
| `values("h" => Cast(F("fastestlaptime") * 1.5, "float8"))` on SQLite | built; read the hours | `QueryBuildError` (#1259) |

`Extract(x, "EPOCH")` still has no stated type, and arithmetic over it keeps its old rule: a number
when its left side is one.

### Who this affects

Code that filters an alias of date or duration arithmetic with a value of another type, or with a
pattern lookup; that combines shifted timestamps with dates in `Coalesce`/`Greatest`/`Least`/`Case`;
that passes a `Case`/`Lag`/`NullIf`/`Min` of such arithmetic to `Concat`, or on SQLite casts a
duration from arithmetic (or `Mod` over one) to a number; or that reads such a `Greatest`/`Coalesce`/`Max` back on SQLite and
expects a `String`, or an `Avg` of day counts on PostgreSQL and expects a `Decimal`.

### How to find the calls to migrate

```bash
grep -rnE 'F\("[a-z_]+"\) *[-+*/] *(F\(|Day|Hour|Minute|Second|Week|Month|[0-9])' --include=*.jl src/ test/
```

For each, check the type of the value its alias is filtered with, and whether it reaches a `Concat`
or, on SQLite, a cast to a number.

### Migrate your app

```julia
# ✗ before: a number compared with a shifted date built, and failed at the server on PostgreSQL
q = M.Race.objects
q.values("raceid", "next_day" => F("date") + Day(1))
q.filter("next_day__@gt" => 10)

# ✓ after: compare it with a date, as the column takes
q.filter("next_day__@gt" => Date(2009, 3, 29))

# ✗ before: a shifted timestamp beside a date built
q.values("first" => Coalesce(F("start_at") - Day(1), "date"))

# ✓ after: combine values of one type (on PostgreSQL, output_field = "timestamptz" also says it)
q.values("first" => Coalesce(F("start_at") - Day(1), "start_at"))

# ✗ before: Concat over a Case of a shifted date built, and each engine wrote its own text
q.values("label" => Concat(Value("-"), Case(When("year" => 2009, then = F("date") + Hour(1)))))

# ✓ after: name the format
q.values("label" => Concat(Value("-"), ToChar(Case(When("year" => 2009, then = F("date") + Hour(1))), "YYYY-MM-DD HH:MI:SS")))
```
