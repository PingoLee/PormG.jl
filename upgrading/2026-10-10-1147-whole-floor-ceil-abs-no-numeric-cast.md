## `Floor`, `Ceil` and `Abs` over a whole number keep it whole on PostgreSQL (#1147)

- **Version**: Unreleased
- **PormG ref**: #1147 ; `src/Dialect.jl` (`ABS`, `FLOOR`, `CEIL`), `src/querybuilder/projection_types.jl` (`_whole_operand_function`, `_whole_numeric_operand`, `_bigint_operand_function`), `src/querybuilder/functions.jl` (`_computed_kind`)
- **Recorded**: 2026-10-10
- **Severity**: behavior change on PostgreSQL. `Floor(x)`, `Ceil(x)` and `Abs(x)` over a whole number `x` return an integer (`Int32`/`Int64`) where they returned a `Decimal`. A whole number is: an integer column, an integer literal, an integer date part, `Count`, `Sum`/`Max`/`Min` of an integer, a `Case` or `Coalesce` of integers, a ranking window (`Rank`, `RowNumber`, …), a `Lag`/`Lead` of an integer with a whole `default`, a CTE column whose body computed one, `+`/`-`/`*` of such, or a cast to an integer type. Divided, they divide as integers (`Floor("grid") / 2` over `5` is `2`, was `2.5`). Breaking on both engines: a `Concat` operand or a `Cast` (or `output_field` cast) to text, an integer or `numeric(p, s)` over `Floor`/`Ceil`/`Abs` of a zero-scale `DecimalField`, divided, raises `QueryBuildError` where it used to render.

### What changed

PostgreSQL rendered `FLOOR((x)::numeric)`, `CEIL((x)::numeric)` and `ABS((x)::numeric)` whatever `x`
was, so over an integer column the value was a `numeric`. SQLite keeps the integer. Division then
split the engines (`numeric / int` keeps the half), and #1111/#1135 refused the division on both. It
was PormG's own cast that made PostgreSQL depart: over a whole number PostgreSQL now renders `ABS(x)`,
and for `FLOOR`/`CEIL` the operand itself. PostgreSQL has no `floor(integer)` and resolves one through
`floor(double precision)`, a double that loses a bigint's digits past 2^53, and the floor or ceiling
of a whole number is that number. Measured on PostgreSQL 16 through the F1 fixture:

| expression (PostgreSQL) | before | after |
|---|---|---|
| `Floor("grid")` over `5` | `Decimal` `5` | `Int32` `5` |
| `Abs("resultid")` | `Decimal` | `Int64` |
| `Floor("grid") / 2` over `5` | `2.5` | `2` (as on SQLite) |
| `Floor("raceid__date__@year")` | `Decimal` | `Int32` |
| `Floor("points")`, `Abs(Value(-5.5))` | `Decimal` | `Decimal` (unchanged: not a whole number) |

So `Cast(Floor("grid") / 2, IntegerField())`, `Concat("x", Floor("grid") / 2)` and the same over an
integer date part (`Floor("dob__@year") / 2`), refused earlier in this train (#1111, #1135), build
again, and read the same on both engines.

Still refused, now also through these functions: `Sum` of a BIGINT column divided (`Sum(Abs("id"))
/ 2` is a `sum(bigint)`, #1111), and `Floor`/`Ceil`/`Abs` of a zero-scale `DecimalField` divided:
PostgreSQL keeps the `::numeric` cast over a decimal, while SQLite stored the whole value as an
INTEGER and divides it as one. That one is new: it rendered and split before.

One edge on PostgreSQL: `abs` of the smallest `integer` (`-2147483648`) has no `integer` answer, so
`Abs` over an `integer` column holding it now raises there ("integer out of range"), as PostgreSQL's
own `abs` does, where SQLite returns `2147483648`. Cast the column to `bigint` first
(`Abs(Cast("col", BigIntegerField()))`) if it can hold that value.

### Who this affects

Code on PostgreSQL that reads `Floor`, `Ceil` or `Abs` of an integer column and expects a `Decimal`
(`x isa Decimal`, `Decimals` arithmetic on it), or divides one and expects the fraction. Code that
divides `Floor`/`Ceil`/`Abs` of a zero-scale `DecimalField` inside `Concat` or a cast: the refusal
names the operand (``FLOOR(…)` over the DecimalField `…``).

### How to find the calls to migrate

```bash
grep -rnE '(Floor|Ceil|Abs)\(' --include=*.jl src/ test/
```

Read each hit whose operand is an integer column, an integer literal or a date part, and check what
the result is compared with, converted to or divided by.

### Migrate your app

```julia
# ✗ before — on PostgreSQL a Decimal, and 2.5 once divided
M.Result.objects.values("resultid", "half" => Floor("grid") / 2)

# ✓ after — an Int32, and 2 on both engines; divide as a float to keep the half
M.Result.objects.values("resultid", "half" => Floor("grid") / 2.0)
```
