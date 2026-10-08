## `Cast` to text or an integer, and more `Concat` operands, are refused when the engines disagree (#1028)

- **Version**: Unreleased
- **PormG ref**: #1028 ; `src/querybuilder/projection_types.jl` (`_cast_divergent_operand`, `_concat_textless_operand`), `src/querybuilder/select_nodes.jl`, `src/querybuilder/functions.jl`, `src/querybuilder/ctes.jl`
- **Recorded**: 2026-10-08
- **Severity**: breaking. A `Cast` (or an `output_field` cast) that each engine applies differently, and a `Concat` with a timestamp, interval or JSON-document operand, raise `QueryBuildError` where they used to render.

### What changed

#1027 refused a boolean, float or decimal `Concat` operand. A cast reaches the same divergence, and
three more `Concat` operand types differ too. Measured on PostgreSQL 16.15 and SQLite 3.45.1:

| expression | PostgreSQL | SQLite |
|---|---|---|
| `Cast("points", CharField())`, a float `10.0` | `'10'` | `'10.0'` |
| `Cast(<bool> true, CharField())` | `'true'` | `'1'` |
| `Cast(<numeric(10,2)> 14, CharField())` | `'14.00'` | `'14'` |
| `Cast(<float> 1.5, IntegerField())` | `2` | `1` |
| `Cast(<numeric> 2.5, IntegerField())` | `3` | `2` |
| `Concat(Value("\|"), "start_at")` | `\|2009-03-29 06:00:00+00` | `\|2009-03-29T06:00:00.000+00:00` |
| `Concat(Value("\|"), <interval>)` | `\|PT25.021S` (its `IntervalStyle`) | `\|00:00:26.898` |
| `Concat(Value("\|"), <JSONField>)` | `\|{"a": [1, 2]}` | `\|{"a":[1,2]}` |

Now refused, when the query is built, on both engines:

- a cast to text (`Cast`, or `output_field` on `Coalesce`/`Greatest`/`Least`) of a boolean, a
  float, a decimal, a function PostgreSQL computes as `numeric` (`Avg`, `Round`, …), a timestamp, an
  interval or a whole JSON document;
- a cast to an integer of a float, a decimal or a `numeric` function, unless the operand is
  `Round(x)`, `Floor(x)` or `Ceil(x)`, which agree on both engines, or a whole number (`Mod` of
  integers, `+`/`-`/`*` of whole numbers);
- a `Concat` operand that is a timestamp (a column, `F("start_at") + Day(1)`, a `DateTime` literal
  — refused when the `Concat` is built), an interval (a `DurationField`, a timestamp difference, `Sum`
  of a duration, a `Period` literal) or a whole JSON document;
- a CTE column built from such an aggregate (`Sum("points")`, `Avg("number")`), which `Concat` and
  `Cast` used to let through because the CTE typed it as an integer.

Unchanged: a cast of an integer, text, date, time or uuid; a boolean cast to an integer; a cast to
any other type (`"numeric"`, `"double precision"`, `"date"`; a scaled `"numeric(10,2)"` is checked
since #1040); a JSON key lookup
(`"payload__driver"`, which agrees when the value is a string; refused for a scaled numeric since
#1040); `Case(…; output_field)`; and the
`@yyyy_q` / `@yyyy_quad` labels.

### Who this affects

Code that casts a float, decimal or boolean to text or an integer in SQL, or that concatenates a
timestamp, interval or JSON column. Measured on 2026-10-08: **0** `Cast(` call sites over such an
operand in the consuming apps' Julia code (one comment casts an integer column, which is
unaffected), and **0** `Concat(` call sites (#1027).

### How to find the calls to migrate

```bash
grep -rnE 'Cast\(|output_field *=|Concat\(' --include=*.jl src/ test/
```

Read each hit for a cast to text or an integer over a float, decimal or boolean, and for a `Concat`
operand that is a timestamp, interval or JSON column. Running the query is the definitive check:
the refusal message names the operand and cites #1028.

### Migrate your app

```julia
# ✗ before — 1.5 reads 2 on PostgreSQL and 1 on SQLite
M.Result.objects.values("resultid", "pts" => Cast("points", IntegerField()))
# ✓ after — say how to round: Round, Floor or Ceil read the same integer on both engines
M.Result.objects.values("resultid", "pts" => Cast(Round("points"), IntegerField()))

# ✗ before — '10' on PostgreSQL, '10.0' on SQLite
M.Result.objects.values("resultid", "label" => Cast("points", CharField()))
# ✓ after — fetch the number and format it in Julia
df = M.Result.objects.values("resultid", "points") |> DataFrame
df.label = string.(df.points)

# ✗ before — '2009-03-29 06:00:00+00' on PostgreSQL, '2009-03-29T06:00:00.000+00:00' on SQLite
M.Race.objects.values("raceid", "label" => Concat("name", Value(" @ "), "start_at"))
# ✓ after — name the format
M.Race.objects.values("raceid", "label" => Concat("name", Value(" @ "), ToChar("start_at", "YYYY-MM-DD HH:MI:SS")))
```
