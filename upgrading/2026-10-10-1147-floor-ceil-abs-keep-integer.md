## `Floor`, `Ceil` and `Abs` over an integer keep the integer on PostgreSQL (#1147)

- **Version**: Unreleased
- **PormG ref**: #1147 ; `src/Dialect.jl` (`ABS`, `FLOOR`, `CEIL`), `src/querybuilder/select_nodes.jl` (`_render_function_body`), `src/querybuilder/projection_types.jl` (`_INTEGER_KEEPING_FUNCTIONS`, `_whole_numeric_operand`, `_bigint_operand_function`)
- **Recorded**: 2026-10-10
- **Severity**: behavior. On PostgreSQL, `Floor(x)`, `Ceil(x)` and `Abs(x)` over an integer `x` return an integer instead of a `numeric`, read back as an `Int32`/`Int64` instead of a `Decimal`, and divide as integers. SQLite is unchanged.

### What changed

PostgreSQL rendered every `Floor`, `Ceil` and `Abs` over a `::numeric` operand, so over an integer
the value was a `numeric`: it read back as a `Decimal`, and `/` kept the half where SQLite, which
keeps the integer, divides as integers. These functions mean the operand's type, so PostgreSQL was
the engine that departed, and only because of the cast PormG added. Now an operand that is an
integer by type — an integer column (`IDField`, `ForeignKey` and `BigIntegerField` included), `Count`,
integer arithmetic, an integer cast or literal, an integer date part such as `"dob__@year"` — renders
without it: `ABS("Tb"."grid")`, and for `Floor`/`Ceil` the integer itself, `("Tb"."grid")` (the floor
of an integer is the integer, and PostgreSQL has no `floor(integer)`: `floor(int)` is a
`double precision`). Every other operand — a float, a decimal, a JSON value, a quotient — keeps
`(x)::numeric`.

Measured on the F1 fixture (`Result.grid` is 1, 5, 7 on the first three rows):

| expression | PostgreSQL before | PostgreSQL now | SQLite |
|---|---|---|---|
| `Floor("grid")` | `Decimal` `1`, `5`, `7` | integer `1`, `5`, `7` | integer `1`, `5`, `7` |
| `Floor("grid") / 2` | `0.5`, `2.5`, `3.5` | `0`, `2`, `3` | `0`, `2`, `3` |
| `Cast(Floor("dob__@year") / 2, IntegerField())`, year 1985 | `993` | `992` | `992` |
| `Floor("points")`, `Abs("payload__points")` | `numeric` | unchanged | unchanged |

This also lifts the `Unreleased` #1111 and #1135 refusals for these functions: a `Concat` or a `Cast`
over `Floor(x) / y`, `Ceil(x) / y` or `Abs(x) / y` with an integer `x` builds on both engines again,
and now agrees. `Sum` of a BIGINT column and a zero-scale `DecimalField`, divided, are still refused
(#1111), and so are `Floor`/`Ceil`/`Abs` over them; `Sum(Abs("id"))` is a `sum(bigint)` like
`Sum("id")`.

### Who this affects

Code on PostgreSQL that reads `Floor`, `Ceil` or `Abs` of an integer as a `Decimal` (`row.x isa
Decimal`, `Decimals` arithmetic on it), or that divides one and relied on the fraction: the quotient
is now an integer division on both engines. On SQLite nothing changes.

### How to find the calls to migrate

```bash
grep -rnE '(Floor|Ceil|Abs)\(' --include=*.jl src/ test/
```

For each match over an integer operand, check what reads the value (a `Decimal` type check or
conversion) and whether a `/` divides it.

### Migrate your app

```julia
# ✗ before — on PostgreSQL a Decimal, and 2.5 for grid 5; 2 on SQLite
M.Result.objects.values("resultid", "half" => Floor("grid") / 2)

# ✓ after — the same integer division on both engines; for the fraction, divide by a float
M.Result.objects.values("resultid", "half" => Floor("grid") / 2)    # 0, 2, 3
M.Result.objects.values("resultid", "half" => F("grid") / 2.0)      # 0.5, 2.5, 3.5
```
