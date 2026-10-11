## `Cast` of a boolean to text, or of a fraction to an integer, is refused on SQLite; more `Concat` operands are refused (#1028)

- **Version**: Unreleased
- **PormG ref**: #1028, amended by #1147 ; `src/querybuilder/projection_types.jl` (`_cast_divergent_operand`, `_concat_textless_operand`), `src/querybuilder/engine_departures.jl` (`_MEANING_DEPARTURES`), `src/querybuilder/select_nodes.jl`, `src/querybuilder/functions.jl`, `src/querybuilder/ctes.jl`
- **Recorded**: 2026-10-08
- **Severity**: breaking. On SQLite, a `Cast` (or an `output_field` cast) of a boolean to text, or of a fractional number to an integer, raises `QueryBuildError` where it used to render. On every engine, a `Concat` with a timestamp, interval or JSON-document operand does.

### What changed

A cast goes through each engine's own conversion. Measured on PostgreSQL 16.15 and SQLite 3.45.1:

| expression | PostgreSQL | SQLite |
|---|---|---|
| `Cast(<bool> true, CharField())` | `'true'` | `'1'` |
| `Cast(<float> 1.5, IntegerField())` | `2` | `1` |
| `Cast(<numeric> 2.5, IntegerField())` | `3` | `2` |
| `Cast("points", CharField())`, a float `10.0` | `'10'` | `'10.0'` |
| `Cast(<numeric(10,2)> 14, CharField())` | `'14.00'` | `'14'` |

Each cast is checked against what it means, and the engine that computes something else refuses it
(#1147):

- a boolean cast to text means `'true'`/`'false'`. SQLite has no boolean and writes `'1'`, so it
  refuses the cast; PostgreSQL builds it;
- a fractional number cast to an integer (a float, a decimal with places, a function PostgreSQL
  computes as `numeric`) means the nearest integer. SQLite's cast truncates, so it refuses the
  cast; PostgreSQL builds it. `Round(x)`, `Floor(x)`, `Ceil(x)` and whole numbers (`Mod` of
  integers, `+`/`-`/`*` of whole numbers) have nothing to round and build on both;
- a float, a decimal, a timestamp, an interval or a JSON document cast to text is the same value
  written in each engine's own text. It builds on both engines, as in v0.7.0, a quotient over a
  decimal or over a value mixing whole numbers and fractions included: SQLite divides it as `REAL`
  (see the #1150 entry).

`Concat` refuses three more operand types on every engine, because the query does not say which
text it means (see #1027): a timestamp (a column, `F("start_at") + Day(1)`, a `DateTime` literal,
refused when the `Concat` is built), an interval (a `DurationField`, a timestamp difference, `Sum`
of a duration, a `Period` literal) and a whole JSON document. A CTE column built from an aggregate
(`Sum("points")`, `Avg("number")`) is classified by the body's own expression, so it is refused
where the aggregate is.

Unchanged: a cast of an integer, text, date, time or uuid; a boolean cast to an integer; a cast to
any other type (`"numeric"`, `"double precision"`, `"date"`; a scaled `"numeric(10,2)"` is checked
since #1040); a JSON key lookup in `Concat` (`"payload__driver"`); `Case(…; output_field)`; and the
`@yyyy_q` / `@yyyy_quad` labels.

### Who this affects

Code that, on SQLite, casts a boolean to text or a float or decimal to an integer in SQL, and code
that concatenates a timestamp, interval or JSON column. A query refused on SQLite only is still
built on PostgreSQL; its tests need to run there.

### How to find the calls to migrate

```bash
grep -rnE 'Cast\(|output_field *=|Concat\(' --include=*.jl src/ test/
```

Read each hit for a cast to text of a boolean, a cast to an integer of a float or decimal, and a
`Concat` operand that is a timestamp, interval or JSON column. Running the query is the definitive
check: the refusal message names the operand, the engine and #1028.

### Migrate your app

```julia
# ✗ before — 1.5 reads 2 on PostgreSQL and 1 on SQLite, which now refuses it
M.Result.objects.values("resultid", "pts" => Cast("points", IntegerField()))
# ✓ after — say how to round: Round, Floor or Ceil read the same integer on both engines
M.Result.objects.values("resultid", "pts" => Cast(Round("points"), IntegerField()))

# ✗ before — refused: which text of `start_at` is meant?
M.Race.objects.values("raceid", "label" => Concat("name", Value(" @ "), "start_at"))
# ✓ after — name the format, the same text on both engines
M.Race.objects.values("raceid", "label" => Concat("name", Value(" @ "), ToChar("start_at", "YYYY-MM-DD HH:MI:SS")))
```
