## A date, timestamp or time cast to a number is refused on SQLite, which read its text's leading digits (#1260)

- **Version**: Unreleased
- **PormG ref**: #1260 ; `src/querybuilder/engine_departures.jl` (`_MEANING_DEPARTURES`), `src/querybuilder/projection_types.jl` (`_cast_divergent_operand`, `_temporal_number_operand`)
- **Recorded**: 2026-10-16
- **Severity**: behavior change. Expressions that built on SQLite now raise `QueryBuildError` when the query is built. PostgreSQL is unchanged.

### What changed

A date, a timestamp and a time have no numeric value, the same meaning #1259 gave an interval.
PostgreSQL rejects `date::integer`, `timestamptz::numeric`, `time::double precision` and the rest when
the query runs, and that error is the meaning. SQLite stores each as text, and its
`CAST(x AS INTEGER)`, `AS REAL` and `AS NUMERIC` read that text's leading digits: `2009-03-29` and
`2009-03-29T06:00:00.000+00:00` became `2009`, the year, and `06:00:00` became `6`, the hour. That
was a silent different answer.

PormG now refuses the cast on SQLite and builds it as before on PostgreSQL, where the server still
raises. The refusal covers a `DateField`, `DateTimeField` or `TimeField` column (a CTE column holding
one included), `Max`/`Min` of one, a cast to `date`, date arithmetic (`F("date") + Day(1)`) and a
`Date`, `DateTime`, `ZonedDateTime` or `Time` literal, cast to any number type (`IntegerField()`,
`BigIntegerField()`, `FloatField()`, `"integer"`, `"float8"`, `"numeric"`, `"numeric(p, s)"`, …), as a
`Cast` type and as the `output_field` of `Case`, `Coalesce`, `Greatest` and `Least`. A part
(`"date__@year"`, `Extract("date", "year")`, `"time__@hour"`) and a day count (`F("date") - F("date")`)
are numbers and build on every engine, as before.

Examples on `Race`, whose `date` is a `DateField`, `start_at` a `DateTimeField` and `time` a
`TimeField`:

| expression | PostgreSQL | SQLite before | SQLite now |
|---|---|---|---|
| `Cast("date", IntegerField())` | raises when the query runs | the year (`2009`) | raises `QueryBuildError` (#1260) |
| `Cast("start_at", FloatField())`, `Cast("start_at", "numeric")` | raises when the query runs | the year | raises `QueryBuildError` (#1260) |
| `Cast("time", IntegerField())` | raises when the query runs | the hour (`6`) | raises `QueryBuildError` (#1260) |
| `Coalesce("date", Value(Date(2009, 3, 29)); output_field = "integer")` | raises when the query runs | the year | raises `QueryBuildError` (#1260) |
| `Cast("date__@year", IntegerField())`, `Cast(F("date") - F("date"), IntegerField())` | the year, the day count | the same | builds, unchanged |

### Who this affects

On SQLite, code that casts a date, a timestamp or a time to a number type, or passes a number
`output_field` over one. The same code already failed on PostgreSQL.

### How to find the calls to migrate

```bash
grep -rnE 'Cast\(|output_field' --include=*.jl src/ test/ | grep -iE 'Integer|Float|Decimal|"(integer|bigint|int[248]?|smallint|real|float[48]?|double precision|numeric|decimal)'
```

For each match, check whether the operand is a date, a timestamp or a time.

### Migrate your app

```julia
# ✗ before — the year on SQLite, an error on PostgreSQL; now raises QueryBuildError on SQLite (#1260)
q = M.Race.objects
q.values("y" => Cast("date", IntegerField()))

# ✓ after — name the part that is the number, which is the same on every engine
q = M.Race.objects
q.values("y" => "date__@year")
```
