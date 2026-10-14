## A `Sum` PormG cannot type, divided and then cast or concatenated, is refused on PostgreSQL whatever it holds (#1034, #1111)

- **Version**: Unreleased
- **PormG ref**: #1034 (phase 3, step 2a), #1111 ; `src/querybuilder/projection_types.jl` (`_whole_numeric_operand`), `src/querybuilder/engine_facts.jl` (`_untyped_sum_departs`)
- **Recorded**: 2026-10-14
- **Severity**: behavior change. Some expressions that built on PostgreSQL now raise `QueryBuildError` when the query is built. The #1111 refusal's message changes for the ones it already refused, and one false refusal of a temporal sum is lifted. SQLite is unchanged.

### What changed

A `Sum` over a number PormG cannot type (arithmetic with a JSON key's value, an `Extract` part it
states no type for), divided, may be a `bigint` or a `numeric` sum. PostgreSQL computes either as a
`numeric`, so the quotient keeps the half (`15 / 2` is `7.5`) where an integer quotient is `7`. When
the quotient is cast to an integer, to text or to `numeric(p, s)`, or used inside `Concat`, PormG
refuses it on PostgreSQL (#1111). That holds with a rounding function between the division and the
cast, and for any divisor that is not a float.

PormG used to refuse it only when it could see a `bigint` column inside the untyped operand, and
built it otherwise. An untyped sum's type is unknown, so it is now refused whatever the sum holds.
Measured on PostgreSQL 16, `Sum(F("year") + Extract("start_at", "EPOCH")) / 2` over the `integer`
column `year` reads back as a `numeric` with the half kept, as the `bigint` version does.

Examples on `Race`, on PostgreSQL:

| expression | before | now |
|---|---|---|
| `Cast(Sum(F("year") + Extract("start_at", "EPOCH")) / 2, IntegerField())` | built | raises `QueryBuildError` (#1111) |
| `Cast(Round(Sum(F("year") + Extract("start_at", "EPOCH")) / 2), IntegerField())` | built | raises `QueryBuildError` (#1111) |
| `Cast(Sum(F("year") + Extract("start_at", "EPOCH")) / Count("raceid"), IntegerField())` | built | raises `QueryBuildError` (#1111) |
| `Concat("name", Sum(F("year") + Extract("start_at", "EPOCH")) / 2)` | built | raises `QueryBuildError` (#1111) |
| `Cast(Sum(F("date") - F("date")) / 2, IntegerField())` (a day count, which PormG does not type yet) | built | raises `QueryBuildError` (#1111) |
| `Cast(Sum(F("raceid") + Extract("start_at", "EPOCH")) / 2, IntegerField())` (a `bigint` column) | raised, naming "`SUM(…)` over the IDField `raceid`" | raises, naming "`SUM(…)` over a value PormG cannot type" |
| the same with a typed dividend, `Cast(Cast(Sum(…), BigIntegerField()) / 2, IntegerField())` | built | builds |
| the same divided by a float, `… / 2.0` | built | builds |

A sum of temporal arithmetic is not a number of unknown type. PormG's type walk cannot type it
either, but the query's render types it as an interval or a timestamp, so it is not refused as a
division:
- `Cast(Sum(F("fastestlaptime") * 2) / 2, "text")` on `Result` was refused on PostgreSQL through the
  integer literal. It now builds, as it does on SQLite;
- `Cast(Sum(F("fastestlaptime") + F("fastestlaptime")) / 2, "text")` and
  `Cast(Sum(F("grid") * F("fastestlaptime")) / 2, "text")` build on both engines, as before;
- `Concat` over the same is refused on both engines as explicit intent (#1028), as before.

A date difference renders as a day count, a number, so a sum over it stays a division: beside a
`bigint` column (`Sum(F("date") - F("date") + F("raceid"))`) it was refused and still is, and alone it
is now refused too (the table above) until PormG types a day count.

Unchanged: a `Sum` PormG types (of integers, of a float, of a decimal), every expression on SQLite,
and a bare quotient that is projected rather than cast or concatenated.

### Who this affects

On PostgreSQL, code that divides a `Sum` whose operand mixes a number column with a value PormG
cannot type, and then casts the quotient (`Cast(…, IntegerField())`, `Cast(…, CharField())`,
`Cast(…, "numeric(p,s)")`, an `output_field`) or puts it in `Concat`. Arithmetic between a number
column and a JSON key's text fails on PostgreSQL when the query runs, so most JSON-key shapes did not
run there; `Extract` parts with no stated type did. Code that matches the old refusal's text
(`over the BigIntegerField …`, `over the IDField …`) needs the new wording.

### How to find the calls to migrate

```bash
grep -rnE 'Sum\(.*(__|Extract\().*\) */ *[0-9]+[^.0-9]' --include=*.jl src/ test/
grep -rnE 'Sum\(.*(__|Extract\().*\) */ *Count\(' --include=*.jl src/ test/
```

For each match inside a `Cast(...)`, an `output_field` or a `Concat(...)`, check whether the summed
operand has a type PormG names (a column, an integer literal, a typed function).

### Migrate your app

```julia
# ✗ before — built on PostgreSQL; now raises QueryBuildError (#1111)
q = M.Result.objects
q.values("half" => Cast(Sum(F("grid") + Extract("raceid__start_at", "EPOCH")) / 2, IntegerField()))

# ✓ after — say which quotient you mean: an integer one …
q = M.Result.objects
q.values("half" => Cast(Cast(Sum(F("grid") + Extract("raceid__start_at", "EPOCH")), BigIntegerField()) / 2, IntegerField()))

# ✓ … or the fraction, divided by a float
q = M.Result.objects
q.values("half" => Cast(Sum(F("grid") + Extract("raceid__start_at", "EPOCH")) / 2.0, IntegerField()))
```
