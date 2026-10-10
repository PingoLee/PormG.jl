## `Sum` over an integer literal, divided, is refused as a `sum(bigint)` (#1141)

- **Version**: Unreleased
- **PormG ref**: #1141 ; `src/querybuilder/projection_types.jl` (`_bigint_column`, `_bigint_operand_function`, `_bigint_valued`)
- **Recorded**: 2026-10-10
- **Severity**: breaking. A `Concat` operand, or a `Cast` (or `output_field` cast) to text, to an integer or to `numeric(p, s)`, over `Sum(…) / y` raises `QueryBuildError` where it used to render when the summed expression holds an integer literal (`Sum(F("grid") + 1)`, `Sum(F("grid") / 2)`, `Sum(F("grid") & 1)`, `Sum(Coalesce("grid", 0))`, the conditional count `Sum(Case(When(…, then = 1), default = 0))`), carries a BIGINT column through a function (`Sum(Coalesce("resultid", …))`), or is a cast to `bigint` (`Sum(Cast("grid", BigIntegerField()))`, an `output_field = BigIntegerField()`). So does the same division over a CTE column built from such a `Sum`, and an outer `Sum(CTE(…)) / y` over a CTE column built from `Lag`/`Lead`/`Max`/`Min` of a `Count` or a ranking window, or from `Lag`/`Lead` with an integer `default`.

### What changed

#1111 refuses `Sum(<BIGINT column>) / y`: PostgreSQL's `sum(bigint)` is `numeric` and keeps the
half, SQLite's is an integer and drops it. It decided "BIGINT" from the column's field only. But
PormG binds an integer literal on PostgreSQL as `$n::bigint`, and `int4 + int8` is `int8`, so a sum
over integer-column arithmetic with a literal is a `sum(bigint)` too:

```julia
M.Result.objects.values("x" => Cast(Sum(F("grid") + 1) / 2, IntegerField()))   # built
M.Result.objects.values("x" => Cast(Sum("resultid") / 2, IntegerField()))      # refused (#1111)
```

PostgreSQL rendered `((SUM(("Tb"."grid" + $1::bigint)) / $2::bigint))::integer`: the sum is
`numeric`, so the quotient kept the half and the cast rounded it (`7.5` → `8`), where SQLite divided
the integer sum (`7`). An integer literal now counts as a BIGINT, on both engines, as #1111's refusal
is decided once for both. A function whose value is one of its operands' own values (`Coalesce`,
`Greatest`, `Least`, `Max`, `Min`, `NullIf`, the window value functions) is a BIGINT when its operand
is, so `Sum(Coalesce("grid", 0))` is refused as well: PostgreSQL resolves `coalesce(int4, int8)` to
`int8`. So is a `Case` with a BIGINT branch, which is how PostgreSQL types the conditional count
`Case(When("grid__@gt" => 3, then = 1), default = 0)` (`THEN $2::bigint ELSE $3::bigint`); the
bitwise operators (`&`, `|`, `xor`) and a shift of a BIGINT column; a declared `bigint` cast; and a
`Lag`/`Lead` whose `default` is one. A CTE column built from one of these is recorded the same way,
so it is refused when divided.

Unchanged: `Sum` of an `IntegerField` with no literal (`Sum("grid") / 2`, `Sum(F("grid") * F("laps")) / 2`),
which both engines divide as integers; a `bigint` that is not summed (`Max(F("grid") + 1) / 2`,
`Coalesce("grid", 0) / 2`), which divides as an integer on both; a declared `integer`
`output_field`, which decides alone; `NullIf("grid", 0)`, which has its first operand's type; a
shift with a literal on either side (`F("grid") << 2`, `1 << F("grid")`: bound `::integer`); and any
of these undivided.

### Who this affects

Code that divides a `Sum` whose argument is arithmetic with an integer literal, a `Coalesce` with an
integer fallback, a `Case` with integer branches, or a cast to `bigint` — or an outer `Sum` over a
CTE column built that way — inside `Concat`, `Cast`, or a `Coalesce`/`Greatest`/`Least` with an
`output_field`. Running the query is the definitive check: the refusal names the operand as
``arithmetic over `SUM(…)` over an integer literal (a `bigint` on PostgreSQL) `` and says
that SQLite divides it as an integer.

### How to find the calls to migrate

```bash
grep -rn 'Sum(' --include=*.jl src/ test/
```

For each match, read the enclosing expression for a `/` over the `Sum`, then the `Sum`'s argument
(or, for `Sum(CTE(…))`, the CTE body's column) for one of the shapes above.

### Migrate your app

As for `Sum` of a BIGINT column (#1111): divide as a float, so both engines keep the half, then say
how to round; or fetch the number and compute in Julia.

```julia
# ✗ before — rounds 7.5 to 8 on PostgreSQL, truncates to 7 on SQLite
M.Result.objects.values("raceid", "half" => Cast(Sum(F("grid") + 1) / 2, IntegerField()))

# ✓ after — a float division has the half on both engines; Round(x) then reads the same integer
M.Result.objects.values("raceid", "half" => Cast(Round(Sum(F("grid") + 1) / 2.0), IntegerField()))
```
