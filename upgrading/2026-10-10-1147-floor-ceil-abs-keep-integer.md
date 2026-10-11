## `Floor`, `Ceil`, `Abs` over an integer return an integer on PostgreSQL, as on SQLite (#1147)

- **Version**: Unreleased
- **PormG ref**: #1147 ; `src/Dialect.jl` (`ABS`, `FLOOR`, `CEIL`), `src/querybuilder/expression_kind.jl` (`_integer_operand_kind`), `src/querybuilder/select_nodes.jl` (`_render_function_body`)
- **Recorded**: 2026-10-10
- **Severity**: behavior change. On PostgreSQL, `Floor(x)`, `Ceil(x)` and `Abs(x)` over an integer `x` read back as an `Int16`/`Int32`/`Int64` instead of a `Decimal`, and a quotient over one (`Floor("grid") / 2`) divides as integers: `3` where it was `3.5`. SQLite is unchanged.

### What changed

PostgreSQL rendered every operand of these functions cast to `numeric` — `FLOOR(("Tb"."grid")::numeric)`
— so over an integer the value was a `numeric`: it read as a `Decimal`, and dividing it kept the half,
where SQLite keeps the integer and divides as integers. Over an operand PormG types as an integer —
an integer column (`IntegerField`, `BigIntegerField`, an `IDField`, a `ForeignKey`, …), an integer
literal, `Count`, `Length`, a `Cast` to an integer, an integer date part (`"dob__@year"`,
`Extract(…, "year")`, `@quarter`, …), or one of these functions over one — PostgreSQL now renders:

| call | before | after |
|---|---|---|
| `Abs("grid")` | `ABS(("Tb"."grid")::numeric)` | `ABS("Tb"."grid")` |
| `Floor("grid")` | `FLOOR(("Tb"."grid")::numeric)` | `FLOOR(("Tb"."grid")::numeric)::integer` |
| `Ceil("resultid")` | `CEIL(("Tb"."resultid")::numeric)` | `CEIL(("Tb"."resultid")::numeric)::bigint` |

`FLOOR`/`CEIL` cast back to the operand's own type (`smallint`, `integer`, `bigint`): PostgreSQL has
no `floor(integer)`, and the round trip through `numeric` is exact for every `bigint`. On the F1
fixture (`Result.grid` 1, 5, 7 on the first rows):

| expression | PostgreSQL before | PostgreSQL after | SQLite |
|---|---|---|---|
| `Floor("grid")` | `Decimal` 1, 5, 7 | `Int32` 1, 5, 7 | 1, 5, 7 |
| `Floor("grid") / 2` | `0.5`, `2.5`, `3.5` | `0`, `2`, `3` | `0`, `2`, `3` |
| `Floor("dob__@year") / 2`, an odd year | `992.5` | `992` | `992` |

Unchanged: these functions over a float, a decimal, or an expression PormG does not type as an
integer (`Floor(F("grid") + 1)`, `Abs(Sum("resultid"))`) keep the `::numeric` cast and read a
`Decimal` on PostgreSQL; and every query on SQLite.

### Who this affects

Code that runs on PostgreSQL and either reads `Floor`, `Ceil` or `Abs` of an integer as a `Decimal`
(`row.f isa Decimal`, `Decimal`-only arithmetic, `round(row.f; digits = 2)` on a column that is now
an integer), or divides one and relies on the fraction PostgreSQL kept. The second was refused by
the unreleased #1111/#1135 checks inside a `Concat` or a cast; a bare division built and returned
`3.5`.

### How to find the calls to migrate

```bash
grep -rnE '(Floor|Ceil|Abs)\(' --include=*.jl src/ test/
```

For each match over an integer column, an integer literal, a count or a date part, read what the
caller does with the value: a type check or conversion that expects a `Decimal`, or a `/` after it.

### Migrate your app

```julia
# ✗ before — PostgreSQL kept the half (2.5), SQLite truncated (2)
M.Result.objects.values("resultid", "half" => Floor("grid") / 2)

# ✓ after — integer division on both engines; for the fraction, say so with a float divisor
M.Result.objects.values("resultid", "half" => Floor("grid") / 2)     # 2 on both
M.Result.objects.values("resultid", "half" => Floor("grid") / 2.0)   # 2.5 on both

# ✓ a Decimal was never the column's type: convert explicitly where a Decimal is needed
d = Decimal(row.f)
```
