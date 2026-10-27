# Rounding

PormG does not decide how a number is rounded. A value is rounded where your query says so, by the
engine that runs it. Where an engine would not honor what a query declares, PormG refuses the query
on that engine rather than return a different number. Julia works the same way: a rounding mode is an
explicit argument (`round(x, RoundNearestTiesAway)`), and a lossy conversion raises
(`Int(2.5)` is an `InexactError`).

This page collects the rules and shows what to write instead of each refused query. The details stay
on the pages they belong to: [The type of a computed number](index.md#The-type-of-a-computed-number),
[Rounding to decimal places](functions_and_dates.md#Rounding-to-decimal-places) and
[A cast an engine computes differently](functions_and_dates.md#A-cast-an-engine-computes-differently).
Every result below was measured on PostgreSQL 16 and SQLite 3.54, and the MySQL results on MySQL 8.4,
against the Formula 1 dataset.

## The three rules

1. **PormG never rounds a value in Julia.** A value with more places than its `DecimalField` holds is
   refused when you write it, not rounded to fit, and a `DecimalField` column reads back as the
   `Decimal` it holds.
2. **A value is rounded only where your code asks for it:** `Round(x, d)`, `Floor(x)`, `Ceil(x)`, or a
   `Cast` to `numeric(p, s)`, to a `DecimalField(max_digits, decimal_places)`, to an integer or to
   single precision (`real`), or the same type as an `output_field`. The rounding is the engine's
   own, on an engine that applies the declaration.
3. **Where an engine would not honor a declared scale or type, PormG refuses the query on that engine
   only.** It raises `QueryBuildError` when the query is built, and the message names the explicit
   spelling. That spelling is usually `Round(x, s)` before the cast.

**Three conversions to the type a call means.** None is rounding to a scale. Each turns what the
driver delivers into the Julia type the call means (#1121):

- SQLite computes a decimal aggregate and decimal arithmetic as a double. PormG reads that double as
  a `Decimal` rounded to **15 significant digits**, as Django's SQLite backend does. That keeps the
  precision the double has and adds none.
- PostgreSQL computes `Avg` over integers, and a function over a float such as `Round` or `Sqrt`, as a
  `numeric`. When the call means a float, PormG reads it as the nearest `Float64`.
- MySQL computes `Avg` over integers, and `Round` over a float, as a `DECIMAL`, read as the nearest
  `Float64` when the call means a float. It computes `Sqrt`, `Exp`, `Ln` and `Power` over a decimal as
  a double, read as a `Decimal` to 15 significant digits, as on SQLite.

## Reading a decimal

A `DecimalField` column reads back as the `Decimal` it holds, on every engine (#648):

```julia
# Constructor result 3835 scored 5.5 points.
M.Constructor_results.objects.filter("constructorresultsid" => 3835).values("points").list()
# => points = Decimal 5.5 on every engine
```

That holds for every value PormG checked on its way in. On SQLite, a cell with more places than the
declaration reads back rounded to its scale, as PostgreSQL's column would hold it. A cell with more
digits before the point than the declaration allows raises `StatementError` with
`sqlstate == "22003"` on every read of it, the error PostgreSQL raises when such a value is written
(#1110). On MySQL a column made wider than its field by hand raises the same error for a value the
field cannot hold ([MySQL Guide](../mysql.md#Reads)). Such a cell can only come from a write PormG did not check, such as a tool other than PormG. An
expression `update` (*Writing a decimal* below) is checked as it writes.

`Sum` and `Avg` of a `DecimalField` read back as a `Decimal` on every engine. `Avg` of an integer reads
back as a `Float64`:

```julia
using PormG.Functions: Avg, Sum

M.Constructor_results.objects.filter("raceid" => 18).
    values("total" => Sum("points"), "avg" => Avg("points")).list()
# PostgreSQL => total 39, avg 3.5454545454545455   both Decimals
# SQLite     => total 39, avg 3.54545454545455     both Decimals, to 15 significant digits
# MySQL      => total 39, avg 3.545454545454545454545454545455   both Decimals

M.Result.objects.filter("raceid" => 2).values("avg_grid" => Avg("grid")).list()
# => avg_grid = 10.5, a Float64 on every engine
```

## Rounding you ask for

`Round`, `Floor` and `Ceil` use each engine's own function. Each reads back as its operand's type:
a `Decimal` over a `DecimalField`, a `Float64` over a float, and an integer over an integer.

`Round(x, d)` rounds half away from zero. PostgreSQL rounds a `numeric` (a float becomes one at 15
significant digits first), and SQLite rounds the stored double. MySQL rounds a double half to even
(its `ROUND(2.5E0)` is `2`), so PormG rounds a float there as a `DECIMAL(65,30)`, half away from zero,
from the double's shortest digits (#1130). The engines agree except at a decimal tie whose double
lies just below it (#1061):

| `Round(Value(v), 2)` | PostgreSQL | SQLite | MySQL |
|---|---|---|---|
| `2.675` | `2.68` | `2.67` | `2.68` |
| `1.555` | `1.56` | `1.55` | `1.56` |

A test that pins a rounded tie is therefore engine-specific. `Round(x)`, to a whole number, gives the
same value on every engine. A text operand is refused on every engine, because the query does not
say what it means: it raises `QueryBuildError`. A negative `d` rounds to tens, hundreds, … where the
engine has it (`Round(125, -1)` is `130` on PostgreSQL and MySQL), and raises `BackendCapabilityError`
on SQLite, whose `ROUND` has no negative precision.

Division keeps the type of its operands, so an integer divided by an integer is an integer quotient
on every engine (#1147, #1196). Divide by a float to keep the fraction:

```julia
using PormG: F

# Result 1: Lewis Hamilton started the 2008 Australian GP from grid 1.
M.Result.objects.filter("resultid" => 1).values(
    "whole" => F("grid") / 2,       # 0 on every engine: integer division
    "half"  => F("grid") / 2.0).list()   # 0.5 on every engine
```

One quotient is refused on PostgreSQL and MySQL instead: a `Sum` PormG cannot type, divided.
PostgreSQL computes that sum as a `numeric`, and MySQL as a `DECIMAL`, and each keeps the fraction
(#1111). Its message names the cast that
says which you mean ([A cast an engine computes differently](functions_and_dates.md#A-cast-an-engine-computes-differently)).

## A declared scale or type

A cast to `numeric(p, s)` means the value rounded to `s` places. PostgreSQL and MySQL round it;
SQLite would keep every digit, so the cast is refused there (#1040). Round to the scale first, and the
cast builds on every engine with the same value:

```julia
using PormG.Functions: Cast, Round
using PormG: F

# Race 2, the 2009 Malaysian GP, was stopped early and scored half points.
M.Result.objects.filter("raceid" => 2).
    values("points", "x" => Cast(F("points") * 1.5, "numeric(10,1)")).list()
# PostgreSQL => 0.5 → 0.8, 1.5 → 2.3, 2.5 → 3.8   (Decimals, rounded by the cast)
# MySQL      => 0.5 → 0.8, 1.5 → 2.3, 2.5 → 3.8   (Decimals, rounded by the cast)
# SQLite     => QueryBuildError: Cast(…, "numeric(10,1)") of arithmetic over the FloatField `points`
#               means the value rounded to the scale of numeric(10,1); SQLite computes every digit
#               of it, so PormG refuses it on SQLite (#1040). Round it to the scale first …

M.Result.objects.filter("raceid" => 2).
    values("points", "x" => Cast(Round(F("points") * 1.5, 1), "numeric(10,1)")).list()
# => 0.5 → 0.8, 1.5 → 2.3, 2.5 → 3.8 on every engine
```

A `DecimalField` object is the same declaration (#1221):
`Cast(x, DecimalField(max_digits = 10, decimal_places = 1))` is `Cast(x, "numeric(10,1)")`, with the
same refusal and the same fix, and `DecimalField()` is `numeric(10,2)`. To leave the value unrounded,
cast to the unscaled `"numeric"`. On SQLite it then reads back through the 15-digit conversion above.

A cast to an integer means the nearest integer. SQLite's cast truncates, so a fraction cast to an
integer is refused there (#1028). Say how to round, and it builds on every engine:

```julia
using PormG.Functions: Cast, Ceil, Floor, Round
using PormG.Models: IntegerField

M.Result.objects.filter("raceid" => 2).values("points",
    "nearest" => Cast(Round("points"), IntegerField()),   # 0.5 → 1, 1.5 → 2, 2.5 → 3
    "down"    => Floor("points"),                         # 0.5 → 0.0, 1.5 → 1.0, 2.5 → 2.0
    "up"      => Ceil("points")).list()                   # 0.5 → 1.0, 1.5 → 2.0, 2.5 → 3.0
```

`Floor` and `Ceil` keep their operand's type, a `Float64` here. Wrap them in
`Cast(…, IntegerField())` for an integer.

`Cast("points", IntegerField())` builds on PostgreSQL and MySQL, which round with their own cast. A
double rounds half to even on both (`0.5` → `0`, `2.5` → `2`), and a `numeric` or `DECIMAL` value
rounds half away from zero (`5.5` → `6`). `Cast(Round(x), IntegerField())` rounds half away from
zero on every engine. Write it when the tie matters.

A cast to `real` means the value rounded to single precision, read back as a `Float32`. SQLite has no
4-byte float and would keep the double, so it is refused there (#1215). For a float on every engine,
cast to `FloatField()`.

An `output_field` on `Case`, `Coalesce`, `Greatest` or `Least` is the same cast, and is held to the
same rules (#1217). On SQLite each refused call below names the operand and its fix:

| refused on SQLite | builds on every engine |
|---|---|
| `Case(When("grid__@lte" => 3, then = F("points") * 1.5), default = 0, output_field = "numeric(10,1)")` | `then = Round(F("points") * 1.5, 1)` |
| `Coalesce("points", 0; output_field = "numeric(10,0)")` | `Coalesce(Round("points"), 0; output_field = "numeric(10,0)")` |
| `Greatest("points", 0; output_field = "integer")` | `Greatest(Round("points"), 0; output_field = "integer")` |
| `Least("points", 25; output_field = "numeric(10,0)")` | `Least(Round("points"), 25; output_field = "numeric(10,0)")` |

A cast or `output_field` that names a decimal type reads back as a `Decimal` on every engine (#1212).

## Writing a decimal

PormG checks a value against its `DecimalField` before any SQL, on every engine (#761, Django's
`DecimalValidator` bounds). A value with more places than `decimal_places` is refused, not rounded:

```julia
# A field declared DecimalField(max_digits = 5, decimal_places = 2):
#   1.234, "1.234" or Decimal("1.234")
#   => InvalidValueError: … decimal_places is 2, but the normalized numeric value uses 3 fractional digits
#   1000.0
#   => InvalidValueError: … at most 3 digits fit before the decimal point …
```

That holds for a value written by `create`, `update`, `get_or_create` or a bulk write. Left to the
engines, the value would be stored differently: PostgreSQL's `numeric(5, 2)` and MySQL's
`DECIMAL(5,2)` columns round it to the scale, and SQLite's column keeps every digit, as the expression
case below shows. PormG raises on every engine instead. Round the value in Julia, with the rounding mode you mean, before you write it:

```julia
round(1.234, RoundNearestTiesAway; digits = 2)   # 1.23
```

A `Float64` has its own ties: `round(1.005, RoundNearestTiesAway; digits = 2)` is `1.0`, because the
double nearest `1.005` lies just below it. Where a tie matters, keep the amount in an exact form,
such as an integer count of hundredths.

An expression written by `update` is held to the field's scale too, by the rule a cast to
`numeric(p, s)` follows (#1279). On a `DecimalField(max_digits = 10, decimal_places = 2)`,
PostgreSQL's and MySQL's columns round `F("points") / 3` over `1.00` to `0.33`. SQLite would store every digit of
its double arithmetic and read it back as a `Float64` (`0.3333333333333333`), so it refuses the
expression. That includes plain arithmetic: SQLite stores `1.10 - 1` as `0.10000000000000009`. Round
the expression to the field's places, which stores the same `Decimal` on every engine:

```julia
# Constructor_results.points is a DecimalField(max_digits = 10, decimal_places = 2)
q = M.Constructor_results.objects.filter("constructorresultsid" => 1)
q.update("points" => F("points") / 3)              # the row holds 14.00
#   PostgreSQL: stores 4.67
#   MySQL:      stores 4.67
#   SQLite:     QueryBuildError: update("points" => …) of arithmetic over the DecimalField `points`
#               means the value rounded to the scale of DecimalField(max_digits = 10, decimal_places = 2);
#               SQLite computes every digit of it, so PormG refuses it on SQLite (#1279). …
q.update("points" => Round(F("points") / 3, 2))   # 4.67 on every engine
```

An expression with nothing to round builds on every engine: the column itself, an integer column,
`Round(x, d)` with `d` at most the field's places, or a `DecimalField` with fewer places. A
`FloatField` or an `IntegerField` takes any number expression.

The expression's width is checked as it is written, on each row. A value that needs more than
`max_digits - decimal_places` digits before the point raises `StatementError` with
`sqlstate == "22003"` on every engine, and the `UPDATE` writes nothing. PostgreSQL and MySQL refuse
it themselves. On SQLite PormG renders the check into the statement (#1330), so a value the column
cannot hold is not stored only to fail on every later read. Whether a row overflows depends on its
value, so the error comes when the statement runs, not when it is built:

```julia
# Constructor_results.points is a DecimalField(max_digits = 10, decimal_places = 2): up to 99999999.99
# Its row 1 is race 18, and `raceid` is an integer column.
M.Constructor_results.objects.filter("constructorresultsid" => 1).
    update("points" => F("raceid") * 10_000_000)   # 180000000: nine digits before the point
#   StatementError, sqlstate == "22003", on every engine; the row still holds 14.00
M.Constructor_results.objects.filter("constructorresultsid" => 1).
    update("points" => F("raceid") * 1_000_000)    # stores 18000000.00 on every engine
```

The check rounds first, as PostgreSQL does: into a `DecimalField(max_digits = 4, decimal_places = 2)`,
`99.995` rounds to `100.00`, which is too wide. A `DecimalField` wider than 15 digits is not checked on SQLite, which stores
none of its values exactly (#648). An operand that is no number, such as a
UUID or a date, is refused into every number field on every engine
([Updating Records](../write/update.md#Basic-F-Expression-Usage), #1297).

## How this compares

| framework | a declared scale |
|---|---|
| Rails (ActiveModel) | rounds the value in Ruby when it casts it, to the column's scale |
| Django | PostgreSQL's column rounds on write. On SQLite, a converter quantizes a decimal column on read. `DecimalValidator` refuses extra places only in `full_clean()`, not on `save()` |
| **PormG** | **refuses on the engine that would not honor it**, refuses a value with extra places on every write, refuses an expression `update` writes with extra places on that engine (#1279), and names the explicit spelling |

On MySQL, `Round` follows the rules above. A cast to `numeric(p, s)` and an expression `update`
writes into a `DecimalField` are rounded to the scale, as PostgreSQL's column rounds them, so neither
is refused there for its extra places ([MySQL Guide](../mysql.md)).
