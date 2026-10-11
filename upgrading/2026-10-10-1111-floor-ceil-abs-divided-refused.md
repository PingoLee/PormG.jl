## `Sum` of a BIGINT column is refused once divided (#1111)

- **Version**: Unreleased
- **PormG ref**: #1111, amended by #1147 ; `src/querybuilder/projection_types.jl` (`_whole_numeric_operand`, `_bigint_column`, `_textless_number`), `src/querybuilder/functions.jl` (`_divergent_text_why`, `_cast_divergent_refusal`)
- **Recorded**: 2026-10-10
- **Severity**: breaking. A `Concat` operand, or a `Cast` (or `output_field` cast) to text, to an integer or to `numeric(p, s)`, over `Sum(<BIGINT column>) / y` (and over `Sum` of `Abs`/`Floor`/`Ceil` of one), raises `QueryBuildError` where it used to render.

### What changed

PostgreSQL's `sum` of a `bigint` column is `numeric`, where SQLite's is an integer. The two agree on
the whole number, and `+`, `-`, `*` keep it whole, so #1027/#1028 let these pass. Division does not
keep it: `numeric / int` keeps the half on PostgreSQL and SQLite divides as integers. Measured on
PostgreSQL 16 and SQLite 3.45 through the F1 fixture (`resultid` is an `IDField`):

| expression | PostgreSQL | SQLite |
|---|---|---|
| `Sum("resultid") / 2` over two rows | `1.5` | `1` |
| `F("grid") / 2`, `Max("grid") / 2`, `Sum("grid") / 2`, `Count("resultid") / 2` | integer | integer |

The quotient reached `Concat` (`7.5` against `7`), a cast to text, a cast to an integer (PostgreSQL
rounds `7.5` to `8`, SQLite has `7`) and a cast to `numeric(p, s)`. #1087 refused the same shape for
a zero-scale `DecimalField`; this extends it to `Sum` of an `IDField`, a `BigIntegerField` or a
`ForeignKey` column, through arithmetic and an aggregate over it.

As first written in this train, the refusal also covered `Floor`, `Ceil` and `Abs` over an integer,
divided. Those split only because PostgreSQL rendered them over `(x)::numeric`; #1147 removed that
cast over a whole number, so they divide as integers on both engines and build (see its entry).

Unchanged: `Sum` of a BIGINT column itself, under `+`, `-`, `*`, or cast directly; `Max`, `Min`,
`Count` and `Sum` of an `IntegerField`, which both engines keep integer; `Round(x)`, `Avg` and `Mod`,
already refused as `numeric` functions (#1027).

### Who this affects

Code that divides a `Sum` of a BIGINT column and concatenates or casts the quotient. Running the
query is the definitive check: the refusal message names the operand (``SUM(…)` over the IDField
`id``) and says that SQLite divides it as an integer.

### How to find the calls to migrate

```bash
grep -rnE 'Sum\([^)]*\) */' --include=*.jl src/ test/
```

Read each hit whose quotient is an operand of `Concat`, `Cast`, or a `Coalesce`/`Greatest`/`Least`
with an `output_field`. A multi-line expression needs reading by hand.

### Migrate your app

Rounding after the division cannot bring the half back on SQLite. Divide as a float, so both engines
keep the fraction, and then say how to round; or fetch the number and compute in Julia:

```julia
# ✗ before — 2 on PostgreSQL and 1 on SQLite for a sum of 3
M.Result.objects.values("raceid", "half" => Cast(Sum("resultid") / 2, IntegerField()))

# ✓ after — a float division has the half on both engines; Round(x) then reads the same integer
M.Result.objects.values("raceid", "half" => Cast(Round(Sum("resultid") / 2.0), IntegerField()))
```
