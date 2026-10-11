## A CTE column built from `Sum` of a BIGINT column, divided, is refused like the `Sum` (#1127)

- **Version**: Unreleased
- **PormG ref**: #1127 ; `src/querybuilder/ctes.jl` (`_build_cte_custom_model`), `src/querybuilder/projection_types.jl` (`_whole_numeric_operand`, `_bigint_column`, `_bigint_valued`)
- **Recorded**: 2026-10-10
- **Severity**: breaking. A `Concat` operand, or a `Cast` (or `output_field` cast) to text, to an integer or to `numeric(p, s)`, over a division of a CTE column whose body projects `Sum(<BIGINT column>)` or `Sum` over `Floor`/`Ceil`/`Abs` of a BIGINT column or of a whole-number expression PormG does not type as an integer (an integer column under them is summed as one since #1147), raises `QueryBuildError` where it used to render. So does an outer `Sum(CTE(…)) / y` over a CTE column whose body projects `Count`, `Sum` of an integer column or a ranking window (`Rank`, `DenseRank`, `RowNumber`), and `Sum(F(<BIGINT column>) / <integer>) / y`.

### What changed

#1111 refuses `Sum(<BIGINT column>) / y`: PostgreSQL's `sum(bigint)` is `numeric` and keeps the
half, SQLite's is an integer and drops it. A CTE column built from that `Sum` slipped past the check.
The CTE gives a `SUM` column an integer type whatever it sums, so the column divided read as an
integer divided:

```julia
totals = M.Result.objects.values("raceid", "id_sum" => Sum("resultid"))
q = M.Race.objects
q.with("totals" => totals, join_field = "raceid" => "raceid")
q.values("raceid", "half" => Cast(Coalesce(CTE("totals", "id_sum"), 0) / 2, IntegerField()))   # built
M.Result.objects.values("raceid", "half" => Cast(Sum("resultid") / 2, IntegerField()))         # refused (#1111)
```

The built one rounded `7.5` on PostgreSQL and truncated `7` on SQLite. The CTE body now records
what each computed column answers once divided, as it already records the column's text
classification (#1028), and the division check reads that record. A CTE column is refused exactly
where its body's expression would be, under `Coalesce`, under an outer `Sum`/`Max`, and in every
target #1111 covers.

A CTE column can also be a `bigint` on PostgreSQL that the CTE types as a plain integer: `Count`,
`Sum` of an integer column, and the ranking windows all return `bigint` there. Divided directly it
splits nothing (`bigint / integer` divides as an integer on both engines), but an outer `Sum` over it
is `sum(bigint)`, a `numeric`, so `Sum(CTE("totals", "n_results")) / 2` keeps the half on PostgreSQL
only. The body records that too, and the outer `Sum` is refused as `Sum("resultid") / 2` is.

The same fix closes a sibling: `bigint / integer` is still a `bigint` on PostgreSQL, so
`Sum(F("resultid") / 2)` sums a `bigint` and is refused once divided, and so is a nested quotient
(`Sum((F("resultid") / 2) / 2)`). A float divisor makes the sum a float on both engines, which the
float rules already handle.

Unchanged: a CTE column of `Sum` over an `IntegerField`, `Max`, `Min` or `Count` divided directly, or
under `Coalesce`/`Max` and then divided, which both engines divide as integers; any CTE column under
`+`, `-`, `*` or cast directly.

### Who this affects

Code that projects `Sum` of an `IDField`, a `BigIntegerField`, a `ForeignKey` or a `OneToOneField` in
a `.with(...)` body and divides that column in the outer query, or projects `Count`, `Sum` of an
integer or a ranking window and divides an outer `Sum` over it, inside `Concat`, `Cast`, or a
`Coalesce`/`Greatest`/`Least` with an `output_field`. Running the query is the definitive check: the
refusal names the operand as ``the CTE column `CTE("…", "…")` (`SUM(…)` over the IDField `…`)`` and
says that SQLite divides it as an integer.

### How to find the calls to migrate

```bash
grep -rnE 'CTE\(|\.with\(' --include=*.jl src/ test/
```

For each `.with(...)` body that projects a `Sum`, read the outer query for a `/` over that column.

### Migrate your app

As for the `Sum` alone (#1111): divide as a float, so both engines keep the half, then say how to
round; or fetch the number and compute in Julia.

```julia
# ✗ before — rounds 7.5 to 8 on PostgreSQL, truncates to 7 on SQLite
q.values("raceid", "half" => Cast(Coalesce(CTE("totals", "id_sum"), 0) / 2, IntegerField()))

# ✓ after — a float division has the half on both engines; Round(x) then reads the same integer
q.values("raceid", "half" => Cast(Round(Coalesce(CTE("totals", "id_sum"), 0) / 2.0), IntegerField()))
```
