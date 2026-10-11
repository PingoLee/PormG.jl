## `Sum` of a BIGINT column, and `Floor`, `Ceil`, `Abs` over an untyped whole number, are refused once divided (#1111)

- **Version**: Unreleased
- **PormG ref**: #1111, amended by #1147 ; `src/querybuilder/projection_types.jl` (`_whole_numeric_operand`, `_textless_number`), `src/querybuilder/functions.jl` (`_divergent_text_why`, `_cast_divergent_refusal`)
- **Recorded**: 2026-10-10
- **Severity**: breaking. A `Concat` operand, or a `Cast` (or `output_field` cast) to text, to an integer or to `numeric(p, s)`, over `Sum(<BIGINT column>) / y`, or over `Floor(x) / y`, `Ceil(x) / y`, `Abs(x) / y` where `x` is a whole-number expression PormG does not type as an integer (`F("grid") + 1`, `Sum(<BIGINT column>)`), raises `QueryBuildError` where it used to render.

### What changed

PostgreSQL's `sum` of a `bigint` column is `numeric`, where SQLite's is an integer. The two agree
on the whole number, and `+`, `-`, `*` keep it whole, so #1027/#1028 let it pass. Division does not
keep it: `numeric / int` keeps the half on PostgreSQL and SQLite divides as integers. `Floor`, `Ceil`
and `Abs` render over `(x)::numeric` on PostgreSQL when `x` is not an integer PormG can name, with
the same split. Measured on PostgreSQL 16 and SQLite 3.45 through the F1 fixture (`Result.grid` is
1, 5, 7 on the first three rows; `resultid` is an `IDField`); the `F("grid") + 2` rows are the
measured `Floor("grid") / 2` split, shifted by one:

| expression | PostgreSQL | SQLite |
|---|---|---|
| `Sum("resultid") / 2` over two rows | `1.5` | `1` |
| `Floor(F("grid") + 2) / 2` | `1.5`, `3.5`, `4.5` | `1`, `3`, `4` |
| `Cast(Floor(F("grid") + 2) / 2, IntegerField())` | `2`, `4`, `5` (rounded) | `1`, `3`, `4` |
| `F("grid") / 2`, `Max("grid") / 2`, `Sum("grid") / 2`, `Count("resultid") / 2` | integer | integer |
| `Floor("grid") / 2`, `Ceil(…)`, `Abs(…)` over an integer (#1147) | integer | integer |

The quotient reached `Concat` (`7.5` against `7`), a cast to text, a cast to an integer (PostgreSQL
rounds `7.5` to `8`, SQLite has `7`) and a cast to `numeric(p, s)`. #1087 refused the same shape
for a zero-scale `DecimalField`; this extends it to `Sum` of an `IDField`, a `BigIntegerField` or a
`ForeignKey` column, and to `Floor`/`Ceil`/`Abs` over a whole number PostgreSQL computes as
`numeric`, through arithmetic and an aggregate over them (`Max(Abs(F("grid") + 1)) / 2`).

As first merged, #1111 refused `Floor`/`Ceil`/`Abs` over an integer column too, divided. #1147, in the
same release, makes them keep an integer operand's type on PostgreSQL (see its own entry), so
`Floor("grid") / 2` divides as integers on both engines and is not refused.

Unchanged: `Floor`, `Ceil`, `Abs` and `Sum` of a BIGINT column themselves, under `+`, `-`, `*`, or
cast directly; `Max`, `Min`, `Count` and `Sum` of an `IntegerField`, which both engines keep
integer; `Round(x)`, `Avg` and `Mod`, already refused as `numeric` functions (#1027).

### Who this affects

Code that divides a `Sum` of a BIGINT column, or a `Floor`, `Ceil` or `Abs` over integer arithmetic,
and concatenates or casts the quotient. Running the query is the definitive check: the refusal
message names the operand (`arithmetic over `FLOOR(…)``, ``SUM(…)` over the IDField `id``) and
says that SQLite divides it as an integer.

### How to find the calls to migrate

```bash
grep -rnE '(Floor|Ceil|Abs|Sum)\(.*\) */' --include=*.jl src/ test/
```

Read each hit whose quotient is an operand of `Concat`, `Cast`, or a `Coalesce`/`Greatest`/`Least`
with an `output_field`. A multi-line expression needs reading by hand.

### Migrate your app

Rounding after the division cannot bring the half back on SQLite. Divide as a float, so both engines
keep the fraction, and then say how to round; or fetch the number and compute in Julia:

```julia
# ✗ before — over results 1 and 2 the sum is 3: `2` on PostgreSQL (1.5, rounded) and `1` on SQLite
M.Result.objects.filter("resultid__@in" => [1, 2]).values("half" => Cast(Sum("resultid") / 2, IntegerField()))

# ✓ after — a float division has the half on both engines; Round(x) then reads the same integer
M.Result.objects.filter("resultid__@in" => [1, 2]).values("half" => Cast(Round(Sum("resultid") / 2.0), IntegerField()))

# ✓ after — the digits you mean: fetch the number and format it in Julia
total = M.Result.objects.values("total" => Sum("resultid")).list(:dict)[1][:total]
half = string(total / 2)
```
