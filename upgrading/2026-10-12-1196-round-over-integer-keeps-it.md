## `Round` over an integer returns that integer on every engine, and divides as one (#1196)

- **Version**: Unreleased
- **PormG ref**: #1196 ; `src/Dialect.jl` (`ROUND`), `src/querybuilder/select_nodes.jl` (`_render_function_body`), `src/querybuilder/functions.jl` (`_computed_kind` for `ROUND`), `src/querybuilder/projection_types.jl` (`_INTEGER_KEEPING_FUNCTIONS`)
- **Recorded**: 2026-10-12
- **Severity**: behavior change. `Round(x)` and `Round(x, d)` over an integer `x` read back as an integer instead of a `Decimal` (PostgreSQL) or a `Float64` (SQLite), and a quotient over one (`Round("grid") / 2`) divides as integers on both engines: `2` where it was `2.5`.

### What changed

`Round` means its operand's type, as Django's `Round` does, and #1121 made a rounded float and a
rounded decimal read back as one. Over an integer it did not: PostgreSQL rendered
`ROUND(("Tb"."grid")::numeric)`, a `numeric` read as a `Decimal`, and SQLite `ROUND("Tb"."grid")`,
a REAL read as a `Float64`. So one call read as two different types, and neither was an integer.

A negative precision is already refused (#1044), so rounding an integer to `d ≥ 0` places gives the
integer back. Over an operand PormG types as an integer (the same operands as `Floor`, `Ceil` and
`Abs` in #1147: an integer column, an integer literal, `Count`, an integer `Case`, a cast to an
integer, an integer date part, integer arithmetic, …), PormG now renders that integer:

| call | engine | before | after |
|---|---|---|---|
| `Round("grid")`, `Round("grid", 2)` | PostgreSQL | `ROUND(("Tb"."grid")::numeric[, $1])` | `ROUND(("Tb"."grid")::numeric)::integer` |
| `Round("grid")`, `Round("grid", 2)` | SQLite | `ROUND("Tb"."grid"[, ?])` | `("Tb"."grid")` |

PostgreSQL casts back to the operand's own type (`smallint`, `integer`, `bigint`), through `numeric`,
which is exact for every `bigint`. SQLite renders the integer itself: its `ROUND` computes through a
double, so `CAST(ROUND(x) AS INTEGER)` would be wrong past 2^53. Neither engine binds the places
any more, so the statement carries one parameter fewer.

On the F1 fixture (`Result.grid` 1, 5, 7 on the first rows):

| expression | PostgreSQL before | SQLite before | both engines now |
|---|---|---|---|
| `Round("grid")`, `Round("grid", 1)` | `Decimal` 1, 5, 7 | `Float64` 1.0, 5.0, 7.0 | integer 1, 5, 7 |
| `Round("grid") / 2` | `Decimal` 0.5, 2.5, 3.5 | `Float64` 0.5, 2.5, 3.5 | integer 0, 2, 3 |

The integer's width is each engine's own, as an integer column's is: an `IntegerField` reads as an
`Int32` on PostgreSQL and every integer as an `Int64` on SQLite. That is the same value in two widths,
not a different one.

Unchanged: `Round` over a float or a decimal (#1121: a `Float64` and a `Decimal` on both engines), and
over an expression PormG does not type as an integer.

### Who this affects

Code that reads `Round` of an integer as a `Decimal` or a `Float64` (`x isa Decimal`, `x isa Float64`,
`Float64` arithmetic on the column, a `Vector{Float64}` built from it), or that divides one and
relies on the fraction.

### How to find the calls to migrate

```bash
grep -rnE 'Round\(' --include=*.jl src/ test/
```

For each match over an integer column, an integer literal, a count or a date part, read what the
caller does with the value: a type check or a conversion that expects a `Decimal` or a `Float64`, or a
`/` after it.

### Migrate your app

```julia
# ✗ before — PostgreSQL: Decimal 2.5; SQLite: Float64 2.5
M.Result.objects.values("resultid", "half" => Round("grid") / 2)

# ✓ after — integer division on both engines; for the fraction, say so with a float divisor
M.Result.objects.values("resultid", "half" => Round("grid") / 2)     # 2 on both
M.Result.objects.values("resultid", "half" => Round("grid") / 2.0)   # 2.5 on both

# ✓ where a float is needed, convert the integer explicitly
x = Float64(row.rounded)
```
