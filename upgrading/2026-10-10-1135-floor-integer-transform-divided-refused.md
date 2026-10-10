## `Floor`/`Ceil`/`Abs` over an integer date part, divided, is refused (#1135)

- **Version**: Unreleased
- **PormG ref**: #1135 ; `src/querybuilder/projection_types.jl` (`_known_whole`, `_integer_transform`)
- **Recorded**: 2026-10-10
- **Severity**: breaking. A `Concat` operand, or a `Cast` (or `output_field` cast) to text, to an integer or to `numeric(p, s)`, over `Floor`, `Ceil` or `Abs` of an integer date part, divided — a `"col__@year"`-style path (`@year`, `@month`, `@day`, `@hour`, `@minute`, `@second`, `@week`, `@iso_year`, `@iso_week_day`, `@week_day`, `@quarter`, `@quadrimester`) or the same `Extract` field — raises `QueryBuildError` where it used to render.

### What changed

#1111 refuses `Floor`, `Ceil` and `Abs` over a whole number once divided: PostgreSQL renders them
over `::numeric` and keeps the half, where SQLite divides the integer as an integer. It counted an
operand whole by its field only, and a transformed path has none, so it passed:

```julia
M.Driver.objects.values("x" => Cast(Floor("dob__@year") / 2, IntegerField()))   # built
M.Driver.objects.values("x" => Cast(Floor("number") / 2, IntegerField()))       # refused (#1111)
```

PostgreSQL rendered `FLOOR((EXTRACT(YEAR FROM "Tb"."dob")::integer)::numeric) / $1::bigint`, a
`numeric` that keeps the half; SQLite rendered `FLOOR(CAST(strftime('%Y', "Tb"."dob") AS INTEGER)) / ?`,
an integer division. So an odd year cast to an integer read one more on PostgreSQL than on SQLite. A
transformed path is now read through the transform ladder, and a date part both engines compute as
an integer counts as a whole number, as an integer column does.

Unchanged: a text transform (`@yyyy_mm`, `@yyyy_q`, `@yyyy_quad`) and `@date`, which are no whole
numbers; `Extract(…, "epoch")` and the sub-second parts, fractional on PostgreSQL; a part SQLite
has no spelling for (`Extract(…, "century")`, `"timezone_hour"`, an `Extract` `"quarter"` field),
which raises `BackendCapabilityError` there instead of dividing differently; a date part
undivided or under `+`, `-`, `*`; and a date part divided directly (`F("dob__@year") / 2`) or summed
(`Sum("dob__@year") / 2`), which both engines divide as integers.

### Who this affects

Code that wraps an integer date part in `Floor`, `Ceil` or `Abs` and divides the result, inside
`Concat`, `Cast`, or a `Coalesce`/`Greatest`/`Least` with an `output_field`. Running the query is
the definitive check: the refusal names the operand as ``arithmetic over `FLOOR(…)` `` and says that
SQLite divides it as an integer.

### How to find the calls to migrate

```bash
grep -rnE '(Floor|Ceil|Abs)\(.*(__@|Extract\()' --include=*.jl src/ test/
```

For each match, read the enclosing expression for a `/` over it.

### Migrate your app

As for `Floor` over an integer column (#1111): divide as a float, so both engines keep the half, then
say how to round; or fetch the number and compute in Julia.

```julia
# ✗ before — 1985 / 2 rounds to 993 on PostgreSQL, truncates to 992 on SQLite
M.Driver.objects.values("x" => Cast(Floor("dob__@year") / 2, IntegerField()))

# ✓ after — a float division has the half on both engines; Floor(x) then reads the same integer
M.Driver.objects.values("x" => Cast(Floor(F("dob__@year") / 2.0), IntegerField()))
```
