## An integer date part counts as a whole number; a CTE `Sum` of one, summed again and divided, is refused (#1135)

- **Version**: Unreleased
- **PormG ref**: #1135, amended by #1147 ; `src/querybuilder/projection_types.jl` (`_known_whole`, `_integer_transform`)
- **Recorded**: 2026-10-10
- **Severity**: breaking. A `Concat` operand, or a `Cast` (or `output_field` cast) to text, to an integer or to `numeric(p, s)`, over `Sum(CTE(…)) / y` where the CTE column is a `Sum` of an integer date part — a `"col__@year"`-style path (`@year`, `@month`, `@day`, `@hour`, `@minute`, `@second`, `@week`, `@iso_year`, `@iso_week_day`, `@week_day`, `@quarter`, `@quadrimester`) or the same `Extract` field — raises `QueryBuildError` where it used to render.

### What changed

PormG decides in several places whether a value is a whole number. It counted an operand whole by
its field only, and a transformed path has none, so a date part was not one. A transformed path is
now read through the transform ladder, and a date part both engines compute as an integer counts as
a whole number, as an integer column does.

One refusal follows from it. A CTE column built from `Sum` of an integer is a `bigint` on
PostgreSQL, so an outer `Sum` over it is a `sum(bigint)`, a `numeric` that keeps the half once
divided, where SQLite's sum is an integer (#1127). That now holds for a `Sum` of a date part too:

```julia
body = M.Race.objects.values("circuitid", "years" => Sum("date__@year"))
M.Circuit.objects.with("c" => body, join_field = "circuitid" => "circuitid").
  values("x" => Cast(Sum(CTE("c", "years")) / 2, IntegerField()))   # refused
```

As first merged, #1135 also refused `Floor`, `Ceil` and `Abs` over an integer date part, divided:
PostgreSQL rendered `FLOOR((EXTRACT(YEAR FROM "Tb"."dob")::integer)::numeric) / $1::bigint`, which
kept the half. #1147, in the same release, makes them keep the integer on PostgreSQL (see its own
entry), so `Floor("dob__@year") / 2` divides as integers on both engines and is not refused.

Unchanged: a text transform (`@yyyy_mm`, `@yyyy_q`, `@yyyy_quad`) and `@date`, which are no whole
numbers; `Extract(…, "epoch")` and the sub-second parts, fractional on PostgreSQL; a part SQLite
has no spelling for (`Extract(…, "century")`, `"timezone_hour"`, an `Extract` `"quarter"` field),
which raises `BackendCapabilityError` there; and a date part divided directly
(`F("dob__@year") / 2`) or summed once (`Sum("dob__@year") / 2`), which both engines divide as
integers.

### Who this affects

Code that sums an integer date part in a CTE body, then sums that column again and divides it,
inside `Concat`, `Cast`, or a `Coalesce`/`Greatest`/`Least` with an `output_field`. Running the
query is the definitive check: the refusal names the CTE column and says that SQLite divides it as
an integer.

### How to find the calls to migrate

```bash
grep -rnE 'Sum\(("[^"]*__@|Extract\()' --include=*.jl src/ test/
```

For each match inside a CTE body, read the outer query for a `Sum` over that column and a `/` over it.

### Migrate your app

As for `Sum` of a BIGINT column (#1111): divide as a float, so both engines keep the half, then say
how to round; or fetch the number and compute in Julia.

```julia
# ✓ after — a float division has the half on both engines; Round(x) then reads the same integer
M.Circuit.objects.with("c" => body, join_field = "circuitid" => "circuitid").
  values("x" => Cast(Round(Sum(CTE("c", "years")) / 2.0), IntegerField()))
```
