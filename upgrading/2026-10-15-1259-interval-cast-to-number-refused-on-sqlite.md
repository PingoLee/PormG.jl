## An interval cast to a number is refused on SQLite, which read its text's hours (#1259)

- **Version**: 0.9.0
- **PormG ref**: #1259 ; `src/querybuilder/engine_departures.jl` (`_MEANING_DEPARTURES`), `src/querybuilder/projection_types.jl` (`_cast_divergent_operand`, `_interval_operand`)
- **Recorded**: 2026-10-15
- **Severity**: behavior change. Expressions that built on SQLite now raise `QueryBuildError` when the query is built. PostgreSQL is unchanged.

### What changed

An interval has no numeric value. PostgreSQL rejects `interval::integer`, `interval::numeric` and
`interval::double precision` when the query runs, and that error is the meaning. SQLite stores a
duration as its `HH:MM:SS.sss` text, and its `CAST(x AS INTEGER)`, `AS REAL` and `AS NUMERIC` read
that text's leading digits: the hours, so `00:01:23.456` became `0`. That was a silent wrong answer.

PormG now refuses the cast on SQLite, the engine that answered wrongly, and builds it as before on
PostgreSQL, where the server still raises. The refusal covers a `DurationField` column, its `Sum` and
its `Avg`, a duration literal and temporal arithmetic, cast to any number type (`IntegerField()`,
`BigIntegerField()`, `FloatField()`, `"integer"`, `"bigint"`, `"float8"`, `"numeric"`,
`"numeric(p, s)"`, …), as a `Cast` type and as the `output_field` of `Case`, `Coalesce`, `Greatest`
and `Least`. `Cast(Avg(<interval>), IntegerField())` and a cast of it to `numeric(p, s)` were already
refused on SQLite, as a fraction; they are refused as an interval now.

Examples on `Result`, whose `fastestlaptime` is a `DurationField`:

| expression | PostgreSQL | SQLite before | SQLite now |
|---|---|---|---|
| `Cast("fastestlaptime", IntegerField())` | raises when the query runs | the hours (`0`) | raises `QueryBuildError` (#1259) |
| `Cast("fastestlaptime", "numeric")`, `Cast("fastestlaptime", FloatField())` | raises when the query runs | the hours | raises `QueryBuildError` (#1259) |
| `Cast(Sum("fastestlaptime"), "bigint")` | raises when the query runs | the hours of the sum | raises `QueryBuildError` (#1259) |
| `Cast(Avg("fastestlaptime"), FloatField())` | raises when the query runs | the hours of the average | raises `QueryBuildError` (#1259) |
| `Coalesce("fastestlaptime", Value(Minute(1)); output_field = "integer")` | raises when the query runs | the hours | raises `QueryBuildError` (#1259) |
| `Cast("fastestlaptime", "text")` | the interval's text | the stored text | builds, unchanged |

### Who this affects

On SQLite, code that casts a `DurationField`, a sum of one or a duration computed from timestamps to
a number type, or passes a number `output_field` over one. The same code already failed on
PostgreSQL.

### How to find the calls to migrate

```bash
grep -rnE 'Cast\(|output_field' --include=*.jl src/ test/ | grep -iE 'Integer|Float|Decimal|"(integer|bigint|int[248]?|smallint|real|float[48]?|double precision|numeric|decimal)'
```

For each match, check whether the operand is a duration.

### Migrate your app

```julia
# ✗ before — the hours on SQLite, an error on PostgreSQL; now raises QueryBuildError on SQLite (#1259)
q = M.Result.objects
q.values("t" => Cast("fastestlaptime", IntegerField()))

# ✓ after — fetch the duration and take the number in Julia
q = M.Result.objects
q.values("t" => "fastestlaptime")
```
