## `Sum` of a `bigint` is an integer on PostgreSQL, and a cross-engine refusal fires only on the engine that departs (#1147)

- **Version**: Unreleased
- **PormG ref**: #1147 ; `src/Dialect.jl` (`SUM`), `src/querybuilder/expression_kind.jl` (`_sums_bigint`, `_operation_kind`), `src/querybuilder/engine_departures.jl` (`_MEANING_DEPARTURES`), `src/querybuilder/projection_types.jl` (`_cast_divergent_operand`, `_whole_numeric_operand`), `src/querybuilder/select_nodes.jl`, `src/querybuilder/functions.jl`
- **Recorded**: 2026-10-11
- **Severity**: behavior change. On PostgreSQL a `Sum` over a `bigint` reads an `Int64` where it read a `Decimal`, a quotient over it truncates, and a sum past the `bigint` range raises. Refusals added earlier in this release now fire on one engine only, and some no longer fire at all (see the table). A few shapes that built in v0.7.0 and answered differently per engine now raise `QueryBuildError` on SQLite: a `DecimalField` divided under `Floor`/`Ceil`/`Abs`, and a value mixing whole numbers and fractions (`Coalesce("grid", 0.5)`, a window with a fractional `default`), divided, then cast to an integer or a scale.

### What changed

**`Sum` over a `bigint` is an integer on PostgreSQL.** Django's `Sum` of an integer field is an
integer, and SQLite sums integers as integers. PostgreSQL sums a `smallint` or an `integer` to a
`bigint`, but widens the sum of a `bigint` to `numeric`. The operand is a `bigint` for an `IDField`,
a `BigIntegerField`, a `ForeignKey` or `OneToOneField`, an integer literal (PormG binds it as
`$n::bigint`), a `Case` or `Coalesce` of those, and integer arithmetic over one, a bitwise operator
or a shift included (a shift has its left operand's type: `Sum(F("resultid") << 1)`). PormG now renders
`SUM(x)::bigint` there. Measured through the F1 fixture on PostgreSQL 16:

| expression | before, PostgreSQL | after, PostgreSQL | SQLite (unchanged) |
|---|---|---|---|
| `Sum("resultid")` | a `Decimal` | an `Int64` | an `Int64` |
| `Sum("resultid") / 2` over results 1 and 2 | `1.5` | `1` | `1` |
| `Sum(Case(When("positionorder__@lte" => 3, then = 1), default = 0))` | a `Decimal` | an `Int64` | an `Int64` |
| `Sum(F("grid") + 1)` | a `Decimal` | an `Int64` | an `Int64` |
| a sum past `9223372036854775807` | an exact `numeric` | raises `bigint out of range` | raises `integer overflow` |

A sum of an `IntegerField` (already a `bigint` there), of a float, of a decimal or of a duration is
unchanged. `Floor`, `Ceil` and `Abs` over integer arithmetic (`Floor(F("grid") + 1)`) now keep the
integer on PostgreSQL too, as over an integer column; see the `Floor`/`Ceil`/`Abs` entry of this
release.

**Each refusal fires on the engine that departs from the meaning.** The refusals #1027, #1028,
#1040, #1087, #1111, #1124, #1127, #1135 and #1141 added earlier in this release fired on both
engines whenever SQLite would answer differently, so a PostgreSQL connection refused queries it
answers exactly. Each is now checked against what the expression means:

| expression | after |
|---|---|
| `Concat` over a boolean, float, decimal, timestamp, interval or JSON document | refused on every engine: say which text you mean, `Cast(x, "text")` (unchanged in effect; the message now names the cast) |
| `Cast(x, "text")` of a float, a decimal, a `numeric` function, a timestamp, an interval or a JSON document | **builds on every engine**, as in v0.7.0; each engine writes its own text |
| `Cast(<boolean>, "text")` | refused on SQLite only (it writes `1`); builds on PostgreSQL (`true`) |
| `Cast(<fraction>, IntegerField())` | refused on SQLite only (it truncates); builds on PostgreSQL (rounds) |
| `Cast(x, "numeric(p, s)")` with more than `s` places | refused on SQLite only (it keeps every digit) |
| `Cast(<literal>, "numeric(p, s)")` too large for `p` | refused on SQLite only; PostgreSQL builds and raises when the query runs |
| a `DecimalField` divided (`F("price") / 2`, `Sum("price") / Count("id")`), or an integer cast to `numeric` and divided, then cast — to text too — directly or under `Floor`/`Ceil`/`Abs` | refused on SQLite only (it stores a whole decimal as an integer and divides it as one); concatenated, refused on every engine as a decimal |
| a value mixing whole numbers and fractions (`Coalesce("grid", 0.5)`, `Least("grid", "points")`, `NullIf("grid", 0.5)`, a `Case` with an integer and a float branch, a `Lag`/`Lead` with a fractional `default`), divided, then cast — to text too | refused on SQLite only: PostgreSQL resolves the value to a float or a `numeric`, and SQLite divides the rows holding an integer as integers; concatenated, refused on every engine as a float |
| `Sum` of a `bigint`, divided, cast or concatenated, a CTE column of one included | **builds on every engine** (the `::bigint` above) |
| a `Sum` over a bitwise operator or a shift (`Sum(F("resultid") << 1)`), divided | **builds on every engine** (the `::bigint` above, #1153) |
| a `Sum` PormG cannot type as an integer, divided | refused on PostgreSQL only |
| `Round(<text>, d)` | refused on every engine (unchanged) |

Refusal messages name the meaning and the engine at hand, never a pair: ``Cast(…, "integer") of the
FloatField `points` means the nearest integer (`1.5` → `2`); SQLite computes the truncated one
(`1`), so PormG refuses it on SQLite (#1028).``

The entries for #1111, #1127, #1135 and #1141 are removed from this release: everything they
refused now builds on both engines and agrees. The entries for
#1027, #1028, #1040 and #1124 are amended to the table above.

### Who this affects

Code on PostgreSQL that reads a `Sum` over an `IDField`, a `BigIntegerField`, a `ForeignKey`, an
integer literal (a conditional count, `Sum(Case(When(…, then = 1), default = 0))`) or integer
arithmetic, and expects a `Decimal`, or divides it and expects the fraction.

### How to find the calls to migrate

```bash
grep -rn 'Sum(' --include=*.jl src/ test/
```

Read each hit whose operand is one of the above and whose value is compared with, or converted
from, a `Decimal`.

### Migrate your app

```julia
# ✗ before — on PostgreSQL the conditional count read a Decimal
podiums = M.Result.objects.values("podiums" => Sum(Case(When("positionorder__@lte" => 3, then = 1), default = 0))).list(:dict)
podiums[1][:podiums] isa Decimal   # PostgreSQL only

# ✓ after — it is an Int64 on both engines; convert explicitly if you need another type
podiums[1][:podiums] isa Int64

# ✓ to keep the fraction of a quotient, divide by a float
M.Result.objects.filter("resultid__@in" => [1, 2]).values("half" => Sum("resultid") / 2.0)
```
