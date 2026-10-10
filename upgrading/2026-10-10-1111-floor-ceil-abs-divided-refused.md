## `Floor`, `Ceil`, `Abs` over an integer, and `Sum` of a BIGINT column, are refused once divided (#1111)

- **Version**: Unreleased
- **PormG ref**: #1111 ; `src/querybuilder/projection_types.jl` (`_whole_numeric_operand`, `_textless_number`), `src/querybuilder/functions.jl` (`_divergent_text_why`, `_cast_divergent_refusal`)
- **Recorded**: 2026-10-10
- **Severity**: breaking. A `Concat` operand, or a `Cast` (or `output_field` cast) to text, to an integer or to `numeric(p, s)`, over `Floor(x) / y`, `Ceil(x) / y`, `Abs(x) / y` with an integer `x`, or over `Sum(<BIGINT column>) / y`, raises `QueryBuildError` where it used to render.

### What changed

PostgreSQL renders `Floor`, `Ceil` and `Abs` over a `::numeric` operand, so their value is
`numeric` there; SQLite keeps an integer operand's type. Its `sum` of a `bigint` column is `numeric`
too, where SQLite's is an integer. The two agree on the whole number, and `+`, `-`, `*` keep it
whole, so #1027/#1028 let these pass. Division does not keep it: `numeric / int` keeps the half on
PostgreSQL and SQLite divides as integers. Measured on PostgreSQL 16 and SQLite 3.45 through the F1
fixture (`Result.grid` is 1, 5, 7 on the first three rows; `resultid` is an `IDField`):

| expression | PostgreSQL | SQLite |
|---|---|---|
| `Floor("grid") / 2`, `Ceil(…)`, `Abs(…)` | `0.5`, `2.5`, `3.5` | `0`, `2`, `3` |
| `(Floor("grid") + 1) / 2` | `1`, `3`, `4` | `1`, `3`, `4` (even sums; `(Floor("grid") + 2) / 2` splits again, so it is refused too) |
| `Cast(Floor("grid") / 2, IntegerField())` | `1`, `3`, `4` (rounded) | `0`, `2`, `3` |
| `Sum("resultid") / 2` over two rows | `1.5` | `1` |
| `F("grid") / 2`, `Max("grid") / 2`, `Sum("grid") / 2`, `Count("resultid") / 2` | integer | integer |
| `Floor("grid") * 2`, `Floor("grid") + 1` | `2`, `10`, `14` / `2`, `6`, `8` | the same |

The quotient reached `Concat` (`7.5` against `7`), a cast to text, a cast to an integer (PostgreSQL
rounds `7.5` to `8`, SQLite has `7`) and a cast to `numeric(p, s)`. #1087 refused the same shape
for a zero-scale `DecimalField`; this extends it to the functions PostgreSQL computes as `numeric`
over a whole number, through arithmetic and an aggregate over them (`(Floor(x) + 1) / 2`,
`Max(Abs(x)) / 2`), and to `Sum` of an `IDField`, a `BigIntegerField` or a `ForeignKey` column.

Unchanged: `Floor`, `Ceil`, `Abs` and `Sum` of a BIGINT column themselves, under `+`, `-`, `*`, or
cast directly; `Max`, `Min`, `Count` and `Sum` of an `IntegerField`, which both engines keep
integer; `Round(x)`, `Avg` and `Mod`, already refused as `numeric` functions (#1027).

### Who this affects

Code that divides a `Floor`, `Ceil` or `Abs` of an integer column, or a `Sum` of a BIGINT column,
and concatenates or casts the quotient. Running the query is the definitive check: the refusal
message names the operand (`arithmetic over `FLOOR(…)``, ``SUM(…)` over the IDField `id``) and
says that SQLite divides it as an integer.

### How to find the calls to migrate

```bash
grep -rnE '(Floor|Ceil|Abs|Sum)\([^)]*\) */' --include=*.jl src/ test/
```

Read each hit whose quotient is an operand of `Concat`, `Cast`, or a `Coalesce`/`Greatest`/`Least`
with an `output_field`. A multi-line expression needs reading by hand.

### Migrate your app

Rounding after the division cannot bring the half back on SQLite. Divide as a float, so both engines
keep the fraction, and then say how to round; or fetch the number and compute in Julia:

```julia
# ✗ before — 1, 3, 4 on PostgreSQL and 0, 2, 3 on SQLite
M.Result.objects.values("resultid", "half" => Cast(Floor("grid") / 2, IntegerField()))

# ✓ after — a float division has the half on both engines; Round(x) then reads the same integer
M.Result.objects.values("resultid", "half" => Cast(Round(Floor("grid") / 2.0), IntegerField()))

# ✓ after — the digits you mean: fetch the number and format it in Julia
df = M.Result.objects.values("resultid", "grid") |> DataFrame
df.half = string.(floor.(df.grid) ./ 2)
```
