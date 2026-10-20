## A `Sum` PormG cannot type, divided and then cast or concatenated, is refused on PostgreSQL whatever it holds (#1034, #1111)

- **Version**: Unreleased
- **PormG ref**: #1034 (phase 3, step 2a), #1111, amended by #1305 ; `src/querybuilder/projection_types.jl` (`_whole_numeric_operand`, `_division_first`), `src/querybuilder/engine_facts.jl` (`_untyped_sum_departs`)
- **Recorded**: 2026-10-14
- **Severity**: behavior change. Some expressions that built on PostgreSQL now raise `QueryBuildError` when the query is built. The #1111 refusal's message changes for the ones it already refused, and one false refusal of a temporal sum is lifted. On SQLite, a cast or `Concat` of such a quotient combined with an interval, a float or a decimal now raises as the interval or fraction it is (#1305, below).

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

Unchanged: a `Sum` PormG types (of integers, of a float, of a decimal), on SQLite every expression
other than the #1305 rows below, and a bare quotient that is projected rather than cast or
concatenated.

> **Amended by #1305:** the quotient is found wherever it sits in the expression. PormG read only
> the first side, operand or branch that it could classify, so a quotient behind an interval or a
> float (`Max(…) * (Sum(…) / 2)`, a later `Coalesce` operand, a later `Case` branch) was not found.
> PostgreSQL kept the half there, where SQLite drops it. Beside an interval, a float or a decimal the
> quotient decides on PostgreSQL only. On SQLite, which divides it as an integer, the value is that
> interval or that fraction, and it is refused as one, on whichever side the quotient is. Before, the
> side read first decided, so `Max("points") * half` and `half * Max("points")` were refused on
> different engines. Examples on `Result`, where `half` is
> `Sum(F("grid") + Extract("raceid__start_at", "EPOCH")) / 2`:
>
> | expression | engine | before | now |
> |---|---|---|---|
> | `Cast(Max("fastestlaptime") * half, "text")` | PostgreSQL | built | raises `QueryBuildError` (#1111) |
> | `Cast(Max("fastestlaptime") / half, "text")` | PostgreSQL | built | raises `QueryBuildError` (#1111) |
> | `Cast(Max("fastestlaptime") * Round(half), "text")` | PostgreSQL | built | raises `QueryBuildError` (#1111) |
> | `Cast(Coalesce(Max("fastestlaptime"), half * Max("fastestlaptime")), "text")` | PostgreSQL | built | raises `QueryBuildError` (#1111) |
> | `Cast(Max("fastestlaptime") * half, IntegerField())` | PostgreSQL | built | raises `QueryBuildError` (#1111) |
> | `Concat(Value("-"), Max("fastestlaptime") * half)` | PostgreSQL | raised (#1028) | raises `QueryBuildError` (#1111) |
> | `Cast(half * Max("fastestlaptime"), IntegerField())` | SQLite | built | raises `QueryBuildError` (#1259, an interval cast to a number) |
> | `Concat(Value("-"), half * Max("fastestlaptime"))` | SQLite | built | raises `QueryBuildError` (#1028, an interval is not text) |
> | `Cast(Max("points") * half, IntegerField())` | PostgreSQL | built | raises `QueryBuildError` (#1111) |
> | `Cast(half * Max("points"), IntegerField())`, `Cast(half * 1.5, IntegerField())`, `Cast(Coalesce(half, 0.5), IntegerField())` | SQLite | built | raises `QueryBuildError` (#1028, a fraction cast to an integer) |
> | `Cast(half * 1.5, "numeric(10,1)")` | SQLite | built | raises `QueryBuildError` (#1040, a scale it would round) |
> | `Concat(Value("-"), half * 1.5)` | SQLite | built | raises `QueryBuildError` (#1027, a float is not text) |
>
> Each of these casts to `"text"` still builds on SQLite.

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
